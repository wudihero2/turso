# 06b. 源碼精讀：BTreeCursor 與 Pager

本篇對應 `06b-btree-cursor-pager.md`：cursor 如何在 B-tree 裡移動，Pager 如何管理 page 與 cache。

前一篇（`06a-source-code-learn-file-format-pages.md`）講了磁碟上的 bytes 長什麼樣。本篇講如何在那些 bytes 上移動與存取。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 75–90 分鐘（約 18k 字，其中 39% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/storage/btree.rs
  ├─ CursorTrait      VM 看到的 cursor 介面
  ├─ BTreeCursor      實作，以及它為什麼有這麼多 state 欄位
  ├─ PageStack        cursor 的位置表示法
  └─ rewind           一個完整的狀態機範例
core/storage/pager.rs
  └─ Pager            page cache、dirty 追蹤、交易入口
```

---

## CursorTrait：VM 與 storage 的契約

**`core/storage/btree.rs:643-651`** — 完整貼出開頭：

```rust
pub trait CursorTrait: Any + Send + Sync {
    /// Move cursor to last entry.
    fn last(&mut self) -> Result<IOResult<()>>;
    /// Move cursor to next entry.
    fn next(&mut self) -> Result<IOResult<()>>;
    /// Move cursor to previous entry.
    fn prev(&mut self) -> Result<IOResult<()>>;
    /// Get the rowid of the entry the cursor is poiting to if any
    fn rowid(&mut self) -> Result<IOResult<Option<i64>>>;
```

**幾乎每個方法都回傳 `Result<IOResult<T>>`。** 這是 `01-source-code-learn-5-cursor-storage.md` 講過的明確 I/O 模型——連「移到下一筆」都可能需要讀 page，所以都要能 yield。

`Any + Send + Sync` 的 supertrait 也有意義：`Any` 讓執行期能向下轉型（VM 有時需要取回具體的 `BTreeCursor`），`Send + Sync` 讓 cursor 能跨執行緒。

### 預設方法：把「不支援」變成明確錯誤

**`core/storage/btree.rs:653-665`** — 完整貼出：

```rust
    /// Incremental blob I/O — read `len` bytes at `off` within column `column`'s value
    /// into `out`. Only table (rowid) b-tree cursors support this; the default errors.
    fn blob_read_column(
        &mut self,
        _column: usize,
        _off: usize,
        _len: usize,
        _out: &mut crate::ValueBlob,
    ) -> Result<IOResult<()>> {
        Err(LimboError::InternalError(
            "incremental blob I/O is only supported on table rows".to_string(),
        ))
    }
```

增量 BLOB I/O（不載入整個 blob，只讀其中一段）只有 table cursor 支援。index cursor、sorter cursor 等用預設實作直接回錯。

**這比讓每個實作者自己寫 `unimplemented!()` 好**：錯誤訊息統一、而且新增 cursor 型別時不會忘記處理。

### peer notification：cursor 之間的互相通知

**`core/storage/btree.rs:684-688`** — 完整貼出這段註解：

```rust
    /// Notification, delivered during a peer's saveAllCursors pass, that the peer is
    /// about to write the row `rowid` in this cursor's b-tree (`None` when the rowid
    /// is unknown, which must be treated as "could be any row"). Lets cursors backing
    /// incremental blob handles expire when their own row is written — SQLite's
    /// invalidateIncrblobCursors — while surviving writes to other rows. Default no-op.
```

這段揭露了一個重要問題：**多個 cursor 可能同時開在同一棵 B-tree 上**。當 cursor A 要寫入時，cursor B 記著的位置可能失效。

所以寫入前要跑一次「通知所有同儕」的流程（SQLite 叫 `saveAllCursors`）。註解裡的細節很講究：

> `None` when the rowid is unknown, which must be treated as "could be any row"

不知道要寫哪一列時，必須**保守假設是任何一列**，讓所有相關 cursor 都失效。**在不確定時選擇保守，是正確性優先於效能的具體表現。**

---

## BTreeCursor：為什麼有這麼多欄位

**`core/storage/btree.rs:754-794`** — 完整貼出：

```rust
pub struct BTreeCursor {
    /// The pager that is used to read and write to the database file.
    pub pager: Arc<Pager>,
    /// Cached value of the usable space of a BTree page, since it is very expensive to call in a hot loop via pager.usable_space().
    /// This is OK to cache because both 'PRAGMA page_size' and '.filectrl reserve_bytes' only have an effect on:
    /// 1. an uninitialized database,
    /// 2. an initialized database when the command is immediately followed by VACUUM.
    usable_space_cached: usize,
    /// Page id of the root page used to go back up fast.
    root_page: i64,
    /// Rowid and record are stored before being consumed.
    pub has_record: bool,
    null_flag: bool,
    /// Index internal pages are consumed on the way up, so we store going upwards flag in case
    /// we just moved to a parent page and the parent page is an internal index page which requires
    /// to be consumed.
    going_upwards: bool,
    /// Information maintained across execution attempts when an operation yields due to I/O.
    state: CursorState,
    /// State machine for balancing.
    balance_state: BalanceState,
    /// Information maintained while freeing overflow pages. Maintained separately from cursor state since
    /// any method could require freeing overflow pages
    overflow_state: OverflowState,
    /// Page stack used to traverse the btree.
    /// Each cursor has a stack because each cursor traverses the btree independently.
    stack: PageStack,
    /// Reusable immutable record, used to allow better allocation strategy.
    reusable_immutable_record: Option<ImmutableRecord>,
    /// Information about the index key structure (sort order, collation, etc)
    pub index_info: Option<Arc<IndexInfo>>,
    /// Maintain count of the number of records in the btree. Used for the `Count` opcode
    count: usize,
    /// Stores the cursor context before rebalancing so that a seek can be done later
    context: Option<CursorContext>,
    /// Store whether the Cursor is in a valid state. Meaning if it is pointing to a valid cell index or not
    pub valid_state: CursorValidState,
    seek_state: CursorSeekState,
    /// Separate state to read a record with overflow pages. This separation from `state` is necessary as
    /// we can be in a function that relies on `state`, but also needs to process overflow pages
    read_overflow_state: Option<ReadPayloadOverflow>,
```

```rust
    // ── 省略（core/storage/btree.rs:795-830 附近）：其餘欄位，
    //    包含 skip_advance、rewind_state、mv_cursor 等 ──
```

欄位可以分成四組。

### 第一組：身分

`pager`、`root_page`、`index_info` —— 這個 cursor 是誰、在哪棵樹上、樹的 key 結構是什麼。

`usable_space_cached` 的註解值得注意：

> since it is very expensive to call in a hot loop via pager.usable_space()

快取一個理論上可能變的值。註解列出了它可以安全快取的理由：`page_size` 和 `reserved_bytes` 只在資料庫未初始化、或緊接著 VACUUM 時才會改變。

**這是「快取的正確性論證」寫進註解**的好例子。快取一個可變的值總是有風險，所以必須說明為什麼在這個情況下安全。

### 第二組：位置

`stack`、`has_record`、`null_flag`、`going_upwards`、`valid_state`。

`going_upwards` 的註解解釋了一個 index B-tree 的特性：

> Index internal pages are consumed on the way up

**table B-tree 和 index B-tree 的走訪方式不同。** table 的 interior 節點只有導航資訊（`06a` 看過 `TableInteriorCell` 只有 `left_child_page` 和 `rowid`），所以中序走訪時 interior 節點不產生資料。

但 index 的 interior 節點**有 payload**（`IndexInteriorCell` 有 `payload` 欄位），也是一筆有效的索引項。所以中序走訪 index 時，從子樹回到父節點時要「消費」父節點的那一項——這就需要一個旗標記住「我是往上走回來的，不是往下走過來的」。

### 第三組：狀態機（本篇重點）

`state`、`balance_state`、`overflow_state`、`seek_state`、`read_overflow_state`、`context`。

**六個獨立的狀態機。** 為什麼需要這麼多？

每一個都對應「一個可能被 I/O 中斷的多步驟操作」：

| 欄位 | 保護的操作 |
|---|---|
| `state` | 一般的游標操作（next、prev、insert、delete） |
| `balance_state` | page 分裂／合併／重平衡 |
| `overflow_state` | 釋放 overflow page 鏈 |
| `seek_state` | 定位操作 |
| `read_overflow_state` | 讀取跨 overflow page 的 payload |
| `context` | 重平衡前保存位置，之後重新 seek |

**為什麼不能共用一個？** `overflow_state` 的註解直接回答了：

> Maintained separately from cursor state since any method could require freeing overflow pages

釋放 overflow page 可能發生在**任何**操作中間。如果和 `state` 共用一個插槽，就會互相覆寫——正在 delete 的狀態被釋放 overflow 的狀態蓋掉，重入時就回不到正確的位置。

`read_overflow_state` 的註解說得更明白：

> This separation from `state` is necessary as we can be in a function that relies on `state`, but also needs to process overflow pages

**巢狀的可中斷操作需要巢狀的狀態儲存。** 這是 `07b-source-code-learn-ioresult-reentry.md` 的核心主題，這裡是它最集中的體現。

### 第四組：效能與快取

`reusable_immutable_record`（`01-source-code-learn-5-cursor-storage.md` 講過的 record 重用）、`count`。

---

## PageStack：cursor 的位置不是一個數字

**`core/storage/btree.rs:8033-8046`** — 完整貼出：

```rust
struct PageStack {
    /// Pointer to the current page being consumed
    current_page: i32,
    /// List of pages in the stack. Root page will be in index 0
    pub stack: [Option<PageRef>; BTCURSOR_MAX_DEPTH + 1],
    /// List of cell indices in the stack.
    /// node_states[current_page] is the current cell index being consumed. Similarly
    /// node_states[current_page-1] is the cell index of the parent of the current page
    /// that we save in case of going back up.
    /// There are two points that need special attention:
    ///  If node_states[current_page] = -1, it indicates that the current iteration has reached the start of the current_page
    ///  If node_states[current_page] = `cell_count`, it means that the current iteration has reached the end of the current_page
    node_states: [BTreeNodeState; BTCURSOR_MAX_DEPTH + 1],
}
```

**這是本篇最重要的資料結構。**

一般的迭代器位置是一個索引。B-tree cursor 的位置是**一條從 root 到當前 page 的路徑**，加上路徑上每一層的 cell 索引：

```text
current_page = 2

stack[0] = root page      node_states[0] = 3   ← 在 root 的第 3 個 cell
stack[1] = interior page  node_states[1] = 7   ← 在該 interior 的第 7 個 cell
stack[2] = leaf page      node_states[2] = 12  ← 在 leaf 的第 12 個 cell ← 目前位置
```

**為什麼要保存整條路徑而不只是 leaf？** 因為 `next()` 走到 leaf 尾端時，必須回到父節點才知道下一個要去哪。沒有路徑就得從 root 重新找一次，每一列都這樣做的話效能會很糟。

### 兩個哨兵值

註解特別點名的兩個特殊值：

- **`-1`** —— 到達 page 的開頭之前（`prev()` 走出界）。
- **`cell_count`** —— 到達 page 的結尾之後（`next()` 走出界）。

用「越界一格」表示邊界，而不是另外開一個布林旗標。這樣 `next()` 的邏輯可以統一：索引 +1，如果等於 `cell_count` 就往上走。

### 固定大小陣列

`[Option<PageRef>; BTCURSOR_MAX_DEPTH + 1]` —— **固定大小，不是 `Vec`**。

B-tree 的深度有上限（`BTCURSOR_MAX_DEPTH`），因為每層至少分支數個子節點，深度是對數成長。用固定陣列就不需要堆積配置，cursor 建立與移動都更快。

而且這個上限也是**防禦**：如果因為資料損毀導致 B-tree 出現環，走訪會撞到深度上限而報錯，不會無限迴圈。

---

## rewind：一個完整的狀態機

**`core/storage/btree.rs:7061-7085`** — 完整貼出：

```rust
    fn rewind(&mut self) -> Result<IOResult<()>> {
        self.set_null_flag(false);
        if self.valid_state == CursorValidState::Invalid {
            return Ok(IOResult::Done(()));
        }
        self.clear_saved_seek();
        self.skip_advance = false;
        loop {
            match self.rewind_state {
                RewindState::Start => {
                    let c = return_if_io!(self.move_to_root_nonblock());
                    self.rewind_state = RewindState::NextRecord;
                    if let Some(c) = c {
                        io_yield_one!(c);
                    }
                }
                RewindState::NextRecord => {
                    return_if_io!(self.get_next_record());
                    self.rewind_state = RewindState::Start;
                    self.read_overflow_state = None;
                    return Ok(IOResult::Done(()));
                }
            }
        }
    }
```

這 25 行是理解整個 storage 層寫作風格的樣板。

**結構是 `loop` + `match state`。** 每個狀態做完一小步，然後推進到下一個狀態，繼續迴圈。遇到 I/O 就 return，下次呼叫從同一個狀態繼續。

**狀態轉移發生在 I/O 之前**：

```rust
                RewindState::Start => {
                    let c = return_if_io!(self.move_to_root_nonblock());
                    self.rewind_state = RewindState::NextRecord;   // ← 先更新狀態
                    if let Some(c) = c {
                        io_yield_one!(c);                          // ← 才 yield
                    }
                }
```

先把 `rewind_state` 設成下一個狀態，**然後才** yield。所以重入時會從 `NextRecord` 繼續，不會重做 `move_to_root`。

這正是 `07b` 的核心原則：**在 yield 之前，把「已完成的進度」記進狀態**。

**完成時重置狀態**：

```rust
                RewindState::NextRecord => {
                    return_if_io!(self.get_next_record());
                    self.rewind_state = RewindState::Start;    // ← 重置給下次用
                    self.read_overflow_state = None;
                    return Ok(IOResult::Done(()));
                }
```

操作完成時把狀態重置回 `Start`，這樣下次呼叫 `rewind` 才能正常開始。**忘記重置就會讓下一次操作從錯誤的狀態開始**——這類 bug 很難查，因為第一次執行完全正常。

同時清掉 `read_overflow_state`，因為 cursor 已經移動，之前讀到一半的 overflow 資料不再有意義。

**開頭的早退**：

```rust
        if self.valid_state == CursorValidState::Invalid {
            return Ok(IOResult::Done(()));
        }
```

cursor 已經失效時直接返回。注意回的是 `Done` 而不是錯誤——失效是正常狀態（例如表被清空），不是異常。

---

## Pager：page 的守門人

**`core/storage/pager.rs:1335-1380`** — 完整貼出主要欄位：

```rust
pub struct Pager {
    /// Source of the database pages.
    pub db_file: Arc<dyn DatabaseStorage>,
    /// The write-ahead log (WAL) for the database.
    /// in-memory databases, ephemeral tables and ephemeral indexes do not have a WAL.
    pub(crate) wal: Option<Arc<dyn Wal>>,
    /// A page cache for the database.
    page_cache: Arc<RwLock<PageCache>>,
    /// Buffer pool for temporary data storage.
    pub buffer_pool: Arc<BufferPool>,
    /// I/O interface for input/output operations.
    pub io: Arc<dyn crate::io::IO>,
    /// Reads that have begun (disk IO issued, page allocated) but whose
    /// `cache_insert` has not yet succeeded because the cache was full and we
    /// yielded waiting for a spill to complete. The next call to
    /// `read_page_nonblock(idx)` reuses the stored `(page, disk_read)` pair
    /// instead of issuing a duplicate disk read.
    pending_reads: RwLock<HashMap<i64, PendingRead>>,
    #[cfg(test)]
    spill_yield: SpillYieldHook,
    /// Dirty pages as a bitmap, naturally sorted by page number.
    dirty_pages: Arc<RwLock<RoaringBitmap>>,
    subjournal: RwLock<Option<Subjournal>>,
    savepoints: Arc<RwLock<Vec<Savepoint>>>,
    commit_info: RwLock<CommitInfo>,
    checkpoint_state: RwLock<CheckpointState>,
    syncing: Arc<AtomicBool>,
    auto_vacuum_mode: AtomicU8,
    /// Mutex for synchronizing database initialization to prevent race conditions
    init_lock: Arc<Mutex<()>>,
    /// The state of the current allocate page operation.
    allocate_page_state: RwLock<AllocatePageState>,
    /// The state of the current allocate page1 operation.
    allocate_page1_state: RwLock<AllocatePage1State>,
    /// Cache page_size and reserved_space at Pager init and reuse for subsequent
    /// `usable_space` calls. TODO: Invalidate reserved_space when we add the functionality
    /// to change it.
    pub(crate) page_size: AtomicU32,
    reserved_space: AtomicU16,
    /// Schema cookie cache.
    ///
    /// Note that schema cookie is 32-bits, but we use 64-bit field so we can
    /// represent case where value is not set.
    schema_cookie: AtomicU64,
    free_page_state: RwLock<FreePageState>,
```

```rust
    // ── 省略（core/storage/pager.rs:1381-1420 附近）：spill 狀態機、
    //    io_ctx（加密/校驗和）、cursor_registry 等其餘欄位 ──
```

### 三個資料來源

`db_file`、`wal`、`page_cache` —— 一個 page 可能來自三個地方，優先順序是：**cache → WAL → 主檔案**。

`wal: Option<...>` 是 `Option`，因為記憶體資料庫、臨時表、臨時索引沒有 WAL。

### pending_reads：一個很細的正確性問題

那段註解描述的情境值得完整理解：

> Reads that have begun (disk IO issued, page allocated) but whose `cache_insert` has not yet succeeded because the cache was full and we yielded waiting for a spill to complete.

流程是：

1. 要讀 page 5，發出磁碟 I/O。
2. 想放進 cache，但 cache 滿了。
3. 需要先把某個 dirty page 寫出去（spill）騰出空間。
4. spill 是 I/O，所以 **yield**。
5. 重入後，又呼叫 `read_page(5)`。

**如果沒有 `pending_reads`，第 5 步會再發一次磁碟讀取**——第一次的結果就浪費了，而且可能造成重複的 I/O 累積。

`pending_reads` 保存 `(page, disk_read)` 讓重入時能接續使用。**這是 I/O 重入模型下特有的問題**：同步程式碼不會遇到，因為它不會在中間讓出。

### dirty_pages 用 RoaringBitmap

> Dirty pages as a bitmap, naturally sorted by page number.

為什麼用 bitmap 而不是 `HashSet<i64>`？註解點出關鍵：**naturally sorted**。

commit 時要把所有 dirty page 寫進 WAL。如果按 page 編號**順序**寫，磁碟的存取模式是接近循序的，比隨機順序快得多。bitmap 天然有序，遍歷就是排序後的結果，不需要額外排序步驟。

RoaringBitmap 則是針對稀疏／密集混合的整數集合最佳化的壓縮 bitmap。

### 大量的狀態機欄位

`allocate_page_state`、`allocate_page1_state`、`free_page_state`、`checkpoint_state`、`commit_info` —— 又是一組狀態機，理由和 `BTreeCursor` 完全相同：這些操作都可能被 I/O 中斷。

配置一個 page 可能需要：讀 freelist trunk page（I/O）→ 取出一個 leaf page 編號 → 更新 trunk page（可能又要 I/O）→ 更新 header。每一步都可能 yield。

### 快取的欄位與 TODO

```rust
    /// Cache page_size and reserved_space at Pager init and reuse for subsequent
    /// `usable_space` calls. TODO: Invalidate reserved_space when we add the functionality
    /// to change it.
```

這個 TODO 很誠實：目前 `reserved_space` 不能改，所以快取是安全的；如果將來支援修改，就必須加上失效機制。

**把「這個快取的安全前提」寫進註解**，讓未來改動的人知道自己會破壞什麼。這比沒有註解好太多——沒註解的話，加了修改功能的人根本不會想到有個快取需要失效。

### schema_cookie 用 u64 存 32-bit 值

```rust
    /// Note that schema cookie is 32-bits, but we use 64-bit field so we can
    /// represent case where value is not set.
```

用更寬的型別，讓超出範圍的值可以表示「未設定」。這和 `05-source-code-learn-schema-values-records.md` 看到的 `Column` 用 `0 = not set` 是同一個手法——**用值域外的值代替 `Option`**，因為這裡需要 atomic 存取，而 `Option<u32>` 不能直接做成 atomic。

---

## 分層總結

```text
VM opcode              core/vdbe/execute.rs
  → CursorTrait        core/storage/btree.rs:643    介面
    → BTreeCursor      core/storage/btree.rs:754    知道怎麼走樹
      → Pager          core/storage/pager.rs:1335   知道 page 從哪來
        → PageCache    快取
        → Wal          已提交但未 checkpoint 的 page
        → DatabaseStorage  主檔案
          → IO / File  實際的 pread/pwrite
```

**每一層的職責界線很清楚**：

- cursor **不知道** page 從哪來（cache？WAL？磁碟？），它只呼叫 `pager.read_page()`。
- pager **不知道** page 裡是什麼（table？index？overflow？），它只管 page 的取得、快取、標記 dirty、寫回。

這個分離讓 WAL、加密、遠端儲存等機制可以插進 pager 層，而 B-tree 程式碼完全不用改。

---

## 動手驗證

觀察 cursor 走訪造成的 page 讀取：

```bash
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO t SELECT value, 'row' || value FROM generate_series(1, 5000);
PRAGMA page_count;
SELECT count(*) FROM t;
```

5000 列會讓 B-tree 有多層，`PageStack` 的深度大於 1。全表掃描會走訪所有 leaf page。

觀察 dirty page 與 commit：

```sql
BEGIN;
UPDATE t SET v = 'changed' WHERE id < 100;
COMMIT;
```

UPDATE 讓相關 page 變 dirty，COMMIT 時按 page 編號順序寫進 WAL。

追 source：

```bash
rg -n "pub trait CursorTrait|pub struct BTreeCursor|struct PageStack" core/storage/btree.rs
rg -n "fn rewind\(&mut self\)|fn next\(&mut self\)|fn seek\(" core/storage/btree.rs
rg -n "pub struct Pager \{|fn read_page|fn add_dirty|fn allocate_page" core/storage/pager.rs
```

---

## 自我檢查

1. `CursorTrait` 的方法為什麼幾乎都回傳 `Result<IOResult<T>>`？連 `next()` 都需要嗎？
2. `blob_read_column` 為什麼要提供一個回傳錯誤的預設實作，而不是讓每個實作者自己寫？
3. 寫入前為什麼要通知其他 cursor？rowid 未知時為什麼要「保守假設是任何一列」？
4. `usable_space_cached` 快取了一個理論上可變的值。註解給了什麼安全論證？
5. `going_upwards` 這個旗標為什麼只有 index B-tree 需要？table B-tree 為什麼不用？
6. `BTreeCursor` 有六個獨立的狀態機欄位。為什麼 `overflow_state` 不能和 `state` 共用？
7. `PageStack` 為什麼要保存整條路徑，而不是只記住當前的 leaf page？
8. `node_states` 的 `-1` 和 `cell_count` 分別代表什麼？用「越界一格」表示邊界的好處是什麼？
9. `PageStack.stack` 為什麼是固定大小陣列而不是 `Vec`？除了效能還有什麼好處？
10. `rewind` 為什麼要在 yield **之前**更新 `rewind_state`？順序反過來會怎樣？
11. `rewind` 完成時為什麼要把狀態重置回 `Start`？忘記重置會發生什麼？
12. `pending_reads` 解決什麼問題？為什麼同步的程式碼不會遇到這個問題？
13. `dirty_pages` 為什麼用 bitmap 而不是 `HashSet`？「naturally sorted」帶來什麼好處？
14. `schema_cookie` 明明是 32-bit，為什麼用 `AtomicU64` 存？

---

下一篇 `07a-source-code-learn-wal-transactions.md`：WAL 的結構、交易的 begin/commit/rollback、checkpoint。
