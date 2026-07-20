# 01. 一條 SQL 的生命週期

本章目標：用一條簡單 SQL 把 top-down 主線串起來。

```sql
SELECT name FROM users WHERE id = ?1;
```

你要先把資料庫想成兩段式系統：

1. `prepare`: SQL text -> AST -> query plan -> bytecode program。
2. `step`: bytecode program -> VM loop -> cursor/storage -> row/done/error。

SQLite architecture 也是這個核心思想：`prepare` 類 API 是 compiler，`step` 類 API 是 VM executor。Turso 在 Rust 裡的形狀不同，但概念一樣。

## 60 分鐘閱讀範圍

| 時間 | 檔案 | 只讀這些 symbol / 區塊 |
|---:|---|---|
| 8 分鐘 | `bindings/rust/src/lib.rs` | `Builder`、`Database::connect` 的高階 API 形狀 |
| 8 分鐘 | `sdk-kit/src/rsapi.rs` | `TursoDatabase`、`TursoConnection::prepare_single` |
| 12 分鐘 | `core/lib.rs` | `Database`、`DatabaseOpts`、open/connect 入口 |
| 14 分鐘 | `core/connection.rs` | `prepare`、`_prepare`、`prepare_with_origin`、`parse_sql`、`compile_cmd` |
| 10 分鐘 | `core/statement.rs` | `Statement::step`、query mode、busy/timeout handling |
| 8 分鐘 | `core/vdbe/mod.rs` | `Program::step`、`normal_step` 的 loop 形狀 |

## 第一層：使用者從哪裡進來

常見入口有三種：

```text
CLI:
  cli/main.rs
  cli/app.rs

Rust user API:
  bindings/rust/src/lib.rs
  bindings/rust/src/connection.rs

Core API / lower-level wrappers:
  sdk-kit/src/rsapi.rs
  core/lib.rs
  core/connection.rs
```

如果你用 Rust binding：

```rust
let db = turso::Builder::new_local(":memory:").build().await?;
let conn = db.connect()?;
let mut stmt = conn.prepare("SELECT name FROM users WHERE id = ?1").await?;
```

`bindings/rust/src/lib.rs` 的 `Builder` 會建立 `turso_sdk_kit::rsapi::TursoDatabase`。`Database::connect` 會拿到 `TursoConnection`，再包成高階 async `Connection`。

高階 `bindings/rust/src/connection.rs` 的 `Connection::prepare` 只是第一層 wrapper：

```text
bindings/rust::Connection::prepare
  -> TursoConnection::prepare_single
  -> core::Connection::prepare
```

這是你讀 source 的第一個重要判斷：binding 層多半處理 async API、parameter conversion、error mapping、lifecycle，不是 SQL engine 真正核心。

## 第二層：Database 和 Connection 分工

核心型別在 `core/lib.rs`：

```text
Database:
  shared per database file
  owns db_file, WAL shared state, schema snapshot, page cache, IO backend

Connection:
  per connection state
  owns transaction state, temp DB, prepared settings, pager handle, local schema view

Statement:
  per prepared SQL statement
  owns Program + ProgramState + pager reference
```

`Database` 是「同一個 DB 檔案的共享狀態」。它不能放敏感 connection-local 狀態，因為多個 connection 會共用。`Connection` 是「某個 session 的當前狀態」，例如 transaction state、PRAGMA 設定、temp schema、active statement accounting。`Statement` 則是「已編譯好的 SQL」。

讀 source 時請刻意問：

- 這個資料應該跟 DB 檔案共用嗎？那應該在 `Database`。
- 這個資料應該跟 connection/session 綁定嗎？那應該在 `Connection`。
- 這個資料只屬於一次 prepared statement/execution 嗎？那應該在 `Statement` 或 `ProgramState`。

## 第三層：prepare 的主線

核心從 `core/connection.rs` 看：

```text
Connection::prepare
  -> Connection::_prepare
  -> Connection::prepare_with_origin
  -> Connection::parse_sql
  -> Connection::compile_cmd
  -> translate::translate
  -> ProgramBuilder
  -> Program
  -> Statement::new_with_origin
```

你可以在 `core/connection.rs` 找 `prepare_with_origin`。它做幾件事：

1. 檢查 connection 是否已關閉。
2. 檢查 SQL 是否空字串。
3. 決定這是 root statement、internal helper statement、還是 subprogram。
4. 呼叫 `parse_sql` 取得 AST `Cmd` 和 consumed byte offset。
5. 呼叫 `compile_cmd` 把 AST 變成 `Program`。
6. 建立 `Statement`。

`StatementOrigin` 很重要：

- `Root`: 使用者直接 prepare 的 SQL，會計入 active root statements。
- `InternalHelper`: engine 自己準備的 helper SQL，例如 schema reparse。
- `Subprogram`: trigger/foreign-key action 的 bytecode subprogram，不是另外 parse 的使用者 SQL。

這個分類是 SQLite-compatible lifecycle 的一部分。資料庫不只執行外部 SQL，也會在內部執行 helper SQL 或子程式。

## 第四層：parse_sql 到 dialect

Turso 支援不只 SQLite text path，還有 Postgres frontend 等不同 dialect 概念。SQLite path 在：

```text
core/dialect/sqlite.rs
  parse(sql)
    -> turso_parser::parser::Parser::new(sql.as_bytes())
    -> parser.next_cmd()
```

parser crate 在 `sqlite/parser/`，它產生 `turso_parser::ast::Cmd`。`Cmd` 通常包著 `Stmt`，例如 `Stmt::Select`、`Stmt::Insert`、`Stmt::CreateTable`。

這一層只回答「SQL 文字是否合法、它的語法樹是什麼」。它還不知道 table 是否存在，也不會決定用哪個 index。

