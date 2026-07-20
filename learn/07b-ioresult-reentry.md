# 07b. IOResult、Completion、Re-entry Correctness

本章目標：專心看 Turso 最獨特的 explicit I/O 模型。讀完後你應該知道為什麼 core 裡有大量 state enum。

## 60 分鐘閱讀範圍

| 時間 | 檔案 | 只讀這些 symbol / 區塊 |
|---:|---|---|
| 8 分鐘 | `docs/agent-guides/async-io-model.md` | `IOResult`、re-entry pitfall |
| 8 分鐘 | `core/types.rs` | `IOCompletions`、`IOResult`、`return_if_io!` |
| 8 分鐘 | `core/util.rs` | `io_yield_one!`、`IOExt::block`、`IOExt::wait` |
| 10 分鐘 | `core/io/completions.rs` | `Completion`、`CompletionGroup` |
| 10 分鐘 | `core/vdbe/mod.rs` | `normal_step` 的 pending I/O handling |
| 10 分鐘 | `core/vdbe/execute.rs` | `OpColumnState` 或 `OpTransactionState` 擇一只看 state flow |
| 6 分鐘 | bug 案例與自我檢查 | 確認 re-entry 風險 |

## 心智模型

Turso core 不大量用 Rust `async/await`，而是用 explicit cooperative I/O：

```rust
pub enum IOResult<T> {
    Done(T),
    IO(IOCompletions),
}
```

呼叫者要反覆呼叫直到 `Done`：

```rust
loop {
    match f()? {
        IOResult::Done(v) => break v,
        IOResult::IO(completions) => completions.wait(io)?,
    }
}
```

`core/util.rs` 的 `IOExt::block` 和 `wait` 就是這種 driver。

## Completion

`core/io/completions.rs` 定義：

```text
Completion
CompletionGroup
Context / Waker
CompletionType
```

Completion 表示一個 read/write/sync/truncate/yield/group operation。`CompletionGroup` 可以把多個 I/O 合成一個 completion，例如 commit 時批量讀 evicted dirty pages 或批量寫 WAL frames。

## return_if_io! 和 state machine

常見 macro：

```rust
return_if_io!(some_operation());
io_yield_one!(completion);
```

`return_if_io!` 的意思是：

- 如果子操作完成，取出值繼續。
- 如果子操作需要 I/O，直接把 I/O 往上回傳。
- 如果錯誤，往上回傳錯誤。

這讓很多 storage/VM function 可以自然地把 I/O yield 傳回最外層 `Statement::step`。

## Re-entry correctness

錯誤模式：

```text
修改 state
呼叫可能 yield 的 I/O
return IO
caller 等完後重新呼叫同一函式
同一個 state 修改又做一次
```

結果可能是：

- row 跳過。
- index 重複插入。
- dirty page 重複加入。
- cursor cell index 錯亂。
- WAL frame/watermark 不一致。

所以你會看到很多 state enum：

```text
OpTransactionState
OpColumnState
OpInsertSubState
CommitState
AllocatePageState
RewindState
MoveToState
```

它們不是程式寫得複雜而已，而是 explicit async I/O 下的 correctness requirement。

## 具體 bug 案例

錯誤寫法：

```rust
fn advance_and_read(&mut self) -> Result<IOResult<Option<Row>>> {
    self.cell_idx += 1;
    let page = return_if_io!(self.pager.read_page(self.next_page));
    Ok(IOResult::Done(read_row(page, self.cell_idx)))
}
```

如果 `read_page` yield，caller 等完後會再次呼叫 `advance_and_read`。這時 `cell_idx` 又加一次，cursor 可能跳過一列。

正確方向：

```rust
enum AdvanceState {
    Start,
    WaitingForPage { target_page: i64, cell_idx_after_advance: usize },
}

fn advance_and_read(&mut self) -> Result<IOResult<Option<Row>>> {
    loop {
        match self.state {
            AdvanceState::Start => {
                let next_idx = self.cell_idx + 1;
                self.state = AdvanceState::WaitingForPage {
                    target_page: self.next_page,
                    cell_idx_after_advance: next_idx,
                };
            }
            AdvanceState::WaitingForPage { target_page, cell_idx_after_advance } => {
                let page = return_if_io!(self.pager.read_page(target_page));
                self.cell_idx = cell_idx_after_advance;
                self.state = AdvanceState::Start;
                return Ok(IOResult::Done(read_row(page, self.cell_idx)));
            }
        }
    }
}
```

重點不是這段 pseudo-code 的 API，而是原則：yield 前把「已決定但未提交的進度」放進 state enum；真正會造成外部可見效果的 mutation，要在 yield 完成後只做一次。

## normal_step 如何處理 pending I/O

`core/vdbe/mod.rs` 的 `Program::normal_step` 會：

1. 如果 `state.io_completions` 尚未完成，回 `StepResult::IO`。
2. 如果 completion failed，abort statement/transaction。
3. 如果 completion 完成，清掉 pending I/O。
4. 重新執行同一個 PC 的 opcode，讓 opcode 根據自己的 state 繼續。

這表示 VM loop 只知道「等待中的 I/O 完成了沒」；具體要從哪個 sub-step 繼續，是 opcode/pager/btree 自己的 state machine 負責。

## IO backend

`core/io/mod.rs` 定義兩個核心 trait：

```text
File:
  lock_file, unlock_file, pread, pwrite, pwritev, sync, size, truncate

IO:
  open_file, remove_file, step, generate_random_number, clock, backend-specific hooks
```

實作包括：

```text
memory.rs
unix.rs
windows.rs
io_uring.rs
vfs.rs
memory_yield.rs
```

`memory_yield` 這類 backend 對測試很有用，因為它可以強迫更多 yield point，暴露 re-entry bug。

## 練習

追 source：

```bash
rg -n "pub enum IOResult|pub enum IOCompletions|macro_rules! return_if_io" core/types.rs
rg -n "macro_rules! io_yield_one|pub trait IOExt" core/util.rs
rg -n "pub struct Completion|pub struct CompletionGroup" core/io/completions.rs
rg -n "state.io_completions|StepResult::IO|StepResult::Yield" core/vdbe/mod.rs
rg -n "pub enum OpColumnState|pub enum OpTransactionState" core/vdbe/execute.rs
```

## 自我檢查

1. `IOResult::IO` 和 `StepResult::IO` 分別在哪一層？
2. 為什麼 yield 後通常不能直接重跑普通 imperative code？
3. state enum 應該保存「已完成的 mutation」還是「下一次要恢復的進度」？
4. `CompletionGroup` 解決什麼問題？
5. 為什麼 testing backend 要故意製造更多 yield point？

