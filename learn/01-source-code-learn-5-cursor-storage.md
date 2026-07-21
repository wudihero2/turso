# 01-5. 源碼精讀：從 opcode 到 storage，讓生命週期閉環

本篇對應 `01-sql-lifecycle.md` 的**第八層與第九層**。前四篇走完了「SQL 文字 → AST → bytecode → VM 迴圈」，但還缺最後一段：指令真正碰到資料時發生什麼事。

**本篇的範圍刻意收窄。** B-tree 的樹狀走訪、page 格式、WAL 協定各有專章（`06a`、`06b`、`07a`、`07b`）。這裡只追**一條完整的讀取路徑**——`Column` 指令如何拿到一個欄位值——目的是讓「一條 SQL 的生命週期」真正閉環，而不是在這裡教 B-tree。

> 行號以撰寫當下的 checkout 為準；symbol 名稱較穩定。找不到時用 `rg -n "symbol_name" <file>`。

> **閱讀時間**：約 75–90 分鐘（約 19k 字，其中 46% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/vdbe/execute.rs   op_open_read ── 開 cursor
core/vdbe/execute.rs   op_column → op_column_fetch ── 取欄位
  └─> core/storage/btree.rs   CursorTrait::record ── 從 page 拿到 record
        └─> core/types.rs     IOResult / return_if_io! ── I/O 如何往上冒泡
              └─> core/vdbe/mod.rs   normal_step ── 回到第 4 篇的主迴圈
```

---

## 先看目標：一條 SELECT 的指令序列

用第 4 篇的 EXPLAIN 輸出當地圖：

```text
addr  opcode             p1    p2    p3    p4             p5  comment
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

本篇聚焦 addr 1（`OpenRead`）和 addr 3（`Column`）。這兩條指令是 VM 與 storage 的全部接觸面。

注意 `OpenRead` 的 comment：`table=t, root=2`。**編譯器只把表名翻成 root page 編號**，storage 層完全不知道「t」這張表叫什麼。這是第 3 篇提過的分層：SQL 名稱在編譯期就解析掉了。

---

## OpenRead：把 root page 變成 cursor

**`core/vdbe/execute.rs:1148-1166`** — 節錄開頭：

```rust
pub fn op_open_read(
    program: &Program,
    state: &mut ProgramState,
    insn: &Insn,
    _pager: &Arc<Pager>,
) -> Result<InsnFunctionStepResult> {
    load_insn!(
        OpenRead {
            cursor_id,
            root_page,
            db,
        },
        insn
    );

    invalidate_deferred_seeks_for_cursor(state, *cursor_id);

    let pager = program.get_pager_from_database_index(db)?;
    let mv_store = program.connection.mv_store_for_db(*db);
```

```rust
    // ── 省略（core/vdbe/execute.rs:1168-1250 附近）：依 cursor_ref 的 CursorType
    //    分派出 IndexMethod cursor、虛擬表 cursor、MVCC cursor、
    //    以及一般 BTreeCursor 的建立分支 ──
```

三個重點：

**指令參數只有 `cursor_id`、`root_page`、`db`。** 沒有表名、沒有欄位資訊。cursor_id 是編譯期配置的密集索引（第 3 篇提過 `alloc_cursor_id`），`root_page` 來自 schema 裡 `BTreeTable.root_page`，`db` 區分 main / temp / attached。

**`get_pager_from_database_index(db)`** —— 每個 attached database 有自己的 pager。這也是為什麼第 3 篇的 `epilogue` 會對每個資料庫各發一條 `Transaction`。

**cursor 型別的分派。** `program.cursor_ref[*cursor_id]` 存的 `CursorType` 是編譯期決定的，執行期據此建立對應的 cursor 實作（B-tree、虛擬表、MVCC、index method）。**VM 之後只透過 trait 操作 cursor，不在乎底下是哪一種。**

執行完後，`state.cursors[cursor_id]` 有了一個可用的 cursor。

---

## Column：VM 與 storage 的真正交會點

`Column` 看起來只是「取第 N 欄」，但它是整個 engine 裡最能體現複雜度的指令之一。

**`core/vdbe/execute.rs:1762-1787`** — 完整貼出快速路徑：

