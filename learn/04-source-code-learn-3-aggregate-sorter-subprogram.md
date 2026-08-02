# 04-3. 源碼精讀：聚合、排序器、子程式類 Opcode

`04-source-code-learn-1-insn-dispatch.md` 拆了純計算 opcode，`04-source-code-learn-2-cursor-opcodes.md` 拆了 cursor 與 storage opcode。本篇拆剩下三類**需要跨越多列或多層狀態**的指令。

這三類的共同特徵是：**一條指令的效果不侷限於當前這一列**。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 60–75 分鐘（約 17k 字，其中 38% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇涵蓋

```text
聚合:  AggStep / AggFinal / AggValue   跨列累加
排序:  SorterOpen / SorterInsert / SorterSort / SorterNext / SorterData
子程式: Program                        trigger 與 FK action
```

---

## 聚合：狀態住在 register 裡

### AggContext 的兩種形態

**`core/types.rs:801-807`** — 完整貼出：

```rust
pub enum AggContext {
    /// Built-in aggregates store state as a flat Vec<Value> payload.
    /// The layout depends on the aggregate function (see init_agg_payload).
    Builtin(Vec<Value>),
    /// External (extension) aggregates need FFI state that can't be serialized.
    External(ExternalAggState),
}
```

`04-source-code-learn-1-insn-dispatch.md` 看過 `Register` 有三個變體，其中 `Aggregate(AggContext)` 就是這個。

**內建聚合用扁平的 `Vec<Value>`**，佈局依函式而定：

| 函式 | payload 內容 |
|---|---|
| `count(x)` | `[計數]` |
| `sum(x)` | `[總和]` |
| `avg(x)` | `[總和, 計數]` |
| `group_concat(x, sep)` | `[已拼接字串]` |
| `min(x)` / `max(x)` | `[目前的極值]` |

**用 `Vec<Value>` 而非為每種聚合定義一個 struct**，好處是所有內建聚合共用同一套儲存與生命週期管理；代價是佈局的知識散在 `init_agg_payload` 與 `finalize_agg_payload` 兩處，必須保持一致。

**外部聚合則不同**：註解說明「FFI state that can't be serialized」。extension 的聚合狀態是一塊不透明的記憶體，由 extension 自己管理。

**`core/types.rs:809-819`** — 完整貼出：

```rust
impl AggContext {
    pub fn compute_external(&self) -> Result<Value> {
        if let Self::External(ext_state) = self {
            let mut final_value =
                unsafe { (ext_state.finalize_fn)(ext_state.context, ext_state.state) };
            let value = Value::from_ffi_ref(&final_value);
            if let Some(value_destructor) = ext_state.value_destructor {
                unsafe { value_destructor(&mut final_value) };
            } else {
                unsafe { final_value.__free_internal_type() };
            }
```

**這段是跨 FFI 邊界的記憶體管理**，值得細看：

1. 呼叫 extension 的 `finalize_fn` 取得結果（`unsafe`，因為是函式指標呼叫）。
2. **立刻**把它轉成 Rust 的 `Value`（`from_ffi_ref` 會複製資料）。
3. **釋放 extension 那側的記憶體** —— 優先用 extension 提供的 destructor，沒有就用內建的。

第三步不能省。extension 配置的記憶體必須由 extension（或雙方約定的方式）釋放——Rust 這側直接 drop 會造成 allocator 不匹配。

`value_destructor` 是 `Option` 說明這是可選的擴充點：extension 如果有特殊的釋放需求就提供，否則走預設。

### AggFinal：兩條指令共用一個實作

**`core/vdbe/execute.rs:7032-7051`** — 完整貼出：

