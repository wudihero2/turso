# 04. VDBE Execution: bytecode VM 如何跑出 rows

本章目標：看懂 `Statement::step` 如何驅動 `Program::normal_step`，以及 opcode 如何透過 cursor/storage 讀寫資料。

## 心智模型

VDBE 是 register-based virtual machine：

```text
Program:
  immutable prepared bytecode + metadata

ProgramState:
  pc, registers, cursors, result row, pending IO, active opcode state

Insn:
  one bytecode instruction

execute::op_*:
  implementation of each instruction
```

`step` 每次做一小段工作：

- 如果產生一列結果，回 `StepResult::Row`。
- 如果完成，回 `StepResult::Done`。
- 如果遇到 I/O，回 `StepResult::IO`，caller 等 completion 後再 step。
- 如果遇到 lock/busy，回 `StepResult::Busy`。
- 如果明確讓出 cooperative scheduler，回 `StepResult::Yield`。

## 60 分鐘閱讀範圍

| 時間 | 檔案 | 只讀這些 symbol / 區塊 |
|---:|---|---|
| 8 分鐘 | `core/statement.rs` | `Statement::step`、`QueryMode` |
| 10 分鐘 | `core/vdbe/mod.rs` | `Program`、`ProgramState`、`StepResult`、`normal_step` |
| 8 分鐘 | `core/vdbe/insn.rs` | `Insn` enum 的資料流、cursor、control 類 opcode |
| 14 分鐘 | `core/vdbe/execute.rs` | 只讀 `op_result_row`、`op_column`、`op_next`、`op_seek_rowid` |
| 6 分鐘 | `core/vdbe/explain.rs` | EXPLAIN 如何把 program 變成 rows |
| 6 分鐘 | `core/vdbe/value.rs`、`core/types.rs` | register/value 的基本表示 |
| 8 分鐘 | 練習 | 用 EXPLAIN 反查 opcode implementation |

`core/vdbe/execute.rs` 很大，第一輪不要整檔讀。只用 EXPLAIN 產生的 opcode 當索引。

## Statement::step

`core/statement.rs` 的 `Statement` 包含：

```text
program: vdbe::Program
state: vdbe::ProgramState
pager: Arc<Pager>
query_mode: QueryMode
busy handler state
query timeout state
```

`Statement::step` 會進入 `Program::step`。`QueryMode` 決定：

- `Normal`: 真正執行 SQL。
- `Explain`: 回傳 bytecode listing。
- `ExplainQueryPlan`: 回傳 query plan。

所以 `EXPLAIN SELECT ...` 不是另外一套 executor，而是同一個 prepared program 用不同 mode 讀 metadata。

## Program 和 PreparedProgram

`core/vdbe/mod.rs` 裡，`Program` 持有：

```text
PreparedProgram:
  insns
  comments
  parameters
  result_columns
  readonly flag
  prepare context

Program:
  prepared: Arc<PreparedProgram>
  connection: Arc<Connection>
```

`PrepareContext` 用來判斷 cached statement 是否仍和 connection settings 相容。若 PRAGMA、attach、extension 等改變會影響 compile result，prepared statement 需要 reprepare。

這是資料庫常見設計：prepared program 可以 cache，但 cache invalidation 必須嚴格，否則 schema 或 setting 改了仍跑舊 bytecode。

## normal_step: VM 主迴圈

`Program::normal_step` 是讀 VM 的主入口。概念上：

```text
loop {
  check closed/interrupted/timeout
  if pending_io exists:
    if not finished -> return StepResult::IO
    if failed -> abort and return error
    clear pending_io

  clear previous result_row
  insn = insns[pc]
  function = insn.to_function()
  result = function(program, state, insn, pager)

  match result:
    Step -> continue
    Row -> return Row
    Done -> return Done
    IO -> store completion or yield
    Busy -> return Busy
    Err -> abort and return error
}
```