```rust
pub fn op_column(
    program: &Program,
    state: &mut ProgramState,
    insn: &Insn,
    _pager: &Arc<Pager>,
) -> Result<InsnFunctionStepResult> {
    load_insn!(
        Column {
            cursor_id,
            column,
            dest,
            default,
        },
        insn
    );
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

這段註解是本篇最重要的一段文字，值得逐句拆解：

> Fast path: no deferred seek pending and no suspended state machine. The column fetch either completes or yields IO with **nothing persisted**, so the op-state slot is bypassed entirely. On IO resume the slot is still idle and this path re-executes.

翻成白話：

當沒有待處理的 deferred seek、也沒有暫停中的狀態機時，`op_column_fetch` 有一個關鍵性質——它要嘛完成，要嘛回報 I/O 但**沒有留下任何半完成的副作用**。既然沒有副作用，重入時直接從頭重跑就是安全的，不需要記錄任何狀態。

**這就是第 4 篇提過的 re-entry correctness 的第一種解法：讓操作變成可安全重做的（idempotent）。** 如果一個操作在 yield 前沒有改動任何外部可見狀態，重入時整段重跑完全沒問題，也就不需要狀態機。

注意 PC 的處理：

```rust
        if matches!(result, InsnFunctionStepResult::Step) {
            state.pc += 1;
        }
        return Ok(result);
