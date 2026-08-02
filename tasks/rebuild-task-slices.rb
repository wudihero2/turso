#!/usr/bin/env ruby
# frozen_string_literal: true

# Rebuilds source-task slices from the locked revision. It preserves chapter
# prose and milestones, but derives every slice and Source units count from the
# same SourceUnits::Unit objects used by the linter.

require "open3"
require_relative "learning_inventory"
require_relative "source_units"

LOCKED_COMMIT = "d7370df0170763e8a8a0db4542a1a181372b8895"
TASK_PATTERN = File.expand_path("[0-1][0-9]-*.md", __dir__)
MAX_LINES = 300
MAX_UNITS = 4

MILESTONE_SUMMARIES = {
  "00-parser" => "SQL lexer/token/AST/parser/formatter與 parser 原測試完整重建。",
  "01-values-schema-records" => "values/schema/catalog/record encoding-decoding與原測試完整重建。",
  "02-page-pager" => "allocator、error、IOResult/completion、platform I/O、header/page/cache/pager與原測試完整重建。",
  "03-btree-cursor" => "B-tree/cursor/seek/scan/write/delete/overflow/balance與原測試完整重建。",
  "04-bytecode-vm" => "bytecode data model、program/cursors/sorter/hash及完整 opcode interpreter與原測試完整重建。",
  "05-compiler-basic-sql" => "dialect/prepare/Plan/planner skeleton/main loop與 CREATE/CRUD compiler及原測試完整重建。",
  "06-expressions-functions" => "value semantics、functions/expressions、aggregate/order/subquery/compound/CTE/window與原測試完整重建。",
  "07-indexes-planner" => "index DDL/DML/statistics與 optimizer constraints/access/cost/order/join/multi-index/rewrite及原測試完整重建。",
  "08-transactions-wal-io" => "transaction/savepoint/statement journal、WAL/shared coordination/checkpoint、resumable I/O與 TLA+ model完整重建。",
  "09-sql-features" => "constraints/FK/views/triggers/ALTER/ATTACH/PRAGMA/VACUUM/integrity/vtab/JSON/vector/index methods/custom types/CDC與原測試完整重建。",
  "10-interfaces-extensions-testing" => "remaining core support/skiplist/vtabs/blob、public APIs、所有 bindings/SDKs/serverless drivers、CLI/extensions/testing/differential tooling、Turso-owned benchmarks/perf harnesses/runnable examples與各自原 build/tests完整重建。",
  "MVCC" => "MVCC transactions/cursors/durable logical log/recovery/checkpoint/yield injection與原測試完整重建。",
  "Incremental-view" => "incremental/DBSP operators/compiler/materialized views/persistence與原測試完整重建。",
  "Sync" => "CDC tape/replay/lazy storage/sync engine/sync SDK kit與原測試完整重建。",
  "PostgreSQL" => "PostgreSQL parser/translator/frontend/catalog/session/COPY/wire server/client/CLI、golden outputs與原測試完整重建。"
}.freeze

def command_output(*command)
  output = IO.popen(command, &:read)
  abort "command failed: #{command.join(' ')}" unless $?.success?
  output
end

def read_locked_blobs(blob_ids)
  contents = {}
  Open3.popen3("git", "cat-file", "--batch") do |stdin, stdout, stderr, wait_thread|
    writer = Thread.new do
      blob_ids.each_value { |blob_id| stdin.puts(blob_id) }
      stdin.close
    end

    blob_ids.each do |path, expected_blob_id|
      header = stdout.gets
      abort "git cat-file ended before #{path}" if header.nil?

      blob_id, object_type, size_text = header.split
      unless blob_id == expected_blob_id && object_type == "blob"
        abort "expected blob #{expected_blob_id} for #{path}, got #{header.inspect}"
      end

      contents[path] = stdout.read(Integer(size_text, 10))
      abort "missing git cat-file separator after #{path}" unless stdout.read(1) == "\n"
    end

    writer.join
    error_output = stderr.read
    abort "git cat-file failed: #{error_output}" unless wait_thread.value.success?
  end
  contents
end

def line_count(content)
  return 0 if content.empty?

  content.count("\n") + (content.end_with?("\n") ? 0 : 1)
end

