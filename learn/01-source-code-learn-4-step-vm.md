# 01-4. 源碼精讀：step 與 VDBE 主迴圈

本篇對應 `01-sql-lifecycle.md` 的**第七層**：編譯好的 bytecode 如何被執行。這是整個系列的轉折點——前三篇都在編譯，從這裡開始才真正碰資料。

前一篇結束在 `translate` 產出 `Program`。本篇看它怎麼跑起來。

> 行號以撰寫當下的 checkout 為準；symbol 名稱較穩定。找不到時用 `rg -n "symbol_name" <file>`。

> **閱讀時間**：約 90–120 分鐘（約 24k 字，其中 53% 是原始碼）。建議分 **2 個 session**，文中有標示休息點。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/statement.rs      Statement::step → _step ── 生命週期記帳、reprepare、timeout、busy
  └─> core/vdbe/mod.rs   Program::step ── 依 QueryMode 分派
        └─> core/vdbe/mod.rs   normal_step ── VM 主迴圈（本篇主角）
              └─> core/vdbe/insn.rs      Insn::to_function
                    └─> core/vdbe/execute.rs   op_* ── 各指令實作
```

本篇的核心觀念：**`step` 不會把整條 SQL 跑完**。它跑到「有事要回報」就停下來——產出一列、需要等 I/O、被鎖擋住、或執行完畢。這個設計是 SQLite 的 streaming 模型，也是 Turso 處理 I/O 的方式。

---

## StepResult：五種回報

先看 `step` 能回報什麼，這樣後面讀迴圈才有座標。

**`core/vdbe/mod.rs:170-182`** — 完整貼出：

```rust
#[derive(Debug)]
pub enum StepResult {
    Done,
    IO,
    Row,
    Interrupt,
    Busy,
    /// The statement explicitly yielded control back to the caller without any pending I/O.
    /// Stepping again immediately (even in a tight loop) is fine; blocking callers should
    /// still drive the event loop (`io.step()`) between steps so progress that depends on
    /// other threads' I/O is not starved.
    Yield,
}
```

六個變體（enum 名稱誤導，實際有六個），意義各不相同：

| 變體 | 意義 | 呼叫者該做什麼 |
|---|---|---|
| `Row` | 產出了一列結果 | 讀取該列，然後再次 `step` |
| `Done` | 執行完畢 | 停止 |
| `IO` | 需要等 I/O 完成 | 驅動 I/O（`io.step()`），完成後再 `step` |
| `Busy` | 被鎖擋住 | 等待或重試 |
| `Interrupt` | 被中斷 | 停止 |
| `Yield` | 主動讓出，但**沒有** pending I/O | 可以立刻再 `step` |

`IO` 和 `Yield` 的差別值得注意，那段註解說得很清楚：`Yield` 沒有待完成的 I/O，是 statement 主動把控制權交回去讓其他 connection 有機會前進（例如釋放競爭中的鎖）。所以立刻再 step 是合法的，不會空轉；但呼叫者仍應驅動事件迴圈，免得依賴其他執行緒 I/O 的進度被餓死。

呼叫者怎麼用這個 enum？看一個現成的驅動迴圈：

**`core/statement.rs:690-705`** — 完整貼出：

```rust
    pub fn run_collect_rows(&mut self) -> Result<Vec<Vec<Value>>> {
        let mut values = Vec::new();
        loop {
            match self.step()? {
                vdbe::StepResult::Done => return Ok(values),
                vdbe::StepResult::IO | vdbe::StepResult::Yield => self.pager.io.step()?,
                vdbe::StepResult::Row => {
                    values.push(self.row().unwrap().get_values().cloned().collect());
                    continue;
                }
                vdbe::StepResult::Interrupt | vdbe::StepResult::Busy => {
                    return Err(LimboError::Busy)
                }
            }
        }
    }
