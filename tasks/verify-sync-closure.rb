#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only final closure check. Every learning source and every manifest copy
# must match the locked Git blob, file type, and executable bit.

require "open3"
require_relative "learning_inventory"

LOCKED_COMMIT = "d7370df0170763e8a8a0db4542a1a181372b8895"
MANIFEST_PATH = File.expand_path("sync-only-manifest.tsv", __dir__)

repository_root = File.expand_path("..", __dir__)
target_root = File.expand_path(ARGV.shift || "learn-codebase", repository_root)
abort "usage: ruby tasks/verify-sync-closure.rb [learn-codebase-path]" unless ARGV.empty?

target_stat = begin
  File.lstat(target_root)
rescue Errno::ENOENT, Errno::ENOTDIR
  nil
end
abort "closure target root does not exist: #{target_root}" if target_stat.nil?
abort "closure target root must not be a symlink: #{target_root}" if target_stat.symlink?
abort "closure target root is not a directory: #{target_root}" unless target_stat.directory?

Dir.chdir(repository_root)
tree_output = IO.popen(["git", "ls-tree", "-r", LOCKED_COMMIT], &:read)
abort "cannot read locked tree #{LOCKED_COMMIT}" unless $?.success?
tree_entries = tree_output.lines.to_h do |line|
  match = line.chomp.match(/\A(\d+) \w+ ([0-9a-f]+)\t(.+)\z/)
  abort "unexpected git ls-tree output: #{line.inspect}" if match.nil?

  [match[3], [match[1], match[2]]]
end

locked_contents = {}
Open3.popen3("git", "cat-file", "--batch") do |stdin, stdout, stderr, wait_thread|
  writer = Thread.new do
    tree_entries.each_value { |_mode, blob_id| stdin.puts(blob_id) }
    stdin.close
  end

  tree_entries.each do |path, (_mode, expected_blob_id)|
    header = stdout.gets
    abort "git cat-file ended before #{path}" if header.nil?

    blob_id, object_type, size_text = header.split
    unless blob_id == expected_blob_id && object_type == "blob"
      abort "expected blob #{expected_blob_id} for #{path}, got #{header.inspect}"
    end
    locked_contents[path] = stdout.read(Integer(size_text, 10))
    abort "missing git cat-file separator after #{path}" unless stdout.read(1) == "\n"
  end

  writer.join
  error_output = stderr.read
  abort "git cat-file failed: #{error_output}" unless wait_thread.value.success?
end

locked_modes = tree_entries.transform_values(&:first)
learning_paths = LearningInventory.learning_paths(locked_modes, locked_contents)
learning_set = learning_paths.to_h { |path| [path, true] }

manifest_entries = {}
File.foreach(MANIFEST_PATH).with_index(1) do |line, line_number|
  next if line.start_with?("#") || line.strip.empty?

  action, path, reason, extra = line.chomp.split("\t", 4)
  abort "invalid sync manifest row at line #{line_number}: #{line.inspect}" if extra || !%w[copy exclude].include?(action) || path.to_s.empty? || reason.to_s.empty?
  abort "duplicate sync manifest path at line #{line_number}: #{path}" if manifest_entries.key?(path)

  manifest_entries[path] = [action, reason]
end

sync_inventory = tree_entries.keys.reject { |path| learning_set[path] }
missing_manifest_paths = sync_inventory - manifest_entries.keys
extra_manifest_paths = manifest_entries.keys - sync_inventory
abort "sync manifest is missing locked paths: #{missing_manifest_paths.first(10).join(', ')}" unless missing_manifest_paths.empty?
abort "sync manifest has learning or unknown paths: #{extra_manifest_paths.first(10).join(', ')}" unless extra_manifest_paths.empty?

sync_inventory.each do |path|
  expected = LearningInventory.sync_disposition(path, locked_contents.fetch(path), mode: locked_modes.fetch(path))
  actual = manifest_entries.fetch(path)
  abort "sync manifest disposition drift for #{path}: #{actual.inspect}, expected #{expected.inspect}" unless actual == expected
end

copy_paths = manifest_entries.select { |_path, (action, _reason)| action == "copy" }.keys.sort
reconstructed_paths = (learning_paths + copy_paths).sort
path_kind = learning_paths.to_h { |path| [path, "learning source"] }
copy_paths.each { |path| path_kind[path] = "sync copy" }

errors = []
reconstructed_paths.each do |path|
  target_path = File.join(target_root, path)
  mode = tree_entries.fetch(path).first
  content = locked_contents.fetch(path)
  kind = path_kind.fetch(path)

  current_parent = target_root
  parent_problem = nil
  path.split("/")[0...-1].each do |component|
    current_parent = File.join(current_parent, component)
    parent_stat = begin
      File.lstat(current_parent)
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end
    if parent_stat.nil?
      parent_problem = "has missing parent directory #{current_parent}"
      break
    end
    if parent_stat.symlink?
      parent_problem = "traverses symlink parent directory #{current_parent}"
      break
    end
    unless parent_stat.directory?
      parent_problem = "has non-directory parent #{current_parent}"
      break
    end
  end
  unless parent_problem.nil?
    errors << "#{kind} #{parent_problem}: #{path}"
    next
  end

  stat = begin
    File.lstat(target_path)
  rescue Errno::ENOENT, Errno::ENOTDIR
    nil
  end

  if stat.nil?
    errors << "missing #{kind}: #{path}"
    next
  end

  if mode == "120000"
    unless stat.symlink?
      errors << "#{kind} has #{stat.ftype} type; expected locked symlink: #{path}"
      next
    end
    errors << "symlink target differs from locked blob: #{path}" if File.readlink(target_path).b != content
    next
  end

  unless mode.start_with?("100")
    errors << "unsupported locked Git mode #{mode}: #{path}"
    next
  end
  unless stat.file? && !stat.symlink?
    errors << "#{kind} has #{stat.ftype} type; expected locked regular file: #{path}"
    next
  end

  errors << "#{kind} differs from locked blob: #{path}" if File.binread(target_path) != content
  expected_executable = (Integer(mode, 8) & 0o111).positive?
  actual_executable = (stat.mode & 0o111).positive?
  if expected_executable != actual_executable
    errors << "#{kind} executable mode differs from locked blob: #{path}"
  end
end

unless errors.empty?
  warn errors.first(30).join("\n")
  warn "... #{errors.length - 30} more closure errors" if errors.length > 30
  exit 1
end

exclude_count = manifest_entries.count { |_path, (action, reason)| action == "exclude" && !reason.empty? }
puts "OK: #{learning_paths.length} learning sources and #{copy_paths.length} sync-only copies match locked bytes, Git file types, and executable modes; #{exclude_count} exclusions retain concrete reasons"
