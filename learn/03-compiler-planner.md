# 03. Compiler / Planner: AST 如何變 VDBE bytecode

本章目標：你要理解 `core/translate/` 的工作：把 AST 變成 `Program`，也就是一串 VDBE `Insn`。

## 心智模型

Parser 只知道「SQL 長什麼樣」。Compiler 要知道：

- table/view/index 是否存在。
- column 名稱綁定到哪張表。
- expression 要讀哪個 register。
- WHERE 可以怎麼拆。
- SELECT 要用 table scan、index seek、join、sorter、aggregate、window、subquery 還是 CTE。
- 最後要 emit 哪些 VM instructions。

整體形狀：

```text
ast::Stmt
  -> Resolver binds schema/function/table/column names
  -> Planner builds Plan
  -> Optimizer mutates Plan
  -> Emitter emits Insn into ProgramBuilder
  -> ProgramBuilder::build creates Program
```

## 60 分鐘閱讀範圍

| 時間 | 檔案 | 只讀這些 symbol / 區塊 |
|---:|---|---|
| 8 分鐘 | `core/translate/mod.rs` | `translate`、`translate_inner` dispatcher |
| 8 分鐘 | `core/translate/emitter/mod.rs` | `Resolver` 的 fields 與名稱解析角色 |
| 12 分鐘 | `core/translate/select.rs` | `translate_select`、`prepare_select_plan`、`emit_select_plan` |
| 10 分鐘 | `core/translate/planner.rs` | `parse_from`、`parse_where`、`ROWID_STRS` |
| 8 分鐘 | `core/translate/plan.rs` | `Plan`、`SelectPlan`、`Search`、`WhereTerm` |
| 8 分鐘 | `core/translate/emitter/select.rs` | scan/seek loop emit 的入口 |
| 6 分鐘 | `core/vdbe/builder.rs`、`core/vdbe/insn.rs` | `emit_insn`、`build`、常見 `Insn` |

`insert.rs`、`update.rs`、`delete.rs`、`schema.rs` 這章只建立位置感，不列入一小時深讀。要追 DML/DDL 時，到第 9 章用 project 方式單獨讀。

## translate/mod.rs: compiler dispatcher

總入口是 `translate`：

```text
translate(schema, stmt, pager, connection, syms, query_mode, input, origin)
```

它先建立 `ProgramBuilder`，再建立 `Resolver`，然後把 statement 分派給 `translate_inner`。

你可以把 `ProgramBuilder` 想成「bytecode array builder」，把 `Resolver` 想成「compiler 看 schema 的眼睛」。

`translate_inner` 有一個很重要的早期檢查：它會判斷 statement 是否 write statement。如果 connection 是 query_only，write statement 會被拒絕。這類檢查屬於 compile-time semantic check，不是 runtime storage check。

## Resolver: 名稱解析器

`Resolver` 在 `core/translate/emitter/mod.rs`。它持有：

```text
schema
database_schemas
temp_database
attached_databases
symbol_table
dialect
custom type setting
trigger context
function resolver
```

SQL 裡的 `users.name` 不是 raw string。Compiler 要回答：

- `users` 是 main schema 還是 temp schema？
- 它是 table、view、virtual table、materialized view？
- `name` 是第幾個 column？
- column affinity/collation 是什麼？
- function `abs()` 是 built-in、extension、aggregate、window？

這就是 Resolver 的角色。

## SELECT 的 compile pipeline

`core/translate/select.rs` 是讀 compiler 最好的第一站。

入口：

```text
translate_select
  -> prepare_select_plan
  -> emit_select_plan
```

`prepare_select_plan` 負責把 AST SELECT 變成 plan：

```text
ast::Select
  -> Plan::Select(Box<SelectPlan>)
  -> or Plan::CompoundSelect
```

接著 `emit_select_plan`：

```text
optimize_plan(program, &mut plan, resolver)
program.extend(opts)
emit_program(connection, resolver, program, plan, |_| {})
```

這裡要看到三個階段：

1. prepare plan。
2. optimize plan。
3. emit bytecode。

不要把 planner 和 emitter 混在一起。Planner 還在抽象層，Emitter 開始決定具體 `Insn`。

## planner.rs: 把 SELECT 拆成語義元件

`core/translate/planner.rs` 很大，先看幾個概念：

`parse_from`
: 把 FROM/JOIN 轉成 joined table structures。

`parse_where`
: 把 WHERE expression 拆成 terms，讓 optimizer 可以選擇 index/search。

`parse_limit`
: 處理 LIMIT/OFFSET。

`resolve_window_and_aggregate_functions`
: 掃 expression tree，找 aggregate/window function，建立 aggregate metadata。

`ROWID_STRS`
: SQLite rowid aliases：`rowid`、`_rowid_`、`oid`。

Planner 的輸出在 `core/translate/plan.rs`。你要找：

```text
Plan
SelectPlan
JoinedTable
Operation
Search
WhereTerm
QueryDestination
ResultSetColumn
```

這些型別是 compiler 中間表示。它們不是 AST，也不是 bytecode。

## emitter: 把 plan 變 instruction

`core/translate/emitter/` 是 bytecode emission。它會根據 plan emit：