```

這 15 行就是「同步執行一條 SQL」的完整樣貌：反覆 step，遇到 `IO`/`Yield` 就推一下 I/O 事件迴圈，遇到 `Row` 就收集，遇到 `Done` 就結束。

**這正是 core 不用 `async fn` 的原因**：把「什麼時候等、怎麼等」的決定權交給呼叫者。同步呼叫者用上面這種阻塞迴圈；async 呼叫者（binding 層）則把 `StepResult::IO` 轉成 `Poll::Pending`，接到 Rust 的 async runtime 上。同一份 core 程式碼同時支援兩種模型。

---

## Statement::step：執行前的守門

**`core/statement.rs:658-675`** — 完整貼出：

```rust
    #[inline]
    pub fn step(&mut self) -> Result<StepResult> {
        self._step(None)
    }

    #[inline]
    pub fn step_with_waker(&mut self, waker: &Waker) -> Result<StepResult> {
        self._step(Some(waker))
    }

    /// Fast step for trigger/FK subprograms: skips reprepare checks, timeout
    /// arming, busy handler, metrics recording, and schema retry.
    /// The parent statement handles all of those concerns.
    #[inline]
    pub fn step_subprogram(&mut self) -> Result<StepResult> {
        self.program
            .step(&mut self.state, &self.pager, self.query_mode, None)
    }
