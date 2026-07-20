# 09. 用小任務學源碼

本章目標：不要只讀文件。用幾個小型 tracing project，把前面章節串起來。

## 本章使用方式

這章不是一小時讀完。每個 project 都是獨立 30-60 分鐘 session。一次只選一個 SQL，照「SQL -> EXPLAIN -> opcode -> source -> 測試」的順序追。

| Project | 建議時間 | 重點 |
|---|---:|---|
| A | 30 分鐘 | constant expression，不碰 storage |
| B | 45 分鐘 | table scan，第一次碰 cursor |
| C | 40 分鐘 | rowid primary-key seek |
| D | 50 分鐘 | secondary index lookup |
| E | 60 分鐘 | INSERT、record、index maintenance |
| F | 60 分鐘 | CREATE TABLE、sqlite_schema、schema cookie |
| G | 60 分鐘 | BEGIN/COMMIT/ROLLBACK、WAL |
| H | 60 分鐘 | I/O yield 與 re-entry |
| I | 30-60 分鐘 | 用測試反推 source layer |

## Project A: 追 `SELECT 1 + 2`

目標：理解 parser、compiler、VM register operation，不碰 storage。

SQL：

```sql
EXPLAIN SELECT 1 + 2;
```

校正輸出：你應該看到 `Integer`、`Add`、`ResultRow` 這類 opcode。實際欄位與 address 可能會變，但語義應該是「兩個 literal 進 register，Add 產生結果，ResultRow 回傳」。完整的實際輸出範例（含 `Init`/`Goto` 執行順序解釋）在 `04-vdbe-execution.md` 的練習節。

讀法：

1. `sqlite/parser/src/parser.rs`
   找 numeric literal、binary expression。

2. `core/translate/select.rs`
   找 `translate_select`、`prepare_select_plan`。

3. `core/translate/expr/translator.rs`
   找 `translate_expr` 對 literal/binary expression 如何 emit。

4. `core/vdbe/insn.rs`
   找 `Integer`、`Add`、`ResultRow`。

5. `core/vdbe/execute.rs`
   找 `op_add`、`op_result_row`。

你應該能畫出：

```text
literal 1 -> register
literal 2 -> register
Add -> destination register
ResultRow -> return row
```

## Project B: 追 table scan

SQL：

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO t VALUES (1, 'alice'), (2, 'bob');
EXPLAIN SELECT name FROM t;
```

校正輸出：你應該看到 table cursor 被打開，然後是 `Rewind`、`Column`、`ResultRow`、`Next` 這種 loop 形狀。

讀法：

1. `core/schema.rs`
   看 `BTreeTable.root_page`。

2. `core/translate/select.rs` / `core/translate/emitter/select.rs`
   找 table scan loop。

3. `core/vdbe/insn.rs`
   找 `OpenRead`、`Rewind`、`Column`、`ResultRow`、`Next`。

4. `core/vdbe/execute.rs`
   看對應 opcode。

5. `core/storage/btree.rs`
   看 `CursorTrait::rewind`、`next`、`record`。

你應該能說明：

```text
OpenRead opens B-tree root page
Rewind moves cursor to first row
Column decodes name column into register
ResultRow yields row
Next advances cursor and loops
```

## Project C: 追 primary-key seek

SQL：

```sql
EXPLAIN SELECT name FROM t WHERE id = 1;
```

校正輸出：和 Project B 相比，這裡應該出現 rowid seek 類 opcode，例如 `SeekRowid`。如果看到整表 scan，先確認表的 `id INTEGER PRIMARY KEY` 是否建立成功。

讀法：

1. 比較 table scan 的 EXPLAIN。
2. 找 `SeekRowid` 或類似 seek opcode。
3. 追 `execute::op_seek_rowid`。
4. 追 `BTreeCursor::seek`。

你要理解 rowid table 的 primary key lookup 不一定需要 secondary index，因為 table B-tree 本身 key 就是 rowid。

## Project D: 追 secondary index lookup

SQL：

```sql
CREATE INDEX t_name_idx ON t(name);
EXPLAIN SELECT id FROM t WHERE name = 'alice';
```

校正輸出：應該有 index cursor 相關 seek，例如 `SeekGE` / `IdxGT`，並可能需要用 rowid 回 table cursor。

讀法：

1. `core/schema.rs` 找 index metadata。
2. `core/translate/planner.rs` 看 WHERE term / search planning。
3. `core/translate/plan.rs` 看 `Search` / `Operation`。
4. EXPLAIN 裡找 index cursor。
5. 看是否需要從 index 回 table cursor 取 row。

你要理解 secondary index B-tree key 通常包含 indexed columns + rowid tie-breaker。

## Project E: 追 INSERT

SQL：

```sql
EXPLAIN INSERT INTO t(name) VALUES ('carol');
```

校正輸出：應該看到 rowid/record/write 相關 opcode，例如 `NewRowid`、`MakeRecord`、`Insert`；若已有 secondary index，還會看到 index write。

讀法：

1. `core/translate/insert.rs`
   看 INSERT 如何建立 row values、rowid、index entries。

2. `core/vdbe/insn.rs`
   找 `NewRowid`、`MakeRecord`、`Insert`、`IdxInsert`。

3. `core/vdbe/execute.rs`
   看 `op_insert`、`op_idx_insert`、`op_new_rowid`。

4. `core/storage/btree.rs`
   看 `insert` 和 page balancing。

5. `core/storage/pager.rs`
   看 dirty page 如何 commit。

你要能回答：INSERT 不是只寫 table，還要維護 indexes、constraints、triggers、foreign keys、change count。

## Project F: 追 CREATE TABLE

SQL：

```sql
EXPLAIN CREATE TABLE x(a INTEGER, b TEXT);
```

校正輸出：DDL 的 EXPLAIN 應該包含建立 root page、寫 `sqlite_schema`、更新 schema cookie 類動作。opcode 名稱可能變動，但不應該只是 memory-only metadata 修改。

讀法：

1. `sqlite/parser/src/parser.rs`
   追 create table AST。

2. `core/translate/schema.rs`
   找 `translate_create_table`。

3. `core/schema.rs`
   找 `create_table`、`BTreeTable`。

4. `core/vdbe/insn.rs`
   找 schema-related opcode，例如 create btree、insert sqlite_schema、set cookie。

5. 執行後查：

```sql
SELECT type, name, rootpage, sql FROM sqlite_schema WHERE name = 'x';
```

你要理解 DDL 的真正持久化結果是 `sqlite_schema` row + allocated root page + schema cookie。

## Project G: 追 BEGIN / COMMIT / ROLLBACK

SQL：

```sql
BEGIN;
INSERT INTO t VALUES (3, 'd');
ROLLBACK;

