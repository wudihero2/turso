# 06a. 源碼精讀：SQLite 檔案格式與 Page 佈局

本篇對應 `06a-file-format-pages.md`，只讀磁碟上的 bytes 長什麼樣。**cursor 如何走樹留給 `06b`**。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 60–75 分鐘（約 15k 字，其中 42% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/storage/sqlite3_ondisk.rs
  ├─ DatabaseHeader   檔案前 100 bytes
  ├─ PageType         四種 B-tree page
  └─ BTreeCell        四種 cell 結構
core/storage/btree.rs
  └─ offset module    B-tree page header 的欄位偏移量
core/storage/pager.rs
  └─ PageInner::offset  page 1 的特殊處理
```

**本篇的核心觀念**：資料庫檔案就是一串固定大小的 page。所有的表、索引、schema 都用同一套 page 機制儲存，差別只在 page 內部的解讀方式。

---

## DatabaseHeader：檔案的前 100 bytes

**`core/storage/sqlite3_ondisk.rs:312-357`** — 完整貼出（註解就是格式規格）：

```rust
pub struct DatabaseHeader {
    /// b"SQLite format 3\0"
    pub magic: [u8; 16],
    /// Page size in bytes. Must be a power of two between 512 and 32768 inclusive, or the value 1 representing a page size of 65536.
    pub page_size: PageSize,
    /// File format write version. 1 for legacy; 2 for WAL.
    pub write_version: RawVersion,
    /// File format read version. 1 for legacy; 2 for WAL.
    pub read_version: RawVersion,
    /// Bytes of unused "reserved" space at the end of each page. Usually 0.
    pub reserved_space: u8,
    /// Maximum embedded payload fraction. Must be 64.
    pub max_embed_frac: u8,
    /// Minimum embedded payload fraction. Must be 32.
    pub min_embed_frac: u8,
    /// Leaf payload fraction. Must be 32.
    pub leaf_frac: u8,
    /// File change counter.
    pub change_counter: U32BE,
    /// Size of the database file in pages. The "in-header database size".
    pub database_size: U32BE,
    /// Page number of the first freelist trunk page.
    pub freelist_trunk_page: U32BE,
    /// Total number of freelist pages.
    pub freelist_pages: U32BE,
    /// The schema cookie.
    pub schema_cookie: U32BE,
    /// The schema format number. Supported schema formats are 1, 2, 3, and 4.
    pub schema_format: U32BE,
    /// Default page cache size.
    pub default_page_cache_size: CacheSize,
    /// The page number of the largest root b-tree page when in auto-vacuum or incremental-vacuum modes, or zero otherwise.
    pub vacuum_mode_largest_root_page: U32BE,
    /// Text encoding.
    pub text_encoding: TextEncoding,
    /// The "user version" as read and set by the user_version pragma.
    pub user_version: I32BE,
    /// True (non-zero) for incremental-vacuum mode. False (zero) otherwise.
    pub incremental_vacuum_enabled: U32BE,
    /// The "Application ID" set by PRAGMA application_id.
    pub application_id: I32BE,
    /// Reserved for expansion. Must be zero.
    _padding: [u8; 20],
    /// The version-valid-for number.
    pub version_valid_for: U32BE,
    /// SQLITE_VERSION_NUMBER
```

這個 struct 是**直接對應磁碟位元組佈局**的，不是一般的 Rust struct。幾個關鍵設計：

**`U32BE` / `I32BE` 而非 `u32` / `i32`。** SQLite 檔案格式規定用 **big-endian**，但主流 CPU 是 little-endian。這些包裝型別在讀取時做位元組序轉換，讓格式與平台無關——同一個資料庫檔案可以在任何機器上開啟。

**`_padding: [u8; 20]`。** 明確保留的空間。格式規格說「必須為零」，所以必須佔位，不能省略。

**編譯期的大小驗證**：

**`core/storage/sqlite3_ondisk.rs:361-372`** — 完整貼出：

```rust
impl DatabaseHeader {
    pub const PAGE_ID: usize = 1;
    pub const SIZE: usize = size_of::<Self>();

    const _CHECK: () = {
        assert!(Self::SIZE == 100);
    };

