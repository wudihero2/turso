# 02. Parser And AST Tasks

這一組把 SQL 文字變成 AST。先看 lexer，再看 parser 狀態與 recursive descent，最後看 AST 如何支援 compiler。

- [ ] T046. **Parser crate boundary**: read `sqlite/parser/src/lib.rs`, `sqlite/parser/README.md`; output the public parse API and error surface.
- [ ] T047. **Token model**: read `sqlite/parser/src/token.rs`, `sqlite/parser/src/lexer.rs`; output what a token stores and what is intentionally borrowed.
- [ ] T048. **Keyword classification**: read `sqlite/parser/src/lexer.rs`; output how identifiers become keywords or remain identifiers.
- [ ] T049. **Lexer main loop**: read `sqlite/parser/src/lexer.rs`; output the major token families: whitespace, comments, strings, numbers, identifiers, operators.
- [ ] T050. **Quoted identifiers**: read `sqlite/parser/src/lexer.rs`; output how `"x"`, `[x]`, and backtick identifiers are tokenized.
- [ ] T051. **String literal cases**: read `sqlite/parser/src/lexer.rs`; output how escaped quotes and blob/string forms are recognized.
- [ ] T052. **Numeric literal cases**: read `sqlite/parser/src/lexer.rs`; output the difference between integer, float, and hexadecimal-looking tokens.
- [ ] T053. **Lexer lookahead**: read `sqlite/parser/src/lexer.rs`; output two examples where one byte is not enough to decide token type.
- [ ] T054. **Parser state**: read `sqlite/parser/src/parser.rs`; output what state is carried across token consumption.
- [ ] T055. **Parser entrypoint**: read `sqlite/parser/src/parser.rs`; output how `next_cmd` handles EOF, semicolons, and byte offsets.
- [ ] T056. **Statement dispatch**: read `sqlite/parser/src/parser.rs`, `sqlite/parser/src/ast.rs`; output how top-level SQL words select an AST branch.
- [ ] T057. **Recursive descent basics**: read expression parsing code in `sqlite/parser/src/parser.rs`; output how precedence and recursion are encoded.
- [ ] T058. **Recursion guard**: read `sqlite/parser/src/parser.rs`; output why expression depth is a correctness and security boundary.
- [ ] T059. **Parameter syntax**: read `sqlite/parser/src/parser.rs`, `sqlite/parser/src/ast.rs`; output how `?`, `?NNN`, `:name`, `$name`, and `@name` are represented.
- [ ] T060. **Literal AST**: read `sqlite/parser/src/ast.rs`; output how null, integer, float, string, blob, and boolean-like values appear before runtime.
- [ ] T061. **Expression AST**: read `sqlite/parser/src/ast.rs`; output the important `Expr` variants and which ones produce subqueries.
- [ ] T062. **Operator AST**: read `sqlite/parser/src/ast.rs`; output binary, unary, LIKE, BETWEEN, IN, IS, and comparison representation.
- [ ] T063. **Name and qualified name**: read `sqlite/parser/src/ast.rs`; output how `schema.table.column` style names are modeled.
- [ ] T064. **SELECT AST skeleton**: read `sqlite/parser/src/ast.rs`, parser SELECT code; output the fields for result columns, FROM, WHERE, GROUP BY, ORDER BY, LIMIT.
- [ ] T065. **JOIN AST**: read `sqlite/parser/src/ast.rs`, parser join code; output how join operators and constraints are represented.
- [ ] T066. **Compound SELECT AST**: read `sqlite/parser/src/ast.rs`; output how UNION, INTERSECT, EXCEPT, and ordering are stored.
- [ ] T067. **INSERT AST**: read `sqlite/parser/src/ast.rs`, parser insert code; output how VALUES, SELECT source, column list, and upsert are represented.
- [ ] T068. **UPDATE and DELETE AST**: read `sqlite/parser/src/ast.rs`; output the AST shape for WHERE, ORDER BY, LIMIT, RETURNING, and table target.
- [ ] T069. **CREATE TABLE AST**: read `sqlite/parser/src/ast.rs`; output column definitions, constraints, table options, generated columns, and foreign keys.
- [ ] T070. **CREATE INDEX AST**: read `sqlite/parser/src/ast.rs`; output indexed columns, expressions, uniqueness, partial predicates, and collation.
- [ ] T071. **ALTER and DROP AST**: read `sqlite/parser/src/ast.rs`; output how DDL variants preserve enough information for translate.
- [ ] T072. **Trigger AST**: read `sqlite/parser/src/ast.rs`; output trigger timing, event, body commands, and conflict behavior.
- [ ] T073. **Pragma AST**: read `sqlite/parser/src/ast.rs`; output why PRAGMA is not just a normal function call.
- [ ] T074. **AST validation and formatting**: read `sqlite/parser/src/ast/check.rs`, `sqlite/parser/src/ast/fmt.rs`; output what can be checked or printed after parse.
- [ ] T075. **Parser tests**: inspect parser tests and `.sqltest` parser-related cases; output three SQL examples and the AST branch they exercise.