- open cursor。
- transaction instruction。
- scan loop。
- seek instruction。
- expression evaluation。
- result row。
- sorter/aggregate/window/subquery handling。
- insert/update/delete side effects。

你會看到 `program.emit_insn(Insn::...)`。這就是 compiler 最終產物。

例如 SELECT table scan 概念上像：

```text
OpenRead cursor
Rewind cursor end
Column cursor col -> reg
... evaluate WHERE ...
ResultRow reg count
Next cursor loop
Halt
```

如果有 index seek，則會變成 `SeekGE`/`IdxGT` 類指令。若有 ORDER BY，可能會開 sorter。若有 aggregate，會有 accumulator state。

## ProgramBuilder: bytecode 的建造者

`core/vdbe/builder.rs` 的 `ProgramBuilder` 管很多 compile-time bookkeeping：

- instructions vector。
- cursor IDs。
- labels/branch offsets。
- parameters。
- result columns。
- materialized CTE registry。
- transaction mode。
- read/write database bitsets。
- statement flags，例如 readonly、may_abort、is_multi_write。
- expression register cache。

新手最容易低估 `ProgramBuilder`。它不是單純 `Vec<Insn>`；它同時維護 compiler 所需的狀態與 SQLite compatibility metadata。

讀 `ProgramBuilder` 時，先找：

```text
emit_insn
allocate_label
preassign_label_to_next_insn
alloc_cursor_id
build
```

然後再看 flags。

## DML 和 DDL compiler

除了 SELECT，其他 statement 在不同檔案：

`insert.rs`
: INSERT、default values、conflict resolution、index writes、RETURNING。

`update.rs`
: UPDATE row image、column assignment、index maintenance、trigger/FK interaction。

`delete.rs`
: DELETE scan、row deletion、index deletion、trigger/FK action。

`schema.rs`
: CREATE/DROP TABLE/INDEX/VIEW/TRIGGER/TYPE 等 schema-changing bytecode。這裡會寫 `sqlite_schema`，也會 emit schema cookie 更新與 schema reparse。

`transaction.rs`
: BEGIN/COMMIT/ROLLBACK statement 的 bytecode。

`pragma.rs`
: PRAGMA statement mapping。

讀 DML/DDL 時要記得：compiler 不直接修改 B-tree，它 emit `Insn::Insert`、`Insn::Delete`、`Insn::CreateBtree` 等，真正修改發生在 VM execution。

## Compiler 的 correctness 重點

Compiler 層的錯誤通常不是 disk corruption，而是 SQL semantics 錯：

- column binding 錯：讀到錯表/錯欄。
- affinity/collation 錯：比較或 ORDER BY 和 SQLite 不一致。
- subquery correlation 錯：outer reference 解析錯。
- transaction mode 錯：readonly/write classification 錯。
- statement journal 判斷錯：constraint abort 後回滾不完整。
- trigger/FK subprogram 錯：執行時機或 conflict policy 錯。

所以讀 compiler 時，一定要用 SQLite 對照。`scripts/diff.sh` 是這層最常用的理解工具。

## 本章練習

先用 EXPLAIN 看 compiler 產物：

```bash
cargo run -q --bin tursodb -- -q
```

輸入：

```sql
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT);
CREATE INDEX users_name_idx ON users(name);
EXPLAIN SELECT name FROM users WHERE id = 1;
EXPLAIN SELECT id FROM users WHERE name = 'alice';
```

第一個查 rowid primary key 時，實際輸出接近（addr/register 編號可能不同）：

```text
addr  opcode             p1    p2    p3    p4             p5  comment
----  -----------------  ----  ----  ----  -------------  --  -------
0     Init               0     6     0                    0   Start at 6
1     OpenRead           0     2     0     k(2,B,B)       0   table=users, root=2, iDb=0
2     SeekRowid          0     2     5                    0   if (r[2]!=cursor 0 rowid) goto 5
3     Column             0     1     1                    0   r[1]=users.name
4     ResultRow          1     1     0                    0   output=r[1]
5     Halt               0     0     0                    0
6     Transaction        0     1     1                    0   iDb=0 tx_mode=Read
7     Integer            1     2     0                    0   r[2]=1
8     Goto               0     1     0                    0
```

對照 table scan 版本：`Rewind`/`Next` loop 消失了，換成一次 `SeekRowid` 直接定位，找不到就跳去 `Halt`。這就是「compiler 依 schema 選擇不同 access path」的具體樣子。

第二個查 secondary index 時，應該看到 index cursor 相關 seek，例如 `SeekGE` / `IdxGT` / 從 index 回 table 的動作。實際 opcode 會因 planner 變動而不同；你只要比較「table root page seek」和「index cursor seek」的差異。

然後追：

```bash
rg -n "translate_select|prepare_select_plan|emit_select_plan" core/translate
rg -n "emit_insn\\(Insn::OpenRead|Insn::Seek|Insn::ResultRow" core/translate
```

## 自我檢查

1. AST、Plan、Insn 三者差在哪？
2. `Resolver` 為什麼不是 parser 的一部分？
3. `prepare_select_plan` 和 `emit_select_plan` 分別做什麼？
4. 為什麼同一個 SELECT 語法，在不同 index 條件下會 emit 不同 bytecode？
5. Compiler 層最常見的 correctness bug 是 disk corruption 還是 SQL semantics？為什麼？