```rust
pub fn op_agg_final(
    _program: &Program,
    state: &mut ProgramState,
    insn: &Insn,
    _pager: &Arc<Pager>,
) -> Result<InsnFunctionStepResult> {
    let (acc_reg, dest_reg, func) = match insn {
        Insn::AggFinal { register, func } => (*register, *register, func),
        Insn::AggValue {
            acc_reg,
            dest_reg,
            func,
        } => (*acc_reg, *dest_reg, func),
        _ => unreachable!("unexpected Insn {:?}", insn),
    };

    if let AccumulatorFunc::Window(win_func) = func {
        return op_window_value(state, acc_reg, dest_reg, win_func);
    }
    let func = func.expect_agg();
```

**注意這裡沒有用 `load_insn!`**，而是手寫 `match` —— 因為這個函式服務**兩條不同的指令**：

- **`AggFinal`** —— 一般聚合。結果**寫回同一個 register**（`(*register, *register, ...)`），累加器就地變成結果。
- **`AggValue`** —— 視窗函式。累加器在 `acc_reg`，結果寫到**另一個** `dest_reg`。

為什麼視窗函式要分開？因為它**每一列都要輸出一次目前的累加值，但累加器要繼續存在**。如果就地覆寫，下一列就沒有累加器可用了。

一般聚合則是整組結束才輸出一次，之後累加器不再需要，就地覆寫最省 register。

**同一個實作服務兩種語義，靠參數解構時的差異來區分。**

### 空集合的預設值

**`core/vdbe/execute.rs:7067-7090`** — 完整貼出：

```rust
        Register::Value(Value::Null) => {
            // No row was stepped: write the empty-set default explicitly.
            // For window aggregates `dest_reg` differs from `acc_reg` and may
            // still hold an earlier partition's result.
            match func {
                AggFunc::Total => {
                    state.registers[dest_reg]
                        .set_float(NonNan::new(0.0).expect("0.0 is a valid NonNan"));
                }
                AggFunc::Count | AggFunc::Count0 => {
                    state.registers[dest_reg].set_int(0);
                }
                #[cfg(feature = "json")]
                AggFunc::JsonGroupArray => {
                    state.registers[dest_reg].set_text(Text::json("[]".to_string()))?;
                }
                #[cfg(feature = "json")]
                AggFunc::JsonbGroupArray => {
                    state.registers[dest_reg]
                        .set_blob(json::jsonb::Jsonb::make_empty_array(1)?.data())?;
                }
                #[cfg(feature = "json")]
                AggFunc::JsonGroupObject => {
                    state.registers[dest_reg].set_text(Text::json("{}".to_string()))?;
```

**register 還是 `Null` 代表 `AggStep` 一次都沒執行**——`05b-source-code-learn-functions-expressions.md` 講過累加器是惰性初始化的，所以「還是 NULL」就等於「沒有任何一列進來」。

**空集合的預設值每個聚合都不同，而且是 SQL 標準規定的**：

| 函式 | 空集合結果 |
|---|---|
| `count()` | `0` |
| `total()` | `0.0`（浮點） |
| `sum()` | `NULL`（**不是 0**） |
| `json_group_array()` | `[]` |
| `json_group_object()` | `{}` |

`sum()` 回 NULL 而 `total()` 回 0.0 是 SQLite 的特有設計（`total` 就是為了避免 NULL 才存在的）。寫錯這裡，`SELECT sum(x) FROM empty_table` 就會回 0 而不是 NULL——是明確的相容性 bug。

那段註解還點出一個視窗函式特有的陷阱：

> For window aggregates `dest_reg` differs from `acc_reg` and **may still hold an earlier partition's result**.

視窗函式分 partition 處理。新 partition 開始時累加器重置為 NULL，但 `dest_reg` **還留著上一個 partition 的結果**。如果不明確寫入預設值，就會把上一個 partition 的答案洩漏到新 partition。

**「明確寫入」而不是「維持原狀」**——這是狀態重用時的通則。

---

## 排序器：ORDER BY 的實作

五條指令構成完整的排序流程：

```text
SorterOpen     建立排序器
  ↓
迴圈中: SorterInsert  每產生一列就丟進去
  ↓
SorterSort     排序（可能外部排序，落磁碟）
  ↓
迴圈: SorterData + SorterNext   依序取出
```

