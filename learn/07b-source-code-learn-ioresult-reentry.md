# 07b. 源碼精讀：IOResult、Completion、重入正確性

本篇對應 `07b-ioresult-reentry.md`，講 Turso 最獨特的設計：**core 不用 `async/await`，而是用明確的 `IOResult` 讓呼叫者決定何時等待**。

這是讀懂 storage 與 VM 程式碼的分水嶺。前面幾篇一直出現的 `return_if_io!`、狀態機欄位、`loop { match state }`，在這裡會被統一解釋。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 60–75 分鐘（約 14k 字，其中 40% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/types.rs           IOResult / IOCompletions / return_if_io!
core/util.rs            io_yield_one! / IOExt::block / IOExt::wait
core/io/completions.rs  Completion / CompletionGroup
core/vdbe/execute.rs    execute.rs 版本的 return_if_io!（跨層轉換）
```

---

## 為什麼不用 async/await

Rust 的 `async fn` 由編譯器自動產生狀態機，保存區域變數，看起來正是這個問題的解法。Turso 沒有用，理由有幾個：

**一、需要同時服務同步與非同步呼叫者。** 嵌入式資料庫的使用者可能完全不用 async runtime（C binding、CLI），也可能在 tokio 裡跑（Rust binding）。`async fn` 會強迫所有呼叫者都進入 async 世界。

**二、需要精確控制 yield 點。** 資料庫要知道「這裡讓出安全嗎」——中途讓出可能讓其他 connection 看到不一致的中間狀態。`async` 的 `.await` 點由編譯器決定何時真正讓出，控制力較弱。

**三、狀態機的大小與配置可見。** `async fn` 產生的 future 大小不透明，巢狀深了可能意外變得很大。手寫狀態機能精確控制。

代價是：**開發者必須自己保證重入安全**。這就是本篇的主題。

---

## IOResult：只有兩個變體

**`core/types.rs:3461-3464`** — 完整貼出：

```rust
pub enum IOResult<T> {
    Done(T),
    IO(IOCompletions),
}
```

**`core/types.rs:3466-3486`** — 完整貼出方法：

```rust
impl<T> IOResult<T> {
    #[inline]
    pub fn is_io(&self) -> bool {
        matches!(self, IOResult::IO(..))
    }

    #[inline]
    pub fn io(self) -> Option<IOCompletions> {
        match self {
            IOResult::Done(_) => None,
            IOResult::IO(io) => Some(io),
        }
    }

    #[inline]
    pub fn map<U>(self, func: impl FnOnce(T) -> U) -> IOResult<U> {
        match self {
            IOResult::Done(t) => IOResult::Done(func(t)),
            IOResult::IO(io) => IOResult::IO(io),
        }
    }
}
```

`map` 讓你轉換成功值而不影響 I/O 分支，形狀和 `Option::map` / `Result::map` 一致。`07a-source-code-learn-wal-transactions.md` 看過的用法：

```rust
                return Ok(self.allocate_page1()?.map(|_| ()));
