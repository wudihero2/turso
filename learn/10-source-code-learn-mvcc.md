# 10. 源碼精讀：MVCC——多版本並行控制

前面所有章節講的都是 **WAL 路徑**：一個寫者、page 層級的快照、透過 read mark 隔離讀者（`07a-source-code-learn-wal-transactions.md`）。

本篇講 Turso 的**實驗性 MVCC 路徑**：多個寫者可以同時進行，隔離發生在**列的層級**而非 page 層級。

`core/mvcc/` 有 46,428 行（其中 19,495 行是測試——這個比例本身就說明了問題的難度）。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **MVCC 目前是實驗性功能。** 先讀懂 `07a`/`07b` 的 WAL 路徑再讀本篇——MVCC 不是取代它，而是疊在它之上的另一層。

> **閱讀時間**：約 90–120 分鐘（約 21k 字，其中 39% 是原始碼）。建議分 **2 個 session**，文中有標示休息點。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/mvcc/mod.rs                  模組文件：它防止哪些異常
core/mvcc/database/mod.rs         RowVersion / Transaction / 可見性規則（10,023 行）
core/mvcc/cursor.rs               MvccLazyCursor ── 雙 cursor 合併
core/mvcc/persistent_storage/     logical log ── 與 WAL 不同的持久化
```

---

## 理論基礎：模組文件就是課程大綱

**`core/mvcc/mod.rs:1-32`** — 完整貼出：

```rust
//! Multiversion concurrency control (MVCC) for Rust.
//!
//! This module implements the main memory MVCC method outlined in the paper
//! "High-Performance Concurrency Control Mechanisms for Main-Memory Databases"
//! by Per-Åke Larson et al (VLDB, 2011).
//!
//! ## Data anomalies
//!
//! * A *dirty write* occurs when transaction T_m updates a value that is written by
//!   transaction T_n but not yet committed. The MVCC algorithm prevents dirty
//!   writes by validating that a row version is visible to transaction T_m before
//!   allowing update to it.
//!
//! * A *dirty read* occurs when transaction T_m reads a value that was written by
//!   transaction T_n but not yet committed. The MVCC algorithm prevents dirty
//!   reads by validating that a row version is visible to transaction T_m.
//!
//! * A *fuzzy read* (non-repeatable read) occurs when transaction T_m reads a
//!   different value in the course of the transaction because another
//!   transaction T_n has updated the value.
//!
//! * A *lost update* occurs when transactions T_m and T_n both attempt to update
//!   the same value, resulting in one of the updates being lost. The MVCC algorithm
//!   prevents lost updates by detecting the write-write conflict and letting the
//!   first-writer win by aborting the later transaction.
//!
//! TODO: phantom reads, cursor lost updates, read skew, write skew.
//!
//! ## TODO
//!
//! * Optimistic reads and writes
//! * Garbage collection
```

**這段文件標明了實作的論文來源**：Larson et al 的 Hekaton 論文（微軟 SQL Server 的記憶體內引擎）。後面的程式碼註解會直接引用論文章節（例如 "Hekaton Section 2.7"），所以看不懂某段設計時可以去查論文。

四種異常各有對應的防護機制。**注意最後一個 TODO**：

> TODO: phantom reads, cursor lost updates, read skew, write skew.

**誠實標示尚未處理的異常。** 這是「實驗性」的具體含義——它防止了四種異常，但 phantom read 等還沒處理。讀實驗性程式碼時，這種 TODO 比什麼都重要：它告訴你邊界在哪。

---

## 核心資料結構：RowVersion

MVCC 的基本想法是：**更新不覆寫舊資料，而是產生新版本**。每個版本標記自己的有效區間。

**`core/mvcc/database/mod.rs:448-473`** — 完整貼出：

```rust
pub struct RowVersion {
    /// Unique identifier for this version within the MvStore.
    /// Used for savepoint tracking to identify specific versions to rollback.
    pub id: u64,
    /// `begin`/`end` timestamps are bit-packed. Read them through the
    /// [`RowVersion::begin`]/[`RowVersion::end`] accessors and write them with
    /// [`RowVersion::set_begin`]/[`RowVersion::set_end`]; the raw `PackedTs`
    /// fields are `pub(crate)` only so they can be set in struct literals (via
    /// `PackedTs::pack`).
    pub(crate) begin: PackedTs,
    pub(crate) end: PackedTs,
    pub row: Row,
    /// Indicates this version was created for a row that existed in B-tree before
    /// MVCC was enabled (e.g., after switching from WAL to MVCC journal mode).
    /// This flag helps the checkpoint logic determine if a delete should be
    /// checkpointed to the B-tree file.
    pub btree_resident: bool,
    /// The WAL position at which this version's *current* (begin, end) state was last
    /// materialized to the B-tree by a checkpoint. [`WalPos::ORIGIN`] means "not yet in the
    /// B-tree" — either never checkpointed, or its state changed (e.g. a delete set `end`) and
    /// the new state is not materialized yet. The version-store GC (`gc_version_chain` Rules 2/3)
    /// may only reclaim a version once its state is materialized (`!= ORIGIN`) AND every reader's
    /// read mark has reached that position — otherwise a reader pinned below it reads the stale
    /// B-tree and the version it needed is gone. Set by the checkpoint at materialization
    /// ([`MvStore::stamp_materialized`]); reset to ORIGIN when a delete supersedes the row.
    pub(crate) materialized_at: WalPos,
}
```

**`begin` / `end` 是核心**：這個版本從哪個時間點開始有效、到哪個時間點失效。

```text
UPDATE t SET x = 2 WHERE id = 1;   -- 在時間戳 100 提交