def task_records(path, content)
  units = SourceUnits.for(path, content)
  return [{ kind: :source, path: path, range: nil, units: [] }] if units.empty?

  units.each do |unit|
    size = unit.last_line - unit.first_line + 1
    abort "#{path}:L#{unit.first_line}-L#{unit.last_line} is one #{size}-line unit; refine tasks/source_units.rb" if size > MAX_LINES
  end

  groups = []
  current = []
  units.each do |unit|
    prospective_lines = current.empty? ? unit.last_line - unit.first_line + 1 : unit.last_line - current.first.first_line + 1
    if !current.empty? && (current.length == MAX_UNITS || prospective_lines > MAX_LINES)
      groups << current
      current = []
    end
    current << unit
  end
  groups << current unless current.empty?

  groups.map do |group|
    {
      kind: :source,
      path: path,
      range: (group.first.first_line..group.last.last_line),
      units: group
    }
  end
end

def source_task_line(record, id)
  path = record.fetch(:path)
  units = record.fetch(:units)
  task_id = format("%03d", id)
  if units.empty?
    return "- [ ] T#{task_id}. 搬入空的 Python package marker `#{path}`；保留空檔，讓原 package/test discovery 行為一致。 Source units: 0. Source basis: `#{path}`.\n"
  end

  range = record.fetch(:range)
  labels = units.flat_map(&:labels).uniq.first(3).map do |label|
    clean_label = label.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    "`#{clean_label.gsub('`', "'")}`"
  end
  boundary_text = labels.empty? ? "檔案中的完整邊界" : labels.join("、")
  "- [ ] T#{task_id}. 搬入 `#{path}` 的 L#{range.begin}–L#{range.end}；此 slice 包含 #{units.length} 個 SourceUnits::Unit，邊界代表為 #{boundary_text}。 Source units: #{units.length}. Source basis: `#{path}`. Source slices: #{path}:L#{range.begin}-L#{range.end}\n"
end

def advanced_source?(path)
  %w[core/incremental/ core/mvcc/ incremental/ postgres/ sync/ testing/concurrent-simulator/ testing/simulator/ tlaplus/].any? do |prefix|
    path.start_with?(prefix)
  end
end

def milestone_key(description)
  return "Final closure audit" if description.start_with?("Final closure audit")

  description.split(" milestone", 2).first
end

repository_root = File.expand_path("..", __dir__)
Dir.chdir(repository_root)

tree_entries = command_output("git", "ls-tree", "-r", LOCKED_COMMIT).lines.to_h do |line|
  match = line.chomp.match(/\A(\d+) \w+ ([0-9a-f]+)\t(.+)\z/)
  abort "unexpected git ls-tree output: #{line.inspect}" if match.nil?

  [match[3], [match[1], match[2]]]
end
locked_contents = read_locked_blobs(tree_entries.transform_values(&:last))
learning_paths = LearningInventory.learning_paths(tree_entries.transform_values(&:first), locked_contents)
learning_set = learning_paths.to_h { |path| [path, true] }
sync_manifest_rows = File.foreach(File.expand_path("sync-only-manifest.tsv", __dir__)).each_with_object([]) do |line, rows|
  next if line.start_with?("#") || line.strip.empty?

  rows << line.split("\t", 2).first
end
sync_copy_count = sync_manifest_rows.count("copy")
sync_exclude_count = sync_manifest_rows.count("exclude")

task_files = Dir[TASK_PATTERN].sort
seen_paths = {}
entries_by_file = {}