**`core/vdbe/execute.rs:7138`、`7213`、`7248`、`7274`、`7309`** — 五個函式的位置：

```rust
pub fn op_sorter_open(      // :7138
pub fn op_sorter_data(      // :7213
pub fn op_sorter_insert(    // :7248
pub fn op_sorter_sort(      // :7274
pub fn op_sorter_next(      // :7309
```

**排序器為什麼不能只用 `Vec` 排序？** 因為結果可能塞不進記憶體。`ORDER BY` 一億列時，排序器必須能**溢出到磁碟**（外部排序：分批排序寫成 run，再多路合併）。

所以 `SorterSort` 和 `SorterNext` 都可能 I/O——它們要讀寫暫存檔。

**排序器的 cursor 介面和 B-tree cursor 一樣**（`06b-source-code-learn-btree-cursor-pager.md` 講的 `CursorTrait`），所以 `SorterNext` 的迴圈結構和 `Next` 完全相同。這是抽象的價值：**emitter 產生迴圈的邏輯不必區分「掃表」和「掃排序結果」**。

`03-source-code-learn-2-optimizer.md` 講過 optimizer 會嘗試**消除排序**——如果選中的 index 讓輸出天然有序，這五條指令就完全不會產生。這是 index 最大的價值之一。

---

## Program：子程式的執行

`Insn::Program` 是最複雜的指令，因為它要**在一條指令內執行另一個完整的 VM 程式**。

用途是 trigger 和外鍵動作（`ON DELETE CASCADE` 等）。

### 入口

**`core/vdbe/execute.rs:4842-4857`** — 完整貼出：

```rust
pub fn op_program(
    program: &Program,
    state: &mut ProgramState,
    insn: &Insn,
    pager: &Arc<Pager>,
) -> Result<InsnFunctionStepResult> {
    load_insn!(
        Program {
            param_registers,
            program: subprogram,
            ignore_jump_target,
        },
        insn
    );
    let subprogram = subprogram.prepared_program()?;
    loop {
        match std::mem::take(state.active_op_state.program()) {
```

**`std::mem::take`** 而不是借用——因為狀態機裡持有一個 `Box<Statement>`（子程式的執行狀態），要把它移出來用。`take` 留下 `Default`（`OpProgramState::Start`），用完再放回去。

### 語句快取

**`core/vdbe/execute.rs:4859-4877`** — 完整貼出：

```rust
            OpProgramState::Start => {
                // Try to reuse a cached statement for this PC, otherwise create a new one.
                // When we have triggers or fk-actions with multi-row inserts, we can re-use
                // cached statements by storing them key'd by the state.pc if we are in a loop
                let pc_key = state.pc as usize;
                let mut statement =
                    if let Some(mut cached) = state.subprogram_stmt_cache.remove(&pc_key) {
                        cached.reset_for_subprogram_reuse();
                        cached
                    } else {
                        Box::new(Statement::new_with_origin(
                            Program::from_prepared(subprogram.clone(), program.connection.clone()),
                            pager.clone(),
                            QueryMode::Normal,
                            0,
                            crate::statement::StatementOrigin::Subprogram,
                            false,
                        ))
                    };
```

**這裡把整個系列的兩條線接了起來。**

第一，`StatementOrigin::Subprogram` —— `01-source-code-learn-1-entry-api.md` 介紹過這個 enum 的三個變體，當時只說「trigger/FK 的子程式」。現在看到它的實際建構點。

回顧 `01-source-code-learn-2-prepare-parse.md` 講的 `needs_nested_guard`：

```rust
impl StatementOrigin {
    pub(crate) const fn needs_nested_guard(self) -> bool {
        matches!(self, Self::InternalHelper)
    }
}
```

`Subprogram` **不需要** nested guard，而且這裡傳的最後一個參數是 `false`。因為子程式的交易與生命週期完全由父語句管理。

