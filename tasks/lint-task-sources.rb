#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "pathname"
require_relative "learning_inventory"
require_relative "source_units"

LOCKED_COMMIT = "d7370df0170763e8a8a0db4542a1a181372b8895"
MAX_FILES_PER_TASK = 6
MAX_SOURCE_LINES_PER_TASK = 300
MAX_SOURCE_UNITS_PER_TASK = 4
TASK_FILE_PATTERN = "tasks/[0-1][0-9]-*.md"
SYNC_MANIFEST_PATH = "tasks/sync-only-manifest.tsv"
SYNC_SCRIPT_PATH = "tasks/sync-codebase.rb"

SOURCE_PATH_EXTENSIONS = %w[
  .rs .toml .json .mjs .js .ts .py .sh .ps1 .tcl .test .sqltest .md .mdx
  .cs .java .kt .kts .c .h .hpp .cpp .yml .yaml .gradle .props .targets
  .csproj .slnx .lock .nix .go .tsx .jsx .sql .properties .podspec .rb
  .swift .m .mm .xml .plist .storyboard
].freeze

PACKAGE_AND_TOOL_ROOTS = %w[
  bindings/go
  bindings/react-native
  bindings/dotnet
  bindings/tcl
  serverless/javascript
  serverless/python
  serverless/go
  scripts
  packages/turso-cli
  fuzz
  sqlite/conformance
  testing/sqlancer
  testing/sqlright
  testing/stress-go
  testing/antithesis
  perf
  examples
].freeze

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
      abort "expected blob #{expected_blob_id} for #{path}, got #{header.inspect}" unless blob_id == expected_blob_id && object_type == "blob"

      size = Integer(size_text, 10)
      contents[path] = stdout.read(size)
      separator = stdout.read(1)
      abort "missing git cat-file separator after #{path}" unless separator == "\n"
    end

    writer.join
    error_output = stderr.read
    abort "git cat-file failed: #{error_output}" unless wait_thread.value.success?
  end
  contents
end

def locked_workspace_directories(root_manifest, locked_contents, tree_set)
  workspace_section = root_manifest[/\[workspace\](.*?)(?=\n\[)/m, 1]
  abort "locked Cargo.toml has no [workspace] section" if workspace_section.nil?

  members_text = workspace_section[/\bmembers\s*=\s*\[(.*?)\]/m, 1]
  abort "locked Cargo.toml has no workspace members" if members_text.nil?

  pending = members_text.scan(/"([^"]+)"/).flatten
  directories = []
  until pending.empty?
    directory = Pathname.new(pending.shift).cleanpath.to_s.sub(%r{\A\./}, "")
    next if directories.include?(directory)

    manifest_path = "#{directory}/Cargo.toml"
    abort "locked workspace manifest is missing: #{manifest_path}" unless tree_set[manifest_path]

    directories << directory
    manifest = locked_contents.fetch(manifest_path)
    manifest.scan(/\bpath\s*=\s*"([^"]+)"/).flatten.each do |dependency_path|
      dependency_directory = Pathname.new(File.join(directory, dependency_path)).cleanpath.to_s
      pending << dependency_directory if tree_set["#{dependency_directory}/Cargo.toml"]
    end
  end
  directories.sort
end

def source_line_count(content)
  return 0 if content.empty?

  content.count("\n") + (content.end_with?("\n") ? 0 : 1)
end

def text_source?(content)
  return false if content.include?("\0")

  content.dup.force_encoding(Encoding::UTF_8).valid_encoding?
end

def task_kind(line)
  return :milestone if line.include?("Task kind: milestone")
  return :verification if line.include?("Task kind: verification")

  :source
end

def source_slices(line)
  marker = line.split("Source slices:", 2)[1]
  return {} if marker.nil?

  marker = marker.split(/完成：|Target:|Task kind:/, 2)[0]
  marker.scan(/([^,;\s]+):L(\d+)-L(\d+)/).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(path, first_line, last_line), slices|
    slices[path] << (Integer(first_line, 10)..Integer(last_line, 10))
  end
end