```

把 `IOResult<Page>` 轉成 `IOResult<()>`，丟掉不需要的值但保留 I/O 語義。

**`core/types.rs:3390-3393`** — `IOCompletions`：

```rust
#[derive(Debug)]
#[must_use]
pub struct IOCompletions(pub Completion);
```

`IOCompletions` 現在是包住一個 `Completion` 的 tuple struct，不是 enum。多個 I/O 先由 `CompletionGroup`（見下面）合成一個 group completion，再放進這個 wrapper；呼叫者可透過 wrapper 的 `wait`、`wait_async`、`finished`、`abort` 與 `get_error` 操作它。

---

## return_if_io!：往上冒泡的機制

**`core/types.rs:3491-3502`** — 完整貼出：

```rust
macro_rules! return_if_io {
    ($expr:expr) => {
        match $expr {
            Ok(IOResult::Done(v)) => v,
            Ok(IOResult::IO(io)) => return Ok(IOResult::IO(io)),
            Err(err) => {
                branches::mark_unlikely();
                return Err(err);
            }
        }
    };
}
```

12 行，是整個模型的樞紐。三個分支：

- **`Done(v)`** → 取值繼續。
- **`IO(io)`** → **立刻 return**，把 completion 原封不動往上傳。
- **`Err`** → 往上傳錯誤。

關鍵是中間那個 `return`：它讓「需要等 I/O」自動沿著呼叫堆疊冒泡，一路傳到最外層。

### 跨層時的型別轉換

`04-source-code-learn-1-insn-dispatch.md` 提過，`execute.rs` 有自己的版本：

**`core/vdbe/execute.rs:181-188`** — 節錄：

```rust
macro_rules! return_if_io {
    ($expr:expr) => {
        match $expr {
            Ok(IOResult::Done(v)) => v,
            Ok(IOResult::IO(io)) => return Ok(InsnFunctionStepResult::IO(io)),
            Err(err) => {
                mark_unlikely();
```

差別只在回傳型別：storage 層包成 `IOResult::IO`，VM 層包成 `InsnFunctionStepResult::IO`。

**同名巨集在不同模組各一份，讓 I/O 在跨層時自動換上該層的型別。** 呼叫端的寫法完全一樣，不需要手動轉換。

### io_yield_one!：主動讓出

**`core/util.rs:24-28`** — 完整貼出：

```rust
macro_rules! io_yield_one {
    ($c:expr) => {
        return Ok(IOResult::IO(IOCompletions($c)));
    };
}
```

當你**已經有一個 completion** 而不是「呼叫了可能 yield 的函式」時用它。`06b-source-code-learn-btree-cursor-pager.md` 的 `rewind` 就是例子：

```rust
                RewindState::Start => {
                    let c = return_if_io!(self.move_to_root_nonblock());
                    self.rewind_state = RewindState::NextRecord;
                    if let Some(c) = c {
                        io_yield_one!(c);
                    }
                }
```

`move_to_root_nonblock` 回傳一個「可選的 completion」——如果 root page 已在 cache 就是 `None`（不需等待），否則是 `Some(completion)`。有 completion 才 yield。

---

## Completion：一次 I/O 的把手

**`core/io/completions.rs:26-29`** — 完整貼出：

```rust
pub struct Completion {
    /// Optional completion state. If None, it means we are Yield in order to not allocate anything
    pub(super) inner: Option<Arc<CompletionInner>>,
}
```

註解點出一個最佳化：`inner` 是 `Option`，`None` 代表「這是一個純粹的 yield，不是真的 I/O」。

`01-source-code-learn-4-step-vm.md` 看過 VM 主迴圈區分 `StepResult::IO` 和 `StepResult::Yield`：

```rust
                    let is_yield = io.is_explicit_yield();
                    if is_yield {
                        return Ok(StepResult::Yield);
                    }
```

純 yield 用 `inner: None` 表示，**完全不配置記憶體**。因為它沒有要等的東西，只是想把控制權交回去讓別人跑。

### Completion 也是 Future

**`core/io/completions.rs:31-44`** — 完整貼出：

```rust
impl Future for Completion {
    type Output = Result<(), crate::LimboError>;

    fn poll(self: std::pin::Pin<&mut Self>, cx: &mut std::task::Context<'_>) -> Poll<Self::Output> {
        self.set_waker(cx.waker());
        if self.finished() {
            self.wake();
            let res = self
                .get_error()
                .map_or(Ok(()), |err| Err(crate::LimboError::CompletionError(err)));
            return Poll::Ready(res);
        }
        Poll::Pending
    }
```

**這是同步模型接上 async 世界的橋。**

core 內部不用 `.await`，但 `Completion` 實作了 `Future`，所以 binding 層可以直接 `.await` 它，接上 tokio 之類的 runtime。

`set_waker(cx.waker())` 註冊喚醒器——I/O 完成時會呼叫它，讓 async task 被排程。這就是 `01-source-code-learn-4-step-vm.md` 看到的 `step_with_waker` 那條路徑最終的去處。

**一份 core 程式碼，兩種消費方式**：同步呼叫者用 `IOExt::block` 阻塞等待，async 呼叫者用 `.await`。

---

## CompletionGroup：批次 I/O

**`core/io/completions.rs:126-144`** — 完整貼出：

```rust
pub struct CompletionGroup {
    completions: Vec<Completion>,
    callback: Box<dyn Fn(Result<i32, CompletionError>) + Send + Sync>,
}

impl CompletionGroup {
    pub fn new<F>(callback: F) -> Self
    where
        F: Fn(Result<i32, CompletionError>) + Send + Sync + 'static,
    {
        Self {
            completions: Vec::new(),
            callback: Box::new(callback),
        }
    }

    pub fn add(&mut self, completion: &Completion) {
        self.completions.push(completion.clone());
    }
```

把多個 I/O 合成一個。等到**全部**完成才觸發 callback，於是整組可以當成單一 `Completion` 回傳。

**典型用途是 commit**：把幾十個 dirty page 一次寫進 WAL。如果一個一個等，就要 yield 幾十次、進出 VM 迴圈幾十次。合成一組後只 yield 一次。

在 io_uring 這類支援批次提交的後端上，這還能讓多個寫入一次進 kernel。

**`core/io/completions.rs:146-148`** — 註解揭露一個細節：

```rust
    /// The children added so far. Used by error paths that need to
    /// wait on the kernel side via `IO::drain_completions` after
    /// cancelling the group.
```

**取消一組 I/O 不能只是丟掉 handle。** kernel 那邊的操作可能還在進行中，它會寫入我們的 buffer。必須等它們真正結束（`drain_completions`）才能安全釋放記憶體。

這是 async I/O 的經典陷阱：**取消不等於立即停止**。

---

## 呼叫者怎麼驅動

**`core/util.rs:82-98`** — 完整貼出：

```rust
pub trait IOExt {
    fn block<T>(&self, f: impl FnMut() -> Result<IOResult<T>>) -> Result<T>;
    fn wait<T, F>(&self, f: F) -> impl Future<Output = Result<T>> + Send
    where
        F: FnMut() -> Result<IOResult<T>> + Send,
        T: Send;
}

impl<I: ?Sized + IO> IOExt for I {
    fn block<T>(&self, mut f: impl FnMut() -> Result<IOResult<T>>) -> Result<T> {
        Ok(loop {
            match f()? {
                IOResult::Done(v) => break v,
                IOResult::IO(io) => io.wait(self)?,
            }
        })
    }
```

**`core/util.rs:100-108`** — async 版本：

```rust
    async fn wait<T, F>(&self, mut f: F) -> Result<T>
    where
        F: FnMut() -> Result<IOResult<T>> + Send,
        T: Send,
    {
        Ok(loop {
            match f()? {
                IOResult::Done(v) => break v,
```

兩個版本**結構完全相同**：`loop` 呼叫 `f`，`Done` 就跳出，`IO` 就等待然後**再呼叫一次 `f`**。

注意 `f: FnMut()` —— 它會被呼叫多次。**這就是「重入」的字面意義**：同一個閉包被反覆執行，直到它回報完成。

`block` 阻塞等待，`wait` 用 `.await`。同一個 `f` 兩種驅動方式都能用。

---

## 重入正確性：本篇的核心

現在問題來了：`f` 被呼叫多次，那它每次都從頭開始執行。**如果它在 yield 之前已經改變了某些狀態，重跑就會重複那個改變。**

### 錯誤示範

```rust
fn advance_and_read(&mut self) -> Result<IOResult<Option<Row>>> {
    self.cell_idx += 1;                                          // ← 危險
    let page = return_if_io!(self.pager.read_page(self.next_page));
    Ok(IOResult::Done(read_row(page, self.cell_idx)))
}
```

如果 `read_page` 需要 I/O：

1. 第一次呼叫：`cell_idx` 從 5 變成 6，然後 return `IO`。
2. 呼叫者等待 I/O 完成。
3. 第二次呼叫：`cell_idx` 從 6 變成 **7**，這次 page 在 cache 裡，讀取成功。

**結果跳過了第 6 列。** 而且這個 bug 只在 page 剛好不在 cache 時出現——本機測試（資料小、全在 cache）可能永遠不會觸發，上線後在大資料集上才爆。

同類的 bug 有：index 重複插入、dirty page 重複登記、WAL frame 編號錯亂、cursor 位置錯亂。

### 解法一：讓操作可安全重做

如果 yield 前**沒有任何外部可見的 mutation**，重跑就是安全的，不需要狀態機。

`01-source-code-learn-5-cursor-storage.md` 看過 `op_column` 的快速路徑正是這樣：

**`core/vdbe/execute.rs:1777-1787`**

```rust
    // Fast path: no deferred seek pending and no suspended state machine. The
    // column fetch either completes or yields IO with nothing persisted, so the
    // op-state slot (enum write + drop on clear) is bypassed entirely. On IO
    // resume the slot is still idle and this path re-executes.
    if state.active_op_state.is_idle() && state.deferred_seeks[*cursor_id].is_none() {
        let result = op_column_fetch(program, state, *cursor_id, *column, *dest, default)?;
        if matches!(result, InsnFunctionStepResult::Step) {
            state.pc += 1;
        }
        return Ok(result);
    }
```

註解裡的關鍵詞是 **"nothing persisted"**。因為沒有留下副作用，重入時整段重跑完全正確，連狀態機的開銷（enum 寫入 + 清除時的 drop）都省了。

**這是首選解法**——沒有狀態就沒有狀態同步的 bug。

### 解法二：狀態機

當操作必然有中間副作用時，用 enum 記錄進度。`06b-source-code-learn-btree-cursor-pager.md` 的 `rewind` 是標準樣板：

**`core/storage/btree.rs:7068-7084`** — 重貼一次，這次專注在重入語義：

```rust
        loop {
            match self.rewind_state {
                RewindState::Start => {
                    let c = return_if_io!(self.move_to_root_nonblock());
                    self.rewind_state = RewindState::NextRecord;    // ①
                    if let Some(c) = c {
                        io_yield_one!(c);                            // ②
                    }
                }
                RewindState::NextRecord => {
                    return_if_io!(self.get_next_record());
                    self.rewind_state = RewindState::Start;          // ③
                    self.read_overflow_state = None;
                    return Ok(IOResult::Done(()));
                }
            }
        }
```

三個編號處是全部的重點：

**① 狀態轉換在 yield 之前。** 先記下「我已經完成 move_to_root」，才 yield。重入時會直接進 `NextRecord` 分支，不會重做。

**② yield。** 此時狀態已經是正確的。

**③ 完成時重置。** 讓下一次 `rewind` 呼叫能正常從 `Start` 開始。

**順序反過來會怎樣？**

```rust
                    if let Some(c) = c {
                        io_yield_one!(c);              // 先 yield
                    }
                    self.rewind_state = RewindState::NextRecord;   // 永遠執行不到
```

`io_yield_one!` 展開成 `return`，所以後面那行**永遠不會執行**。重入時狀態還是 `Start`，於是又跑一次 `move_to_root`——無限迴圈。

### 核心原則

> **狀態要記錄「下一次該從哪裡繼續」，而不是「已經做了什麼」。**

而且真正產生外部可見效果的 mutation，要放在**確定不會再 yield 之後**，只做一次。

### 為什麼會有這麼多狀態機欄位

回想 `06b` 看到的 `BTreeCursor` 六個狀態欄位：

```rust
    state: CursorState,
    balance_state: BalanceState,
    overflow_state: OverflowState,
    seek_state: CursorSeekState,
    read_overflow_state: Option<ReadPayloadOverflow>,
    context: Option<CursorContext>,
```

以及 `Pager` 的：

```rust
    commit_info: RwLock<CommitInfo>,
    checkpoint_state: RwLock<CheckpointState>,
    allocate_page_state: RwLock<AllocatePageState>,
    allocate_page1_state: RwLock<AllocatePage1State>,
    free_page_state: RwLock<FreePageState>,
```

**每一個都對應一個可能被 I/O 中斷的多步驟操作。**

而它們必須**分開**的理由，`06b` 引過的註解說得最清楚：

> Maintained separately from cursor state since any method could require freeing overflow pages

釋放 overflow page 可能發生在任何操作**中間**。共用一個插槽的話，內層操作的狀態會覆寫外層的——**巢狀的可中斷操作需要巢狀的狀態儲存**。

用 `async fn` 的話這是自動的（每層 future 有自己的狀態）。手寫就必須自己攤開成獨立欄位。**這是「不用 async」付出的主要代價。**

---

## 完整的 I/O 冒泡路徑

以 `SELECT name FROM t` 讀到一個不在 cache 的 page 為例：

```text
Pager::read_page                     發現 page 不在 cache，發出磁碟讀取
  → 回傳 IOResult::IO(completion)
    ↑ return_if_io!（core/types.rs 版本）
BTreeCursor::record                  core/storage/btree.rs:6385
  → 回傳 IOResult::IO
    ↑ return_if_io!
op_column_fetch                      core/vdbe/execute.rs:1866
  → 回傳 InsnFunctionStepResult::IO   ← 型別在這層轉換（execute.rs 版本的巨集）
    ↑
op_column                            core/vdbe/execute.rs:1762
  → 回傳 IO，PC 不遞增
    ↑
normal_step                          core/vdbe/mod.rs:1736
  → state.io_completions = Some(io)
  → 回傳 StepResult::IO
    ↑
Statement::step                      core/statement.rs:659
  → 回傳 StepResult::IO
    ↑
呼叫者（IOExt::block 或 run_collect_rows）
  → io.wait() / io.step()  驅動 I/O
  → 完成後再次 step
    ↓
normal_step 檢查 io_completions 已完成 → 清掉 → PC 沒動 → 重新執行 op_column
    ↓
這次 record() 從 cache 拿到 page → IOResult::Done
```

**七層深的呼叫堆疊，中間沒有任何 `async fn`，也沒有 runtime。** 每一層只是 return，狀態由各層自己的欄位保存。

---

## 測試重入正確性

重入 bug 的可怕之處是**只在特定的 I/O 時機出現**。正常測試（小資料、全在 cache）幾乎不會觸發。

Turso 的對策是 `core/io/memory_yield.rs` 這個測試用 I/O 後端：它**故意讓每次操作都 yield**，強制暴露所有重入路徑。

搭配 `testing/simulator/` 的確定性模擬，可以重現特定的 I/O 交錯順序。這也是 `.claude/skills/yield-injections/SKILL.md` 涵蓋的機制——在指定的 yield point 注入中斷，驗證重入後的狀態仍然正確。

**如果你要修改 storage 或 VM 的程式碼，這類測試是必須跑的**，因為一般測試抓不到這類 bug。

---

## 動手驗證

觸發真實的 I/O yield（資料量要大到超過 page cache）：

```bash
cd /tmp && rm -f big.db*
/Users/stanhsu/projects/turso/target/debug/tursodb big.db "
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO t SELECT value, printf('%.*c', 200, 'x') FROM generate_series(1, 20000);
"
ls -la big.db
```

然後全表掃描，這會強制從磁碟讀入大量 page：

```bash
/Users/stanhsu/projects/turso/target/debug/tursodb big.db "SELECT count(*) FROM t;"
```

過程中 `op_column` / `op_next` 會多次回報 `IO`，由 CLI 的驅動迴圈推進。

看 `IOExt::block` 的實際使用：

```bash
rg -n "\.block\(" core/ | head -20
```

追 source：

```bash
rg -n "pub enum IOResult|pub struct IOCompletions|macro_rules! return_if_io" core/types.rs
rg -n "macro_rules! io_yield_one|pub trait IOExt" core/util.rs
rg -n "pub struct Completion|pub struct CompletionGroup" core/io/completions.rs
rg -n "macro_rules! return_if_io" core/vdbe/execute.rs
```

---

## 自我檢查

1. Turso 為什麼不用 `async fn` 寫 core？列出三個理由。
2. `return_if_io!` 的三個分支各做什麼？中間那個 `return` 造成什麼效果？
3. 為什麼 `core/types.rs` 和 `core/vdbe/execute.rs` 各有一份同名的 `return_if_io!`？
4. `Completion.inner` 為什麼是 `Option`？`None` 代表什麼？
5. `Completion` 實作 `Future` 有什麼用？core 內部會 `.await` 它嗎？
6. `CompletionGroup` 解決什麼問題？commit 時為什麼特別需要它？
7. 取消一組 I/O 為什麼不能只是丟掉 handle？
8. `IOExt::block` 的參數是 `FnMut` 而不是 `FnOnce`。這暗示了什麼？
9. 寫出「先 `cell_idx += 1` 再 `return_if_io!(read_page)`」會產生什麼 bug？為什麼本機測試可能抓不到？
10. 重入安全的兩種解法是什麼？各在什麼情況適用？
11. `rewind` 為什麼要在 `io_yield_one!` **之前**更新 `rewind_state`？順序反了會發生什麼？
12. 「狀態要記錄下一次從哪繼續，而不是已經做了什麼」——這句話用 `rewind` 舉例說明。
13. `BTreeCursor` 為什麼需要六個獨立的狀態機欄位，不能共用一個？
14. 為什麼一般測試抓不到重入 bug？Turso 用什麼機制測試它們？

---

下一篇 `08-source-code-learn-extensions-sync-testing.md`：extension API、虛擬表、VFS、sync engine、以及測試架構。