task_files.each do |task_file|
  entries = []
  File.foreach(task_file) do |line|
    next if line.match?(/\A## (?:Advanced )?Runtime、fixture|\A## Advanced runtime、golden/)

    match = line.match(/\A- \[ \] T(\d+)\./)
    unless match
      entries << line
      next
    end

    old_id = Integer(match[1], 10)
    if line.include?("Task kind: milestone")
      description = line[/\A- \[ \] T\d+\.\s*(.*?)\s*Source basis:/, 1]
      abort "cannot parse milestone T#{old_id} in #{task_file}" if description.nil?
      entries << { kind: :milestone, old_id: old_id, description: description }
      next
    end

    paths = line.split("Source basis:", 2).last.to_s.scan(/`([^`]+)`/).flatten
    abort "source T#{old_id} does not own exactly one path" unless paths.length == 1

    path = paths.first
    next unless learning_set[path]
    next if seen_paths[path]

    seen_paths[path] = task_file
    entries.concat(task_records(path, locked_contents.fetch(path)))
  end
  entries_by_file[task_file] = entries
end

missing_paths = learning_paths.reject { |path| seen_paths[path] }
relocatable_resources = LearningInventory.relocatable_resource_paths(
  tree_entries.transform_values(&:first),
  locked_contents
)
resource_set = relocatable_resources.to_h { |path| [path, true] }

missing_by_file = missing_paths.reject { |path| resource_set[path] }.group_by do |path|
  advanced_source?(path) ? task_files.last : task_files[-2]
end

missing_by_file.each do |task_file, paths|
  entries = entries_by_file.fetch(task_file)
  insertion_index = entries.rindex { |entry| entry.is_a?(Hash) && entry[:kind] == :milestone }
  abort "#{task_file} has no closing milestone" if insertion_index.nil?

  additions = []
  paths.sort.each do |path|
    additions.concat(task_records(path, locked_contents.fetch(path)))
    seen_paths[path] = task_file
  end
  entries.insert(insertion_index, *additions)
end

resource_records = Hash.new { |hash, key| hash[key] = [] }
entries_by_file.each_value do |entries|
  entries.delete_if do |entry|
    next false unless entry.is_a?(Hash) && entry[:kind] == :source && resource_set[entry.fetch(:path)]

    resource_records[entry.fetch(:path)] << entry
    true
  end
end
missing_paths.select { |path| resource_set[path] }.each do |path|
  resource_records[path].concat(task_records(path, locked_contents.fetch(path)))
end

path_order = {}
order = 0
task_files.each do |task_file|
  entries_by_file.fetch(task_file).each do |entry|
    next unless entry.is_a?(Hash) && entry[:kind] == :source

    path = entry.fetch(:path)
    path_order[path] ||= order
    order += 1
  end
end
relocatable_resources.each do |path|
  path_order[path] ||= order
  order += 1
end

placements = LearningInventory.resource_placements(
  tree_entries.transform_values(&:first),
  locked_contents,
  path_order
)
unplaced_resources = resource_records.keys.select { |path| placements.fetch(path).nil? }
unless unplaced_resources.empty?
  abort "cannot place runtime/test resources next to a source dependency: #{unplaced_resources.sort.join(', ')}"
end
placement_groups = Hash.new { |hash, key| hash[key] = [] }
resource_records.each_key do |path|
  placement = placements.fetch(path)

  anchor = placement.fetch(:anchor)
  target_file = entries_by_file.find do |_task_file, entries|
    entries.any? { |entry| entry.is_a?(Hash) && entry[:kind] == :source && entry[:path] == anchor }
  end&.first
  abort "cannot find task file for resource anchor #{anchor}" if target_file.nil?

  placement_groups[[target_file, anchor, placement.fetch(:side)]] << path
  seen_paths[path] = target_file
end

placement_groups.each do |(task_file, anchor, side), paths|
  entries = entries_by_file.fetch(task_file)
  anchor_indexes = entries.each_index.select do |index|
    entry = entries[index]
    entry.is_a?(Hash) && entry[:kind] == :source && entry[:path] == anchor
  end
  abort "resource anchor disappeared: #{anchor}" if anchor_indexes.empty?

  insertion_index = side == :before ? anchor_indexes.first : anchor_indexes.last + 1
  additions = paths.sort.flat_map { |path| resource_records.fetch(path) }
  entries.insert(insertion_index, *additions)
end

abort "learning inventory still has no task: #{(learning_paths - seen_paths.keys).join(', ')}" unless learning_paths.length == seen_paths.length

# Keep the closure heading attached to the audit itself. Newly classified
# advanced source is inserted before the final milestone; without this
# normalization those source tasks would appear under "Final repository
# closure" even though they still belong to the preceding implementation work.
final_entries = entries_by_file.fetch(task_files.last)
closure_heading_index = final_entries.index { |entry| entry == "## Final repository closure\n" }
unless closure_heading_index.nil?
  while closure_heading_index.positive? && final_entries[closure_heading_index - 1].is_a?(String) && final_entries[closure_heading_index - 1].strip.empty?
    final_entries.delete_at(closure_heading_index - 1)
    closure_heading_index -= 1
  end
  final_entries.delete_at(closure_heading_index)
  final_entries.delete_at(closure_heading_index) while final_entries[closure_heading_index].is_a?(String) && final_entries[closure_heading_index].strip.empty?
end
final_audit_index = final_entries.rindex do |entry|
  entry.is_a?(Hash) && entry[:kind] == :milestone && entry.fetch(:description).start_with?("Final closure audit")
end
abort "final closure audit milestone is missing" if final_audit_index.nil?
final_entries.insert(final_audit_index, "\n", "## Final repository closure\n", "\n")

next_id = 1
file_ranges = {}
task_files.each do |task_file|
  ids = []
  entries_by_file.fetch(task_file).each do |entry|
    next unless entry.is_a?(Hash)

    entry[:id] = next_id
    ids << next_id
    next_id += 1
  end
  file_ranges[task_file] = (ids.first..ids.last)
end

task_files.each do |task_file|
  entries = entries_by_file.fetch(task_file)
  segment_start = file_ranges.fetch(task_file).begin
  entries.each do |entry|
    next unless entry.is_a?(Hash) && entry[:kind] == :milestone

    entry[:owners] = if entry.fetch(:description).start_with?("Final closure audit")
                       (1..(entry.fetch(:id) - 1))
                     else
                       (segment_start..(entry.fetch(:id) - 1))
                     end
    segment_start = entry.fetch(:id) + 1
  end

  output = entries.map do |entry|
    next entry unless entry.is_a?(Hash)

    if entry[:kind] == :source
      source_task_line(entry, entry.fetch(:id))
    else
      description = entry.fetch(:description)
      if description.start_with?("Final closure audit")
        description = "Final closure audit；確認開始 T001 前已執行 `ruby tasks/sync-codebase.rb learn-codebase`，再執行只讀的 `ruby tasks/verify-sync-closure.rb learn-codebase`：逐一核對全部 learning source與 `tasks/sync-only-manifest.tsv` copy entry 的 locked bytes、Git file type、symlink target及 executable mode，target root與每個 reconstructed path的所有父目錄都是實體 directory，每個 exclude entry 保留具體 exclude reason；並稽核 source mapping 與 deferred-test ledger，不補搬 source。"
      end
      owners = entry.fetch(:owners)
      format(
        "- [ ] T%<id>03d. %<description>s Source basis: 本 task 不承接新 source。 Task kind: milestone. Owner tasks: T%<first>03d–T%<last>03d.\n",
        id: entry.fetch(:id),
        description: description,
        first: owners.begin,
        last: owners.end
      )
    end
  end.join
  File.write(task_file, output)
end

readme_path = File.expand_path("README.md", __dir__)
readme = File.read(readme_path)
file_ranges.each do |task_file, range|
  basename = File.basename(task_file)
  replacement = format("`%s` (T%03d–T%03d)", basename, range.begin, range.end)
  readme.sub!(/`#{Regexp.escape(basename)}` \(T\d+–T\d+\)/, replacement)
