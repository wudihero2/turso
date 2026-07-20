# 02. Parser 和 AST: SQL 文字如何變成語法樹

本章目標：你要知道 parser 做什麼、不做什麼，並能從一個 SQL statement 追到 AST enum。

## 心智模型

Parser 的工作是把文字變成結構：

```text
"SELECT name FROM users WHERE id = ?1"
  -> tokens
  -> ast::Cmd::Stmt(ast::Stmt::Select { ... })
```

它不負責：

- 檢查 `users` 這張表是否存在。
- 決定 `id` 是否有 index。
- 決定 join order。
- 執行任何 I/O。
- 產生 bytecode。

這些都在 `core/translate/` 之後才做。

## 60 分鐘閱讀範圍

| 時間 | 檔案 | 只讀這些 symbol / 區塊 |
|---:|---|---|
| 6 分鐘 | `core/dialect/sqlite.rs` | `parse` 如何建立 `Parser` 並呼叫 `next_cmd` |
| 8 分鐘 | `sqlite/parser/src/lib.rs`、`token.rs` | module export、token kind 命名方式 |
| 10 分鐘 | `sqlite/parser/src/lexer.rs` | identifier、number、string、parameter token 的掃描入口 |
| 16 分鐘 | `sqlite/parser/src/parser.rs` | `Parser` struct、`next_cmd`、`parse_select`、`parse_expr` |
| 12 分鐘 | `sqlite/parser/src/ast.rs` | `Cmd`、`Stmt`、`Select`、`Expr` |
| 5 分鐘 | `sqlite/parser/src/ast/check.rs`、`ast/fmt.rs` | AST check 與 SQL formatting 的用途 |
| 3 分鐘 | `sqlite/parser/src/error.rs` | parse error 帶哪些資訊 |

## Turso parser 和 SQLite parser 的差異

SQLite 官方 architecture 裡，SQLite tokenizer 和 Lemon-generated parser 互動，grammar 在 `parse.y`。Turso 這裡是 Rust hand-written recursive descent parser：

```text
Lexer<'a>
  -> Token<'a>
  -> Parser<'a>
  -> ast::Cmd / ast::Stmt / ast::Expr
```

入口在 `core/dialect/sqlite.rs`：

```rust
pub fn parse(sql: &str) -> crate::Result<(Option<turso_parser::ast::Cmd>, usize)> {
    let mut parser = turso_parser::parser::Parser::new(sql.as_bytes());
    let cmd = parser.next_cmd()?;
    Ok((cmd, parser.offset()))
}
```

這個 function 有兩個回傳值：

- `Option<Cmd>`：解析出的第一個 statement，或只有分號/空白時是 `None`。
- `usize`：已消耗的 byte offset。這讓 batch SQL 可以一段一段 prepare。

## Lexer: 先切 token

`sqlite/parser/src/lexer.rs` 負責掃描 bytes。`token.rs` 定義 token type。你會看到 SQLite-style token 名稱，例如 `TK_SELECT`、`TK_ID`、`TK_INTEGER`。

對新手來說，lexer 可以先看三件事：

1. keyword 如何和 identifier 區分。
2. string literal、blob literal、number literal 怎麼切。
3. parameter token，例如 `?`、`?1`、`:name`、`@name`、`$name`。

不要一開始背 token 表。只要知道 parser 後面會用 `peek`、`eat`、`eat_expect` 消耗 token。

## Parser struct

`sqlite/parser/src/parser.rs` 裡的核心型別：

```rust
pub struct Parser<'a> {
    lexer: Lexer<'a>,
    current_token: Token<'a>,
    peekable: bool,
    last_variable_id: u32,
    named_variables: HashMap<&'a [u8], NonZeroU32>,
    type_nesting_depth: u32,
    expr_nesting_depth: u32,
    last_expr_height: usize,
}
```

這裡有幾個新手必懂點：

`lexer`
: 實際掃 token。

`current_token` + `peekable`
: parser 需要看下一個 token 但不一定消耗，所以有 peek/eat 狀態。

`last_variable_id`, `named_variables`
: SQL parameter 的編號規則。`?` 會依出現順序自動編號；`?1` 指定位置；`:name` 這類 named variable 會 map 到 slot。

`expr_nesting_depth`, `last_expr_height`
: 防止 expression 太深造成 stack overflow。Turso 的 `MAX_EXPR_DEPTH` 目前比 SQLite default 更低，因為 Rust translator/optimizer 的 stack frame 比較大。

