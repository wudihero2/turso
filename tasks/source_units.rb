# frozen_string_literal: true

require "open3"

# Finds boundaries that are safe for a teaching task to use as a Source slice.
# A boundary is before a complete source item: a Rust item/method/test, a SQLtest
# case (including its annotations), or the equivalent test/function boundary in
# another language. The returned units always cover every line exactly once.
module SourceUnits
  Unit = Struct.new(:first_line, :last_line, :labels, :kind, keyword_init: true)

  TARGET_LINES = 200
  CONTROL_FLOW_NAMES = %w[
    catch do else finally for foreach if lock new return super switch synchronized
    this throw try using while when
  ].freeze
  RUST_ITEM_KINDS = %w[
    Const Enum EnumMember ExternBlock Function Impl Macro Method Module Static Struct Trait TypeAlias Union Variant
  ].freeze

  module_function

  def for(path, content)
    line_count = count_lines(content)
    return [] if line_count.zero?

    extension = File.extname(path)
    starts = if File.basename(path) == "Makefile"
               makefile_starts(content)
             elsif extension.empty? && content.start_with?("#!")
               content.lines.first.to_s.match?(/python|uv\s+run\s+--script/) ? python_starts(content) : shell_starts(content)
             else
               case extension
             when ".rs" then rust_starts(content)
             when ".sqltest" then sqltest_starts(content)
             when ".test", ".tcl" then tcl_test_starts(content)
             when ".py" then python_starts(content)
             when ".sh" then shell_starts(content)
             when ".ps1" then powershell_starts(content)
             when ".sql" then golden_sql_starts(content)
             when ".tla" then tla_starts(content)
             when ".go" then go_starts(content)
             when ".java", ".kt", ".kts", ".cs" then brace_language_starts(content)
             when ".js", ".jsx", ".mjs", ".ts", ".tsx" then javascript_starts(content)
             when ".h", ".hpp" then c_header_starts(content)
             when ".c", ".cpp", ".m", ".mm" then c_family_starts(content)
             when ".json" then json_starts(content)
             when ".xml", ".csproj", ".props", ".targets", ".plist", ".storyboard", ".xcscheme", ".xcworkspacedata" then xml_starts(content)
             when ".out" then golden_sql_starts(content)
             when ".snap" then snapshot_starts(content)
             when ".patch" then regexp_starts(content, /^(---\s+.+|@@\s+.+@@)/, documentation: false)
             when ".toml" then regexp_starts(content, /^\s*(\[\[?[^\]]+\]\]?)/, documentation: false)
             when ".yml", ".yaml", ".sublime-syntax" then yaml_starts(content)
             when ".md", ".mdx" then regexp_starts(content, /^(\#{1,6}\s+.+)/, documentation: false)
             when ".lock" then lockfile_starts(content)
             else paragraph_starts(content)
             end
             end

    build_units(starts, line_count)
  end

  def count_lines(content)
    return 0 if content.empty?

    content.count("\n") + (content.end_with?("\n") ? 0 : 1)
  end

  def build_units(raw_starts, line_count)
    starts = { 1 => [["file prelude"], :preamble] }
    raw_starts.each do |line, label, kind|
      next unless line.between?(1, line_count)

      entry = starts[line] ||= [[], kind]
      entry[0] << label unless entry[0].include?(label)
      entry[1] = kind if entry[1] == :preamble
    end

    ordered = starts.keys.sort
    ordered.each_with_index.map do |first_line, index|
      last_line = index + 1 < ordered.length ? ordered[index + 1] - 1 : line_count
      labels, kind = starts.fetch(first_line)
      Unit.new(first_line: first_line, last_line: last_line, labels: labels, kind: kind)
    end
  end

  def rust_starts(content)
    output, error_output, status = Open3.capture3("rust-analyzer", "symbols", stdin_data: content)
    raise "rust-analyzer could not parse locked Rust source: #{error_output}" unless status.success?

    nodes = output.lines.map do |line|
      match = line.match(
        /\AStructureNode \{ parent: (None|Some\((\d+)\)), label: "(.*?)", .*?node_range: (\d+)\.\.(\d+), kind: (?:SymbolKind\((\w+)\)|(\w+))/
      )
      next if match.nil?

      {
        parent: match[1] == "None" ? nil : Integer(match[2], 10),
        label: match[3].gsub('\\"', '"'),
        first_byte: Integer(match[4], 10),
        last_byte: Integer(match[5], 10),
        kind: match[6] || match[7]
      }
    end.compact

    line_offsets = [0]
    content.each_byte.with_index { |byte, index| line_offsets << index + 1 if byte == 10 }
    byte_line = lambda do |byte_offset|
      index = line_offsets.bsearch_index { |offset| offset > byte_offset }
      index || line_offsets.length
    end
    syntax_start_lines = nil
    load_syntax_start_lines = lambda do
      next syntax_start_lines unless syntax_start_lines.nil?

      syntax_output, syntax_errors, syntax_status = Open3.capture3("rust-analyzer", "parse", stdin_data: content)
      raise "rust-analyzer could not build the locked Rust syntax tree: #{syntax_errors}" unless syntax_status.success?

      syntax_start_lines = Hash.new { |hash, key| hash[key] = {} }
      syntax_output.scan(/^(\s*)(MATCH_ARM|TUPLE_EXPR|LET_STMT|IF_EXPR|FOR_EXPR|WHILE_EXPR|LOOP_EXPR|MACRO_CALL)@(\d+)\.\.(\d+)/).each do |indent, kind, first_byte, last_byte|
        syntax_start_lines[kind][byte_line.call(Integer(first_byte, 10))] = {
          indent: indent.length,
          last_line: byte_line.call([Integer(last_byte, 10) - 1, Integer(first_byte, 10)].max)
        }
      end
      syntax_start_lines
    end

    children = Hash.new { |hash, key| hash[key] = [] }
    nodes.each_with_index { |node, index| children[node[:parent]] << index }
    starts = []

    select_node = lambda do |index|
      node = nodes.fetch(index)
      return unless RUST_ITEM_KINDS.include?(node[:kind])

      first_line = byte_line.call(node[:first_byte])
      last_line = byte_line.call([node[:last_byte] - 1, node[:first_byte]].max)
      kind_label = node[:kind].downcase
      label = node[:label].start_with?(kind_label + " ") ? node[:label] : "#{kind_label} #{node[:label]}"
      starts << [first_line, label, :rust_item]

      length = last_line - first_line + 1
      item_children = children[index].select do |child_index|
        RUST_ITEM_KINDS.include?(nodes.fetch(child_index)[:kind])
      end
      if length > TARGET_LINES && %w[Const Static].include?(node[:kind])
        starts.concat(rust_data_table_starts(content, first_line, last_line))
      elsif length > TARGET_LINES && %w[Enum ExternBlock Impl Module Trait].include?(node[:kind]) && !item_children.empty?
        item_children.each { |child_index| select_node.call(child_index) }
      elsif length > TARGET_LINES && %w[Function Method].include?(node[:kind])
        entries = if node[:label].start_with?("test", "prop_")
                    # Table-driven cases are often inside vec!/macro token trees,
                    # which rust-analyzer intentionally does not lower as
                    # TUPLE_EXPR nodes. The repeated tuple + string rule below
                    # keeps each complete macro scenario together.
                    rust_test_scenario_starts(content, first_line, last_line)
                  else
                    rust_match_arm_starts(
                      content,
                      first_line,
                      last_line,
                      load_syntax_start_lines.call["MATCH_ARM"]
                    )
                  end
        if entries.empty?
          entries = rust_local_tuple_table_starts(
            content,
            first_line,
            last_line,
            load_syntax_start_lines.call["LET_STMT"],
            load_syntax_start_lines.call["TUPLE_EXPR"]
          )
        end
        if entries.empty?
          local_children = children[index].select { |child_index| nodes.fetch(child_index)[:kind] == "Local" }
          if local_children.length >= 4
            let_starts = load_syntax_start_lines.call["LET_STMT"]
            entries = local_children.map do |child_index|
              child = nodes.fetch(child_index)
              line = byte_line.call(child[:first_byte])
              next unless let_starts[line]

              [line, "stage #{child[:label]}", :rust_stage]
            end.compact
          end
        end
        entries.each { |entry| starts << entry }
      end
    end

    children[nil].each { |index| select_node.call(index) }

    # rust-analyzer treats the body of quote! as an opaque token tree. Procedural
    # macros can still contain hundreds of lines of complete generated methods;
    # use the generated method declarations (including their attributes) as the
    # teaching boundary instead of treating the whole quote as one unit.
    content.lines.each_with_index do |line, index|
      next unless line.match?(/^\s*(?:pub\s+)?unsafe\s+extern\s+"C"\s+fn\s+#[A-Za-z_][A-Za-z0-9_]*/)

      start_index = index
      start_index -= 1 while start_index.positive? && content.lines[start_index - 1].match?(/^\s*#\[/)
      label = line[/\bfn\s+#([A-Za-z_][A-Za-z0-9_]*)/, 1]
      starts << [start_index + 1, "generated function ##{label}", :rust_generated_item]
    end

    # Benchmark and test functions often keep large scenario tables in a local
    # `let ... = [(...), ...]`. Keep each top-level tuple intact even when an
    # unrelated match later in the same function already provided boundaries.
    syntax = load_syntax_start_lines.call
    starts.concat(
      rust_local_tuple_table_starts(
        content,
        1,
        count_lines(content),
        syntax["LET_STMT"],
        syntax["TUPLE_EXPR"]
      )
    )

    # A single outer arm can itself contain a full state machine. Refine only
    # the still-oversized gaps, using syntax-tree statement/branch starts. This
    # never falls back to an arbitrary line number.
    line_count = count_lines(content)
    2.times do
      ordered = ([1] + starts.map(&:first)).uniq.sort
      oversized_gaps = ordered.each_with_index.map do |first, index|
        last = index + 1 < ordered.length ? ordered[index + 1] - 1 : line_count
        (last - first + 1 > TARGET_LINES) ? (first..last) : nil
      end.compact
      break if oversized_gaps.empty?

      syntax = load_syntax_start_lines.call
      added = false
      oversized_gaps.each do |gap|
        candidates = %w[MATCH_ARM LET_STMT IF_EXPR FOR_EXPR WHILE_EXPR LOOP_EXPR MACRO_CALL].flat_map do |kind|
          syntax[kind].map do |line_number, info|
            next unless gap.cover?(line_number) && line_number > gap.begin

            [line_number, info.fetch(:indent), kind, info.fetch(:last_line)]
          end.compact
        end
        next if candidates.empty?

        shallowest_indent = candidates.map { |_line, indent, _kind, _last_line| indent }.min
        candidates.each do |line_number, indent, kind, last_line|
          next unless indent == shallowest_indent

          preview = content.lines[line_number - 1].to_s.strip.gsub(/\s+/, " ")[0, 64]
          starts << [line_number, "#{kind.downcase} #{preview}", :rust_stage]
          if last_line < gap.end
            starts << [last_line + 1, "resume after #{kind.downcase}", :rust_stage]
          end
          added = true
        end
      end
      break unless added
    end
    starts
  end

  def rust_local_tuple_table_starts(content, first_line, last_line, let_starts, tuple_starts)
    lines = content.lines
    long_lets = let_starts.select do |line_number, info|
      line_number.between?(first_line, last_line) && info.fetch(:last_line) - line_number + 1 > TARGET_LINES
    end

    long_lets.flat_map do |let_line, let_info|
      tuples = tuple_starts.select do |line_number, info|
        line_number > let_line && line_number <= let_info.fetch(:last_line) && info.fetch(:last_line) <= let_info.fetch(:last_line)
      end
      next [] if tuples.length < 2

      shallowest_indent = tuples.values.map { |info| info.fetch(:indent) }.min
      top_level_tuples = tuples.select { |_line_number, info| info.fetch(:indent) == shallowest_indent }.sort
      next [] if top_level_tuples.length < 2

      top_level_tuples.drop(1).map do |line_number, _info|
        preview_lines = lines[(line_number - 1)..[line_number + 2, last_line - 1].min]
        preview = preview_lines.join(" ").strip.gsub(/\s+/, " ")[0, 72]
        [line_number, "data tuple #{preview}", :rust_data_group]
      end
    end
  end

  def rust_data_table_starts(content, first_line, last_line)
    lines = content.lines
    header = lines[(first_line - 1)..[first_line + 4, last_line - 1].min].join
    return [] unless header.include?("= [")

    entries = (first_line..last_line).each_with_object([]) do |line_number, result|
      line = lines[line_number - 1]
      match = line.match(/\A(\s+)\S.*?,\s*(?:\/\*.*\*\/)?\s*$/)
      result << [line_number, match[1].length] unless match.nil?
    end
    return [] if entries.empty?

    shallowest_indent = entries.map(&:last).min
    entry_lines = entries.select { |_line_number, indent| indent == shallowest_indent }.map(&:first)
    starts = []
    chunk_start = first_line
    while last_line - chunk_start + 1 > TARGET_LINES
      boundary = entry_lines.find { |line_number| line_number >= chunk_start + TARGET_LINES }
      break if boundary.nil? || boundary >= last_line

      starts << [boundary, "data entry group at line #{boundary}", :rust_data_group]
      chunk_start = boundary
    end
    starts
  end

  # Large interpreter and aggregate functions are naturally taught by complete
  # match arms. Only use a pattern indentation that occurs repeatedly, so an
  # inner one-off match cannot become an accidental outer task boundary.
  def rust_match_arm_starts(content, first_line, last_line, syntax_starts = nil)
    lines = content.lines
    candidates = []
    (first_line..last_line).each do |line_number|
      line = lines[line_number - 1].to_s
      match = line.match(/\A(\s*)(?:\|\s*)?((?:[A-Za-z_][A-Za-z0-9_]*::)+[A-Za-z0-9_]+|Self::[A-Za-z0-9_]+|_)\b/)
      next if match.nil?
      next if syntax_starts && !syntax_starts[line_number]
      next unless lines[(line_number - 1)..[line_number + 20, last_line - 1].min].join.include?("=>")

      candidates << [line_number, match[1].length, match[2]]
    end
    repeated_indents = candidates.group_by { |_line, indent, _label| indent }
      .select { |_indent, entries| entries.length >= 4 }
    repeated_indents.values.flatten(1).map do |line_number, _candidate_indent, label|
      [line_number, "match arm #{label}", :rust_match_arm]
    end
  end

  # Some upstream tests intentionally put hundreds of table-driven cases in a
  # single Rust #[test]. A complete tuple/object in that table is the scenario
  # boundary; splitting one tuple would be just as bad as splitting a test fn.
  def rust_test_scenario_starts(content, first_line, last_line, syntax_starts = nil)
    lines = content.lines
    candidates = []
    (first_line..last_line).each do |line_number|
      line = lines[line_number - 1].to_s
      match = line.match(/\A(\s*)\(\s*$/)
      next if match.nil?
      next if syntax_starts && !syntax_starts[line_number]

      lookahead = lines[line_number, 4].to_a.join
      next unless lookahead.match?(/\bb?["']/)

      candidates << [line_number, match[1].length]
    end
    indent, entries = candidates.group_by { |_line, candidate_indent| candidate_indent }
      .select { |_candidate_indent, grouped| grouped.length >= 4 }
      .min_by(&:first)
    return [] if indent.nil?

    entries.map do |line_number, _candidate_indent|
      preview = lines[line_number, 3].to_a.join(" ").strip.gsub(/\s+/, " ")
      [line_number, "test scenario #{preview[0, 80]}", :rust_test_scenario]
    end
  end

  def sqltest_starts(content)
    lines = content.lines
    starts = []
    lines.each_with_index do |line, index|
      match = line.match(/^(?:test|snapshot|setup)\s+([^\s{]+)/)
      next if match.nil?

      start_index = index
      while start_index.positive?
        previous = lines[start_index - 1]
        break unless previous.match?(/^\s*(?:@|#|\/\/)/) || previous.strip.empty?

        start_index -= 1
      end
      starts << [start_index + 1, "SQLtest #{match[1]}", :sqltest_case]
    end
    starts
  end

  def tcl_test_starts(content)
    lines = content.lines
    starts = []
    lines.each_with_index do |line, index|
      match = line.match(/^\s*(do_[A-Za-z0-9_]*test|test|proc)\s+([^\s{]+)/)
      next if match.nil?

      start_index = preceding_comments(lines, index, /^\s*#/)
      kind = match[1] == "proc" ? :tcl_proc : :tcl_test
      starts << [start_index + 1, "TCL #{match[2]}", kind]
    end
    starts
  end

  def python_starts(content)
    lines = content.lines
    starts = []
    lines.each_with_index do |line, index|
      match = line.match(/\A( {0,4})(?:async\s+)?(?:def|class)\s+([A-Za-z_]\w*)/)
      unless match.nil?
        start_index = index
        while start_index.positive? && lines[start_index - 1].match?(/^\s*@/)
          start_index -= 1
        end
        starts << [start_index + 1, "Python #{match[2]}", :python_item]
        next
      end

      stage = line.match(/\A(?:(for|if|while|with|try)\b|([A-Za-z_]\w*)\.(execute|executemany)\s*\(|(print)\s*\()/)
      next if stage.nil?

      label = stage.captures.compact.join(" ")
      starts << [preceding_documentation(lines, index) + 1, "Python top-level #{label}", :python_stage]
    end
    starts
  end

  def shell_starts(content)
    lines = content.lines
    starts = []
    lines.each_with_index do |line, index|
      if (match = line.match(/^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{/))
        starts << [preceding_comments(lines, index, /^\s*#/) + 1, "shell function #{match[1]}", :shell_function]
      elsif line.match?(/^#\s*\S/) && (index.zero? || lines[index - 1].strip.empty?)
        label = line.sub(/^#\s*/, "").strip
        starts << [index + 1, "shell section #{label[0, 80]}", :shell_section]
      end
    end
    starts
  end

  def powershell_starts(content)
    lines = content.lines
    lines.each_with_index.each_with_object([]) do |(line, index), starts|
      if (match = line.match(/^\s*function\s+([A-Za-z_][A-Za-z0-9_-]*)/i))
        starts << [preceding_comments(lines, index, /^\s*#/) + 1, "PowerShell function #{match[1]}", :powershell_function]
      elsif line.match?(/^#\s*\S/) && (index.zero? || lines[index - 1].strip.empty?)
        starts << [index + 1, "PowerShell section #{line.sub(/^#\s*/, '').strip[0, 80]}", :powershell_section]
      end
    end
  end

  def makefile_starts(content)
    lines = content.lines
    lines.each_with_index.each_with_object([]) do |(line, index), starts|
      match = line.match(/^([^.#\s][^:=]*):(?:\s|$)/)
      next if match.nil?

      starts << [preceding_comments(lines, index, /^\s*#/) + 1, "Make target #{match[1].strip}", :make_target]
    end
  end

  def tla_starts(content)
    lines = content.lines
    lines.each_with_index.each_with_object([]) do |(line, index), starts|
      match = line.match(/^([A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)\s*==/)
      match ||= line.match(/^((?:VARIABLES?|CONSTANTS?)\b.*)/)
      next if match.nil?

      starts << [index + 1, "TLA+ #{match[1].strip[0, 80]}", :tla_operator]
    end
  end

  def regexp_starts(content, regexp, documentation: true)
    lines = content.lines
    lines.each_with_index.map do |line, index|
      match = line.match(regexp)
      next if match.nil?

      start_index = documentation ? preceding_documentation(lines, index) : index
      [start_index + 1, match[1], :language_item]
    end.compact
  end

  def go_starts(content)
    lines = content.lines
    starts = regexp_starts(content, /^func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)/)
    lines.each_with_index do |line, index|
      match = line.match(/^(type|const|var)\s+(?:\(|([A-Za-z_]\w*))/)
      next if match.nil?

      label = match[2] || "#{match[1]} declaration group"
      starts << [preceding_documentation(lines, index) + 1, "Go #{label}", :go_declaration]
    end
    starts
  end

  # Java, Kotlin, and C# methods live directly inside a class/interface body.
  # Tracking brace depth prevents an if/try/synchronized inside a method from
  # becoming a fake teaching boundary. The scanner masks strings and comments
  # first, so braces in documentation and literals do not change the scope.
  def brace_language_starts(content)
    lines = content.lines
    masked_lines = mask_comments_and_strings(content).lines
    starts = []
    depth = 0
    class_depths = []
    pending_class_depth = nil

    masked_lines.each_with_index do |masked_line, index|
      class_depths.reject! { |class_depth| depth < class_depth }
      if masked_line.match?(/\b(?:class|interface|enum|record|object)\s+[A-Za-z_]\w*/)
        pending_class_depth = depth
      end

      allowed_scope = depth.zero? || class_depths.include?(depth)
      if allowed_scope && (name = callable_name(masked_lines, index))
        start_index = preceding_documentation(lines, index)
        starts << [start_index + 1, name, :language_item]
      end

      opens = masked_line.count("{")
      closes = masked_line.count("}")
      if !pending_class_depth.nil? && opens.positive?
        class_depths << pending_class_depth + 1
        pending_class_depth = nil
      end
      depth += opens - closes
      depth = 0 if depth.negative?
    end
    starts
  end

  def callable_name(masked_lines, index)
    first_line = masked_lines[index].to_s
    return nil unless first_line.include?("(")
    return nil if first_line.lstrip.start_with?("@", "[")

    signature = String.new
    index.upto([index + 12, masked_lines.length - 1].min) do |line_index|
      signature << " " << masked_lines[line_index].strip
      break if signature.include?("{") || signature.include?(";") || signature.include?("=>")
    end
    return nil unless signature.include?("(")
    return nil unless signature.include?("{") || signature.include?(";") || signature.include?("=>")
    return nil if signature.split("(", 2).first.include?("=")

    name = callable_identifier(signature)
    return nil if name.nil? || CONTROL_FLOW_NAMES.include?(name)

    prefix = signature[0...top_level_open_paren(signature)]
    return nil if prefix.rstrip.end_with?(".", "::")

    name
  end

  # Find the identifier attached to the first call parenthesis outside a
  # TypeScript/Java generic parameter list. A plain regexp sees the `(` in
  # `F extends (...args)` first and incorrectly calls the method `extends`.
  def callable_identifier(signature)
    paren_index = top_level_open_paren(signature)
    return nil if paren_index.nil?

    prefix = signature[0...paren_index].rstrip
    if prefix.end_with?(">")
      generic_start = matching_top_level_generic_start(prefix)
      return prefix[0...generic_start][/[A-Za-z_$][\w$]*\s*\z/]&.strip unless generic_start.nil?
    end

    prefix[/([A-Za-z_$][\w$]*)\s*\z/, 1]
  end

  def top_level_open_paren(signature)
    angle_depth = 0
    signature.each_char.with_index do |character, index|
      case character
      when "<" then angle_depth += 1
      when ">"
        angle_depth -= 1 if angle_depth.positive? && signature[index - 1] != "="
      when "(" then return index if angle_depth.zero?
      end
    end
    nil
  end

  def matching_top_level_generic_start(prefix)
    angle_depth = 0
    (prefix.length - 1).downto(0) do |index|
      case prefix[index]
      when ">" then angle_depth += 1 unless prefix[index - 1] == "="
      when "<"
        angle_depth -= 1
        return index if angle_depth.zero?
      end
    end
    nil
  end

  def javascript_starts(content)
    lines = content.lines
    masked_lines = mask_comments_and_strings(content).lines
    starts = []
    depth = 0
    class_depths = []
    pending_class_depth = nil

    masked_lines.each_with_index do |masked_line, index|
      class_depths.reject! { |class_depth| depth < class_depth }
      pending_class_depth = depth if masked_line.match?(/\bclass\s+[A-Za-z_$][\w$]*/)

      original = lines[index]
      label = if depth.zero? && (match = masked_line.match(/^\s*(?:export\s+)?(?:declare\s+)?(?:interface|type|enum|namespace)\s+([A-Za-z_$][\w$]*)/))
                match[1]
              elsif depth.zero? && masked_line.match?(/^\s*declare\s+global\s*\{/)
                "declare global"
              elsif (match = masked_line.match(/^\s*(?:(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*))/))
                match[1]
              elsif depth.zero? && (match = masked_line.match(/^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\b/))
                match[1]
              elsif (match = original.match(/^\s*\/\/\s*(?:Performance test|Test):\s*(.+)/))
                "scenario #{match[1].strip}"
              elsif (match = original.match(/^\s*(describe|it|test|testFn)(?:\.[A-Za-z_$][\w$]*)*\s*\(\s*['"`]([^'"`]*)/))
                "#{match[1]} #{match[2]}"
              elsif class_depths.include?(depth)
                callable_name(masked_lines, index)
              end
      unless label.nil? || CONTROL_FLOW_NAMES.include?(label)
        start_index = preceding_documentation(lines, index)
        starts << [start_index + 1, label, :javascript_item]
      end

      opens = masked_line.count("{")
      closes = masked_line.count("}")
      if !pending_class_depth.nil? && opens.positive?
        class_depths << pending_class_depth + 1
        pending_class_depth = nil
      end
      depth += opens - closes
      depth = 0 if depth.negative?
    end
    starts
  end

  def c_family_starts(content)
    lines = content.lines
    masked_lines = mask_comments_and_strings(content).lines
    starts = masked_lines.each_with_index.map do |line, index|
      match = line.match(/^\s{0,4}(?:[A-Za-z_][A-Za-z0-9_:<>,~*&]*[\s*&]+)+([~A-Za-z_][A-Za-z0-9_:~]*)\s*\(/)
      knr_match = match.nil?
      match ||= line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*\(/)
      next if match.nil?
      next if CONTROL_FLOW_NAMES.include?(match[1])

      signature = String.new(line)
      index.succ.upto([index + 40, masked_lines.length - 1].min) do |line_index|
        break if signature.include?("{")
        break if !knr_match && signature.include?(";")

        signature << masked_lines[line_index]
      end
      next unless signature.include?("{")
      next if !knr_match && signature.index(";") && signature.index(";") < signature.index("{")

      [preceding_documentation(lines, index) + 1, match[1], :c_item]
    end.compact

    # React Native host installers can be one C++ function containing several
    # complete JSI host-function lambdas. Each assignment is a real independent
    # API stage and its closing `});` keeps the boundary safer than cutting the
    # outer function at an arbitrary line budget.
    host_functions = []
    masked_lines.each_with_index do |line, index|
      match = line.match(/^\s*auto\s+([A-Za-z_]\w*)\s*=\s*jsi::Function::createFromHostFunction\s*\(/)
      next if match.nil?

      starts << [preceding_documentation(lines, index) + 1, "host function #{match[1]}", :c_stage]
      host_functions << [index, line[/^\s*/].length, match[1]]
    end
    host_functions.each_with_index do |(first_index, indent, label), host_index|
      last_index = host_index + 1 < host_functions.length ? host_functions[host_index + 1][0] - 1 : lines.length - 1
      next unless last_index - first_index + 1 > TARGET_LINES

      stage_indent = indent + 8
      (first_index..last_index).each do |index|
        match = lines[index].match(/^\s{#{stage_indent}}\/\/\s*(.+)/)
        next if match.nil?

        starts << [index + 1, "#{label} stage #{match[1].strip[0, 72]}", :c_host_stage]
      end
    end

    # A command dispatcher is often one large C function. A full switch case
    # is a meaningful independent command path. Keep adjacent fall-through
    # labels together so the first label is not detached from its body.
    masked_lines.each_with_index do |line, index|
      match = line.match(/^\s*(case\s+.+?|default)\s*:/)
      next if match.nil?

      previous_index = index - 1
      previous_index -= 1 while previous_index >= 0 && masked_lines[previous_index].strip.empty?
      next if previous_index >= 0 && masked_lines[previous_index].match?(/^\s*(?:case\s+.+?|default)\s*:/)

      starts << [preceding_documentation(lines, index) + 1, "switch #{match[1]}", :c_switch_case]
    end

    # Long C entrypoints often contain several complete setup, run, and report
    # phases without helper functions. A comment at the function body's own
    # brace depth names that phase; comments inside if/loop bodies do not.
    # Only add these boundaries inside a gap that is still too large.
    ordered = ([1] + starts.map(&:first)).uniq.sort
    oversized_gaps = ordered.each_with_index.each_with_object([]) do |(first, index), gaps|
      last = index + 1 < ordered.length ? ordered[index + 1] - 1 : lines.length
      gaps << (first..last) if last - first + 1 > TARGET_LINES
    end
    unless oversized_gaps.empty?
      depth = 0
      masked_lines.each_with_index do |masked_line, index|
        line_number = index + 1
        original = lines[index]
        if depth == 1 && oversized_gaps.any? { |gap| gap.cover?(line_number) }
          match = original.match(/^\s{0,4}(?:\/\*+|\/\/)\s*([^*\/].*?)\s*(?:\*\/)?\s*$/)
          unless match.nil?
            label = match[1].sub(/\s*\*\/$/, "").strip
            starts << [line_number, "C stage #{label[0, 72]}", :c_stage] unless label.empty?
          end
        end
        depth += masked_line.count("{") - masked_line.count("}")
        depth = 0 if depth.negative?
      end
    end
    starts
  end

  def c_header_starts(content)
    lines = content.lines
    starts = []
    lines.each_with_index do |line, index|
      if line.match?(%r{^/\*})
        starts << [index + 1, "documentation section at line #{index + 1}", :c_header_section]
      elsif (match = line.match(/^\s*(?:SQLITE_API\s+)?(?:typedef\s+)?(?:struct\s+)?([A-Za-z_][A-Za-z0-9_]*)[^;]*;\s*$/))
        starts << [preceding_documentation(lines, index) + 1, match[1], :c_header_declaration]
      elsif (match = line.match(/^#\s*(?:define|if|ifdef|ifndef)\s+([A-Za-z_][A-Za-z0-9_]*)/))
        starts << [preceding_documentation(lines, index) + 1, match[1], :c_header_directive]
      end
    end
    starts
  end

  def json_starts(content)
    lines = content.lines
    properties = lines.each_with_index.map do |line, index|
      match = line.match(/\A(\s*)"((?:\\.|[^"\\])+)"\s*:/)
      [index + 1, match[1].length, match[2]] unless match.nil?
    end.compact
    objects = lines.each_with_index.each_with_object([]) do |(line, index), result|
      match = line.match(/\A(\s*)\{\s*$/)
      next if match.nil? || match[1].empty?

      preview = lines[index, 4].join
      label = preview[/"(?:id|name|kind|variant)"\s*:\s*"?([^",}\n]+)/, 1] || "line #{index + 1}"
      result << [index + 1, match[1].length, label]
    end
    if objects.length >= 4
      object_indent = objects.map { |_line, indent, _label| indent }.min
      semantic_starts = properties.select { |_line, indent, _label| indent < object_indent }.map do |line, _indent, label|
        [line, "JSON section #{label}", :data_entry]
      end
      semantic_starts.concat(objects.select { |_line, indent, _label| indent == object_indent }.map do |line, _indent, label|
        [line, "JSON object #{label}", :data_entry]
      end)
      recursive_indented_starts(properties, count_lines(content), "JSON property", semantic_starts)
    else
      recursive_indented_starts(properties, count_lines(content), "JSON property")
    end
  end

  def xml_starts(content)
    elements = content.lines.each_with_index.map do |line, index|
      match = line.match(/\A(\s*)<([A-Za-z_][A-Za-z0-9_.:-]*)(?:\s|>|\/)/)
      [index + 1, match[1].length, match[2]] unless match.nil?
    end.compact
    recursive_indented_starts(elements, count_lines(content), "XML element")
  end

  def golden_sql_starts(content)
    lines = content.lines
    starts = lines.each_with_index.map do |line, index|
      match = line.match(/^\s*((?:SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|COPY|SET|RESET|BEGIN|COMMIT|ROLLBACK|EXPLAIN)\b.*)/i)
      next if match.nil?

      [preceding_comments(lines, index, /^\s*--/) + 1, "golden SQL #{match[1].strip[0, 80]}", :golden_case]
    end.compact

    # Performance queries can contain hundreds of independent scalar values in
    # one IN list. Keep each literal intact, but group the repetitive data so a
    # single benchmark query does not become a 400-line reading task.
    literal_lines = lines.each_with_index.each_with_object([]) do |(line, index), entries|
      match = line.match(/\A(\s*)(?:'(?:[^']|'')*'|"(?:[^"]|"")*"|[-+]?\d+(?:\.\d+)?)\s*,\s*\z/)
      entries << [index + 1, match[1].length] unless match.nil?
    end
    ordered = ([1] + starts.map(&:first)).uniq.sort
    ordered.each_with_index do |first_line, index|
      last_line = index + 1 < ordered.length ? ordered[index + 1] - 1 : lines.length
      next if last_line - first_line + 1 <= TARGET_LINES

      candidates = literal_lines.select { |line_number, _indent| line_number.between?(first_line, last_line) }
      next if candidates.length < 2

      common_indent = candidates.group_by(&:last).max_by { |_indent, entries| entries.length }&.first
      entry_lines = candidates.select { |_line_number, indent| indent == common_indent }.map(&:first)
      chunk_start = first_line
      while last_line - chunk_start + 1 > TARGET_LINES
        boundary = entry_lines.find { |line_number| line_number >= chunk_start + TARGET_LINES }
        break if boundary.nil? || boundary >= last_line

        starts << [boundary, "SQL literal data group at line #{boundary}", :golden_data_group]
        chunk_start = boundary
      end
    end
    starts
  end

  def snapshot_starts(content)
    lines = content.lines
    starts = lines.each_with_index.each_with_object([]) do |(line, index), result|
      if line.match?(/\A(?:---|QUERY PLAN|BYTECODE|RESULTS?)\s*$/)
        result << [index + 1, "snapshot section #{line.strip}", :snapshot_section]
      end
    end

    opcode_lines = lines.each_with_index.each_with_object([]) do |(line, index), result|
      match = line.match(/^\s*(\d+)\s+[A-Za-z][A-Za-z0-9_]*/)
      result << [index + 1, match[1]] unless match.nil?
    end
    ordered = ([1] + starts.map(&:first)).uniq.sort
    gaps = ordered.each_with_index.map do |first_line, index|
      last_line = index + 1 < ordered.length ? ordered[index + 1] - 1 : lines.length
      first_line..last_line
    end
    gaps.each do |gap|
      chunk_start = gap.begin
      while gap.end - chunk_start + 1 > TARGET_LINES
        boundary, address = opcode_lines.find { |line_number, _address| line_number >= chunk_start + TARGET_LINES && gap.cover?(line_number) }
        break if boundary.nil?

        starts << [boundary, "bytecode address #{address}", :snapshot_bytecode]
        chunk_start = boundary
      end
    end
    starts
  end

  def yaml_starts(content)
    entries = content.lines.each_with_index.map do |line, index|
      match = line.match(/\A(\s*)(?:-\s+)?([A-Za-z0-9_.-]+):(?:\s|$)/)
      [index + 1, match[1].length, match[2]] unless match.nil?
    end.compact
    recursive_indented_starts(entries, count_lines(content), "YAML key")
  end

  def recursive_indented_starts(entries, line_count, label_prefix, initial_starts = [])
    starts = initial_starts.dup
    ordered = ([1] + starts.map(&:first)).uniq.sort
    gaps = ordered.each_with_index.map do |first_line, index|
      last_line = index + 1 < ordered.length ? ordered[index + 1] - 1 : line_count
      first_line..last_line
    end
    8.times do
      added = []
      gaps.each do |gap|
        next if gap.size <= TARGET_LINES

        candidates = entries.select { |line, _indent, _label| gap.cover?(line) && line > gap.begin }
        next if candidates.empty?

        shallowest = candidates.map { |_line, indent, _label| indent }.min
        candidates.each do |line, indent, label|
          added << [line, "#{label_prefix} #{label}", :data_entry] if indent == shallowest
        end
      end
      break if added.empty?

      starts.concat(added)
      ordered = ([1] + starts.map(&:first)).uniq.sort
      gaps = ordered.each_with_index.map do |first_line, index|
        last_line = index + 1 < ordered.length ? ordered[index + 1] - 1 : line_count
        first_line..last_line
      end
    end
    starts
  end

  def lockfile_starts(content)
    lines = content.lines
    starts = regexp_starts(content, /^\s*(\[\[?[^\]]+\]\]?)/, documentation: false)
    unless starts.empty?
      return starts
    end

    if lines.any? { |line| line.match?(/^PODS:\s*$/) }
      return lines.each_with_index.map do |line, index|
        match = line.match(/^(  -\s+[^:]+(?::|\z))/)
        [index + 1, match[1].strip[0, 80], :data_entry] unless match.nil?
      end.compact + regexp_starts(content, /^(\S[^:]*:)\s*$/, documentation: false)
    end

    lines.each_with_index.map do |line, index|
      next unless line.match?(/^\S.*:\s*$/) || (index.positive? && !line.strip.empty? && lines[index - 1].strip.empty?)

      [index + 1, line.strip[0, 80], :data_entry]
    end.compact
  end

  def paragraph_starts(content)
    lines = content.lines
    return [] if lines.length <= TARGET_LINES

    lines.each_with_index.map do |line, index|
      next unless index.positive? && !line.strip.empty? && lines[index - 1].strip.empty?

      [index + 1, "paragraph at line #{index + 1}", :text_section]
    end.compact
  end

  def mask_comments_and_strings(content)
    result = String.new
    index = 0
    state = :code
    quote = nil
    while index < content.length
      char = content[index]
      following = content[index, 2]
      case state
      when :code
        if content[index, 3] == '"""'
          result << "   "
          index += 3
          state = :raw_string
          next
        elsif following == "//"
          result << "  "
          index += 2
          state = :line_comment
          next
        elsif following == "/*"
          result << "  "
          index += 2
          state = :block_comment
          next
        elsif char == '"' || char == "'" || char == "`"
          quote = char
          result << " "
          state = :string
        else
          result << char
        end
      when :line_comment
        if char == "\n"
          result << char
          state = :code
        else
          result << " "
        end
      when :block_comment
        if following == "*/"
          result << "  "
          index += 2
          state = :code
          next
        else
          result << (char == "\n" ? "\n" : " ")
        end
      when :string
        if char == "\\"
          result << " "
          if index + 1 < content.length
            result << (content[index + 1] == "\n" ? "\n" : " ")
            index += 2
            next
          end
        elsif char == quote
          result << " "
          state = :code
        else
          result << (char == "\n" ? "\n" : " ")
        end
      when :raw_string
        if content[index, 3] == '"""'
          result << "   "
          index += 3
          state = :code
          next
        else
          result << (char == "\n" ? "\n" : " ")
        end
      end
      index += 1
    end
    result
  end

  def preceding_documentation(lines, index)
    start_index = index
    while start_index.positive? && lines[start_index - 1].match?(/^\s*(?:@|\[)/)
      start_index -= 1
    end
    while start_index.positive? && lines[start_index - 1].match?(/^\s*\/\//)
      start_index -= 1
    end
    if start_index >= 2 && lines[start_index - 1].strip.empty? && lines[start_index - 2].match?(/^\s*\/\//)
      start_index -= 1
      start_index -= 1 while start_index.positive? && lines[start_index - 1].match?(/^\s*\/\//)
    end
    if start_index.positive? && lines[start_index - 1].include?("*/")
      start_index -= 1
      start_index -= 1 while start_index.positive? && !lines[start_index].include?("/*")
    end
    start_index
  end

  def preceding_comments(lines, index, comment_regexp)
    start_index = index
    while start_index.positive?
      previous = lines[start_index - 1]
      break unless previous.match?(comment_regexp) || previous.strip.empty?

      start_index -= 1
    end
    start_index
  end
end