```

三個入口：

- `step()` —— 同步呼叫者用。
- `step_with_waker()` —— async 呼叫者用。`Waker` 是 Rust async 的喚醒把手；I/O 完成時會用它叫醒 task。這就是 core 接上 async runtime 的接點。
- `step_subprogram()` —— **直接跳過 `_step`**，注意那段註解：trigger 和 FK action 的子程式跳過 reprepare 檢查、timeout、busy handler、metrics，因為父語句已經處理過了。重複做不只浪費，還可能算錯（例如 metrics 重複計數）。

### _step：五道關卡

**`core/statement.rs:507-551`** — 完整貼出前半：

```rust
    fn _step(&mut self, waker: Option<&Waker>) -> Result<StepResult> {
        if !self.counted_as_active_root && matches!(self.origin, StatementOrigin::Root) {
            self.program
                .connection
                .n_active_root_statements
                .fetch_add(1, Ordering::SeqCst);
            self.counted_as_active_root = true;
        }
        if matches!(self.state.execution_state, ProgramExecutionState::Init)
            && self.origin != StatementOrigin::InternalHelper
        {
            if self.program.connection.mvcc_enabled() {
                // MVCC checkpoints can publish internal schema roots without changing
                // SQLite's schema cookie, so refresh before deciding whether to reprepare.
                self.program.connection.maybe_update_schema();
            }
            if !self
                .program
                .prepare_context
                .matches_connection(&self.program.connection)
            {
                if let Err(err) = self.reprepare() {
                    self.release_active_root_if_counted();
                    return Err(err);
                }
            }
        }

        self.arm_query_timeout_if_needed();

        // If we're waiting for a busy handler timeout, check if we can proceed
        if let Some(busy_state) = self.busy_handler_state.as_ref() {
            if self.pager.io.current_time_monotonic() < busy_state.timeout() {
                // Yield the query as the timeout has not been reached yet
                if let Some(waker) = waker {
                    waker.wake_by_ref();
                }
                return Ok(StepResult::IO);
            }
        }

        const MAX_SCHEMA_RETRY: usize = 50;
        let mut res = self
            .program
            .step(&mut self.state, &self.pager, self.query_mode, waker);
```

四件事發生在真正執行之前：

**一、活躍語句計數（只加一次）。** `counted_as_active_root` 這個旗標確保即使 `step` 被呼叫一百次，計數也只加一次。這是第 1 篇提過的成對記帳。

**二、reprepare 檢查——第 3 篇伏筆的回收。**

```rust
            if !self.program.prepare_context.matches_connection(&self.program.connection) {
                if let Err(err) = self.reprepare() {
```

這就是 `prepare_context` 的用途。條件是 `execution_state == Init`，也就是**只在語句還沒開始跑的時候檢查**——執行到一半才發現設定變了就太晚了，那時已經有 cursor 開著、可能已經寫了資料。

MVCC 那段註解揭露一個微妙情況：MVCC checkpoint 可能改變內部 schema 但**不動 SQLite 的 schema cookie**，所以不能只靠 cookie 判斷，要主動刷新。這種「常規的變更偵測機制在某條路徑下失效」的情況，在資料庫裡很常見，也是 bug 的溫床。

**三、arm timeout。** 設定這次執行的截止時間。

**四、busy handler。** 如果上次被鎖擋住、正在等待重試，就檢查時間到了沒。沒到就回 `StepResult::IO`，並且**如果有 waker 就立刻喚醒**（`waker.wake_by_ref()`）——因為這不是真的在等 I/O，只是在等時鐘，需要主動安排下次輪詢。

### schema 重試迴圈

**`core/statement.rs:548-574`** — 完整貼出：

```rust
        const MAX_SCHEMA_RETRY: usize = 50;
        let mut res = self
            .program
            .step(&mut self.state, &self.pager, self.query_mode, waker);
        for attempt in 0..MAX_SCHEMA_RETRY {
            // Only reprepare if we still need to update schema
            if !matches!(res, Err(LimboError::SchemaUpdated)) {
                break;
            }
            // In a write transaction, reprepare may not help (e.g. cross-process
            // schema change where the in-memory schema hasn't been refreshed from
            // disk). Allow a few retries for the in-process case where reprepare
            // *can* resolve the issue, but bail early to avoid burning 50 attempts.
            if attempt >= 2
                && !self.program.connection.get_auto_commit()
                && matches!(
                    self.program.connection.get_tx_state(),
                    TransactionState::Write { .. } | TransactionState::PendingUpgrade { .. }
                )
            {
                break;
            }
            tracing::debug!("reprepare: attempt={}", attempt);
            if let Err(err) = self.reprepare() {
                self.release_active_root_if_counted();
                return Err(err);
            }
            // ── 省略：重試 step 並更新 res ──
```

如果執行過程中 VM 回報 `SchemaUpdated`（表示 schema 在執行期間變了），就重新編譯再試。

兩層保護：

- 硬上限 50 次。
- **提早放棄的啟發式**：如果已經試了 3 次以上，而且處在明確的寫交易中，就別再試了。註解解釋了原因——跨程序的 schema 變更，記憶體裡的 schema 沒從磁碟刷新，重編一百次也是一樣的結果。與其燒完 50 次配額，不如早點回報錯誤。

**這種「重試有上限、而且知道什麼時候重試沒用」的設計，是生產級資料庫和玩具的差別之一。**

---

## Program::step：依模式分派

**`core/vdbe/mod.rs:1563-1590`** — 完整貼出：

```rust
    #[turso_macros::trace_stack]
    pub fn step(
        &self,
        state: &mut ProgramState,
        pager: &Arc<Pager>,
        query_mode: QueryMode,
        waker: Option<&Waker>,
    ) -> Result<StepResult> {
        state.execution_state = ProgramExecutionState::Running;
        let result = match query_mode {
            QueryMode::Normal => self.normal_step(state, pager, waker),
            QueryMode::Explain => self.explain_step(state, pager),
            QueryMode::ExplainQueryPlan => self.explain_query_plan_step(state, pager),
        };
        match &result {
            Ok(StepResult::Done) => {
                state.execution_state = ProgramExecutionState::Done;
            }
            Ok(StepResult::Interrupt) => {
                state.execution_state = ProgramExecutionState::Interrupted;
            }
            Err(_) => {
                state.execution_state = ProgramExecutionState::Failed;
            }
            _ => {}
        }
        result
    }
```

三分之一的函式在維護 `execution_state`，這個狀態機讓後續程式碼（reset、drop、reprepare）知道語句處在什麼階段。

`QueryMode` 的分派在此揭曉：**`EXPLAIN` 走的是完全不同的 step 函式**，但用的是**同一份 bytecode**。

- `normal_step` —— 真的執行指令。
- `explain_step` —— 不執行，把指令逐條格式化成結果列輸出。

這印證第 3 篇的說法：EXPLAIN 不是模擬器，它就是把即將執行的那份 bytecode 印出來。`explain_step` 的作法可以瞄一眼：

**`core/vdbe/mod.rs:1629-1634`** — 節錄：

```rust
        let pc = state.pc as usize;

        // Explain the current instruction from the active program.
        // We collect subprograms separately to avoid borrow conflicts with explain_state.
        let (row, subprogram) = if let Some(ref current) = explain_state.current {
            let (insn, _) = &current.insns[pc];
```

它同樣用 `state.pc` 逐條走訪 `insns`，只是把每條指令變成一列文字而不是執行它。連 trigger 子程式都會被展開（`explain_state.pending` 佇列），所以 `EXPLAIN` 看得到 trigger 內部的 bytecode。

---

---

> ### ⏸ Session 1 到此
>
> 目前為止涵蓋了：StepResult 的六種回報、Statement::step 的四道關卡、QueryMode 分派。
>
> 休息之前，先確認你能說出這幾件事；說不出來就往回翻，不要硬推進——後半段會用到它們。
>
> **Session 2** 從下一節開始：VM 主迴圈本身，以及 ProgramState 保存了什麼。

---

## normal_step：VM 主迴圈

這是本篇的核心。函式約 160 行，我拆成四段完整貼出。

### 第一段：迴圈開頭的安全檢查

**`core/vdbe/mod.rs:1736-1755`**

```rust
    fn normal_step(
        &self,
        state: &mut ProgramState,
        pager: &Arc<Pager>,
        waker: Option<&Waker>,
    ) -> Result<StepResult> {
        let enable_tracing = tracing::enabled!(tracing::Level::TRACE);
        loop {
            if self.connection.is_closed() {
                // Connection is closed for whatever reason, rollback the transaction.
                let state = self.connection.get_tx_state();
                if let TransactionState::Write { .. } = state {
                    pager.rollback_tx(&self.connection);
                }
                return Err(LimboError::InternalError("Connection closed".to_string()));
            }
            if self.maybe_request_interrupt(state, pager.io.as_ref()) {
                self.abort(pager, None, state)?;
                return Ok(StepResult::Interrupt);
            }
```

注意這兩個檢查在**迴圈內**，也就是每執行一條指令都檢查一次。為什麼不放迴圈外？因為 `normal_step` 一次呼叫可能執行成千上萬條指令（一路跑到產出下一列為止）。如果只在進入時檢查，一條掃描百萬列的查詢就會變成無法中斷。

connection 關閉時**主動 rollback 寫交易**。這是關鍵的正確性行為：不能留下一個開著的寫交易，否則 WAL 的 write lock 不會釋放，其他 connection 全部卡死。

`maybe_request_interrupt` 同時處理使用者中斷、progress handler、查詢逾時。

### 第二段：pending I/O 的處理

**`core/vdbe/mod.rs:1757-1785`**

```rust
            if let Some(io) = &state.io_completions {
                if !io.finished() {
                    io.set_waker(waker);
                    return Ok(StepResult::IO);
                }
                if let Some(err) = io.get_error() {
                    if pager.is_checkpointing() {
                        // Wrap IO errors that occurred during checkpointing in CheckpointFailed error,
                        // so that abort() knows not to try to rollback the transaction, because the transaction
                        // is already durable in the WAL and hence committed.
                        // This also lets the simulator know that it should shadow the results of the query because
                        // the write itself succeeded.
                        let checkpoint_err = LimboError::CheckpointFailed(err.to_string());
                        tracing::error!("Checkpoint failed: {checkpoint_err}");
                        if let Err(abort_err) = self.abort(pager, Some(&checkpoint_err), state) {
                            tracing::error!(
                                "Abort also failed during checkpoint error handling: {abort_err}"
                            );
                        }
                        return Err(checkpoint_err);
                    }
                    let err = err.into();
                    if let Err(abort_err) = self.abort(pager, Some(&err), state) {
                        tracing::error!("Abort failed during error handling: {abort_err}");
                    }
                    return Err(err);
                }
                state.io_completions = None;
            }
```

這段是「I/O 重入」的入口，三種情況：

**還沒完成** → 掛上 waker，回 `StepResult::IO`。注意此時 **PC 沒有前進**，下次呼叫會回到同一條指令。

**完成但出錯** → 中止。

**完成且成功** → 清掉 `io_completions`，繼續往下執行同一條指令。

中間那段 checkpoint 的特殊處理是本段最有價值的部分，值得細讀註解：

> Wrap IO errors that occurred during checkpointing in CheckpointFailed error, so that abort() knows not to try to rollback the transaction, because the transaction is already durable in the WAL and hence committed.

**checkpoint 失敗 ≠ 交易失敗。** checkpoint 是把 WAL 裡已提交的資料搬回主資料庫檔案。如果 commit frame 已經寫進 WAL 並且 durable，交易**就已經提交了**，之後的 checkpoint 失敗只是「搬運工作沒做完」，資料還在 WAL 裡，下次還能再搬。

如果這裡誤把它當成一般 I/O 錯誤去 rollback，就會把一個**已經對使用者承諾提交**的交易回滾掉——這是資料遺失等級的 bug。所以要包成專門的 `CheckpointFailed` 讓 `abort()` 知道別動交易。

這也呼應 `07a-wal-transactions-checkpoint.md` 的自我檢查題「auto-checkpoint 失敗時，為什麼 transaction 仍可能已提交？」——答案的實作就在這裡。

### 第三段：取指令並執行

**`core/vdbe/mod.rs:1786-1793`** — 主線；中間的 trace 區塊省略：

```rust
            // invalidate row
            let _ = state.result_row.take();
            let (insn, _) = &self.insns[state.pc as usize];
            let insn_function = insn.to_function();
            if enable_tracing {
                trace_insn(self, state.pc as InsnReference, insn);
                crate::stack::trace_remaining("program_step:opcode");
            }
```

```rust
            // ── 省略（core/vdbe/mod.rs:1794-1833）：get_vdbe_trace() 開啟時的
            //    register diff 輸出與 opcode 列印，純除錯功能，不影響控制流 ──
```

**`core/vdbe/mod.rs:1834-1837`**

```rust
            // Always increment VM steps for every loop iteration
            state.metrics.vm_steps = state.metrics.vm_steps.saturating_add(1);

            match insn_function(self, state, insn, pager) {
```

三個動作：

**`state.result_row.take()`** —— 清掉上一輪的結果列。這確保呼叫者不會誤讀到過期的列。

**`&self.insns[state.pc as usize]`** —— 用 PC 取指令。這就是「程式計數器」的字面意義。

**`insn.to_function()`** —— 查表拿到實作函式。第 3 篇提過這是 `const fn`，對應關係編譯期就固定了，執行期只是查表，沒有動態分派成本。

### 第四段：處理指令的回報

**`core/vdbe/mod.rs:1837-1892`** — 完整貼出：

```rust
            match insn_function(self, state, insn, pager) {
                Ok(InsnFunctionStepResult::Step) => {
                    // Instruction completed, moving to next
                    state.metrics.insn_executed = state.metrics.insn_executed.saturating_add(1);
                }
                Ok(InsnFunctionStepResult::Done) => {
                    // Instruction completed execution
                    state.metrics.insn_executed = state.metrics.insn_executed.saturating_add(1);
                    state.auto_txn_cleanup = TxnCleanup::None;
                    return Ok(StepResult::Done);
                }
                Ok(InsnFunctionStepResult::IO(io)) => {
                    // Instruction not complete - waiting for I/O, will resume at same PC
                    io.set_waker(waker);
                    let is_yield = io.is_explicit_yield();
                    if is_yield {
                        // Yield: return control to the cooperative scheduler so
                        // other connections can make progress (e.g. release a
                        // contended lock). Don't store in io_completions —
                        // yields aren't pending I/O, so the instruction will
                        // simply re-execute on the next step.
                        return Ok(StepResult::Yield);
                    }
                    let finished = io.finished();
                    state.io_completions = Some(io);
                    if !finished {
                        return Ok(StepResult::IO);
                    }
                    // just continue the outer loop if IO is finished so db will continue execution immediately
                }
                Ok(InsnFunctionStepResult::Row) => {
                    // Instruction completed (ResultRow already incremented PC)
                    state.metrics.insn_executed = state.metrics.insn_executed.saturating_add(1);
                    return Ok(StepResult::Row);
                }
                Err(LimboError::Busy) => {
                    // Instruction blocked - will retry at same PC
                    return Ok(StepResult::Busy);
                }
                Err(LimboError::BusySnapshot)
                    if self.connection.transaction_state.get() == TransactionState::None =>
                {
                    // For interactive transactions that are already in a read transaction, retrying BusySnapshot is pointless
                    // because the snapshot will continue to be stale no matter how many times we retry.
                    // However, for auto-commits or BEGIN IMMEDIATE, failing to promote to write transaction means it was rolled
                    // back, so auto-retrying can be useful.
                    return Ok(StepResult::Busy);
                }
                Err(err) => {
                    if let Err(abort_err) = self.abort(pager, Some(&err), state) {
                        tracing::error!("Abort failed during error handling: {abort_err}");
                    }
                    return Err(err);
                }
            }
        }
    }
```

指令的回報型別定義在：

**`core/vdbe/execute.rs:388-393`**

```rust
pub enum InsnFunctionStepResult {
    Done,
    IO(IOCompletions),
    Row,
    Step,
}
```

逐個對照：

**`Step`** —— 指令完成，繼續迴圈跑下一條。**注意它不 return**，這就是為什麼一次 `step()` 呼叫可能執行大量指令。

**`Done`** —— 整個程式結束（`Halt` 指令會回這個）。

**`IO(io)`** —— 這個分支最重要，它區分了兩種情況：

```rust
                    let is_yield = io.is_explicit_yield();
                    if is_yield {
                        return Ok(StepResult::Yield);
                    }
                    let finished = io.finished();
                    state.io_completions = Some(io);
                    if !finished {
                        return Ok(StepResult::IO);
                    }
                    // just continue the outer loop if IO is finished so db will continue execution immediately
```

- **明確 yield** → 回 `Yield`，而且**不存進 `io_completions`**。註解解釋：yield 不是待完成的 I/O，下次 step 直接重跑該指令即可。
- **真的 I/O，還沒完成** → 存進 `io_completions`，回 `IO`。下次進迴圈會走第二段那個檢查。
- **真的 I/O，但已經完成了** → 不 return，**直接繼續迴圈**。這是效能最佳化：如果資料已經在 page cache 裡，`read_page` 會立刻完成，此時沒必要繞一圈回到呼叫者再回來。

**`Row`** —— 產出一列。註解特別註明「ResultRow 已經自己遞增了 PC」。

這點很重要，看一下 `op_result_row` 的實作：

**`core/vdbe/execute.rs:2978-2992`** — 完整貼出：

```rust
pub fn op_result_row(
    _program: &Program,
    state: &mut ProgramState,
    insn: &Insn,
    _pager: &Arc<Pager>,
) -> Result<InsnFunctionStepResult> {
    load_insn!(ResultRow { start_reg, count }, insn);
    let row = Row {
        values: &state.registers[*start_reg] as *const Register,
        count: *count,
    };
    state.result_row = Some(row);
    state.pc += 1;
    Ok(InsnFunctionStepResult::Row)
}
```

只有 15 行，但示範了整個 VM 的核心手法：

- `load_insn!` 把 enum 變體解構出參數（`start_reg`、`count`）。
- 從 registers 建立一個 `Row`——注意是**裸指標**，不是複製資料。列的內容還在 registers 裡，`Row` 只是一個視窗。這避免了每列一次配置記憶體。
- **`state.pc += 1` 在 return 之前**。所以下次 step 從下一條指令繼續，不會重複輸出同一列。

對照之下，回傳 `IO` 的指令**不會**遞增 PC，因為它下次要從同一條指令重新進入。**「PC 有沒有前進」就是 VM 判斷「這條指令做完了沒」的方式。**

**`Err(LimboError::Busy)`** —— 回 `StepResult::Busy`，PC 不動，之後重試同一條指令。

**`Err(LimboError::BusySnapshot)`** 這個分支的守衛條件值得看：

```rust
                Err(LimboError::BusySnapshot)
                    if self.connection.transaction_state.get() == TransactionState::None =>
```

只有在**沒有明確交易**時才轉成 `Busy` 讓呼叫者重試。註解解釋得很清楚：如果已經在一個互動式交易裡，snapshot 是固定的，重試一萬次那個 snapshot 還是舊的，永遠不會成功——這種情況要直接把錯誤丟給使用者，讓他自己決定要不要 rollback 重來。但如果是 autocommit 或 `BEGIN IMMEDIATE`，升級寫交易失敗代表已經回滾了，自動重試是有意義的。

**知道「什麼時候重試沒用」和知道「怎麼重試」一樣重要。**

---

## ProgramState：執行期的全部狀態

VM 迴圈操作的可變狀態都在這裡。

**`core/vdbe/mod.rs:699-720`** — 節錄前段欄位：

```rust
pub struct ProgramState {
    pub io_completions: Option<IOCompletions>,
    pub pc: InsnReference,
    pub(crate) cursors: Vec<Option<Cursor>>,
    cursor_seqs: Vec<i64>,
    registers: Box<[Register]>,
    /// Trace state: register snapshot for diffing.
    pre_op_registers: Option<Box<[Register]>>,
    pub(crate) result_row: Option<Row>,
    last_compare: Option<std::cmp::Ordering>,
    deferred_seeks: Vec<Option<DeferredSeekState>>,
    /// Indicate whether a coroutine has ended for a given yield register.
    /// If an element is present, it means the coroutine with the given register number has ended.
    ended_coroutine: Vec<u32>,
    /// Indicate whether an [Insn::Once] instruction at a given program counter position has already been executed, well, once.
    once: SmallVec<[u32; 4]>,
    pub execution_state: ProgramExecutionState,
    /// Per-execution statement deadline derived from the connection query timeout.
    /// `None` means no timeout.
    pub query_deadline: Option<crate::MonotonicInstant>,
    pub parameters: Vec<Value>,
    commit_state: CommitState,
    // ── 省略：MVCC sequence inner-tx 相關欄位、json_cache、metrics、
    //         current_collation 等，屬於各自主題的專門狀態 ──
```

核心四個：

**`pc`** —— 程式計數器。
**`registers`** —— 暫存格陣列。`Box<[Register]>` 而非 `Vec`，因為大小在編譯期就確定了（`PreparedProgram.max_registers`），不需要動態成長的能力。
**`cursors`** —— 開啟的 cursor。`Option` 是因為 cursor id 是編譯期配置的密集索引，執行期未必全部開啟。
**`io_completions`** —— pending I/O，主迴圈第二段檢查的就是它。

還有一個欄位透露了下一篇的主題：

**`core/vdbe/mod.rs:748`**

```rust
    active_op_state: ActiveOpStateSlot,
```

這是「指令執行到一半被 I/O 打斷時，用來記住進度」的插槽。因為一條指令（例如 `Column` 讀 overflow page）可能需要多次 I/O 才能完成，每次重入都要知道上次停在哪。這是 `07b-ioresult-reentry.md` 的核心主題，第 5 篇會看到它的實際使用。

---

## 回顧：一次 step 的完整路徑

```text
Statement::step                       core/statement.rs:659
  └─ _step                            core/statement.rs:507
       ├─ 活躍語句計數（只加一次）
       ├─ prepare_context 檢查 → 必要時 reprepare
       ├─ arm timeout
       ├─ busy handler 等待檢查
       ├─ Program::step               core/vdbe/mod.rs:1564
       │    └─ normal_step            core/vdbe/mod.rs:1736
       │         loop {
       │           檢查 closed / interrupt
       │           檢查 pending I/O → 未完成就 return IO
       │           insn = insns[pc]
       │           insn.to_function()  core/vdbe/insn.rs:2019
       │           執行 op_*           core/vdbe/execute.rs
       │           match 回報 → Step 續跑 / Row / Done / IO / Busy
       │         }
       └─ SchemaUpdated 重試迴圈（上限 50，寫交易中提早放棄）
```

---

## 動手驗證

觀察 `step` 的 streaming 行為——插入多列後查詢，VM 是一列一列吐出來的，不是一次算完：

```bash
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO t VALUES (1,'a'),(2,'b'),(3,'c');
EXPLAIN SELECT name FROM t;
```

對照 EXPLAIN 輸出裡的 `Next`（p2 指回 `Column` 的位址）。每次 `ResultRow` 執行時 `normal_step` 就 return 一次；`Next` 跳回去，下次 step 再跑一輪。三列資料代表 `normal_step` 被呼叫至少四次（三次 `Row` + 一次 `Done`）。

追 source：

```bash
rg -n "fn _step|pub fn step\b|fn step_subprogram" core/statement.rs
rg -n "fn normal_step|pub enum StepResult|pub struct ProgramState" core/vdbe/mod.rs
rg -n "pub enum InsnFunctionStepResult|pub fn op_result_row" core/vdbe/execute.rs
```

---

## 自我檢查

1. `StepResult::IO` 和 `StepResult::Yield` 差在哪？為什麼 `Yield` 不存進 `io_completions`？
2. connection 關閉時，`normal_step` 為什麼要主動 rollback 寫交易？不做會怎樣？
3. checkpoint 期間的 I/O 錯誤為什麼要包成 `CheckpointFailed`？如果當成一般錯誤處理會出什麼事？
4. `op_result_row` 在 return 前遞增 PC，但回傳 `IO` 的指令不遞增。這個差別的意義是什麼？
5. 指令回報 `IO` 但 `io.finished()` 已經是 true 時，為什麼直接繼續迴圈而不 return？
6. `BusySnapshot` 的守衛條件為什麼要看 `transaction_state`？什麼情況下重試是沒用的？
7. `prepare_context` 檢查為什麼限定在 `execution_state == Init`？
8. `step_subprogram` 跳過了哪些檢查？為什麼可以跳過？
9. `ProgramState` 的 `registers` 為什麼用 `Box<[Register]>` 而不是 `Vec<Register>`？

---

下一篇 `01-source-code-learn-5-cursor-storage.md`：追一條完整的讀取路徑——`op_column` 如何透過 cursor 拿到資料、遇到 I/O 時如何交還控制權，讓「一條 SQL 的生命週期」真正閉環。