版本鏈:
  RowVersion { begin: 50,  end: 100, row: {id:1, x:1} }   ← 舊版本
  RowVersion { begin: 100, end: None, row: {id:1, x:2} }  ← 新版本
```

一個 `begin_ts = 80` 的交易讀這一列時看到**舊版本**（80 落在 [50, 100) 區間）；`begin_ts = 120` 的交易看到新版本。**兩個交易讀到不同的值，而且都不需要鎖。**

### 兩個與 WAL 路徑的接縫

**`btree_resident`** —— 這一列在啟用 MVCC **之前**就存在於 B-tree 裡。

因為 MVCC 是可以中途啟用的（切換 journal mode），既有資料還在 B-tree 中，沒有對應的版本鏈。這個旗標讓 checkpoint 知道「刪除這一列時要不要去 B-tree 裡真的刪掉」。

**`materialized_at`** —— 這是本篇最複雜的欄位，註解也最長。它記錄「這個版本的當前狀態是否已經寫回 B-tree」。

用途是**垃圾回收的安全條件**。註解說明了不遵守會發生什麼：

> may only reclaim a version once its state is materialized (`!= ORIGIN`) **AND** every reader's read mark has reached that position — otherwise **a reader pinned below it reads the stale B-tree and the version it needed is gone**.

回收一個版本需要同時滿足兩個條件：

1. 它的狀態已經寫回 B-tree（否則資料就永久遺失了）。
2. 所有讀者的 read mark 都已經越過那個位置（否則舊讀者會去讀 B-tree，但 B-tree 是更新後的狀態，而它需要的舊版本已經被回收）。

**只滿足其中一個就回收 = 讀到錯誤資料。** 這是 MVCC 最容易出錯的地方——版本什麼時候可以丟掉。

`WalPos::ORIGIN` 當「尚未物化」的哨兵值，和 `06b-source-code-learn-btree-cursor-pager.md` 看到的 `schema_cookie` 用 `AtomicU64` 存 32-bit 值是同一個手法：**用值域外的值代替 `Option`**。

註解裡的 `gc_version_chain Rules 2/3` 表示 GC 有一套編號的規則——這種「規則編號」通常代表那段邏輯經過反覆推敲。

---

## 時間戳的雙重身分

**`core/mvcc/database/mod.rs:775-780`** — 完整貼出：

```rust
pub enum TxTimestampOrID {
    /// A committed transaction's timestamp.
    Timestamp(u64),
    /// The ID of a non-committed transaction.
    TxID(TxID),
}
```

**`begin` / `end` 欄位存的可能是兩種東西**：

- **已提交** → 存**時間戳**。可見性用數值比較就能判斷。
- **未提交** → 存**交易 ID**。要去查那個交易現在的狀態。

這個設計避免了「等交易提交才寫入版本」——寫入時直接填自己的 tx_id，提交時再統一改成時間戳。

**代價是可見性判斷變複雜**：拿到一個 `TxID` 時，必須去查那個交易的狀態，而它可能正在提交中（race）。下面的可見性規則就是在處理這件事。

---

## 交易狀態機

**`core/mvcc/database/mod.rs:1281-1289`** — 完整貼出：

```rust
enum TransactionState {
    Active,
    /// Preparing state includes the end_ts so other transactions can compare
    /// timestamps during validation to resolve races (first-committer-wins).
    Preparing(u64),
    Aborted,
    Terminated,
    Committed(u64),
}
```

**`Preparing(u64)` 是關鍵狀態。**

提交不是原子的一瞬間——它有一個「正在提交」的窗口：分配了 end_ts、正在驗證、正在寫 log。這期間**其他交易可能來讀它寫的版本**。

註解說明了為什麼 `Preparing` 要帶時間戳：

> so other transactions can compare timestamps during validation to resolve races (**first-committer-wins**)

其他交易看到 `Preparing(end_ts)` 時，可以比較自己的 `begin_ts` 和那個 `end_ts`，**推測**「如果它提交成功，這個版本對我可見嗎」。

**`core/mvcc/database/mod.rs:1291-1301`** — 狀態的編碼：

```rust
impl TransactionState {
    // Bit patterns for encoding states with timestamps
    const PREPARING_BIT: u64 = 0x4000_0000_0000_0000;
    const COMMITTED_BIT: u64 = 0x8000_0000_0000_0000;
    const TIMESTAMP_MASK: u64 = 0x3fff_ffff_ffff_ffff;