## next_cmd: parser 主入口

`Parser` 實作了 `Iterator<Item = Result<Cmd>>`，但核心還是 `next_cmd`。

讀 `next_cmd` 時，你要看它如何：

1. 重置 parameter state。
2. 跳過前置分號。
3. 判斷 statement 類型。
4. 呼叫對應 parse function。
5. 在 statement 結尾處理分號/EOF。

這會帶你進入很多 parse function，例如：

```text
parse_select
parse_insert
parse_update
parse_delete
parse_create_table
parse_expr
parse_from
parse_join
parse_order_by
parse_limit
```

不要試圖一次讀完整個 `parser.rs`。第一次只追一條 SQL。

## AST: parser 的輸出

AST 在 `sqlite/parser/src/ast.rs`。你會看到幾種大 enum：

```text
Cmd
Stmt
Select
OneSelect
Expr
Literal
Operator
CreateTableBody
ColumnDefinition
```

對一條 `SELECT`，大致是：

```text
Cmd::Stmt(
  Stmt::Select {
    select: Select {
      with,
      body,
      order_by,
      limit
    }
  }
)
```

`WHERE id = ?1` 會是 expression tree：

```text
Expr::Binary(
  Expr::Id("id"),
  Operator::Equals,
  Expr::Variable(Variable::indexed(1))
)
```

AST 的價值是：後面的 compiler 不再處理 raw SQL string，而是處理 typed Rust enum。

## ast/check.rs 和 ast/fmt.rs

`ast/check.rs`
: 一些 AST consistency checks，例如 column count 類規則。

`ast/fmt.rs`
: AST -> SQL tokens/string 的格式化。這對 schema replay、trigger SQL reconstruction、debugging 很有用。

資料庫常常要把 SQL text 存進 `sqlite_schema`，之後再讀出來 parse 回 schema。`fmt` 類工具能幫助 engine 產生 canonical 或可重放 SQL。

## Error handling

`sqlite/parser/src/error.rs` 定義 parse error。你會看到錯誤包含：

- expected token。
- got token。
- offset。
- token text。

資料庫 parser 的錯誤品質很重要，因為 SQL 是使用者直接輸入的語言。讀 parser 時，不要只看 happy path，也要看 `peek_expect!`、`eat_expect!` 這類 macro 如何產生錯誤。

## 跟 compiler 的接口

Parser 的輸出不是直接給 VM，而是給 dialect/core：

```text
core/dialect/sqlite.rs::parse
  -> turso_parser::parser::Parser
  -> ast::Cmd
  -> core/connection.rs::compile_cmd
  -> core/translate/mod.rs::translate
```

`compile_cmd` 會拿目前 connection 的 schema、pager、symbol table、query mode 一起交給 translate。這表示 AST 只是語法，語義解析要等到 compile 階段。

## 讀法：用三條 SQL 追 AST

第一條：

```sql
SELECT 1 + 2;
```

追：

- numeric literal。
- binary expression。
- result column。
- no FROM clause。

第二條：

```sql
SELECT name FROM users WHERE id = ?1 ORDER BY name LIMIT 10;
```

追：

- result column name。
- from table。
- where binary expression。
- variable parameter。
- order by。
- limit。

第三條：

```sql
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL);
```

追：

- `Stmt::CreateTable`。
- `CreateTableBody`。
- `ColumnDefinition`。
- column constraints。

## 本章練習

用 `rg` 找入口：

```bash
rg -n "pub fn next_cmd|parse_select|parse_expr|create_variable" sqlite/parser/src/parser.rs
rg -n "pub enum Stmt|pub enum Expr|pub struct Select" sqlite/parser/src/ast.rs
```

再跑：

```bash
scripts/diff.sh "SELECT 1 + 2"
```

預期輸出形狀很小，通常就是一列結果：

```text
3
```

這個命令不是看 AST，而是提醒你 parser 只是第一步。真正結果還要靠後面的 compiler 和 VM。

## 自我檢查

1. Lexer 和 parser 的責任差在哪？
2. `next_cmd` 為什麼要回傳 consumed offset？
3. AST 為什麼不能回答 table 是否存在？
4. `?`、`?1`、`:name` 這些 parameter token 為什麼需要 parser 記狀態？
5. `ast/fmt.rs` 對 schema replay 有什麼用？