BEGIN;
INSERT INTO t VALUES (3, 'd');
COMMIT;
```

校正輸出：第一段 rollback 後，`SELECT * FROM t WHERE id = 3;` 應該沒有 row；第二段 commit 後應該看得到 `(3, 'd')`。

讀法：

1. `core/translate/transaction.rs`
   看 transaction SQL 如何 emit bytecode。

2. `core/vdbe/execute.rs`
   找 `op_transaction`、commit/rollback handling。

3. `core/storage/pager.rs`
   看 `begin_write_tx`、`commit_tx`、`rollback_tx`。

4. `core/storage/wal.rs`
   看 WAL locks/snapshot。

你要能回答：SQL transaction statement、connection transaction state、pager transaction、WAL write lock 是不同層的概念。

## Project H: 追一次 I/O yield

這個 project 不一定要馬上跑測試；先讀 source。

讀：

```text
core/types.rs: IOResult
core/util.rs: IOExt::block
core/io/completions.rs: Completion
core/vdbe/mod.rs: normal_step pending_io handling
core/vdbe/execute.rs: OpColumnState / OpTransactionState
core/storage/pager.rs: CommitState
```

你要畫出：

```text
opcode starts I/O
  -> returns IO completion
  -> Statement::step returns IO
  -> caller drives IO
  -> next Statement::step re-enters same opcode
  -> opcode state resumes without repeating unsafe mutation
```

這是讀 Turso source 的分水嶺。懂這個後，很多看似複雜的 state enum 會變得合理。

## Project I: 用測試定位 source

選一個 `.sqltest`，例如：

```text
sqlite/conformance/sqlite-sqltests/insert.sqltest
sqlite/conformance/sqlite-sqltests/transactions.sqltest
sqlite/conformance/sqlite-sqltests/btree-large-page-overflow.sqltest
```

讀法：

1. 看 SQL 測什麼。
2. 用 `scripts/diff.sh` 跑其中一段 SQL。
3. 用 `EXPLAIN` 看 bytecode。
4. 根據 opcode 找 translate/execute/storage。
5. 問：如果這個測試失敗，最可能是哪一層？

這是實務上最快的學習方式，因為測試會逼你把抽象概念接到實際行為。

## 最終閱讀路線圖

當你讀一個新 feature，照這個順序：

```text
1. SQL syntax:
   sqlite/parser/src/parser.rs
   sqlite/parser/src/ast.rs

2. Statement translation:
   core/translate/<feature>.rs
   core/translate/mod.rs

3. Plan/emission:
   core/translate/planner.rs
   core/translate/plan.rs
   core/translate/emitter/
   core/vdbe/builder.rs

4. VM execution:
   core/vdbe/insn.rs
   core/vdbe/execute.rs
   core/vdbe/mod.rs

5. Runtime values/schema:
   core/types.rs
   core/schema.rs
   core/function.rs

6. Storage:
   core/storage/btree.rs
   core/storage/pager.rs
   core/storage/wal.rs
   core/io/

7. Tests:
   sqlite/conformance/sqlite-sqltests/
   tests/integration/
   testing/simulator/
```

不要反過來從 `btree.rs` 直接硬讀。B-tree 很重要，但如果你不知道上層 opcode 為什麼叫它，很容易迷路。

## 自我檢查

1. 你能不能從一個 EXPLAIN opcode 反查到 `core/vdbe/execute.rs` 的實作？
2. 你能不能判斷某個錯誤比較像 parser、planner、VM、storage、WAL 還是 binding 問題？
3. 追 `INSERT` 時，除了 table B-tree，還有哪些 side effects 可能需要看？
4. 追 transaction 時，SQL statement、connection state、pager transaction、WAL lock 為什麼是不同層？
5. 你能不能把一個 `.sqltest` 失敗轉成「先看哪三個 source 檔」？
