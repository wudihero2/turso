#!/usr/bin/env ruby
# frozen_string_literal: true

# Copies the sync-only portion of the locked repository into learn-codebase.
# Learning sources remain owned by T001...; this script only applies manifest
# rows whose action is `copy`.

require "fileutils"
require "open3"
require "pathname"

LOCKED_COMMIT = "d7370df0170763e8a8a0db4542a1a181372b8895"
MANIFEST_PATH = File.expand_path("sync-only-manifest.tsv", __dir__)

repository_root = File.expand_path("..", __dir__)
target_argument = ARGV.shift || "learn-codebase"
abort "usage: ruby tasks/sync-codebase.rb [learn-codebase-path]" unless ARGV.empty?

target_root = File.expand_path(target_argument, repository_root)
abort "refusing to synchronize into the repository root" if target_root == repository_root

target_stat = begin
  File.lstat(target_root)
rescue Errno::ENOENT, Errno::ENOTDIR
  nil
end
if target_stat.nil?
  FileUtils.mkdir_p(target_root)
  target_stat = File.lstat(target_root)
end
abort "sync target root must not be a symlink: #{target_root}" if target_stat.symlink?
abort "sync target root is not a directory: #{target_root}" unless target_stat.directory?

entries = File.foreach(MANIFEST_PATH).each_with_object([]) do |line, result|
  next if line.start_with?("#") || line.strip.empty?

  action, path, reason, extra = line.chomp.split("\t", 4)
  abort "invalid sync manifest row: #{line.inspect}" if extra || !%w[copy exclude].include?(action) || path.to_s.empty? || reason.to_s.empty?

  clean_path = Pathname.new(path).cleanpath.to_s
  abort "unsafe sync manifest path: #{path.inspect}" if Pathname.new(path).absolute? || clean_path != path || path == "."

  result << [action, path]
end

copy_paths = entries.select { |action, _path| action == "copy" }.map(&:last)
abort "sync manifest has duplicate paths" unless entries.map(&:last).uniq.length == entries.length

Dir.chdir(repository_root)
tree_output = IO.popen(["git", "ls-tree", "-r", LOCKED_COMMIT], &:read)
abort "cannot read locked tree #{LOCKED_COMMIT}" unless $?.success?
tree_entries = tree_output.lines.to_h do |line|
  match = line.chomp.match(/\A(\d+) \w+ ([0-9a-f]+)\t(.+)\z/)
  abort "unexpected git ls-tree output: #{line.inspect}" if match.nil?

  [match[3], [match[1], match[2]]]
end
copy_paths.each { |path| abort "cannot resolve locked blob: #{path}" unless tree_entries.key?(path) }

locked_contents = {}
Open3.popen3("git", "cat-file", "--batch") do |stdin, stdout, stderr, wait_thread|
  writer = Thread.new do
    copy_paths.each { |path| stdin.puts(tree_entries.fetch(path).last) }
    stdin.close
  end

  copy_paths.each do |path|
    expected_blob_id = tree_entries.fetch(path).last
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

copy_paths.each do |path|
  target_path = File.join(target_root, path)
  parent_path = File.dirname(target_path)
  relative_parent = Pathname.new(parent_path).relative_path_from(Pathname.new(target_root))
  current_parent = target_root
  relative_parent.each_filename do |component|
    current_parent = File.join(current_parent, component)
    parent_stat = begin
      File.lstat(current_parent)
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end
    if parent_stat.nil?
      Dir.mkdir(current_parent)
      parent_stat = File.lstat(current_parent)
    end
    abort "refusing to traverse symlink directory: #{current_parent}" if parent_stat.symlink?
    abort "sync parent is not a directory: #{current_parent}" unless parent_stat.directory?
  end

  target_stat = begin
    File.lstat(target_path)
  rescue Errno::ENOENT, Errno::ENOTDIR
    nil
  end
  abort "sync target is a directory: #{target_path}" if target_stat&.directory?
  if target_stat && !target_stat.file? && !target_stat.symlink?
    abort "sync target has unsupported #{target_stat.ftype} type: #{target_path}"
  end
  File.unlink(target_path) if target_stat&.symlink?

  mode = tree_entries.fetch(path).first
  content = locked_contents.fetch(path)
  if mode == "120000"
    File.unlink(target_path) if target_stat&.file?
    File.symlink(content, target_path)
  else
    File.binwrite(target_path, content)
    File.chmod(Integer(mode, 8) & 0o777, target_path)
  end
end

puts "OK: copied #{copy_paths.length} locked sync-only blobs into #{target_root} with Git symlink and executable modes"