第二，`Program::from_prepared(subprogram.clone(), ...)` —— `01-source-code-learn-3-translate.md` 講的 `PreparedProgram` / `Program` 拆分在這裡發揮作用。子程式的 bytecode 是編譯期就產生好的 `Arc<PreparedProgram>`，這裡只是綁定當前 connection，clone 一個 `Arc` 而已。

第三，**依 `state.pc` 快取子程式的 statement**。註解說明了場景：

> When we have triggers or fk-actions with multi-row inserts, we can re-use cached statements by storing them key'd by the state.pc if we are in a loop

`INSERT INTO t SELECT ...` 插入一萬列，每列都要觸發 trigger。如果每次都重新建立 `Statement`（配置 registers、cursors 陣列），成本會很可觀。

用 `state.pc` 當 key 是因為**同一個 PC 位置代表同一個 trigger**——迴圈裡的那條 `Program` 指令每次執行時 PC 都相同。

`reset_for_subprogram_reuse()` 清掉上一輪的狀態但保留配置好的緩衝區。

### trigger 的狀態保存

**`core/vdbe/execute.rs:4879-4892`** — 完整貼出：

```rust
                // Check if this is a trigger subprogram - if so, track execution
                // and save last_insert_rowid so it can be restored after the trigger finishes.
                let (is_trigger, saved_last_insert_rowid, saved_last_changes_value) =
                    if let Some(ref trigger) = statement.get_trigger() {
                        program.connection.start_trigger_execution(trigger.clone());
                        (
                            true,
                            Some(program.connection.last_insert_rowid()),
                            Some(program.connection.changes()),
                        )
                    } else {
                        (false, None, None)
                    };
```

**trigger 內部的操作不該影響外部可見的 `last_insert_rowid()` 和 `changes()`。**

考慮：使用者執行 `INSERT INTO t VALUES(...)`，t 上有一個 trigger 會往 log 表插入一列。之後使用者呼叫 `last_insert_rowid()`——他期待拿到 **t 的 rowid**，不是 log 表的。

所以進入 trigger 前保存、離開後還原。`changes()`（影響列數）同理。

`start_trigger_execution(trigger.clone())` 則是**遞迴防護**：記錄「這個 trigger 正在執行中」，避免 trigger 直接或間接觸發自己造成無限遞迴。

### 參數傳遞

**`core/vdbe/execute.rs:4894-4906`** — 完整貼出：

```rust
                // Copy parameter values from parent registers into the subprogram's parameters.
                for (param_idx, &parent_reg) in param_registers.iter().enumerate() {
                    let value = state.registers[parent_reg].get_value().clone();
                    let param_index = NonZero::<usize>::new(param_idx + 1)
                        .expect("param_idx + 1 should be non-zero");
                    statement.bind_at(param_index, value)?;
                }

                *state.active_op_state.program() = OpProgramState::Step {
                    is_trigger,
                    statement,
                    saved_last_insert_rowid,
                    saved_changes_value: saved_last_changes_value,
                };
            }
```

**父程式的 register 值，透過 SQL 參數綁定機制傳給子程式。**

這就是 trigger 裡 `OLD.x` 和 `NEW.x` 的實作：編譯 trigger 時，那些引用被轉成參數；執行時，父程式把對應 register 的值綁進去。

`NonZero::<usize>::new(param_idx + 1)` —— 參數編號從 1 開始（`02-source-code-learn-parser-and-ast.md` 講過 `?0` 被拒絕、型別是 `NonZeroU32` 的原因）。這裡 `+1` 就是在做這個轉換。

**注意 `.clone()`** —— 值被複製進子程式。這是必要的：子程式執行期間可能修改父程式的 register（例如遞迴的 trigger），拿指標會造成 aliasing 問題。

### 執行與 I/O 傳遞

**`core/vdbe/execute.rs:4927-4953`** — 完整貼出：