    pub fn encode(&self) -> u64 {
        match self {
            TransactionState::Active => 0,
            TransactionState::Preparing(ts) => {
                // We only support 2^62 - 1 timestamps
```

**整個狀態被壓進一個 `u64`**：兩個高位元表示狀態，低 62 位元放時間戳。

為什麼要這樣？因為狀態要能**原子讀寫**（`AtomicTransactionState`）。多個執行緒同時讀取一個交易的狀態，如果狀態是「enum + 另一個欄位」，就沒辦法原子地一起讀——可能讀到「狀態是 Committed 但時間戳還是舊的」這種撕裂狀態。

**壓進一個 `u64` 就能用一次 atomic load 讀完。** 代價是時間戳上限降到 2^62，註解也標明了。

---

## 可見性規則

這是 MVCC 的核心演算法。

**`core/mvcc/database/mod.rs:9628-9636`** — 完整貼出：

```rust
    fn is_visible_to<A: ConcurrentAllocator>(
        &self,
        tx: &Transaction<A>,
        txs: &SkipMap<TxID, Transaction<A>, BasicComparator, A>,
        finalized_tx_states: &SkipMap<TxID, TransactionState, BasicComparator, A>,
    ) -> bool {
        is_begin_visible(txs, finalized_tx_states, tx, self)
            && is_end_visible(txs, finalized_tx_states, tx, self)
    }
```

可見 = **開始可見** 且 **結束可見**。也就是「這個版本已經生效」且「還沒失效」。

### 已提交的情況：純數值比較

**`core/mvcc/database/mod.rs:9795-9808`** — 完整貼出：

```rust
fn is_begin_visible<A: ConcurrentAllocator>(
    txs: &SkipMap<TxID, Transaction<A>, BasicComparator, A>,
    finalized_tx_states: &SkipMap<TxID, TransactionState, BasicComparator, A>,
    tx: &Transaction<A>,
    rv: &RowVersion,
) -> bool {
    match rv.begin() {
        Some(TxTimestampOrID::Timestamp(rv_begin_ts)) => {
            turso_assert!(
                tx.begin_ts != rv_begin_ts,
                "begin_ts and committed rv_begin_ts cannot be equal: txn timestamps are strictly monotonic"
            );
            tx.begin_ts > rv_begin_ts
        }
```

**最單純的情況**：版本由已提交的交易產生，比較兩個時間戳即可。我開始得比它晚，就看得到它。

那個斷言值得注意：

```rust
                tx.begin_ts != rv_begin_ts,
                "begin_ts and committed rv_begin_ts cannot be equal: txn timestamps are strictly monotonic"
```

**時間戳嚴格單調遞增，所以不可能相等。**

為什麼要斷言這件事？因為如果相等，`>` 比較就會給出「不可見」——但語義上應該如何處理是不明確的。與其默默走進一個未定義的情況，不如斷言它不可能發生。**如果這個斷言爆了，代表時間戳分配有 bug，那是必須修的根本問題。**

### 未提交的情況：三種狀態

**`core/mvcc/database/mod.rs:9809-9840`** — 完整貼出：

```rust
        Some(TxTimestampOrID::TxID(rv_begin)) => {
            let visible = match txs.get(&rv_begin) {
                Some(tb_entry) => {
                    let tb = tb_entry.value();
                    let visible = match tb.state.load() {
                        TransactionState::Active => tx.tx_id == tb.tx_id && rv.end().is_none(),
                        TransactionState::Preparing(end_ts) => {
                            // Hekaton Table 1 / Section 2.5: speculative read of TB.
                            // If begin_ts > end_ts, the version would be visible once TB
                            // commits. Speculatively return true and register a dependency.
                            // Fixes partial commit visibility (Bug #8).
                            turso_assert!(
                                tx.tx_id != tb.tx_id,
                                "a txn cannot read its own row versions during prepare"
                            );
                            turso_assert!(
                                tx.begin_ts != end_ts,
                                "begin_ts and preparing end_ts cannot be equal: txn timestamps are strictly monotonic"
                            );
                            if tx.begin_ts > end_ts {
                                register_commit_dependency(txs, tx, rv_begin);
                                true
                            } else {
                                false
                            }
                        }
                        TransactionState::Committed(committed_ts) => {
                            turso_assert!(
                                tx.begin_ts != committed_ts,
```

**三種狀態的處理各不相同。**

**`Active`（還在執行）**：

```rust
                        TransactionState::Active => tx.tx_id == tb.tx_id && rv.end().is_none(),
```

只有**自己寫的**版本自己看得見（`tx.tx_id == tb.tx_id`）。別人未提交的寫入絕對不可見——這就是模組文件說的**防止 dirty read**。

`rv.end().is_none()` 則是「我自己還沒刪掉它」。

**`Preparing(end_ts)`（正在提交）** —— 這是最精妙的一段：

```rust
                            // Hekaton Table 1 / Section 2.5: speculative read of TB.
                            // If begin_ts > end_ts, the version would be visible once TB
                            // commits. Speculatively return true and register a dependency.
                            // Fixes partial commit visibility (Bug #8).
                            if tx.begin_ts > end_ts {
                                register_commit_dependency(txs, tx, rv_begin);
                                true
                            } else {
                                false
                            }
```

**推測性讀取（speculative read）。**

TB 正在提交，還不知道會成功還是失敗。如果等它決定，就會阻塞——那 MVCC 的無鎖優勢就沒了。

Hekaton 的解法是：**先假設它會成功**，回傳可見，但**登記一個提交相依**（`register_commit_dependency`）。

意思是「我讀了你未確定的資料，所以**我不能比你先提交**」。如果 TB 最後中止，我也必須中止。

這對應 `Transaction` 的兩個欄位：

**`core/mvcc/database/mod.rs:969-976`** — 完整貼出：

```rust
    /// Number of unresolved commit dependencies (must reach 0 before commit).
    /// i.e the number of transactions this transaction is dependent on and waiting for
    /// commit or abort.
    /// Hekaton Section 2.7: "A transaction cannot commit until this counter is zero."
    commit_dep_counter: AtomicU64,
    /// Flag: a depended-on transaction aborted; this transaction must abort too.
    /// Hekaton Section 2.7: "AbortNow that other transactions can set to tell T to abort."
    abort_now: AtomicBool,
```

**兩個欄位直接引用論文的章節與術語。** `commit_dep_counter` 必須歸零才能提交；`abort_now` 被別人設定時代表「你依賴的交易掛了，你也得掛」。

註解裡的 "Fixes partial commit visibility (Bug #8)" 說明這段程式碼是**修 bug 修出來的**——早期版本沒有推測讀取，導致交易看到「部分提交」的狀態。這種註解很有價值：它告訴後人這裡不能簡化。

那個斷言也值得看：

```rust
                                tx.tx_id != tb.tx_id,
                                "a txn cannot read its own row versions during prepare"
```

自己不可能在自己 preparing 時讀自己——因為那時已經沒有在執行 SQL 了。斷言把這個不變量寫死。

---

---

> ### ⏸ Session 1 到此
>
> 目前為止涵蓋了：RowVersion 的版本鏈、時間戳的雙重身分、交易狀態機、可見性規則。
>
> 休息之前，先確認你能說出這幾件事；說不出來就往回翻，不要硬推進——後半段會用到它們。
>
> **Session 2** 從下一節開始：寫寫衝突偵測、雙 cursor 合併、logical log 持久化。

---

## 寫寫衝突：first-writer-wins

模組文件說 MVCC 用「偵測寫寫衝突、讓先寫者贏」來防止 lost update。

**`core/mvcc/database/mod.rs:1735-1736`、`1759`** — 兩處函式註解：

```rust
    /// Returns [LimboError::WriteWriteConflict] when another transaction committed or is
```

`core/mvcc/database/mod.rs` 裡有六處回傳 `WriteWriteConflict`（行 1841、1863、1867、1909 等），對應不同的衝突偵測點。

**這是 MVCC 與 WAL 路徑最大的行為差異。**

| | WAL 路徑 | MVCC 路徑 |
|---|---|---|
| 並行寫入 | 第二個寫者**等待**（拿不到 write lock） | 兩個都能進行 |
| 衝突處理 | 不會衝突（序列化了） | 偵測到就**中止**較晚的 |
| 應用程式要做什麼 | 處理 `SQLITE_BUSY`、重試 | 處理衝突中止、重試 |

**兩者都需要重試邏輯，但時機不同**：WAL 是「開始時就拿不到鎖」，MVCC 是「做到一半（甚至提交時）才發現衝突」。

MVCC 的代價是**做白工的可能性更高**——一個長交易可能跑了很久才在提交時被中止。好處是高並行度下不會有寫者互相阻塞。

`01-source-code-learn-4-step-vm.md` 看過的 `LimboError::BusySnapshot` 處理，就是這類衝突在 VM 層的表現：

```rust
                Err(LimboError::BusySnapshot)
                    if self.connection.transaction_state.get() == TransactionState::None =>
```

註解說「已經在交易裡就重試沒用，因為 snapshot 不會變」——這個判斷在 MVCC 下同樣成立。

---

## 雙 Cursor：MVCC 與 B-tree 的合併

MVCC 的資料分散在兩個地方：**版本鏈**（記憶體）和 **B-tree**（磁碟，已 checkpoint 的部分）。查詢必須同時看兩邊。

**`core/mvcc/cursor.rs:493-515`** — 完整貼出：

```rust
pub struct MvccLazyCursor<Clock: LogicalClock + 'static, A: ConcurrentAllocator = TursoAllocator> {
    pub db: Arc<MvStore<Clock, A>>,
    #[cfg(any(test, injected_yields))]
    connection: Arc<Connection>,
    #[cfg(any(test, injected_yields))]
    yield_instance_id: u64,
    current_pos: CursorPosition<A>,
    /// Stateful MVCC table iterator if this is a table cursor.
    table_iterator: Option<MvccIterator<'static, RowID, A>>,
    /// Stateful MVCC index iterator if this is an index cursor.
    index_iterator: Option<MvccIterator<'static, Arc<SortableIndexKey>, A>>,
    mv_cursor_type: MvccCursorType,
    table_id: MVTableId,
    tx_id: u64,
    /// Reusable immutable record, used to allow better allocation strategy.
    reusable_immutable_record: Option<ImmutableRecord>,
    btree_cursor: Box<dyn CursorTrait>,
    null_flag: bool,
    creating_new_rowid: bool,
    state: Option<MvccLazyCursorState>,
    // we keep count_state separate to be able to call other public functions like rewind and next
    count_state: Option<CountState>,
    btree_advance_state: Option<AdvanceBtreeState>,
```

**關鍵欄位是 `btree_cursor: Box<dyn CursorTrait>`** —— MVCC cursor **內部包著一個 B-tree cursor**。

`06b-source-code-learn-btree-cursor-pager.md` 講的 `CursorTrait` 在這裡發揮了作用：MVCC cursor 自己也實作 `CursorTrait`（所以 VM 用起來沒有差別），同時它持有一個 B-tree cursor 當作第二個資料來源。

**合併邏輯**（回顧 `06b` 講的 `is_btree_invalidating_version`）：

```rust
    /// Check if this version indicates the B-tree row has been modified (updated or deleted).
    ///
    /// A version is "relevant" to a transaction if:
    /// 1. The version is fully visible (begin visible AND end visible), OR
    /// 2. The version has an end timestamp that indicates the row was deleted before/at the transaction's begin, OR
    /// 3. The current transaction itself has deleted/updated this row (end = current tx_id)
    ///
    /// This is used by dual-cursor to determine if a B-tree row should be shown or hidden.
```

**這就是雙 cursor 的核心判斷**：掃到一個 B-tree 列時，要看版本鏈裡有沒有「使它失效」的版本。有的話就隱藏 B-tree 那一列，改用版本鏈的內容。

三個條件涵蓋了「已提交的修改」、「已提交的刪除」、「自己的未提交修改」。

**三個獨立的 state 欄位**（`state`、`count_state`、`btree_advance_state`）—— 又是 `07b-source-code-learn-ioresult-reentry.md` 的老問題。註解直接說明了為什麼要分開：

> we keep count_state separate to be able to call other public functions like rewind and next

`count()` 操作內部會呼叫 `rewind`/`next`，而那些也有自己的狀態。共用一個插槽就會互相覆寫——和 `06b` 講的 `BTreeCursor` 六個狀態機是完全相同的理由。

---

## 持久化：Logical Log 而非 WAL

`core/mvcc/persistent_storage/logical_log.rs` 有 8,105 行。

**與 WAL 的根本差異**：

| | WAL（`07a`） | Logical Log |
|---|---|---|
| 記錄單位 | **page**（實體） | **列的操作**（邏輯） |
| 內容 | 修改後的整個 page | insert/update/delete + 列資料 |
| 恢復方式 | 重放 page 覆寫 | 重放列操作重建版本 |

**`core/mvcc/database/mod.rs:483-497`** — `LogRecord` 的定義：

```rust
/// A log record contains all durable effects of a committed transaction,
/// pre-serialized into a frame buffer that the logical-log flush path
/// finalizes (backfills the TX header, appends the CRC trailer, optionally
/// chunk-encrypts the payload) and writes to disk.
#[derive(Clone, Debug)]
pub struct LogRecord {
    pub(crate) tx_timestamp: TxID,
    /// Frame buffer that grows in place into the on-disk representation.
    /// The first `LOG_HDR_SIZE + TX_HEADER_SIZE` bytes are pre-reserved
    /// (zeros) so that op-entry appends land at the correct on-disk
    /// offset; the flush path backfills the framing prefix and appends
    /// the trailer.
    pub buf: Vec<u8>,
    /// Number of op entries appended to `buf`. Includes any header op.
    pub op_count: u32,
```

**「pre-serialized」與「backfills」是這裡的關鍵技巧。**

交易執行過程中就把操作序列化進 `buf`，而且**預留了前面的 header 空間**（填零）。提交時只要回填 header、加上 CRC，就能直接寫出去——**不需要重新配置或搬移緩衝區**。

這和 `03-source-code-learn-1-planner.md` 講的 label 回填是同一個手法：**先預留位置，之後回填**，避免資料搬移。

**為什麼 MVCC 不能直接用 WAL？** 因為版本鏈是記憶體結構，它的狀態不是「某個 page 長什麼樣」，而是「哪些交易在什麼時間做了什麼」。用 page 層級的 log 記不下這個資訊。

而 checkpoint（`checkpoint_state_machine.rs`，3,670 行）則負責把版本鏈的內容**物化回 B-tree**——這就是上面 `materialized_at` 欄位追蹤的事情。

---

## 與 WAL 路徑的完整對照

| 面向 | WAL 路徑 | MVCC 路徑 |
|---|---|---|
| 並行寫者 | 1 個 | 多個 |
| 隔離單位 | page | 列 |
| 讀者看到的 | WAL frame 快照（read mark） | 版本鏈（begin/end 時間戳） |
| 寫入衝突 | 拿不到 write lock → `Busy` | 偵測後中止 → `WriteWriteConflict` |
| 持久化 | WAL frame（實體 page） | logical log（邏輯操作） |
| 回收機制 | checkpoint 回填 + WAL restart | 版本 GC（`materialized_at` 條件）+ checkpoint |
| 成熟度 | 生產可用 | **實驗性** |

**MVCC 沒有取代 WAL——它疊在上面。** B-tree、pager、page cache 都還在用；MVCC 加的是版本鏈與可見性判斷，checkpoint 時仍然寫回同一個 B-tree。

---

## 動手驗證

MVCC 需要明確啟用：

```bash
cd /Users/stanhsu/projects/turso
cargo run -q --bin tursodb -- -q
```

```sql
PRAGMA journal_mode;
```

MVCC 相關的多連線測試比較適合用專用工具：

```bash
cargo run -q --bin tursodb -- --help 2>&1 | grep -i mvcc
```

`AGENTS.md` 提到 `cli/mvcc_repl.rs` 是「多連線並行交易測試 REPL」——那是實際觀察寫寫衝突的地方。

跑 MVCC 的測試：

```bash
make test 2>&1 | grep -i mvcc | head
cargo test -p turso_core mvcc 2>&1 | tail -20
```

`core/mvcc/database/hermitage_tests.rs`（921 行）特別值得一看——**Hermitage 是一套業界標準的隔離級別測試套件**，用來驗證資料庫真的達到宣稱的隔離級別。它測的正是模組文件列出的那些異常。

追 source：

```bash
rg -n "pub struct RowVersion|pub enum TxTimestampOrID|enum TransactionState" core/mvcc/database/mod.rs
rg -n "fn is_visible_to|^fn is_begin_visible|^fn is_end_visible" core/mvcc/database/mod.rs
rg -n "commit_dep_counter|abort_now|register_commit_dependency" core/mvcc/database/mod.rs | head
rg -n "pub struct MvccLazyCursor" core/mvcc/cursor.rs
wc -l core/mvcc/**/*.rs
```

---

## 自我檢查

1. 模組文件列出四種資料異常，但 TODO 標明還有哪些沒處理？這對「實驗性」的含義是什麼？
2. `RowVersion` 的 `begin`/`end` 如何實現「兩個交易讀到不同的值卻不需要鎖」？
3. `materialized_at` 的兩個 GC 安全條件是什麼？只滿足一個就回收會發生什麼？
4. `TxTimestampOrID` 為什麼要能存「時間戳」或「交易 ID」兩種東西？這個設計省下了什麼、代價是什麼？
5. `TransactionState` 為什麼要壓進一個 `u64`？如果用「enum + 獨立時間戳欄位」會有什麼問題？
6. 為什麼 `Preparing` 狀態要帶 `end_ts`？
7. `is_visible_to` 為什麼要同時檢查 begin 和 end？
8. 讀到 `Active` 狀態的交易寫的版本時，什麼情況才可見？這防止了哪種異常？
9. 什麼是「推測性讀取」？讀了正在 prepare 的交易的資料後，讀者要承擔什麼義務？
10. `commit_dep_counter` 和 `abort_now` 各對應論文的什麼機制？
11. 時間戳「嚴格單調遞增」為什麼要用斷言而不是用 `>=` 容錯？
12. MVCC 的寫寫衝突與 WAL 的 `SQLITE_BUSY`，應用程式的處理有什麼不同？哪一種比較容易做白工？
13. `MvccLazyCursor` 為什麼內部要包一個 `btree_cursor`？資料為什麼分散在兩處？
14. 為什麼 `count_state` 要和 `state` 分開？這對應 `07b` 講的什麼原則？
15. Logical log 和 WAL 的記錄單位有什麼根本差異？為什麼 MVCC 不能直接用 WAL？
16. `LogRecord.buf` 預留 header 空間再回填，這個技巧和編譯器的什麼機制類似？
17. MVCC 是取代了 WAL 路徑，還是疊在上面？B-tree 還在用嗎？

---

## MVCC 篇結束

MVCC 是**疊在 WAL 之上**的另一層，不是取代它。B-tree、pager、page cache 都還在用；`07a`/`07b` 講的那條路徑仍然是預設。

本篇是進階系列的第一篇，後面還有四篇，彼此獨立：

- **下一篇 `11-source-code-learn-incremental-views.md`** —— Materialized view 與 DBSP 增量計算。和本篇有一個共同點：`op_insert` 擷取舊值的機制同時服務 MVCC 與 IVM。
- `12-source-code-learn-postgres-frontend.md` —— PostgreSQL frontend
- `13-source-code-learn-sync-engine.md` —— 完整同步協定（本篇講的 logical log 是它的基礎）
- `14-source-code-learn-simulator.md` —— 確定性模擬器（`core/mvcc/database/hermitage_tests.rs` 就是它驗證隔離級別的地方）