    pub fn usable_space(self) -> usize {
        (self.page_size.get() as usize) - (self.reserved_space as usize)
    }
}
```

`const _CHECK` 是**編譯期斷言**：如果有人加了欄位或改了型別，導致 struct 不再是剛好 100 bytes，**編譯就會失敗**。

這是很強的保護。檔案格式的正確性不能靠人記得，要靠編譯器。100 這個數字是 SQLite 規格寫死的——多一個 byte 或少一個 byte，寫出的檔案 SQLite 就讀不了。

### 幾個欄位的實際意義

**`page_size`** —— 註解提到一個怪異之處：「the value 1 representing a page size of 65536」。因為 page_size 欄位只有 2 bytes，最大存 65535，放不下 65536。SQLite 的解法是用 1 這個不可能的值來表示 65536。**格式相容性就是由這類 hack 組成的。**

**`write_version` / `read_version`** —— 1 是舊式 rollback journal，2 是 WAL。這兩個欄位讓舊版本的 SQLite 知道「這個檔案我讀不讀得懂」。

**`change_counter`** —— 每次寫入就遞增。其他 connection 靠它判斷「檔案變過了，我的快取要作廢」。

**`schema_cookie`** —— schema 版本。`01-source-code-learn-4-step-vm.md` 講的 reprepare 機制、`05-source-code-learn-schema-values-records.md` 講的 `Schema.schema_version` 都對應到它。

**`freelist_trunk_page` / `freelist_pages`** —— 已釋放可重用的 page 鏈。刪除資料時 page 不還給作業系統，而是掛進 freelist 等待重用。

**`usable_space()`** —— `page_size - reserved_space`。`reserved_space` 是每個 page 尾端保留的空間，加密或校驗和擴充會用到。**所有 page 內部的計算都必須用 usable space 而不是 page size**，否則會寫進保留區。

### Page 1 的雙重身分

**`core/storage/pager.rs:170-176`** — 完整貼出：

```rust
    pub fn offset(&self) -> usize {
        if self.id == 1 {
            DatabaseHeader::SIZE
        } else {
            0
        }
    }
```

**Page 1 同時是 database header 和 `sqlite_schema` 的 B-tree root page。** 前 100 bytes 是 header，之後才是 B-tree 內容。

所以讀 page 1 的 B-tree 部分時，所有偏移量都要加 100。這個函式就是那個修正。

**`core/storage/pager.rs:178-180`** — 節錄：

```rust
    /// Read a u8 from the page content at the given offset, taking account the possible db header on page 1.
    #[inline]
    fn read_u8(&self, pos: usize) -> u8 {
```

存取方法把這個修正封裝起來，呼叫者不必每次記得加 100。**把容易忘記的修正封裝進存取器**，是避免這類 off-by-100 bug 的標準做法。

---

## PageType：四種 B-tree page

**`core/storage/sqlite3_ondisk.rs:506-520`** — 完整貼出：

```rust
pub enum PageType {
    IndexInterior = 2,
    TableInterior = 5,
    IndexLeaf = 10,
    TableLeaf = 13,
}

impl PageType {
    pub fn is_table(&self) -> bool {
        match self {
            PageType::IndexInterior | PageType::IndexLeaf => false,
            PageType::TableInterior | PageType::TableLeaf => true,
        }
    }
}
```

這四個數值（2、5、10、13）是**寫進磁碟的**，是 SQLite 格式規定的，不能改。

兩個維度交叉：

|  | Interior（內部節點） | Leaf（葉節點） |
|---|---|---|
| **Table** | 5 | 13 |
| **Index** | 2 | 10 |

- **Table vs Index** —— key 不同。table 用 rowid（整數），index 用欄位值組合。
- **Interior vs Leaf** —— interior 只有導航資訊（key + 子 page 指標），leaf 才有實際資料。

除了這四種，檔案裡還有 **overflow page** 和 **freelist page**。它們沒有 page type 欄位，因為不是 B-tree page——只有從 B-tree 或 freelist 的鏈結才能找到它們，不需要自我描述。

---

## B-tree page header

**`core/storage/btree.rs:84-124`** — 完整貼出（註解是本節的主要內容）：

```rust
pub mod offset {
    /// Type of the B-Tree page (u8).
    pub const BTREE_PAGE_TYPE: usize = 0;

    /// A pointer to the first freeblock (u16).
    ///
    /// This field of the B-Tree page header is an offset to the first freeblock, or zero if
    /// there are no freeblocks on the page.  A freeblock is a structure used to identify
    /// unallocated space within a B-Tree page, organized as a chain.
    ///
    /// Please note that freeblocks do not mean the regular unallocated free space to the left
    /// of the cell content area pointer, but instead blocks of at least 4
    /// bytes WITHIN the cell content area that are not in use due to e.g.
    /// deletions.
    pub const BTREE_FIRST_FREEBLOCK: usize = 1;

    /// The number of cells in the page (u16).
    pub const BTREE_CELL_COUNT: usize = 3;

    /// A pointer to the first byte of cell allocated content from top (u16).
    ///
    /// A zero value for this integer is interpreted as 65,536.
    /// If a page contains no cells (which is only possible for a root page of a table that
    /// contains no rows) then the offset to the cell content area will equal the page size minus
    /// the bytes of reserved space. If the database uses a 65536-byte page size and the
    /// reserved space is zero (the usual value for reserved space) then the cell content offset of
    /// an empty page wants to be 6,5536
    ///
    /// SQLite strives to place cells as far toward the end of the b-tree page as it can, in
    /// order to leave space for future growth of the cell pointer array. This means that the
    /// cell content area pointer moves leftward as cells are added to the page.
    pub const BTREE_CELL_CONTENT_AREA: usize = 5;

    /// The number of fragmented bytes (u8).
    ///
    /// Fragments are isolated groups of 1, 2, or 3 unused bytes within the cell content area.
    pub const BTREE_FRAGMENTED_BYTES_COUNT: usize = 7;

    /// The right-most pointer (saved separately from cells) (u32)
    pub const BTREE_RIGHTMOST_PTR: usize = 8;
}
```

header 只有 8 bytes（leaf page）或 12 bytes（interior page，多了 rightmost pointer）。

### Page 內部的空間佈局

這是本篇最重要的一張圖：

```text
┌─────────────────────────────────────────────────┐
│ B-tree page header (8 或 12 bytes)              │
├─────────────────────────────────────────────────┤
│ cell pointer array  →→→ 由前往後成長             │
│ (每個 cell 一個 u16 偏移量)                      │
├─────────────────────────────────────────────────┤
│                                                 │
│              未使用的自由空間                     │
│                                                 │
├─────────────────────────────────────────────────┤
│ ←←← cell content area  由後往前成長              │
│ (實際的 cell 資料)                               │
└─────────────────────────────────────────────────┘
                                    page 尾端
```

**兩端往中間長。** 註解說明了為什麼：

> SQLite strives to place cells as far toward the end of the b-tree page as it can, in order to leave space for future growth of the cell pointer array.

cell 內容盡量往後放，讓前面的指標陣列有成長空間。兩者相遇時，這個 page 就滿了，需要分裂。

**為什麼要有 cell pointer array？** 因為 cell 大小不一（record 長度不同），無法用固定索引定位。而且 **cell 在 page 裡的實體順序不必等於邏輯順序**——插入新 cell 時，只要把它放進任何有空間的地方，然後在指標陣列的正確位置插入偏移量即可。排序由指標陣列維持，內容不必搬動。

### 三種「空閒空間」

這是新手最容易混淆的地方，註解特別澄清：

**一、自由空間（free space）** —— 指標陣列與 cell content area 之間那塊連續空間。最容易使用。

**二、freeblock** —— 註解強調：

> freeblocks do not mean the regular unallocated free space to the left of the cell content area pointer, but instead blocks of at least 4 bytes WITHIN the cell content area that are not in use due to e.g. deletions.

刪除 cell 後，它原本佔的空間在 cell content area **中間**留下一個洞。這些洞串成鏈（`BTREE_FIRST_FREEBLOCK` 是鏈頭），可以重複使用。至少要 4 bytes 才值得管理（因為鏈結本身就要 4 bytes）。

**三、fragment** —— 小於 4 bytes 的碎片，太小放不進 freeblock 鏈。只用 `BTREE_FRAGMENTED_BYTES_COUNT` 記個總數，實際上放棄使用。累積太多時，page 需要重整（defragment）。

**這三者要分清楚**，因為「這個 page 還能不能塞下一個 cell」的判斷必須把三者一起算。算錯就會誤判需要分裂（浪費空間）或誤判塞得下（覆寫資料，資料損毀）。

### rightmost pointer

`BTREE_RIGHTMOST_PTR` 只有 interior page 有。

一個有 N 個 key 的 interior 節點，會有 N+1 個子節點。前 N 個子節點指標存在各自的 cell 裡，**最後那個沒有對應的 key**，所以單獨存在 header。

```text
interior page:
  cell[0]: key=10, left_child=page5    → 小於 10 的在 page5
  cell[1]: key=20, left_child=page7    → 10~20 的在 page7
  rightmost_ptr = page9                → 大於 20 的在 page9
```

---

## BTreeCell：四種 cell

**`core/storage/sqlite3_ondisk.rs:774-779`** — 完整貼出：

```rust
pub enum BTreeCell {
    TableInteriorCell(TableInteriorCell),
    TableLeafCell(TableLeafCell),
    IndexInteriorCell(IndexInteriorCell),
    IndexLeafCell(IndexLeafCell),
}
```

對應四種 page type。

**`core/storage/sqlite3_ondisk.rs:781-785`** — 完整貼出：

```rust
#[derive(Debug, Clone)]
pub struct TableInteriorCell {
    pub left_child_page: u32,
    pub rowid: i64,
}
```

最精簡的 cell：只有導航資訊。**沒有 payload**——interior 節點不存資料，只指路。

**`core/storage/sqlite3_ondisk.rs:787-795`** — 完整貼出：

```rust
#[derive(Debug, Clone)]
pub struct TableLeafCell {
    pub rowid: i64,
    /// Payload of cell, if it overflows it won't include overflowed payload.
    pub payload: &'static [u8],
    /// This is the complete payload size including overflow pages.
    pub payload_size: u64,
    pub first_overflow_page: Option<u32>,
}
```

這是實際存資料的 cell。三個欄位需要一起理解：

- **`payload`** —— 註解說明：**只包含存在這個 page 裡的部分**，不含溢出的部分。
- **`payload_size`** —— **完整**大小，含溢出部分。
- **`first_overflow_page`** —— 溢出鏈的第一個 page，`None` 表示沒有溢出。

所以 `payload.len() < payload_size` 就代表有溢出。

**`payload: &'static [u8]` 這個 `'static` 值得注意。** 它顯然不是真的 static 資料——payload 指向 page buffer。這裡用 `'static` 是繞過 lifetime 檢查的手法，實際的生命週期由 pager 的 page 固定（pin）機制保證：只要有 cursor 指著這個 cell，對應的 page 就不會被逐出快取。

**這是一個以正確性換效能的取捨**，也是為什麼 `06b` 會強調 cursor 失效與 page pin 的規則——那些規則就是在保證這個 `'static` 不會說謊。

---

## Overflow page

當 record 太大放不進一個 page，多出來的部分放進 overflow chain：

```text
TableLeafCell:
  payload           = 前面放得下的部分
  first_overflow_page = 100
                          ↓
                    page 100: [next=101][資料...]
                          ↓
                    page 101: [next=0  ][資料...]   next=0 表示結束
```

每個 overflow page 開頭 4 bytes 是下一個 page 的編號，其餘是資料。

**這解釋了 `01-source-code-learn-5-cursor-storage.md` 的一個現象**：`Column` 指令讀一個大欄位時，可能要追好幾個 page，每一次都可能 I/O。所以 `op_column` 必須能處理多次 yield。

「放不放得下」的判斷用的是 header 裡的 `max_embed_frac` / `min_embed_frac` / `leaf_frac`（都必須是 64/32/32）。這幾個值決定「一個 cell 最多能佔 page 的多少比例」——如果每個 cell 都佔滿整個 page，B-tree 就退化成鏈結串列了。

---

## Freelist

刪除資料時，空出來的 page 不還給作業系統，而是掛進 freelist：

```text
DatabaseHeader.freelist_trunk_page → trunk page
                                        ├─ leaf page 編號
                                        ├─ leaf page 編號
                                        └─ next trunk page → ...
```

`freelist_pages` 記總數。需要新 page 時先從 freelist 拿，拿不到才擴充檔案。

**這是為什麼 `DELETE` 通常不會讓檔案變小**——空間被保留供重用。要真的縮小檔案需要 `VACUUM`。

---

## 完整的檔案佈局

```text
byte 0                                    file end
├────────────────────────────────────────────┤
│ page 1 │ page 2 │ page 3 │ ... │ page N    │
└────────────────────────────────────────────┘
   ↑
   前 100 bytes 是 DatabaseHeader
   之後是 sqlite_schema 的 B-tree root

page N 的檔案位置 = (N - 1) * page_size
```

每個 page 可能是：

- B-tree page（四種之一）——屬於某張表或某個索引
- overflow page —— 某個大 record 的續存
- freelist trunk/leaf page —— 待重用
- pointer map page —— 只在 auto-vacuum 模式

**所有的表和索引共用同一個 page 空間**，靠 root page 編號區分。`05-source-code-learn-schema-values-records.md` 講的 `BTreeTable.root_page` 就是這個編號，而它存在 `sqlite_schema` 的 `rootpage` 欄位裡。

---

## 動手驗證

觀察 page 配置：

```bash
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, data TEXT);
PRAGMA page_size;
PRAGMA page_count;
INSERT INTO t VALUES (1, 'small');
PRAGMA page_count;
```

建表後 `page_count` 至少是 2（page 1 是 header + schema，page 2 是 t 的 root）。插入小資料不會增加 page 數。

觸發 overflow：

```sql
INSERT INTO t VALUES (2, printf('%.*c', 50000, 'x'));
PRAGMA page_count;
```

page 數會明顯增加——5 萬 bytes 放不進一個 page（預設 4096），需要十幾個 overflow page。

觀察 freelist：

```sql
DELETE FROM t WHERE id = 2;
PRAGMA freelist_count;
PRAGMA page_count;
```

`freelist_count` 增加（page 被釋放），但 `page_count` **不變**（檔案沒縮小）。這就是 freelist 的行為。

用 sqlite3 交叉驗證格式相容：

```bash
./target/debug/tursodb /tmp/test.db "CREATE TABLE t(a); INSERT INTO t VALUES (1);"
sqlite3 /tmp/test.db "SELECT * FROM t;"
```

sqlite3 能讀 Turso 寫的檔案，就證明格式實作正確。這是 `scripts/diff.sh` 背後的原理。

追 source：

```bash
rg -n "pub struct DatabaseHeader|pub enum PageType|pub enum BTreeCell" core/storage/sqlite3_ondisk.rs
rg -n "pub mod offset" core/storage/btree.rs
rg -n "fn offset\(&self\)" core/storage/pager.rs
```

---

## 自我檢查

1. `const _CHECK` 那個編譯期斷言在防什麼？如果 struct 不是 100 bytes 會發生什麼事？
2. 為什麼欄位型別是 `U32BE` 而不是 `u32`？
3. `page_size` 欄位用 1 表示 65536，為什麼要這樣 hack？
4. Page 1 為什麼特別？`PageInner::offset()` 在修正什麼？
5. 四種 page type 的兩個區分維度是什麼？overflow page 為什麼不在這四種裡？
6. cell pointer array 和 cell content area 為什麼要從兩端往中間長？
7. 為什麼需要 cell pointer array？cell 在 page 裡的實體順序等於邏輯順序嗎？
8. 「自由空間」、「freeblock」、「fragment」三者差在哪？算錯會出什麼問題？
9. interior page 的 rightmost pointer 為什麼要單獨存在 header？
10. `TableLeafCell` 的 `payload.len()` 和 `payload_size` 什麼時候會不相等？
11. `payload: &'static [u8]` 的 `'static` 顯然不是真的。它靠什麼機制保證安全？
12. `usable_space()` 為什麼要扣掉 `reserved_space`？不扣會怎樣？
13. `DELETE` 之後為什麼檔案不會變小？空間跑到哪裡去了？

---

下一篇 `06b-source-code-learn-btree-cursor-pager.md`：cursor 如何在樹裡移動、Pager 如何管理 page 與 cache。