```rust
            OpProgramState::Step {
                is_trigger,
                mut statement,
                saved_last_insert_rowid,
                saved_changes_value: saved_last_changes_value,
            } => {
                let mut raise_ignore = false;
                // Track whether the subprogram aborted with an error. When abort()
                // runs inside the subprogram, it already calls end_trigger_execution(),
                // so we must not call it again after the loop.
                let mut subprogram_aborted = false;
                loop {
                    let res = statement.step_subprogram();
                    match res {
                        Ok(step_result) => match step_result {
                            StepResult::Done => break,
                            StepResult::IO | StepResult::Yield => {
                                let io = statement
                                    .take_io_completions()
                                    .unwrap_or_else(|| IOCompletions(Completion::new_yield()));
                                *state.active_op_state.program() = OpProgramState::Step {
                                    is_trigger,
                                    statement,
                                    saved_last_insert_rowid,
                                    saved_changes_value: saved_last_changes_value,
                                };
                                return Ok(InsnFunctionStepResult::IO(io));
                            }
```

**這是本篇最重要的一段：I/O 如何穿越兩層 VM。**

`statement.step_subprogram()` —— 這正是 `01-source-code-learn-4-step-vm.md` 看過的那個「跳過所有檢查」的快速入口：

```rust
    /// Fast step for trigger/FK subprograms: skips reprepare checks, timeout
    /// arming, busy handler, metrics recording, and schema retry.
    /// The parent statement handles all of those concerns.
    pub fn step_subprogram(&mut self) -> Result<StepResult> {
```

當時說「父語句已經處理過這些關切」，現在看到父語句就是這裡。

而 I/O 的處理是關鍵：

1. 子程式回報 `IO` 或 `Yield`。
2. **把整個 `statement` 存進父程式的狀態機**（`OpProgramState::Step { statement, ... }`）。
3. 父程式回報 `InsnFunctionStepResult::IO`，讓 I/O 繼續往上冒泡。
4. 重入時從 `Step` 狀態繼續，`statement` 還在，子程式從它自己的 PC 繼續。

**子程式的執行狀態被完整保存在父程式的狀態機裡。** 這是 `07b-source-code-learn-ioresult-reentry.md` 講的「巢狀的可中斷操作需要巢狀的狀態儲存」的極致例子——這裡巢狀的不是一個小狀態，而是**一整個 VM 的執行狀態**。

那個 `unwrap_or_else(|| IOCompletions(Completion::new_yield()))` 處理 `Yield` 的情況：`Yield` 沒有真正的 completion，所以造一個空的 yield completion。呼應 `07b` 講的 `Completion.inner: Option`（`None` 代表純 yield，不配置記憶體）。

`subprogram_aborted` 那段註解也值得注意：

> When abort() runs inside the subprogram, it already calls end_trigger_execution(), so we must not call it again after the loop.

**成對操作在錯誤路徑上容易重複執行。** 這裡用旗標記錄「已經清理過了」，避免 `end_trigger_execution` 被呼叫兩次（那會讓 trigger 遞迴計數變成負數）。

---

## 三類指令的共同主題

| | 跨越什麼 | 狀態放哪 |
|---|---|---|
| 聚合 | 多列 | `Register::Aggregate` |
| 排序 | 全部結果 + 可能落磁碟 | 排序器（獨立的 cursor） |
| 子程式 | 一整個 VM | `OpProgramState` 裡的 `Box<Statement>` |

**三者都打破了「一條指令處理一列」的簡單模型**，也因此都需要額外的狀態管理。

而且三者都可能 I/O：聚合的 `AggStep` 可能讀 overflow page、排序器可能讀寫暫存檔、子程式可能做任何事。所以 `07b-source-code-learn-ioresult-reentry.md` 的重入規則在這三類指令上一體適用。

---

## 動手驗證

看聚合的空集合行為：

