# frozen_string_literal: true

# Classifies locked-revision files by their role in a runnable checkout.
# Code, build definitions, runtime resources, and readable test inputs belong
# to learning tasks. Opaque/generated material is synchronized byte-for-byte;
# project-only documentation and agent metadata can have an explicit exclusion.
module LearningInventory
  SOURCE_EXTENSIONS = %w[
    .c .cc .cpp .cs .go .h .hpp .java .js .jsx .kt .kts .m .mjs .mm .py .rb
    .bat .ps1 .rs .sh .sql .sqltest .swift .tcl .test .tla .ts .tsx
  ].freeze

  READABLE_RESOURCE_EXTENSIONS = %w[
    .cfg .conf .csv .env .expected .golden .html .json .out .patch .properties
    .snap .stderr .stdout .toml .txt .xml .yaml .yml
  ].freeze

  BUILD_BASENAMES = %w[
    .python-version Cargo.toml CMakeLists.txt Dockerfile Gemfile Makefile
    Package.swift Pipfile Podfile
    pyproject.toml setup.py flake.nix rust-toolchain rust-toolchain.toml
    cbindgen.toml gradle.properties gradlew gradlew.bat package.json
  ].freeze

  BUILD_EXTENSIONS = %w[
    .csproj .gradle .kts .nix .pbxproj .plist .podspec .pro .props .sln .slnx
    .storyboard .targets .xcprivacy .xcscheme .xcworkspacedata
  ].freeze

  SKIPPED_ROOTS = %w[
    .claude .codex .github assets docs learn licenses tasks
  ].freeze

  IMPORTED_SYNC_PREFIXES = %w[
    sqlite/conformance/upstream/
    testing/sqlite_test_ext/include/
  ].freeze

  OPAQUE_TOOL_SYNC_PREFIXES = %w[
    bindings/javascript/.yarn/releases/
  ].freeze

  EXPLICIT_SYNC_PREFIXES = (IMPORTED_SYNC_PREFIXES + OPAQUE_TOOL_SYNC_PREFIXES).freeze

  GENERATED_OR_LOCK_BASENAMES = %w[
    Cargo.lock package-lock.json yarn.lock
  ].freeze

  module_function

  def direct_learning_paths(modes, contents)
    modes.keys.select do |path|
      learning_source?(path, contents.fetch(path), mode: modes.fetch(path))
    end
  end

  def learning_paths(modes, contents)
    direct = direct_learning_paths(modes, contents)
    referenced = referenced_paths(direct, modes.keys, contents)
    (direct + referenced).uniq.reject { |path| modes.fetch(path) == "120000" }.sort
  end

  def learning_source?(path, content, mode: nil)
    return false if ignored_path?(path)

    learning_role?(path, content, mode: mode)
  end

  def learning_role?(path, content, mode: nil)
    return false if mode == "120000"

    basename = File.basename(path)
    return true if basename == "__init__.py" && content.empty?
    return false if content.empty? || !text?(content)
    return false if generated_or_lock?(path) || generated_content?(content)
    return false if document_path?(path)

    extension = File.extname(path)
    return true if SOURCE_EXTENSIONS.include?(extension)
    return true if READABLE_RESOURCE_EXTENSIONS.include?(extension)
    return true if build_definition?(path)
    return true if executable?(mode)
    return true if runtime_resource_path?(path)

    false
  end

  def text?(content)
    return false if content.include?("\0")

    content.dup.force_encoding(Encoding::UTF_8).valid_encoding?
  end

  def referenced_paths(source_paths, tree, contents)
    reference_map(source_paths, tree, contents).keys.select do |path|
      content = contents.fetch(path)
      !learning_source?(path, content) &&
        text?(content) &&
        !content.empty? &&
        !ignored_path?(path) &&
        !generated_or_lock?(path) &&
        !generated_content?(content) &&
        !document_path?(path)
    end
  end

  def reference_map(source_paths, tree, contents)
    tree_set = tree.to_h { |path| [path, true] }
    unique_basenames = tree.group_by { |path| File.basename(path) }
      .select { |_basename, paths| paths.one? }
      .transform_values(&:first)
    references = Hash.new { |hash, key| hash[key] = [] }

    source_paths.each do |source_path|
      content = contents.fetch(source_path)
      next unless text?(content)

      directory = File.dirname(source_path)
      content.scan(/[A-Za-z0-9_@.+-]+(?:\/[A-Za-z0-9_@.+-]+)+|[A-Za-z0-9_.-]+\.[A-Za-z0-9_.-]+/).each do |raw_token|
        token = raw_token.sub(%r{\A\./}, "").sub(/[?#].*\z/, "")
        candidates = [token, File.expand_path(token, "/#{directory}").sub(%r{\A/}, "")]
        candidates << unique_basenames[token] if unique_basenames.key?(token)
        candidates.compact.uniq.each do |candidate|
          next if candidate == source_path || !tree_set[candidate]

          references[candidate] << source_path unless references[candidate].include?(source_path)
        end
      end
    end

    references
  end

  def relocatable_resource_paths(modes, contents)
    direct_set = direct_learning_paths(modes, contents).to_h { |path| [path, true] }
    learning_paths(modes, contents).select do |path|
      support_resource?(path, contents.fetch(path)) || !direct_set[path]
    end
  end

  def support_resource?(path, content)
    basename = File.basename(path)
    return true if basename == "__init__.py" && content.empty?
    return false if SOURCE_EXTENSIONS.include?(File.extname(path))
    return false if build_definition?(path)

    READABLE_RESOURCE_EXTENSIONS.include?(File.extname(path)) || runtime_resource_path?(path)
  end

  def build_definition?(path)
    basename = File.basename(path)
    extension = File.extname(path)
    (!path.include?("/") && %w[.json .toml .xml .yaml .yml].include?(extension)) ||
      path.start_with?(".cargo/", ".config/") ||
      path.end_with?("/.bundle/config") ||
      BUILD_BASENAMES.include?(basename) ||
      BUILD_EXTENSIONS.include?(extension) ||
      basename.start_with?("Dockerfile") ||
      basename.match?(/\A(?:requirements(?:-[A-Za-z0-9_.-]+)?\.txt|tsconfig(?:\.[A-Za-z0-9_.-]+)?\.json)\z/) ||
      %w[go.mod go.sum settings.gradle settings.gradle.kts build.gradle build.gradle.kts].include?(basename) ||
      %w[openapi.json nswag.json].include?(basename)
  end

  def resource_placements(modes, contents, path_order)
    learning = learning_paths(modes, contents)
    learning_set = learning.to_h { |path| [path, true] }
    resources = relocatable_resource_paths(modes, contents)
    resource_set = resources.to_h { |path| [path, true] }
    anchors = learning.reject { |path| resource_set[path] || !path_order.key?(path) }
    references = reference_map(learning, modes.keys, contents)

    resources.to_h do |path|
      pair = paired_source_path(path, learning_set)
      placement = if pair && path_order.key?(pair) && !resource_set[pair]
                    { anchor: pair, side: :after, reason: :paired_source }
                  else
                    referrers = references.fetch(path, []).select do |referrer|
                      path_order.key?(referrer) && !resource_set[referrer]
                    end
                    referrer = referrers.min_by { |candidate| path_order.fetch(candidate) }
                    if referrer
                      { anchor: referrer, side: :before, reason: :first_reference }
                    else
                      anchor = nearest_package_anchor(path, anchors, path_order)
                      anchor.nil? ? nil : { anchor: anchor, side: :before, reason: :same_package }
                    end
                  end
      [path, placement]
    end
  end

  def paired_source_path(path, learning_set)
    if File.extname(path) == ".snap" && File.basename(File.dirname(path)) == "snapshots"
      suite = File.basename(path, ".snap").split("__", 2).first
      candidate = File.join(File.dirname(File.dirname(path)), "#{suite}.sqltest")
      return candidate if learning_set[candidate]
    end

    extension_pairs = {
      ".cfg" => ".tla",
      ".out" => ".sql"
    }
    replacement = extension_pairs[File.extname(path)]
    return nil if replacement.nil?

    candidate = path.sub(/#{Regexp.escape(File.extname(path))}\z/, replacement)
    learning_set[candidate] ? candidate : nil
  end

  def nearest_package_anchor(path, candidates, path_order)
    path_components = path.split("/")
    scope_length = %w[bindings extensions postgres serverless sync testing tlaplus].include?(path_components.first) ? 2 : 1
    scope = path_components.first(scope_length)
    scoped_candidates = candidates.select do |candidate|
      candidate.split("/").first(scope_length) == scope
    end
    return nil if scoped_candidates.empty?

    scoped_candidates.max_by do |candidate|
      candidate_components = candidate.split("/")
      common_length = path_components.zip(candidate_components).take_while { |left, right| left == right }.length
      [common_length, -path_order.fetch(candidate)]
    end
  end

  def ignored_path?(path)
    components = path.split("/")
    return true if EXPLICIT_SYNC_PREFIXES.any? { |prefix| path.start_with?(prefix) }
    return true if SKIPPED_ROOTS.include?(components.first)
    return true if components.any? do |component|
      component.start_with?(".") && !%w[.bundle .cargo .config].include?(component) && component != File.basename(path)
    end
    return true if components.any? do |component|
      %w[node_modules target vendor].include?(component)
    end

    false
  end

  def generated_or_lock?(path)
    basename = File.basename(path)
    return true if GENERATED_OR_LOCK_BASENAMES.include?(basename)
    return true if basename.end_with?(".lock")
    return true if path.include?("/templates/") && path.include?(".xcframework/")

    false
  end

  def generated_content?(content)
    header = content.lines.first(8).join.downcase
    header.include?("auto-generated") ||
      header.include?("automatically generated") ||
      header.include?("@generated") ||
      header.include?("generated by napi-rs")
  end

  def runtime_resource_path?(path)
    path.include?("/src/main/resources/") ||
      path.include?("/META-INF/services/") ||
      File.basename(path) == "AndroidManifest.xml"
  end

  def executable?(mode)
    !mode.nil? && (Integer(mode, 8) & 0o111).positive?
  end

  def sync_disposition(path, content, mode: nil)
    raise "learning source cannot have a sync-only disposition: #{path}" if learning_source?(path, content, mode: mode)

    top_level = path.split("/", 2).first
    return ["exclude", "curriculum specification is maintained outside learn-codebase"] if top_level == "tasks"
    return ["exclude", "source-learning guide is maintained outside learn-codebase"] if top_level == "learn"
    return ["exclude", "repository documentation is not required by build/runtime/tests"] if %w[docs licenses].include?(top_level)
    return ["exclude", "agent configuration is not part of the reconstructed codebase"] if %w[.claude .codex].include?(top_level)
    return ["exclude", "CI and repository-host configuration is outside the runnable codebase"] if top_level == ".github"
    return ["exclude", "project illustration or design asset is not required by build/runtime/tests"] if top_level == "assets"
    return ["exclude", "human-facing repository document is not required by build/runtime/tests"] if document_path?(path)
    return ["exclude", "editor temporary file is not part of build/runtime/tests"] if File.basename(path).match?(/\.(?:swp|swo|tmp)\z/)
    return ["copy", "locked symlink target must be recreated byte-for-byte"] if mode == "120000"

    reason = if IMPORTED_SYNC_PREFIXES.any? { |prefix| path.start_with?(prefix) }
               "imported compatibility material must be copied byte-for-byte"
             elsif OPAQUE_TOOL_SYNC_PREFIXES.any? { |prefix| path.start_with?(prefix) }
               "packaged build tool must be copied byte-for-byte"
             elsif generated_or_lock?(path) || generated_content?(content)
               "generated or dependency-locked asset must be copied byte-for-byte"
             elsif !text?(content)
               "binary runtime/test asset must be copied byte-for-byte"
             else
               "non-learning repository asset must be copied byte-for-byte"
             end
    ["copy", reason]
  end

  def document_path?(path)
    basename = File.basename(path)
    extension = File.extname(path).downcase
    basename.match?(/\A(?:README|CHANGELOG|CONTRIBUTING|LICENSE|SECURITY|CODE_OF_CONDUCT)(?:\.|\z)/i) ||
      %w[.md .mdx].include?(extension)
  end
end