關鍵是 PC。大多數 opcode 成功時會 `state.pc += 1`。跳躍 opcode 會改 `state.pc` 到 target。若 opcode 遇到 I/O，通常不 advance PC，因為 re-entry 要重跑同一個 opcode 的下一個 state。

## Insn enum

`core/vdbe/insn.rs` 定義全部 bytecode。你不用一次背完，只要先認這幾類：

資料流/register:

```text
Null, Integer, Real, String8, Blob
Copy, Move, SCopy
Add, Subtract, Multiply, Divide
Eq, Ne, Lt, Le, Gt, Ge
Cast, Affinity
MakeRecord
```

Cursor/table/index:

```text
OpenRead, OpenWrite
Rewind, Next, Prev
SeekRowid, SeekGE, SeekGT, SeekLE, SeekLT
Column, RowId
Insert, Delete, IdxInsert, IdxDelete
```

Result/control:

```text
Init, Goto, If, IfNot, Jump
ResultRow
Halt
Transaction
Savepoint
```

Higher-level helpers:

```text
SorterOpen, SorterInsert, SorterNext
AggStep, AggFinal
Program
VOpen, VFilter, VColumn, VNext, VUpdate
```

## Insn -> function mapping

每個 `Insn` 會透過 `to_function()` 對應到 `core/vdbe/execute.rs` 的 function：

```text
InsnVariants::OpenRead  -> execute::op_open_read
InsnVariants::Column    -> execute::op_column
InsnVariants::ResultRow -> execute::op_result_row
InsnVariants::Next      -> execute::op_next
InsnVariants::Insert    -> execute::op_insert
InsnVariants::Delete    -> execute::op_delete
```

讀 opcode implementation 時，先不要從 `execute.rs` 第一行讀到最後。用 EXPLAIN 產生 opcode，再逐個 `rg "fn op_name"`。

## ResultRow

`op_result_row` 把 register range 變成使用者可見的一列。VM 不會一次把所有 rows 算完；它跑到 `ResultRow` 就停下來，把控制權還給 caller。下一次 `step` 從下一個 PC 繼續。

這就是 SQLite/Turso streaming rows 的核心。

## Column

`op_column` 從 cursor 目前指向的 record 取第 N 欄，decode 成 `Value`，放進 register。

這裡會牽涉：

- rowid alias。
- table cursor vs index cursor。
- record format。
- affinity/default value。
- short record after ALTER TABLE ADD COLUMN。
- overflow payload 可能 yield I/O。

所以 `Column` 看起來是簡單 opcode，但其實是 SQL type/schema/storage 的交會點。

## Next / Rewind / Seek

掃表大致是：

```text
OpenRead
Rewind end
...
ResultRow
Next loop_start
Halt
```

`Rewind` 把 cursor 移到第一筆。`Next` 前進到下一筆並跳回 loop。若有 index lookup，會用 `SeekGE`、`SeekGT`、`SeekRowid` 等。

這些 opcode 最後會呼叫 cursor trait：

```text
CursorTrait::rewind
CursorTrait::next
CursorTrait::seek
CursorTrait::record
CursorTrait::rowid
```

而 B-tree cursor 的實作在 `core/storage/btree.rs`。

## Transaction opcode

`Insn::Transaction` 是 VM 和 pager/WAL 交易層的交會點。它會根據 `TransactionMode` 進行 read/write transaction setup。

這裡要注意：

- 讀 transaction 需要穩定 snapshot。
- 寫 transaction 需要 WAL write lock。
- autocommit statement 和 explicit transaction 行為不同。
- MVCC path 有額外分支。
- attached database 也可能需要 transaction handling。

如果你要學 durability，先不要從 `op_transaction` 開始；先讀第 7 章的 pager/WAL，再回來看這個 opcode 會比較順。

## I/O re-entry 是 VM 最大難點