## 第五層：compile_cmd 到 translate

compile 階段在 `core/translate/`。總入口是 `core/translate/mod.rs` 的 `translate`：

```text
translate(schema, stmt, pager, connection, symbols, query_mode, input, origin)
  -> create ProgramBuilder
  -> program.prologue()
  -> Resolver::new(...)
  -> translate_inner(stmt, ...)
  -> program.epilogue(schema)
  -> program.build(...)
```

`Resolver` 是 compiler 看 schema 的窗口。它知道 main/temp/attached schemas、symbol table、custom types、dialect function resolution、trigger context。

`translate_inner` 根據 statement kind 分派：

```text
SELECT       -> translate_select
INSERT       -> translate_insert
UPDATE       -> translate_update
DELETE       -> translate_delete
CREATE TABLE -> translate_create_table
PRAGMA       -> translate_pragma
BEGIN/COMMIT -> translate_tx_begin / translate_tx_commit
```

對新手來說，先不要把 `translate` 想成「直接執行 SQL」。它只是「產生一串 VM 指令」。像 compiler 把 Python/JavaScript 轉 bytecode 一樣。

## 第六層：Program 和 Insn

VDBE 相關檔案：

```text
core/vdbe/insn.rs
  enum Insn

core/vdbe/builder.rs
  ProgramBuilder emits Insn

core/vdbe/mod.rs
  Program, ProgramState, StepResult, normal_step

core/vdbe/execute.rs
  each opcode implementation
```

`Insn` 是 Turso 的 VM 指令。你會看到熟悉的 SQLite VDBE 風格名稱：

```text
OpenRead
OpenWrite
Rewind
Column
ResultRow
Next
SeekGE / SeekGT / SeekLE / SeekLT
Insert
Delete
IdxInsert
Transaction
Halt
```

對 `SELECT name FROM users WHERE id = ?1`，概念上會有：

```text
Init
Transaction read
OpenRead users/table-or-index
bind/read parameter
Seek or Rewind
Column
comparison / filter
ResultRow
Next
Halt
```

實際指令會依 schema、index、optimizer 不同而不同，所以要用 `EXPLAIN` 看。

## 第七層：step 的主線

`Statement::step` 在 `core/statement.rs`，最後會呼叫：

```text
Program::step
  -> Program::normal_step
  -> insn.to_function()
  -> execute::op_*
```

`Program::normal_step` 是 VM loop。它重複做：

1. 檢查 connection 是否關閉。
2. 檢查 interrupt/progress/timeout。
3. 如果上一個 opcode 等 I/O，確認 completion 是否完成。
4. 取 `state.pc` 指向的 `Insn`。
5. 執行對應 opcode function。
6. 根據結果回 `StepResult::Row`、`Done`、`IO`、`Busy`、`Yield`。

這裡是你第一次看到 Turso 和一般 async Rust 很不同的地方：core 不是用 `async fn`，而是明確回傳 `IOResult`/`StepResult`，把「現在要等 I/O」這件事交給 caller。

## 第八層：cursor 和 storage

當 opcode 需要讀表或索引，會經過 cursor：

```text
execute::op_open_read / op_open_write
  -> CursorType
  -> BTreeCursor / virtual cursor / sorter / pseudo cursor

execute::op_column
  -> cursor.record()
  -> decode record column into Register

execute::op_next
  -> cursor.next()

execute::op_insert / op_delete
  -> cursor.insert() / cursor.delete()
```

B-tree cursor 實作在 `core/storage/btree.rs`。它往下會用 `Pager` 讀 page、寫 dirty page、處理 overflow page、balance page。

## 第九層：Pager、WAL、IO

底層主線：

```text
BTreeCursor
  -> Pager
  -> page cache
  -> WAL or main db file
  -> DatabaseStorage
  -> IO / File
```

`Pager` 在 `core/storage/pager.rs`。它是 storage correctness 的中心：

- `begin_read_tx`
- `begin_write_tx`
- `commit_tx`
- `rollback_tx`
- `commit_wal`
- `checkpoint`
- `read_page`
- `allocate_page`
- dirty page tracking

`WAL` 在 `core/storage/wal.rs`。它管理 `.db-wal` frames、read marks、write lock、checkpoint、frame cache。

`IO` 在 `core/io/mod.rs`。它把本地檔案、memory、io_uring、custom VFS 變成共同介面。

## 本章練習

1. 用 `rg -n "pub fn prepare" core/connection.rs bindings/rust/src sdk-kit/src` 看三層 prepare。
2. 用 `rg -n "pub fn step|normal_step|InsnFunctionStepResult" core/statement.rs core/vdbe` 看 step path。
3. 跑：

```bash
cargo run -q --bin tursodb -- -q
```

輸入：

```sql
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO users VALUES (1, 'alice');
EXPLAIN SELECT name FROM users WHERE id = 1;
```

你不需要輸出完全一致，但應該看到這類 opcode：

```text
Init
Transaction
OpenRead
SeekRowid
Column
ResultRow
Halt
```

如果 planner 改用 scan，也可能看到 `Rewind` / `Next`。重點是把 EXPLAIN 裡的 opcode 名稱拿去 `core/vdbe/insn.rs` 搜尋。

## 自我檢查

1. `prepare` 和 `step` 的責任差在哪？
2. `Database`、`Connection`、`Statement` 各保存哪一類狀態？
3. `StatementOrigin::Root` 和 `InternalHelper` 為什麼要分開？
4. Parser 產生 AST 後，哪個 layer 才開始查 schema？
5. 如果 `Statement::step` 回 I/O，下一次 step 為什麼要能從原 opcode 繼續？