def owner_task_ids(line)
  marker = line.split("Owner tasks:", 2)[1]
  return [] if marker.nil?

  marker.split(/完成：|Target:|Source basis:/, 2)[0].scan(/T(\d+)(?:[–-]T?(\d+))?/).flat_map do |first_id, last_id|
    first_id = Integer(first_id, 10)
    last_id.nil? ? [first_id] : (first_id..Integer(last_id, 10)).to_a
  end
end

def explicit_symbols(description)
  description.scan(/`([^`]+)`/).flatten.map do |value|
    candidate = value.strip.sub(/\(\)\z/, "").sub(/<.*>\z/, "")
    next unless candidate.match?(/\A[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*\z/)

    candidate
  end.compact.uniq
end

def verification_symbols(line)
  marker = line.split("Verification symbols:", 2)[1]
  return [] if marker.nil?

  marker.split(/Owner tasks:|完成：|Target:/, 2).first.scan(/`([^`]+)`/).flatten
end

def source_path?(value)
  value.include?("/") || value == "Cargo.toml" ||
    SOURCE_PATH_EXTENSIONS.include?(File.extname(value)) ||
    File.basename(value) == "Makefile" ||
    File.basename(value) == "CMakeLists.txt" ||
    File.basename(value).start_with?("Dockerfile")
end

def resolve_source_path(value, tree, tree_set)
  value = value.strip.sub(/[.。:]\z/, "")
  return [value] if tree_set[value]
  return [] unless source_path?(value)

  directory_prefix = value.sub(%r{/\z}, "") + "/"
  directory_matches = tree.select { |path| path.start_with?(directory_prefix) }
  return directory_matches unless directory_matches.empty?

  if value.match?(/[\*?\[]/)
    return tree.select do |path|
      File.fnmatch?(value, path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
    end
  end

  []
end

repository_root = File.expand_path("..", __dir__)
Dir.chdir(repository_root)

tree_entries = command_output("git", "ls-tree", "-r", LOCKED_COMMIT).lines.map do |line|
  line = line.chomp
  match = line.match(/\A(\d+) \w+ ([0-9a-f]+)\t(.+)\z/)
  abort "unexpected git ls-tree output: #{line.inspect}" unless match

  [match[3], match[1], match[2]]
end
tree = tree_entries.map(&:first)
tree_set = tree.to_h { |path| [path, true] }
blob_ids = tree_entries.to_h { |path, _mode, blob_id| [path, blob_id] }
locked_modes = tree_entries.to_h { |path, mode, _blob_id| [path, mode] }
locked_contents = read_locked_blobs(blob_ids)
locked_line_counts = locked_contents.transform_values { |content| source_line_count(content) }
learning_inventory = LearningInventory.learning_paths(locked_modes, locked_contents)
learning_inventory_set = learning_inventory.to_h { |path| [path, true] }

task_ids = []
task_ids_by_file = Hash.new { |hash, key| hash[key] = [] }
task_sources = {}
task_kinds = {}
task_locations = {}
task_slices = {}
task_owner_ids = {}
task_descriptions = {}
task_verification_symbols = {}
task_declared_units = {}
unresolved = []
missing_source_basis = []
banned_batch_descriptions = []

Dir[TASK_FILE_PATTERN].sort.each do |task_file|
  File.foreach(task_file).with_index(1) do |line, line_number|
    match = line.match(/\A- \[ \] T(\d+)\./)
    next unless match

    task_id = match[1].to_i
    task_ids << task_id
    task_ids_by_file[task_file] << task_id
    task_locations[task_id] = [task_file, line_number]
    task_kinds[task_id] = task_kind(line)
    task_slices[task_id] = source_slices(line)
    task_owner_ids[task_id] = owner_task_ids(line)
    task_descriptions[task_id] = line[/\A- \[ \] T\d+\.\s*(.*?)Source basis:/, 1].to_s.strip
    task_verification_symbols[task_id] = verification_symbols(line)
    task_declared_units[task_id] = line[/\bSource units:\s*(\d+)/, 1]&.to_i
    banned_batch_descriptions << [task_id, task_file, line_number] if line.include?("檔案批次")
    source_basis = line.split("Source basis:", 2)[1]
    if source_basis.nil?
      missing_source_basis << [task_id, task_file, line_number]
      next
    end

    source_basis = source_basis.split(/完成：|Target:/, 2)[0]
    files = source_basis.scan(/`([^`]+)`/).flatten.flat_map do |source_path|
      matches = resolve_source_path(source_path, tree, tree_set)
      if matches.empty?
        next [] unless source_path?(source_path)

        unresolved << [task_id, task_file, line_number, source_path]
      end
      matches
    end
    task_sources[task_id] = files.uniq.sort
  end
end

errors = []
expected_ids = (1..task_ids.length).to_a
errors << "task IDs are not continuous from T001" unless task_ids == expected_ids

readme = File.read("tasks/README.md")
readme_ranges = readme.scan(
  /`([0-1][0-9]-[^`]+\.md)` \(T(\d+)–T(\d+)\)/
).to_h do |task_file, first_id, last_id|
  ["tasks/#{task_file}", [first_id.to_i, last_id.to_i]]
end

readme_milestone_section = readme[/## 里程碑\n(.*?)(?=\n## |\z)/m, 1]
if readme_milestone_section.nil?
  errors << "README has no milestone summary section"
else
  readme_milestone_ids = readme_milestone_section.scan(/^- T(\d+):/).flatten.map(&:to_i)
  actual_milestone_ids = task_ids.select { |task_id| task_kinds.fetch(task_id) == :milestone }
  unless readme_milestone_ids == actual_milestone_ids
    errors << "README milestone IDs are #{readme_milestone_ids.map { |id| format('T%03d', id) }.join(', ')}; expected #{actual_milestone_ids.map { |id| format('T%03d', id) }.join(', ')}"
  end
  readme_milestone_ids.each do |task_id|
    unless task_ids.include?(task_id) && task_kinds.fetch(task_id) == :milestone
      errors << format("README T%03d does not resolve to a milestone task", task_id)
    end
  end
end

unless File.file?(SYNC_SCRIPT_PATH) && readme.include?("ruby #{SYNC_SCRIPT_PATH} learn-codebase")
  errors << "README must provide the locked sync command: ruby #{SYNC_SCRIPT_PATH} learn-codebase"
end
task_ids_by_file.each do |task_file, ids|
  expected_range = [ids.first, ids.last]
  actual_range = readme_ranges[task_file]
  unless actual_range == expected_range
    errors << format(
      "README range for %s is %p; expected T%03d-T%03d",
      task_file,
      actual_range,
      expected_range[0],
      expected_range[1]
    )
  end
end

missing_source_basis.each do |task_id, task_file, line_number|
  errors << format("T%03d has no Source basis at %s:%d", task_id, task_file, line_number)
end

banned_batch_descriptions.each do |task_id, task_file, line_number|
  errors << format("T%03d uses a mechanical file-batch description at %s:%d", task_id, task_file, line_number)
end

task_descriptions.select { |task_id, _description| task_kinds.fetch(task_id) == :source }
                 .group_by { |_task_id, description| description }.each do |description, entries|
  next if description.empty? || entries.one?

  task_labels = entries.map { |task_id, _value| format("T%03d", task_id) }
  errors << "tasks repeat the same teaching description (#{task_labels.join(', ')}): #{description}"
end

unresolved.each do |task_id, task_file, line_number, source_path|
  errors << format(
    "T%03d has an unresolved Source basis path %p at %s:%d",
    task_id,
    source_path,
    task_file,
    line_number
  )
end

task_sources.each do |task_id, files|
  next unless files.length > MAX_FILES_PER_TASK

  errors << format(
    "T%03d expands to %d files; split it to at most %d",
    task_id,
    files.length,
    MAX_FILES_PER_TASK
  )
end

task_sources.each do |task_id, files|
  files.reject { |path| learning_inventory_set[path] }.each do |path|
    errors << format(
      "T%03d assigns a sync-only repository asset as a learning source: %s",
      task_id,
      path
    )
  end
end

task_ids.each do |task_id|
  kind = task_kinds.fetch(task_id)
  files = task_sources.fetch(task_id, [])
  task_file, line_number = task_locations.fetch(task_id)
  if files.empty? && kind == :source
    errors << format(
      "T%03d resolves to zero source files at %s:%d; mark a real milestone or verification task explicitly",
      task_id,
      task_file,
      line_number
    )
  end
  if kind == :source && task_declared_units.fetch(task_id).nil?
    errors << format("T%03d source task has no explicit Source units metadata", task_id)
  end
  if kind == :verification && task_owner_ids.fetch(task_id).empty?
    errors << format("T%03d is verification-only but has no Owner tasks", task_id)
  end
  if kind == :verification
    description = task_descriptions.fetch(task_id)
    unless description.start_with?("驗證 ")
      errors << format("T%03d verification action must start with 驗證, not 搬入", task_id)
    end
    unless description.include?("source→target mapping") && description.include?("deferred-test")
      errors << format("T%03d verification must record source→target mapping and deferred-test status", task_id)
    end
  end
  task_owner_ids.fetch(task_id).each do |owner_task_id|
    unless task_ids.include?(owner_task_id) && owner_task_id < task_id
      errors << format("T%03d refers to invalid or non-prior owner T%03d", task_id, owner_task_id)
    end
  end
end

source_task_ids = task_ids.select { |task_id| task_kinds.fetch(task_id) == :source }
source_owners = Hash.new { |hash, key| hash[key] = [] }
source_task_ids.each do |task_id|
  task_sources.fetch(task_id, []).each { |path| source_owners[path] << task_id }
end

owned_text_cache = {}
owned_text = lambda do |task_id|
  owned_text_cache[task_id] ||= task_sources.fetch(task_id, []).select { |path| text_source?(locked_contents.fetch(path)) }.map do |path|
    content = locked_contents.fetch(path).dup.force_encoding(Encoding::UTF_8)
    ranges = task_slices.fetch(task_id).fetch(path, [])
    next content if ranges.empty?

    lines = content.lines
    ranges.map { |range| lines[(range.begin - 1)..(range.end - 1)].join }.join
  end.join("\n")
end

task_ids.select { |task_id| task_kinds.fetch(task_id) == :verification }.each do |task_id|
  declared_symbols = task_verification_symbols.fetch(task_id)
  expected_symbols = explicit_symbols(task_descriptions.fetch(task_id))
  unless declared_symbols == expected_symbols
    errors << format(
      "T%03d Verification symbols are %p; expected the literal identifiers %p from its description",
      task_id,
      declared_symbols,
      expected_symbols
    )
  end

  source_owner_ids = task_owner_ids.fetch(task_id).select { |owner_id| task_kinds.fetch(owner_id, nil) == :source }
  unless source_owner_ids.length == task_owner_ids.fetch(task_id).length
    errors << format("T%03d verification owners must all be source tasks", task_id)
  end
  declared_symbols.each do |symbol|
    leaf = symbol.split("::").last
    pattern = /(?<![A-Za-z0-9_])#{Regexp.escape(leaf)}(?![A-Za-z0-9_])/
    next if source_owner_ids.any? { |owner_id| owned_text.call(owner_id).match?(pattern) }

    errors << format("T%03d has no owner slice containing verification symbol `%s`", task_id, symbol)
  end
end

source_owners.each do |path, owner_ids|
  next if owner_ids.one?

  unless owner_ids.all? { |task_id| task_slices.fetch(task_id).key?(path) }
    errors << "source has more than one owner without complete Source slices: #{path} (#{owner_ids.map { |task_id| format('T%03d', task_id) }.join(', ')})"
  end
end

task_slices.each do |task_id, slices_by_path|
  slices_by_path.each_key do |path|
    unless task_sources.fetch(task_id, []).include?(path)
      errors << format("T%03d has Source slices for a path outside its Source basis: %s", task_id, path)
    end
  end
end

source_units_by_path = {}
source_owners.each do |path, owner_ids|
  sliced_owner_ids = owner_ids.select { |task_id| task_slices.fetch(task_id).key?(path) }
  units = if text_source?(locked_contents.fetch(path))
            source_units_by_path[path] ||= SourceUnits.for(path, locked_contents.fetch(path))
          else
            []
          end
  if text_source?(locked_contents.fetch(path)) && sliced_owner_ids.empty? &&
      (locked_line_counts.fetch(path) > MAX_SOURCE_LINES_PER_TASK || units.length > MAX_SOURCE_UNITS_PER_TASK)
    errors << "oversized source has no explicit structural Source slices: #{path} (#{locked_line_counts.fetch(path)} lines, #{units.length} units)"
    next
  end
  next if sliced_owner_ids.empty?

  unless sliced_owner_ids == owner_ids
    errors << "#{path} mixes sliced and unsliced owners: #{owner_ids.map { |task_id| format('T%03d', task_id) }.join(', ')}"
    next
  end

  ranges = owner_ids.flat_map do |task_id|
    task_slices.fetch(task_id).fetch(path).map { |range| [range, task_id] }
  end.sort_by { |range, _task_id| range.begin }
  expected_line = 1
  ranges.each do |range, task_id|
    if range.begin != expected_line || range.end < range.begin
      errors << format("%s has a missing or overlapping slice before T%03d %s", path, task_id, range)
      break
    end
    expected_line = range.end + 1
  end
  line_count = locked_line_counts.fetch(path)
  errors << "#{path} slices end at line #{expected_line - 1}; expected #{line_count}" unless expected_line == line_count + 1

  safe_starts = units.to_h { |unit| [unit.first_line, true] }
  safe_ends = units.to_h { |unit| [unit.last_line, true] }
  ranges.each do |range, task_id|
    unless safe_starts[range.begin] && safe_ends[range.end]
      errors << format(
        "T%03d cuts %s inside a source item/test case (%s); use boundaries emitted by tasks/source_units.rb",
        task_id,
        path,
        range
      )
    end
  end
end

source_task_ids.each do |task_id|
  exact_lines = 0
  exact_units = 0
  task_sources.fetch(task_id, []).each do |path|
    next unless text_source?(locked_contents.fetch(path))

    slices = task_slices.fetch(task_id).fetch(path, [])
    exact_lines += slices.empty? ? locked_line_counts.fetch(path) : slices.sum(&:size)
    units = source_units_by_path[path] ||= SourceUnits.for(path, locked_contents.fetch(path))
    exact_units += if slices.empty?
                     units.length
                   else
                     slices.sum do |range|
                       units.count { |unit| range.cover?(unit.first_line) && range.cover?(unit.last_line) }
                     end
                   end
  end
  if exact_lines > MAX_SOURCE_LINES_PER_TASK
    errors << format(
      "T%03d owns %d exact source lines; split it at complete source units (max %d)",
      task_id,
      exact_lines,
      MAX_SOURCE_LINES_PER_TASK
    )
  end
  if exact_units > MAX_SOURCE_UNITS_PER_TASK
    errors << format(
      "T%03d owns %d complete source units; split the teaching concept further (max %d)",
      task_id,
      exact_units,
      MAX_SOURCE_UNITS_PER_TASK
    )
  end
  declared_units = task_declared_units.fetch(task_id)
  if !declared_units.nil? && declared_units != exact_units
    errors << format(
      "T%03d declares %d Source units but owns %d actual SourceUnits::Unit entries",
      task_id,
      declared_units,
      exact_units
    )
  end
end

path_order = source_owners.transform_values(&:min)
resource_placements = LearningInventory.resource_placements(locked_modes, locked_contents, path_order)
resource_placements.each do |path, placement|
  if placement.nil?
    errors << "runtime/test resource has no first-reference, pair, or package anchor: #{path}"
    next
  end

  resource_owner_ids = source_owners.fetch(path, [])
  anchor = placement.fetch(:anchor)
  anchor_owner_ids = source_owners.fetch(anchor, [])
  if resource_owner_ids.empty? || anchor_owner_ids.empty?
    errors << "cannot validate resource placement for #{path} against #{anchor}: missing owner"
    next
  end

  resource_file = task_locations.fetch(resource_owner_ids.first).first
  anchor_file = task_locations.fetch(anchor_owner_ids.first).first
  if resource_file != anchor_file
    errors << "resource #{path} is in #{resource_file}; its #{placement.fetch(:reason)} anchor #{anchor} is in #{anchor_file}"
    next
  end

  ordered = if placement.fetch(:side) == :before
              resource_owner_ids.max < anchor_owner_ids.min
            else
              anchor_owner_ids.max < resource_owner_ids.min
            end
  unless ordered
    errors << "resource #{path} must be #{placement.fetch(:side)} #{placement.fetch(:reason)} anchor #{anchor}"
    next
  end

  first_related_id = [resource_owner_ids.min, anchor_owner_ids.min].min
  last_related_id = [resource_owner_ids.max, anchor_owner_ids.max].max
  intervening_milestone = task_ids.find do |task_id|
    task_id > first_related_id && task_id < last_related_id && task_kinds.fetch(task_id) == :milestone
  end
  if intervening_milestone
    errors << format(
      "resource %s and anchor %s cross milestone T%03d; runtime/test dependencies must close in the same milestone",
      path,
      anchor,
      intervening_milestone
    )
  end
end

sync_inventory = tree.reject { |path| learning_inventory_set[path] }
sync_manifest_entries = {}
if !File.file?(SYNC_MANIFEST_PATH)
  errors << "missing #{SYNC_MANIFEST_PATH}"
else
  File.foreach(SYNC_MANIFEST_PATH).with_index(1) do |line, line_number|
    next if line.start_with?("#") || line.strip.empty?

    action, path, reason, extra = line.chomp.split("\t", 4)
    if extra || !%w[copy exclude].include?(action) || path.to_s.empty? || reason.to_s.empty?
      errors << "invalid sync manifest row at #{SYNC_MANIFEST_PATH}:#{line_number}"
      next
    end
    if sync_manifest_entries.key?(path)
      errors << "duplicate sync manifest path: #{path}"
      next
    end
    sync_manifest_entries[path] = [action, reason]
  end
end

(sync_inventory - sync_manifest_entries.keys).each do |path|
  errors << "sync-only blob is missing from the manifest: #{path}"
end
(sync_manifest_entries.keys - sync_inventory).each do |path|
  errors << "sync manifest contains a learning or nonexistent path: #{path}"
end
sync_inventory.each do |path|
  next unless sync_manifest_entries.key?(path)

  expected = LearningInventory.sync_disposition(
    path,
    locked_contents.fetch(path),
    mode: locked_modes.fetch(path)
  )
  actual = sync_manifest_entries.fetch(path)
  errors << "sync manifest disposition for #{path} is #{actual.inspect}; expected #{expected.inspect}" unless actual == expected
end

locked_symlink_paths = locked_modes.select { |_path, mode| mode == "120000" }.keys
locked_symlink_paths.each do |path|
  errors << "locked symlink is incorrectly present in learning inventory: #{path}" if learning_inventory_set[path]
  errors << "locked symlink has a source-task owner instead of sync ownership: #{path}" unless source_owners.fetch(path, []).empty?
  expected_action = LearningInventory.sync_disposition(
    path,
    locked_contents.fetch(path),
    mode: locked_modes.fetch(path)
  ).first
  if expected_action == "copy" && sync_manifest_entries[path]&.first != "copy"
    errors << "in-scope locked symlink must be a sync manifest copy: #{path}"
  end
end

workspace_manifest_paths = ["Cargo.toml"] + tree.grep(%r{/Cargo\.toml\z})
workspace_manifest_contents = locked_contents.slice(*workspace_manifest_paths)
workspace_package_directories = locked_workspace_directories(
  locked_contents.fetch("Cargo.toml"),
  workspace_manifest_contents,
  tree_set
)

workspace_files = tree.select do |path|
  workspace_package_directories.any? do |directory|
    path == directory || path.start_with?(directory + "/")
  end
end

required_workspace_files = workspace_files.select do |path|
  LearningInventory.learning_role?(path, locked_contents.fetch(path), mode: locked_modes.fetch(path)) &&
    LearningInventory::EXPLICIT_SYNC_PREFIXES.none? { |prefix| path.start_with?(prefix) }
end
missing_required_workspace_files = required_workspace_files.reject { |path| learning_inventory_set[path] }
missing_required_workspace_files.each do |path|
  errors << "workspace source/build/test file is bypassed by learning inventory rules: #{path}"
end

supplemental_code_files = tree.select do |path|
  components = path.split("/")
  next false unless %w[examples perf].include?(components.first) ||
    components.any? { |component| %w[benches benchmark benchmarks examples].include?(component) }

  LearningInventory.learning_role?(path, locked_contents.fetch(path), mode: locked_modes.fetch(path)) &&
    LearningInventory::EXPLICIT_SYNC_PREFIXES.none? { |prefix| path.start_with?(prefix) }
end
supplemental_code_files.reject { |path| learning_inventory_set[path] }.each do |path|
  errors << "Turso-owned benchmark/example file is bypassed by learning inventory rules: #{path}"
end

workspace_inventory = workspace_files.select { |path| learning_inventory_set[path] }

final_task_id = task_ids.max
covered_before_final = task_sources.each_with_object({}) do |(task_id, files), covered|
  next if task_id == final_task_id || task_kinds.fetch(task_id) != :source

  files.each { |path| covered[path] = true }
end
missing_inventory = workspace_inventory.reject { |path| covered_before_final[path] }

package_and_tool_inventory = learning_inventory.select do |path|
  PACKAGE_AND_TOOL_ROOTS.any? do |root|
    path == root || path.start_with?(root + "/")
  end
end
missing_package_and_tool_inventory = package_and_tool_inventory.reject do |path|
  covered_before_final[path]
end

repository_inventory = learning_inventory
missing_repository_inventory = repository_inventory.reject do |path|
  covered_before_final[path]
end

missing_inventory.each do |path|
  errors << "workspace inventory has no owner before the final audit: #{path}"
end

missing_package_and_tool_inventory.each do |path|
  errors << "package/tool inventory has no owner before the final audit: #{path}"
end

missing_repository_inventory.each do |path|
  errors << "repository inventory has no owner before the final audit: #{path}"
end

unless task_sources.fetch(final_task_id, []).empty? && task_kinds.fetch(final_task_id) == :milestone
  errors << format("final task T%03d must be a closure audit with no new source", final_task_id)
end
final_description = task_descriptions.fetch(final_task_id, "")
unless final_description.include?(SYNC_MANIFEST_PATH) &&
    final_description.include?(SYNC_SCRIPT_PATH) &&
    final_description.include?("tasks/verify-sync-closure.rb") &&
    final_description.include?("learning source") &&
    final_description.include?("locked bytes") &&
    final_description.include?("Git file type") &&
    final_description.include?("executable mode") &&
    final_description.include?("exclude reason")
  errors << format(
    "final task T%03d must verify every learning/copy blob, Git file type, executable mode, and exclude reason in %s",
    final_task_id,
    SYNC_MANIFEST_PATH
  )
end

if errors.empty?
  puts format(
    "OK: %d continuous tasks; 0 unresolved paths; max %d files, %d exact lines, and %d structural units/task; learning inventory %d/%d, workspace subset %d/%d, package/tool subset %d/%d owned before T%03d; sync manifest %d/%d blobs classified",
    task_ids.length,
    MAX_FILES_PER_TASK,
    MAX_SOURCE_LINES_PER_TASK,
    MAX_SOURCE_UNITS_PER_TASK,
    repository_inventory.length,
    repository_inventory.length,
    workspace_inventory.length,
    workspace_inventory.length,
    package_and_tool_inventory.length,
    package_and_tool_inventory.length,
    final_task_id,
    sync_manifest_entries.length,
    sync_inventory.length
  )
  exit 0
end

warn errors.join("\n")
exit 1
