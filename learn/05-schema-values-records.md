# 05. Schema、Value、Record: SQL 世界如何落到 runtime

本章目標：理解 `sqlite_schema`、table/index metadata、runtime `Value`、record format、affinity。Function system 移到下一章，讓這章維持一小時內。

## 60 分鐘閱讀範圍

| 時間 | 檔案 | 只讀這些 symbol / 區塊 |
|---:|---|---|
| 10 分鐘 | `core/schema.rs` | schema constants、`Schema` struct fields |
| 12 分鐘 | `core/schema.rs` | `Table` enum、`BTreeTable`、`Index` struct |
| 8 分鐘 | `core/util.rs` | `parse_schema_rows` free function 的入口與呼叫形狀 |
| 8 分鐘 | `core/connection.rs` | `reparse_schema_nonblock` 呼叫 `parse_schema_rows` 的位置 |
| 10 分鐘 | `core/types.rs` | `ValueType`、`Value`、record/compare 相關型別入口 |
| 7 分鐘 | `core/vdbe/affinity.rs` | `Affinity` enum 與 type conversion 方向 |
| 5 分鐘 | 練習與自我檢查 | 查 `sqlite_schema`，確認 rootpage 概念 |

## 心智模型

SQL 看起來像：

```sql
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL);
SELECT name FROM users WHERE id = 1;
```

Engine 內部會拆成：

```text
Schema:
  users table metadata
  columns, primary key, indexes, triggers, views

Runtime Values:
  Value::Integer, Value::Text, Value::Blob, ...

VDBE Registers:
  temporary slots used by bytecode

Records:
  SQLite on-disk serial format used inside B-tree payloads
```

本章只看「SQL 世界的 metadata 和 value 如何表示」。不要在這章鑽 function callback 或 B-tree balancing。

## sqlite_schema 是 schema 的根

SQLite-compatible database 的 schema 存在 `sqlite_schema` 表。Turso 在 `core/schema.rs` 定義：

```text
SCHEMA_TABLE_NAME = "sqlite_schema"
SCHEMA_TABLE_NAME_ALT = "sqlite_master"
TEMP_SCHEMA_TABLE_NAME = "sqlite_temp_schema"
SQLITE_SEQUENCE_TABLE_NAME = "sqlite_sequence"
```

`sqlite_schema` 本身也是一張 B-tree table，root page 是 page 1。這很重要：schema 不是只在 memory 裡，它也存在 database file 裡。

Turso 啟動或 schema reparse 時會掃：

```sql
SELECT * FROM sqlite_schema
```

然後把每一 row 的 stored SQL parse 回 in-memory metadata。這段不是 `Schema` 的 method；實際入口是 `core/util.rs` 的 free function `parse_schema_rows`，由 `core/connection.rs` 的 schema reparse state machine 呼叫。

## Schema struct

`core/schema.rs` 的 `Schema` 是 compiler 查詢 metadata 的主要來源。你第一輪只看 fields：

- tables。
- indexes。
- views。
- triggers。
- sequences。
- custom types/domains。
- analyze stats。
- schema version/cookie。

不要一開始追完所有 validation。先建立概念：compiler 要知道 table/index/column/function 這些名稱是否存在，會透過 `Resolver` 查 `Schema`。

## Table、BTreeTable、Index

`Table` 大致分幾類：

```text
BTree table:
  ordinary SQLite table stored in B-tree

Virtual table:
  extension-provided table implementation

From-clause subquery/materialized/internal tables:
  compiler/runtime helper shapes
```

普通 table 的 metadata 在 `BTreeTable`：

```text
root_page
name
primary_key_columns
columns
has_rowid
is_strict
has_autoincrement
unique_sets
foreign_keys
check_constraints
logical_to_physical_map
```

`root_page` 是 storage 世界的關鍵。Compiler 解析到 `users` 表後，最後會 emit cursor open 到這個 root page。Storage 不知道 SQL table name，它只知道 root page + B-tree。

Index metadata 也在 `core/schema.rs`。Index 是另一棵 B-tree，通常存：

```text
indexed column values + rowid tie-breaker
```

Compiler 選 index 時，會根據 schema 裡的 index definition、WHERE terms、collation、sort order 等決定是否 emit index seek。VM 執行時，index cursor 和 table cursor 是不同 cursor。

## declared type、affinity、runtime value、serial type

新手要先分清四件事：

`declared type`
: 使用者在 `CREATE TABLE` 寫的字串，例如 `INTEGER`、`TEXT`、`VARCHAR(20)`。

`affinity`
: SQLite 根據 declared type 推出的儲存/比較傾向，例如 INTEGER、TEXT、NUMERIC、REAL、BLOB。

`runtime Value`
: 某個 register 裡此刻真的拿的是 integer/text/blob/null/float。

`serial type`
: record 寫到 B-tree payload 時的 SQLite on-disk encoding。

這四者不是同一件事。SQLite compatibility 的很多細節都卡在這裡。

## Value 和 Record

`core/types.rs` 定義 runtime value。常見：

```text
Value::Null
Value::Integer(i64)
Value::Float(...)
Value::Text(...)
Value::Blob(...)
```

VM registers 裡放的是 runtime values 或 aggregate/record 等狀態。Expression opcode 對 registers 操作；`Column` 從 record decode value 到 register；`MakeRecord` 從 registers encode record；`ResultRow` 從 registers 產生 row。

SQLite record payload 形狀：

```text
header_size varint
serial_type_1 varint
serial_type_2 varint
...
data_1
data_2
...
```

理解 record format 後，你才會懂：

- 為什麼 `Column` 可能只 decode 其中一欄。
- 為什麼 ALTER TABLE ADD COLUMN 會遇到 short record/default value。
- 為什麼 index key 是 record-like 格式。
- 為什麼 affinity/collation 在比較時重要。

## Schema-changing SQL 的路徑

`CREATE TABLE` 不是直接在 memory map 插一張表。它大致會：

```text
parse CREATE TABLE AST
translate_create_table
  -> validate columns/constraints/default/check
  -> allocate btree root page
  -> write sqlite_schema row
  -> update schema cookie
  -> reparse or update in-memory schema
```

核心檔案：

```text
core/translate/schema.rs
core/schema.rs
core/util.rs
core/connection.rs
core/storage/pager.rs
```

這就是 DDL 的 correctness 核心：disk schema、memory schema、schema cookie、prepared statement invalidation 必須一致。

## 練習

建立表後觀察 schema：

```sql
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE INDEX users_name_idx ON users(name);
SELECT type, name, tbl_name, rootpage, sql FROM sqlite_schema;
```

預期你會看到至少兩列：一列 `table|users|users|...`，一列 `index|users_name_idx|users|...`。`rootpage` 是 table/index B-tree 的 root page；實際數字會因 database 狀態不同而不同。

追 source：

```bash
rg -n "pub struct Schema|pub enum Table|pub struct BTreeTable|pub struct Index" core/schema.rs
rg -n "pub fn parse_schema_rows" core/util.rs
rg -n "parse_schema_rows\\(" core/connection.rs
rg -n "pub enum Value|ImmutableRecord|MakeRecord" core/types.rs core/vdbe
```

## 自我檢查

1. `sqlite_schema` 為什麼也是一張 table？
2. `BTreeTable.root_page` 對 compiler 和 storage 各代表什麼？
3. declared type、affinity、runtime `Value`、serial type 有什麼差別？
4. `parse_schema_rows` 實際在哪個檔案？誰呼叫它？
5. 為什麼 DDL 必須同時照顧 disk schema 和 memory schema？