end
milestones = task_files.flat_map do |task_file|
  entries_by_file.fetch(task_file).select { |entry| entry.is_a?(Hash) && entry[:kind] == :milestone }
end
milestone_lines = milestones.map do |entry|
  key = milestone_key(entry.fetch(:description))
  summary = if key == "Final closure audit"
              format(
                "final closure audit；確認 deterministic/concurrent simulators 與所有前置 learning tasks 已完成、%s-file learning inventory 均有唯一 owner、`tasks/sync-codebase.rb` 已建立 %s 個 copy、只讀 closure verifier 已核對全部 learning/copy locked bytes與 Git file type並拒絕 symlink root/parent、%s 個 exclusion 均保留理由，且 deferred verification 清空。此 task 不搬入或補實作新 source。",
                learning_paths.length.to_s.reverse.scan(/.{1,3}/).join(",").reverse,
                sync_copy_count,
                sync_exclude_count
              )
            else
              MILESTONE_SUMMARIES.fetch(key) { abort "missing README summary for milestone #{key.inspect}" }
            end
  format("- T%03d: %s", entry.fetch(:id), summary)
end
milestone_section = "## 里程碑\n\n#{milestone_lines.join("\n")}\n"
unless readme.sub!(/## 里程碑\n.*?(?=\n## |\z)/m, milestone_section.rstrip)
  abort "tasks/README.md has no milestone section"
end
final_milestone_id = milestones.last.fetch(:id)
readme.sub!(/T\d+ 完成時不得留下任何 deferred verification。/, format("T%03d 完成時不得留下任何 deferred verification。", final_milestone_id))
File.write(readme_path, readme)

puts "Rebuilt #{next_id - 1} tasks from #{learning_paths.length} learning files; added #{missing_paths.length} newly classified resources"