很多 opcode 不是一次做完。例如 `Column` 讀 overflow payload、`Insert` 寫 page、`Transaction` 開 write tx、`Commit` flush WAL，都可能需要 I/O。

Turso 的模式不是：

```rust
async fn op_column(...) -> ...
```

而是：

```text
op_column returns InsnFunctionStepResult::IO(...)
state.active_op_state remembers sub-state
next step re-enters same opcode
```

所以你會在 `execute.rs` 看到很多 `OpColumnState`、`OpTransactionState`、`OpInsertSubState`。這些 state 是 correctness 核心：如果 yield 前後 state mutation 不安全，就可能重複插入、跳過 row、破壞 cursor。

## 本章練習

用 EXPLAIN 產生最小 VM：

```sql
EXPLAIN SELECT 1 + 2;
```

實際輸出（addr/register 編號可能隨版本改變，但形狀應該接近）：

```text
addr  opcode             p1    p2    p3    p4             p5  comment
----  -----------------  ----  ----  ----  -------------  --  -------
0     Init               0     3     0                    0   Start at 3
1     ResultRow          1     1     0                    0   output=r[1]
2     Halt               0     0     0                    0
3     Integer            1     2     0                    0   r[2]=1
4     Integer            2     3     0                    0   r[3]=2
5     Add                2     3     1                    0   r[1]=r[2]+r[3]
6     Goto               0     1     0                    0
```

兩個新手常見疑問，先在這裡回答：

- 為什麼第一條 `Init` 跳到 addr 3？SQLite-style program 的慣例是把「初始化/常數載入」放在程式尾端，`Init` 先跳過去執行，再 `Goto` 跳回主體。所以執行順序是 0 -> 3 -> 4 -> 5 -> 6 -> 1 -> 2，不是從上到下。
- `r[2]=1` 這種 comment 就是 register 語義：把 literal 1 放進 register 2。`Add 2 3 1` 表示 `r[1] = r[2] + r[3]`。

追：

```bash
rg -n "Add \\{|ResultRow \\{|Halt \\{" core/vdbe/insn.rs
rg -n "fn op_add|fn op_result_row|fn op_halt" core/vdbe/execute.rs
```

再試 table scan：

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO t VALUES (1, 'a'), (2, 'b');
EXPLAIN SELECT name FROM t;
```

實際輸出（root page、register 編號可能不同）：

```text
addr  opcode             p1    p2    p3    p4             p5  comment
----  -----------------  ----  ----  ----  -------------  --  -------
0     Init               0     7     0                    0   Start at 7
1     OpenRead           0     2     0     k(2,B,B)       0   table=t, root=2, iDb=0
2     Rewind             0     6     0                    0   Rewind table t
3       Column           0     1     1                    0   r[1]=t.name
4       ResultRow        1     1     0                    0   output=r[1]
5     Next               0     3     0                    0
6     Halt               0     0     0                    0
7     Transaction        0     1     1                    0   iDb=0 tx_mode=Read
8     Goto               0     1     0                    0
```

注意三件事：`Transaction` 在尾端先跑（讀 transaction / snapshot 建立）；`Rewind` 的 p2=6 是「表為空時跳去 Halt」；`Next` 的 p2=3 是 loop 跳回 `Column`。addr 3-4 的縮排表示它們在 loop body 裡。

追 `OpenRead`、`Rewind`、`Column`、`ResultRow`、`Next`。如果能講出每個 opcode 對 cursor/register/PC 做什麼，就可以進下一章。

## 自我檢查

1. `Program` 和 `ProgramState` 為什麼要分開？
2. `ResultRow` 為什麼會讓 `step` 停下來，而不是繼續跑完整個 SELECT？
3. `Column` opcode 為什麼會牽涉 schema、record format、overflow page？
4. PC 什麼時候加一？什麼時候由 jump opcode 改寫？
5. 為什麼遇到 I/O 時通常不能 advance PC？