```

**只有 `Step`（完成）才遞增 PC。** 回報 `IO` 時 PC 不動，下次 step 會重新進入 `op_column`，再次走這條快速路徑重跑一次。這正是第 4 篇說的「PC 有沒有前進就是判斷指令做完沒的方式」。

### 慢速路徑：需要狀態機的情況

**`core/vdbe/execute.rs:1788-1799`** — 節錄：

```rust
    'outer: loop {
        match *state.active_op_state.column() {
            OpColumnState::Start => {
                if let Some(deferred) = state.deferred_seeks[*cursor_id].take() {
                    *state.active_op_state.column() = OpColumnState::Rowid {
                        index_cursor_id: deferred.index_cursor_id,
                        table_cursor_id: deferred.table_cursor_id,
                    };
                } else {
                    *state.active_op_state.column() = OpColumnState::GetColumn;
                }
            }
```

```rust
            // ── 省略（core/vdbe/execute.rs:1800-2004）：OpColumnState::Rowid 分支
            //    （先用 index cursor 的 rowid 去 seek table cursor）與
            //    OpColumnState::GetColumn 分支的完整狀態轉移 ──
```

什麼時候需要狀態機？當有 **deferred seek** 時。

情境是這樣：查詢用 secondary index 找到了符合條件的項目，但要取的欄位不在 index 裡，必須回主表拿。這個「回表」動作可以延後——如果最後根本不需要那個欄位（例如被其他條件過濾掉了），就省下一次 seek。所以編譯器會標記「deferred seek」，等到真的有人要讀欄位時才執行。

於是 `Column` 變成兩步：**先 seek 主表，再讀欄位**。兩步之間可能發生 I/O。如果 seek 完成後才 yield，重入時不能再 seek 一次（游標已經在對的位置了，重做會出錯或浪費）。所以必須用 `OpColumnState` 記住「我已經走到哪一步」。

**這就是 re-entry correctness 的第二種解法：用狀態機記錄進度。** 兩種解法的選擇原則很清楚：

| 情況 | 解法 |
|---|---|
| yield 前沒有任何外部可見的 mutation | 直接重跑（快速路徑） |
| yield 前已經改變了狀態（游標位置、寫入等） | 狀態機記錄進度 |

`07b-ioresult-reentry.md` 專門講這個主題，那裡有更完整的錯誤示範與正確寫法對照。

---

## op_column_fetch：真正去拿資料

**`core/vdbe/execute.rs:1866-1913`** — 完整貼出主要路徑：

```rust
fn op_column_fetch(
    program: &Program,
    state: &mut ProgramState,
    cursor_id: usize,
    column: usize,
    dest: usize,
    default: &Option<Value>,
) -> Result<InsnFunctionStepResult> {
    // First check if this is a MaterializedViewCursor
    {
        let cursor = state.get_cursor(cursor_id);
        if let Cursor::MaterializedView(mv_cursor) = cursor {
            // Handle materialized view column access
            let value = return_if_io!(mv_cursor.column(column));
            state.registers[dest].set_value(value);
            return Ok(InsnFunctionStepResult::Step);
        }
        // Fall back to normal handling
    }

    let (_, cursor_type) = program
        .cursor_ref
        .get(cursor_id)
        .expect("cursor_id should exist in cursor_ref");
    match cursor_type {
        CursorType::BTreeTable(_)
        | CursorType::BTreeIndex(_)
        | CursorType::MaterializedView(_, _) => {
            {
                let cursor_ref =
                    must_be_btree_cursor!(cursor_id, program.cursor_ref, state, "Column");
                let cursor = cursor_ref.as_btree_mut();

                if cursor.get_null_flag() {
                    tracing::trace!("op_column(null_flag)");
                    state.registers[dest].set_null();
                    return Ok(InsnFunctionStepResult::Step);
                }

                let record_result = return_if_io!(cursor.record());
                let Some(record) = record_result else {
                    // Cursor is not positioned on a valid row (e.g., empty table).
                    // Return NULL, not the column's default value.
                    // DEFAULT handling below is for when record exists
                    // but has fewer columns than expected.
                    state.registers[dest].set_null();
                    return Ok(InsnFunctionStepResult::Step);
                };

                let mut payload_iterator = record.iter()?;
```

**`core/vdbe/execute.rs:1917-1926`** — 繼續：

```rust
                // Parse the header for serial types incrementally until we have the target column
                // Use nth_into_register to write directly to the register without
                // creating intermediate ValueRef allocations

                match payload_iterator.nth_into_register(column, &mut state.registers[dest]) {
                    Some(result) => {
                        result?;
                        return Ok(InsnFunctionStepResult::Step);
                    }
                    None => {
                        // ── 省略：record 欄位數不足時套用 DEFAULT 值（ALTER TABLE ADD COLUMN 的情況）──
```

四個值得注意的地方：

**一、`return_if_io!(cursor.record())`** —— 這一行就是 I/O 往上冒泡的機制，下一節詳談。

**二、`record_result` 是 `Option`。** 游標可能沒有停在有效的列上（空表、或已走到尾端）。這時回 NULL。註解特別澄清：**這種情況回 NULL，不是回欄位的 DEFAULT 值**。DEFAULT 是給「record 存在但欄位數不足」用的。

這個區分很細但很重要。什麼時候 record 欄位數會不足？`ALTER TABLE ADD COLUMN` 之後——舊的資料列是用舊 schema 寫的，實體上就是少幾個欄位。讀到這種舊列時，缺的欄位要補上 DEFAULT 值，而不是 NULL（除非 DEFAULT 就是 NULL）。這是 SQLite 相容性的細節，也是為什麼 `Column` 指令需要帶 `default` 參數。

**三、`nth_into_register`** —— 註解說明了兩個最佳化：
- **增量解析 header**：record 的 header 記錄每個欄位的 serial type。要取第 5 欄，只需解析到第 5 個 serial type 就好，不必解析整個 header。
- **直接寫入 register**：不建立中間的 `ValueRef` 配置。

在一個掃描百萬列的查詢裡，每列省下一次配置就是百萬次。這種地方的最佳化是有意義的。

**四、`get_null_flag()`** —— cursor 可能處於「NULL row」狀態，這是 OUTER JOIN 沒配到對應列時的表示法。此時所有欄位都回 NULL。

---

## return_if_io!：I/O 如何往上冒泡

現在看第 4 篇一直提到、卻還沒展開的機制。

**`core/types.rs:3265-3268`** — 完整貼出：

```rust
pub enum IOResult<T> {
    Done(T),
    IO(IOCompletions),
}
```

只有兩個變體：完成了（帶值），或者需要等 I/O（帶 completion 把手）。

**`core/types.rs:3295-3306`** — 完整貼出：

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

12 行的巨集，是整個 Turso I/O 模型的樞紐。三種情況：

- **`Done(v)`** → 取出值 `v`，繼續往下執行。
- **`IO(io)`** → **立刻從當前函式 return**，把 completion 原封不動往上傳。
- **`Err`** → 往上傳錯誤（`mark_unlikely()` 是給分支預測的提示，錯誤路徑很少走）。

關鍵在中間那行：`return Ok(IOResult::IO(io))`。它讓「需要等 I/O」這件事**自動沿著呼叫堆疊往上冒泡**，一路傳到最外層。

用本篇的路徑舉例：

```text
BTreeCursor::record()  發現需要讀一個還不在 cache 的 page
  → 回傳 IOResult::IO(completion)
    ↓ return_if_io! 攔到，立刻 return
op_column_fetch  回傳 IO
    ↓
op_column  回傳 InsnFunctionStepResult::IO(completion)
    ↓
normal_step  存進 state.io_completions，回傳 StepResult::IO
    ↓
Statement::step  回傳 StepResult::IO
    ↓
呼叫者（例如 run_collect_rows）  執行 io.step() 推進 I/O
```

I/O 完成後，呼叫者再次 `step()`：`normal_step` 檢查 `io_completions` 發現完成了，清掉它，然後**因為 PC 沒動**，重新執行 `op_column`，這次 `cursor.record()` 能從 cache 拿到 page，順利回傳 `Done`。

**這就是「明確 I/O」相對於 `async/await` 的差別**：`async fn` 會由編譯器自動產生狀態機來保存區域變數；Turso 選擇讓函式直接 return，由呼叫者重新進入。代價是開發者必須自己確保重入安全（前面講的兩種解法），好處是完全掌控何時讓出、沒有隱藏的狀態機配置、而且同一份程式碼能同時服務同步與 async 呼叫者。

---

## cursor.record()：storage 層的入口

**`core/storage/btree.rs:6385-6400`** — 完整貼出前半：

```rust
    fn record(&mut self) -> Result<IOResult<Option<&ImmutableRecord>>> {
        // Mirrors sqlite3BtreeRestoreCursorPosition called at btree read
        // entry points (btree.c:5315, etc).
        if self.needs_restore() {
            return_if_io!(self.restore_context());
        }
        if !self.has_record() {
            return Ok(IOResult::Done(None));
        }
        let invalidated = self
            .reusable_immutable_record
            .as_ref()
            .is_none_or(|record| record.is_invalidated());
        if !invalidated {
            return Ok(IOResult::Done(self.reusable_immutable_record.as_ref()));
        }
```

**`core/storage/btree.rs:6401-6412`** — 繼續：

```rust
        let page = self.stack.top_ref();
        let contents = page.get_contents();
        let cell_idx = self.stack.current_cell_index();
        let cell = contents.cell_get(cell_idx as usize, self.usable_space())?;
        let (payload, payload_size, first_overflow_page) = match cell {
            BTreeCell::TableLeafCell(TableLeafCell {
                payload,
                payload_size,
                first_overflow_page,
                // ── 省略：其餘 cell 型別的分支，以及 overflow chain 的讀取邏輯 ──
```

四個階段，每個都值得看：

**一、cursor 位置還原**

```rust
        if self.needs_restore() {
            return_if_io!(self.restore_context());
        }
```

註解直指 SQLite 的對應函式（`sqlite3BtreeRestoreCursorPosition`），連原始檔案行號都標了。

為什麼游標需要「還原」？因為在兩次操作之間，B-tree 可能被別的操作改動過（同一交易內的寫入、page 被 evict 出 cache、或 balance 造成 cell 位移）。游標記著的「第幾個 page 的第幾個 cell」可能已經失效，必須根據記住的 key 重新定位。

而「重新定位」需要讀 page，所以這裡也可能 I/O——於是又是一個 `return_if_io!`。

**二、沒有 record 就回 `Done(None)`**

這對應到 `op_column_fetch` 那個 `let Some(record) = record_result else` 分支。**注意它回的是 `Done(None)` 而不是錯誤**：游標沒停在有效列上是正常狀態（空表、掃到尾端），不是異常。

**三、快取重用**

```rust
        let invalidated = self
            .reusable_immutable_record
            .as_ref()
            .is_none_or(|record| record.is_invalidated());
        if !invalidated {
            return Ok(IOResult::Done(self.reusable_immutable_record.as_ref()));
        }
```

cursor 持有一個可重用的 record 緩衝區。如果它還有效，直接回傳，**不重新解析**。

為什麼重要？因為 `SELECT a, b, c FROM t` 會對同一列發三次 `Column` 指令。如果每次都重新從 page bytes 解析 record，就做了三倍的工。這個快取讓後兩次幾乎零成本。

`is_invalidated()` 的存在則說明了另一面：**快取必須能被作廢**。游標移動、page 被改寫、交易結束時，這個 record 就不再有效。作廢時機錯了就會讀到過期資料——這是典型的快取正確性問題。

**四、真的去解析 page**

```rust
        let page = self.stack.top_ref();
        let contents = page.get_contents();
        let cell_idx = self.stack.current_cell_index();
        let cell = contents.cell_get(cell_idx as usize, self.usable_space())?;
```

到這裡才真正碰 page bytes。三個概念，各有專章：

- **`self.stack`** —— cursor 的走訪路徑。B-tree 游標的位置不是一個索引，而是「從 root 到目前 page 的整條路徑 + cell 索引」。這是 `06b-btree-cursor-pager.md` 的主題。
- **`contents.cell_get(...)`** —— 從 page bytes 解出一個 cell。SQLite page 格式（cell pointer array 從前往後長、cell content 從後往前放）是 `06a-file-format-pages.md` 的主題。
- **`first_overflow_page`** —— 如果 payload 太大放不進一個 page，剩下的資料在 overflow page chain 上。**追這條 chain 需要讀更多 page，於是又可能 I/O**——這是 `op_column` 最容易觸發 I/O 的路徑。

`self.stack.top_ref()` 能直接拿到 page，代表**那個 page 此刻已經在記憶體裡**。它是誰讀進來的？是先前的 `Rewind` / `Seek` / `Next` 指令。那些指令負責移動游標，過程中會透過 `Pager` 把需要的 page 讀進 page cache。所以到 `record()` 這裡通常不需要再讀主 page——除非游標需要還原，或者要追 overflow chain。

---

## 底下還有什麼（本篇只給座標）

`record()` 之下的層次，各有專章，這裡只標出位置與職責：

**`core/storage/pager.rs`** —— `Pager`。負責 page cache、dirty page 追蹤、交易的 begin/commit/rollback、page 配置。B-tree **不直接寫檔案**，一律透過 Pager。詳見 `06b`。

**`core/storage/wal.rs`** —— WAL。管理 `.db-wal` 的 frames、read mark（決定讀者看到哪個快照）、write lock、checkpoint。詳見 `07a`。

**`core/storage/database.rs`** —— `DatabaseStorage` trait。把「讀第 N 個 page」翻譯成「從 byte offset `(page_idx - 1) * page_size` 讀 page_size bytes」。

**`core/io/mod.rs`** —— `IO` 與 `File` trait。最底層的抽象，實作有 `unix.rs`、`windows.rs`、`io_uring.rs`、`memory.rs`、extension VFS。詳見 `07b`。

完整的往下路徑：

```text
BTreeCursor              core/storage/btree.rs
  → Pager                core/storage/pager.rs      page cache / dirty / tx
    → WAL 或主檔案        core/storage/wal.rs
      → DatabaseStorage  core/storage/database.rs   page 編號 → byte offset
        → IO / File      core/io/mod.rs             實際的 pread/pwrite/fsync
```

---

## 閉環：一條 SQL 的完整生命週期

把五篇串起來，`SELECT name FROM t` 的全程：

```text
【編譯階段 — 完全沒有 I/O】

turso::Connection::prepare              bindings/rust/src/connection.rs:137   第 1 篇
  → TursoConnection::prepare_single     sdk-kit/src/rsapi.rs:1067
    → core::Connection::prepare         core/connection.rs:952
      → prepare_with_origin             core/connection.rs:971                第 2 篇
        → parse_sql                     core/connection.rs:1731
          → dialect::parse              core/dialect/sqlite.rs:80
            → Parser::next_cmd          sqlite/parser/src/parser.rs:255
              → ast::Cmd / ast::Stmt
        → compile_cmd                   core/connection.rs:893                第 3 篇
          → translate                   core/translate/mod.rs:74
            → ProgramBuilder::prologue  core/vdbe/builder.rs:1641   發 Init
            → translate_inner           core/translate/mod.rs:150   依語句分派
            → ProgramBuilder::epilogue  core/vdbe/builder.rs:1719   發 Halt/Transaction/Goto
            → build → Program { Arc<PreparedProgram>, connection }
        → Statement::new_with_origin    core/statement.rs:344

【執行階段 — 從這裡開始碰資料】

Statement::step                         core/statement.rs:659                 第 4 篇
  → _step                               core/statement.rs:507   記帳/reprepare/timeout
    → Program::step                     core/vdbe/mod.rs:1564   依 QueryMode 分派
      → normal_step                     core/vdbe/mod.rs:1736   VM 主迴圈
        loop {
          檢查 closed / interrupt
          檢查 pending I/O
          insn = insns[pc]
          insn.to_function()            core/vdbe/insn.rs:2019
          執行 op_*                     core/vdbe/execute.rs                  第 5 篇
            op_open_read  :1148  → 建立 cursor
            op_column     :1762  → op_column_fetch :1866
                                    → cursor.record()  core/storage/btree.rs:6385
                                      → Pager → WAL/檔案 → IO
            op_result_row :2978  → 產出一列，PC += 1
          match 回報 → Step 續跑 / Row / Done / IO / Busy
        }
```

**兩件事值得最後強調：**

第一，**編譯與執行的界線非常清楚**。prepare 全程不碰資料、不開交易、不做 I/O。所有 I/O 都發生在 step 之後。

第二，**I/O 可以從最深處一路冒泡到最上層**。`btree.rs` 深處的一次 page 讀取，透過 `return_if_io!` 的鏈式傳遞，會變成使用者手上 `step()` 回傳的 `StepResult::IO`。中間每一層都不需要是 `async fn`，也不需要 runtime。這是 Turso 最獨特的設計，也是 `07b-ioresult-reentry.md` 的完整主題。

---

## 動手驗證

觸發 overflow page 讀取，看看什麼情況會讓 `Column` 真的做 I/O：

```bash
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE big(id INTEGER PRIMARY KEY, data TEXT);
INSERT INTO big VALUES (1, printf('%.*c', 100000, 'x'));
PRAGMA page_count;
SELECT length(data) FROM big;
```

`page_count` 會明顯大於 2，因為 10 萬 bytes 的字串放不進單一 page，溢出到 overflow chain。而 `SELECT length(data)` 就必須追那條 chain——這正是 `op_column` 會多次 yield I/O 的場景。

驗證 record 快取重用：

```sql
CREATE TABLE t3(a,b,c);
INSERT INTO t3 VALUES (1,2,3);
EXPLAIN SELECT a, b, c FROM t3;
```

你會看到**三條 `Column` 指令**針對同一列。第一條解析 record，後兩條命中 `reusable_immutable_record` 快取。

追 source：

```bash
rg -n "pub fn op_open_read|pub fn op_column\b|fn op_column_fetch" core/vdbe/execute.rs
rg -n "pub enum IOResult|macro_rules! return_if_io" core/types.rs
rg -n "fn record\(&mut self\)" core/storage/btree.rs
```

---

## 自我檢查

1. `OpenRead` 指令的參數裡沒有表名，只有 `root_page`。這說明了什麼分層原則？
2. `op_column` 的快速路徑為什麼可以完全不用狀態機？它依賴什麼性質？
3. 什麼情況會讓 `op_column` 走慢速路徑（需要 `OpColumnState`）？
4. 游標沒停在有效列上時，`Column` 回 NULL 還是回欄位的 DEFAULT？為什麼要區分？什麼情況才用 DEFAULT？
5. `return_if_io!` 的三個分支各做什麼？中間那個 `return` 造成什麼效果？
6. `cursor.record()` 為什麼一開始要檢查 `needs_restore()`？游標的位置怎麼會失效？
7. `reusable_immutable_record` 解決什麼問題？它為什麼需要 `is_invalidated()`？
8. 從 `btree.rs` 深處的一次 page 讀取，到使用者拿到 `StepResult::IO`，中間經過哪些層？每層做了什麼轉換？
9. 為什麼說「prepare 階段完全沒有 I/O」？如果 prepare 需要查 schema，schema 是從哪來的？

---

## 01 系列到此結束

五篇走完了一條 SQL 的完整生命週期。接下來的章節會把本系列刻意略過的部分展開：

- `02-source-code-learn-*.md` —— parser 內部：lexer、遞迴下降、AST 結構
- `03-source-code-learn-*.md` —— 編譯器內部：planner、optimizer、emitter
- `04-source-code-learn-*.md` —— VDBE 內部：指令集、register、explain
- `05` / `05b` —— schema、value、record 格式、function system
- `06a` / `06b` —— page 格式、B-tree、Pager
- `07a` / `07b` —— WAL、交易、checkpoint、I/O 重入
- `08` —— extension、sync、測試
- `09` —— 綜合追蹤練習