```bash
cd /Users/stanhsu/projects/turso
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE empty_t(x INTEGER);
SELECT count(x), sum(x), total(x) FROM empty_t;
```

應該得到 `0|<NULL>|0.0` —— 三個不同的空集合預設值，正好對應上面那段 `match func`。

看 `AggStep` / `AggFinal` 的位置：

```sql
CREATE TABLE t(a INTEGER);
INSERT INTO t VALUES (1),(2),(3);
EXPLAIN SELECT sum(a) FROM t;
```

確認 `AggStep` 在 `Rewind`/`Next` 迴圈**內**，`AggFinal` 在迴圈**外**。

看排序器：

```sql
EXPLAIN SELECT a FROM t ORDER BY a DESC;
```

應該有 `SorterOpen`、`SorterInsert`、`SorterSort`、`SorterData`、`SorterNext`。再建一個 index 看排序被消除：

```sql
CREATE INDEX t_a ON t(a);
EXPLAIN SELECT a FROM t ORDER BY a;
```

有 index 之後，sorter 指令應該消失——optimizer 判斷 index 掃描天然有序（`03-source-code-learn-2-optimizer.md`）。

看子程式：

```sql
CREATE TABLE log(msg TEXT);
CREATE TRIGGER t_ins AFTER INSERT ON t BEGIN
  INSERT INTO log VALUES ('inserted');
END;
EXPLAIN INSERT INTO t VALUES (99);
```

`EXPLAIN` 會把 trigger 的 bytecode 也展開（`04-source-code-learn-1-insn-dispatch.md` 講的 `explain_state.pending` 佇列）。

驗證 `last_insert_rowid` 的保存：

```sql
INSERT INTO t VALUES (100);
SELECT last_insert_rowid();
```

應該是 t 的 rowid，不是 log 表的。

追 source：

```bash
rg -n "pub enum AggContext" core/types.rs
rg -n "pub fn op_agg_step|pub fn op_agg_final" core/vdbe/execute.rs
rg -n "pub fn op_sorter_" core/vdbe/execute.rs
rg -n "pub fn op_program|pub enum OpProgramState" core/vdbe/execute.rs
```

---

## 自我檢查

1. 內建聚合用 `Vec<Value>` 存狀態，這個設計的好處與代價各是什麼？
2. `avg(x)` 的 payload 為什麼需要兩個值？
3. `compute_external` 為什麼一定要釋放 extension 那側的記憶體？直接 drop 會怎樣？
4. `op_agg_final` 為什麼不用 `load_insn!` 而是手寫 `match`？
5. `AggFinal` 和 `AggValue` 的差別是什麼？為什麼視窗函式需要不同的 register 配置？
6. 累加器 register 還是 `Null` 代表什麼？
7. `sum()` 和 `total()` 在空集合上的結果為什麼不同？
8. 視窗函式的 `dest_reg` 為什麼「可能還留著上一個 partition 的結果」？不明確寫入預設值會怎樣？
9. 排序器為什麼不能只用 `Vec` 排序？哪兩條 sorter 指令可能 I/O？
10. 排序器實作 `CursorTrait` 帶來什麼好處？
11. `op_program` 為什麼用 `std::mem::take` 而不是借用狀態？
12. 子程式的 `Statement` 為什麼要依 `state.pc` 快取？什麼場景下效益最大？
13. `StatementOrigin::Subprogram` 為什麼不需要 nested guard？
14. trigger 執行前為什麼要保存 `last_insert_rowid()` 和 `changes()`？
15. trigger 裡的 `OLD.x` / `NEW.x` 是怎麼從父程式傳進來的？為什麼要 `.clone()`？
16. 子程式回報 `IO` 時，父程式怎麼保存它的執行狀態？這對應 `07b` 的什麼原則？
17. `subprogram_aborted` 這個旗標在防什麼？

---

下一篇 `06c-source-code-learn-btree-balancing.md`：B-tree 的 page 分裂與合併——storage 層最難的部分。
