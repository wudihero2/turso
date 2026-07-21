# 06c. 源碼精讀：B-tree Balancing——Page 分裂與重新分配

`06b-source-code-learn-btree-cursor-pager.md` 講了 cursor 如何移動，但刻意跳過了 balancing，只說「第一輪先不要看」。本篇補上這個坑。

**這是整個 storage 層最難的部分**，也是最容易寫出資料損毀 bug 的地方。B-tree 的正確性——所有 page 都保持有序、所有指標都有效、沒有 page 洩漏——全繫於這段程式碼。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 75–90 分鐘（約 18k 字，其中 39% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 前置知識

| 概念 | 出處 |
|---|---|
| page 佈局、cell pointer array、free space | `06a-source-code-learn-file-format-pages.md` |
| `PageStack`、cursor 位置 | `06b-source-code-learn-btree-cursor-pager.md` |
| `return_if_io!`、狀態機重入 | `07b-source-code-learn-ioresult-reentry.md` |

---

## 為什麼需要 balancing

`06a-source-code-learn-file-format-pages.md` 講過 page 的佈局：cell pointer array 從前往後長，cell content 從後往前長。兩者相遇就是**滿了**。

插入時如果放不下，就必須：

1. 找幾個相鄰的 page（siblings）
2. 把它們的 cell 全部收集起來
3. 重新平均分配到（可能不同數量的）page 上
4. 更新父節點的 divider cell 與指標

**這個過程叫 balancing**，SQLite 的 `balance_nonroot()` 是它最著名的實作（也是 SQLite 原始碼裡註解最多的函式之一）。

---

## 進入點：什麼時候需要 balance

**`core/storage/btree.rs:2975-2986`** — 完整貼出函式註解：

```rust
    /// Balancing is done when a page overflows.
    /// see e.g. https://en.wikipedia.org/wiki/B-tree
    ///
    /// This is a naive algorithm that doesn't try to distribute cells evenly by content.
    /// It will try to split the page in half by keys not by content.
    /// Sqlite tries to have a page at least 40% full.
    ///
    /// `balance_ancestor_at_depth` specifies whether to balance an ancestor page at a specific depth.
    /// If `None`, balancing stops when a level is encountered that doesn't need balancing.
    /// If `Some(depth)`, the page on the stack at depth `depth` will be rebalanced after balancing the current page.
    #[cfg_attr(debug_assertions, instrument(skip(self), level = Level::DEBUG))]
    fn balance(&mut self, balance_ancestor_at_depth: Option<usize>) -> Result<IOResult<()>> {
```

註解很誠實地標示了與 SQLite 的差距：

> This is a **naive** algorithm that doesn't try to distribute cells evenly **by content**. It will try to split the page in half **by keys not by content**. Sqlite tries to have a page at least 40% full.

**按「cell 數量」平分，而不是按「位元組數」平分。** 如果 cell 大小差異很大（有的 10 bytes、有的 500 bytes），按數量分會造成一邊很空、一邊接近滿。

這不是正確性問題，是**空間效率**問題——會讓檔案比 SQLite 產生的稍大、B-tree 稍深。把已知的簡化寫進註解，比假裝它和 SQLite 一樣好。

`balance_ancestor_at_depth` 這個參數則處理**串聯分裂**：子節點分裂會往父節點插入一個 divider cell，父節點可能因此也滿了，需要繼續往上分裂。

### 判斷是否需要 balance

**`core/storage/btree.rs:2996-3029`** — 完整貼出：

```rust
                BalanceSubState::Start => {
                    turso_assert!(
                        balance_info.is_none(),
                        "BalanceInfo should be empty on start"
                    );
                    let current_page = self.stack.top_ref();
                    let next_balance_depth =
                        balance_ancestor_at_depth.unwrap_or_else(|| self.stack.current());
                    {
                        // check if we don't need to balance
                        // don't continue if:
                        // - current page is not overfull root
                        // OR
                        // - current page is not overfull and the amount of free space on the page
                        // is less than 2/3rds of the total usable space on the page
                        //
                        // https://github.com/sqlite/sqlite/blob/0aa95099f5003dc99f599ab77ac0004950b281ef/src/btree.c#L9064-L9071
                        let page = current_page.get_contents();
                        let free_space = compute_free_space(page, usable_space)?;
                        let this_level_is_already_balanced = page.overflow_cells.is_empty()
                            && (!self.stack.has_parent() || free_space * 3 <= usable_space * 2);
                        if this_level_is_already_balanced {
                            if self.stack.current() > next_balance_depth {
                                while self.stack.current() > next_balance_depth {
                                    // Even though this level is already balanced, we know there's an upper level that needs balancing.
                                    // So we pop the stack and continue.
                                    self.stack.pop();
                                }
                                continue;
                            }
                            // Otherwise, we're done.
                            *sub_state = BalanceSubState::Start;
                            return Ok(IOResult::Done(()));
                        }
                    }
```

**兩個觸發條件**：

```rust
                        let this_level_is_already_balanced = page.overflow_cells.is_empty()
                            && (!self.stack.has_parent() || free_space * 3 <= usable_space * 2);
```

- **`overflow_cells` 非空** → page 塞不下，必須分裂。（這裡的 "overflow cell" 是「暫時放不進 page 的 cell」，不是 `06a` 講的 overflow page。同名不同義，容易混淆。）
- **free space > 2/3** → page 太空，應該和鄰居合併。

第二個條件是**下溢**（underflow）處理。刪除大量資料後，如果不合併，B-tree 會退化成一堆幾乎空的 page，掃描時要讀很多 page 卻拿不到多少資料。

註解裡直接給了 SQLite 對應程式碼的 **permalink**（含 commit hash）。這是很好的實踐：相容性實作應該能指出「我對照的是哪一版」。

`free_space * 3 <= usable_space * 2` 是避免浮點數的整數寫法（等價於 `free_space / usable_space <= 2/3`）。**在正確性關鍵路徑上避免浮點比較**是好習慣。

注意 root page 的特例：`!self.stack.has_parent()`。root 沒有兄弟可以合併，所以不套用下溢規則——root 可以很空。

### 已平衡但仍要往上走

```rust
                            if self.stack.current() > next_balance_depth {
                                while self.stack.current() > next_balance_depth {
                                    // Even though this level is already balanced, we know there's an upper level that needs balancing.
                                    // So we pop the stack and continue.
                                    self.stack.pop();
                                }
                                continue;
                            }
```

即使當前層已平衡，如果呼叫者指定了要平衡某個祖先（`balance_ancestor_at_depth`），就 pop 到那一層繼續。

**`self.stack.pop()` 就是 `06b` 講的 `PageStack`**——cursor 的位置路徑。balancing 過程中會沿著這條路徑往上走。

---

## 狀態機：八個子狀態

**`core/storage/btree.rs:270-297`** — 完整貼出：

```rust
enum BalanceSubState {
    #[default]
    Start,
    BalanceRoot,
    Decide,
    Quick,
    /// Choose which sibling pages to balance (max 3).
    /// Generally, the siblings involved will be the page that triggered the balancing and its left and right siblings.
    /// The exceptions are:
    /// 1. If the leftmost page triggered balancing, up to 3 leftmost pages will be balanced.
    /// 2. If the rightmost page triggered balancing, up to 3 rightmost pages will be balanced.
    NonRootPickSiblings,
    /// Perform the actual balancing. This will result in 1-5 pages depending on the number of total cells to be distributed
    /// from the source pages.
    NonRootDoBalancing,
    NonRootDoBalancingAllocate {
        i: usize,
        context: Option<BalanceContext>,
    },
    NonRootDoBalancingFinish {
        context: BalanceContext,
    },
    /// Free pages that are not used anymore after balancing.
    FreePages {
        curr_page: usize,
        sibling_count_new: usize,
    },
}
```

**八個狀態，全部是因為「這一步可能 I/O」而存在**（`07b-source-code-learn-ioresult-reentry.md`）。

註解裡的兩個數字定義了演算法的規模：

**「最多 3 個 sibling」** —— 通常是「觸發分裂的 page + 左鄰 + 右鄰」。邊界情況（最左或最右的 page）就取那一側的三個。

**「產生 1-5 個 page」** —— 3 個來源 page 的 cell 重新分配後，可能變成 1 到 5 個 page。

- 變**少**（3→1 或 3→2）：下溢合併的情況。
- 變**多**（3→4 或 3→5）：cell 太多需要分裂。

**為什麼是 3 而不是 2？** 只看兩個 sibling 的話，分裂後兩個 page 都會是半滿，很快又要再分裂。取三個重新分配，能讓每個 page 更接近滿，減少後續的分裂次數。這是 SQLite 的選擇，Turso 沿用。

`NonRootDoBalancingAllocate { i, ... }` 帶著 `i` —— 因為配置新 page 要一個一個來，每次都可能 I/O，所以要記住「已經配置到第幾個」。

`FreePages { curr_page, sibling_count_new }` —— 如果重新分配後用的 page 比原本少，多餘的要還給 freelist（`06a-source-code-learn-file-format-pages.md`）。**這一步不能漏，否則 page 洩漏**：檔案裡有永遠不會被使用、也不會被回收的空間。

---

## BalanceState：為什麼要保存這些東西

**`core/storage/btree.rs:299-319`** — 完整貼出：

```rust
#[derive(Debug, Default)]
struct BalanceState {
    sub_state: BalanceSubState,
    balance_info: Option<BalanceInfo>,
    /// Reusable buffers for divider cell payloads.
    /// These persist across balance operations to avoid repeated allocations.
    /// We use Vec<u8> with clear/resize instead of allocating new each time.
    reusable_divider_buffers: [Vec<u8>; MAX_SIBLING_PAGES_TO_BALANCE - 1],
    /// Reusable Vec for CellArray cell_payloads to avoid per-balance allocation.
    /// Cleared before each use; grows as needed and retains capacity across operations.
    reusable_cell_payloads: Vec<&'static mut [u8]>,
    /// Disk-read completions accumulated during the sibling-load loop in
    /// `NonRootPickSiblings`. We persist them in `BalanceState` (rather than
    /// in a local `CompletionGroup`) so that when the loop yields for spill
    /// IO and is re-entered, completions from earlier iterations are not
    /// lost — they would otherwise leak: the IO is still in flight, but we
    /// would no longer have a handle to wait on them before reading page
    /// contents in `NonRootDoBalancing`. Cleared when the loop completes
    /// and transitions to `NonRootDoBalancing`.
    pending_sibling_load_completions: Vec<Completion>,
}
```

三組欄位，各有各的理由。

### 可重用緩衝區

`reusable_divider_buffers` 和 `reusable_cell_payloads` 是**效能最佳化**：balancing 每次都需要暫存 divider cell 的內容與所有 cell 的指標，如果每次都重新配置 `Vec`，在寫入密集的工作負載下會產生大量配置。

保留容量、只 `clear()` 不釋放，就能重複使用。

`reusable_cell_payloads: Vec<&'static mut [u8]>` 那個 `'static` 又出現了（`06a` 講過 `TableLeafCell.payload` 也是）。同樣是繞過 lifetime 檢查的手法——實際生命週期由 page pin 機制保證。**在這種手動管理的地方，任何 page 被提早 evict 都會造成 use-after-free。**

### pending_sibling_load_completions：一個真實的洩漏修復

這個欄位的註解是本篇最值得細讀的一段：

> We persist them in `BalanceState` (rather than in a local `CompletionGroup`) so that when the loop yields for spill IO and is re-entered, completions from earlier iterations are not lost — **they would otherwise leak**: the IO is still in flight, but we would no longer have a handle to wait on them before reading page contents.

情境是這樣：

1. `NonRootPickSiblings` 要載入 3 個 sibling page。
2. 對每個 page 發出讀取，收集 completion。
3. 載入第 2 個時，page cache 滿了，需要 spill（把 dirty page 寫出去騰空間）。
4. spill 是 I/O，於是 **yield**。
5. 重入後從頭跑這個迴圈。

**如果 completion 存在區域變數裡，第 4 步 return 時它們就被 drop 了。**

但那些讀取**還在進行中**——kernel 那側的 I/O 沒有停止，它會寫入我們的 page buffer。我們卻失去了等待它們的把手。

後果是 `NonRootDoBalancing` 讀取 page 內容時，**可能讀到還沒填完的資料**——B-tree 會被建構在垃圾資料上，造成資料損毀。

解法是把 completion 存進狀態機，跨越 yield 保留。這正好呼應 `07b-source-code-learn-ioresult-reentry.md` 講的 `CompletionGroup` 取消問題：

> 取消一組 I/O 不能只是丟掉 handle。kernel 那邊的操作可能還在進行中。

**這是「重入正確性」在最底層的具體後果**：不是邏輯錯誤，而是記憶體與資料的損毀。

---

## balance_root：樹長高的唯一方式

root page 的分裂和其他 page 不同——**root 的 page 編號不能變**，因為 `sqlite_schema` 裡記著它（`05-source-code-learn-schema-values-records.md` 講的 `BTreeTable.root_page`）。

如果 root 分裂時換了 page 編號，所有 schema 記錄都要更新——不可行。

**`core/storage/btree.rs:4967-4982`** — 完整貼出：

```rust
    fn balance_root(&mut self) -> Result<IOResult<()>> {
        /* todo: balance deeper, create child and copy contents of root there. Then split root */
        /* if we are in root page then we just need to create a new root and push key there */

        // Since we are going to change the btree structure, let's forget our cached knowledge of the rightmost page.
        let _ = self.move_to_right_state.1.take();

        let root = self.stack.top();
        let root_contents = root.get_contents();
        let child = return_if_io!(self.pager.do_allocate_page(
            root_contents.page_type()?,
            0,
            BtreePageAllocMode::Any
        ));

        let is_page_1 = root.get().id == 1;
        let offset = if is_page_1 { DatabaseHeader::SIZE } else { 0 };
```

**解法是把 root 的內容「下推」到一個新的子 page**：

```text
分裂前:                分裂後:
   root(page 2)          root(page 2)   ← 編號不變，變成 interior
   [所有 cell]                 ↓
                         child(page 7)  ← 新配置，接收原本的內容
                         [所有 cell]
```

**這是 B-tree 長高的唯一方式**——所有其他 page 的分裂都是橫向增加同層的 page 數，只有 root 分裂會增加樹的深度。

第一行的清理值得注意：

```rust
        // Since we are going to change the btree structure, let's forget our cached knowledge of the rightmost page.
        let _ = self.move_to_right_state.1.take();
```

**快取的結構資訊在結構改變時必須作廢。** cursor 快取了「最右邊的 page 是哪個」（用於 append 最佳化），但 root 分裂後這個資訊可能失效。

這類「改結構前先清快取」的動作在 balancing 裡到處都是，漏掉一個就會讀到過期的位置。

### page 1 的特殊處理

```rust
        let is_page_1 = root.get().id == 1;
        let offset = if is_page_1 { DatabaseHeader::SIZE } else { 0 };
        #[cfg(debug_assertions)]
        turso_assert_eq!(offset, root_contents.offset());
```

`06a-source-code-learn-file-format-pages.md` 講過 page 1 前 100 bytes 是 database header。所以複製內容時要從 offset 100 開始，不能覆寫 header。

`turso_assert_eq!(offset, root_contents.offset())` 是**交叉驗證**：手算的 offset 應該和 `PageInner::offset()` 一致。debug build 才檢查，release 零成本。

**這種「同一個值用兩種方式算出來然後比對」的斷言**，在容易算錯的地方很有價值。

### 前置條件斷言

**`core/storage/btree.rs:5005-5010`** — 完整貼出：

```rust
        turso_assert!(root.is_dirty(), "root must be marked dirty");
        turso_assert!(
            child.is_dirty(),
            "child must be marked dirty as freshly allocated page"
        );
```

**兩個 page 都必須已經被標記為 dirty**，否則修改不會被寫進 WAL——修改會靜默遺失，crash 後 B-tree 結構就壞了。

這符合專案原則：**斷言不變量，不要用 if 靜默容錯**。如果沒 dirty，那是呼叫者的 bug，應該立刻爆。

### 實際的複製

**`core/storage/btree.rs:5012-5030`** — 完整貼出：

```rust
        let root_buf = root_contents.as_ptr();
        let child_contents = child.get_contents();
        let child_buf = child_contents.as_ptr();
        let (root_pointer_start, root_pointer_len) =
            root_contents.cell_pointer_array_offset_and_size();
        let (child_pointer_start, _) = child.get_contents().cell_pointer_array_offset_and_size();

        let top = root_contents.cell_content_area() as usize;

        // 1. Modify child
        // Copy pointers
        child_buf[child_pointer_start..child_pointer_start + root_pointer_len]
            .copy_from_slice(&root_buf[root_pointer_start..root_pointer_start + root_pointer_len]);
        // Copy cell contents
        child_buf[top..].copy_from_slice(&root_buf[top..]);
        // Copy header
        child_buf[0..root_contents.header_size()]
            .copy_from_slice(&root_buf[offset..offset + root_contents.header_size()]);
        // Copy overflow cells
        std::mem::swap(
            &mut child_contents.overflow_cells,
```

**三段複製，對應 `06a` 講的 page 三個區域**：

1. **cell pointer array**（從前面）
2. **cell content area**（`top` 到 page 尾端）
3. **page header**

注意 header 的來源是 `root_buf[offset..]` —— 用了前面算的 offset，跳過 page 1 的 database header。而目標是 `child_buf[0..]` —— 子 page 不是 page 1，沒有 header 要跳過。

**這種「來源和目標的偏移量不同」是最容易寫錯的地方**，而且錯了不會 crash，只會產生結構錯誤的 page。

`std::mem::swap(&mut child_contents.overflow_cells, ...)` —— 連「暫時放不下的 cell」也要一起轉移給子 page，因為接下來要對子 page 做正常的 balancing。

---

## 完整流程

```text
insert 發現 page 放不下
  └─ cursor.balance(None)              core/storage/btree.rs:2986
       │
       ├─ Start:  檢查是否需要 balance
       │            overflow_cells 非空 → 需要（上溢）
       │            free_space > 2/3    → 需要（下溢）
       │            都不是 → Done
       │
       ├─ 沒有 parent（是 root）→ BalanceRoot   core/storage/btree.rs:4967
       │     ├─ 配置新 child page
       │     ├─ 把 root 的三個區域全部複製到 child
       │     ├─ root 變成只有一個指標的 interior page
       │     └─ 樹長高一層
       │
       └─ 有 parent → Decide → NonRootPickSiblings
            ├─ 選最多 3 個 sibling
            ├─ 讀取它們的內容（completion 存進 BalanceState）
            ├─ NonRootDoBalancing
            │     收集所有 cell，計算要分成幾個 page
            ├─ NonRootDoBalancingAllocate { i }
            │     逐一配置新 page（每次可能 I/O）
            ├─ NonRootDoBalancingFinish
            │     寫入 cell、更新父節點的 divider
            └─ FreePages
                  多餘的 page 還給 freelist
                      │
                      └─ 父節點可能因新 divider 而滿 → 迴圈回 Start，往上一層
```

---

## 為什麼這裡的 bug 特別可怕

`09-source-code-learn-reading-projects.md` 提過「資料小時對、大時錯」通常指向重入 bug。**balancing 是這個症狀最典型的來源**：

- 小資料不會讓 page 滿，`balance` 根本不會被呼叫。
- 大資料才會觸發，而且要 page cache 滿到需要 spill 才會走到那些 yield 路徑。

而且 balancing 的 bug **不會立刻顯現**。寫壞的 B-tree 可能要等到很久以後、某個特定的查詢走到那個 page 才爆出來——那時已經很難追溯是哪次寫入造成的。

這就是為什麼專案有這些機制（`08-source-code-learn-extensions-sync-testing.md`）：

- **`.sqltest` 的 `@cross-check-integrity`** —— 每個測試後跑完整性檢查。
- **`core/io/memory_yield.rs`** —— 強制每次 I/O 都 yield，讓小資料也能走到重入路徑。
- **`testing/simulator/`** —— 確定性重現特定的 I/O 交錯。
- **`tools/dbhash`** —— 比對兩個資料庫的內容是否一致。

**如果你要修改 balancing，這些測試不是可選的。**

---

## 動手驗證

觸發 page 分裂與樹長高：

```bash
cd /Users/stanhsu/projects/turso
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
PRAGMA page_count;

INSERT INTO t SELECT value, 'row' || value FROM generate_series(1, 100);
PRAGMA page_count;

INSERT INTO t SELECT value, 'row' || value FROM generate_series(101, 10000);
PRAGMA page_count;
PRAGMA integrity_check;
```

`page_count` 從 2 開始逐步增長。10000 列時 B-tree 至少有兩層——過程中 `balance_root` 至少被呼叫過一次。

`integrity_check` 驗證 balancing 的結果是正確的 B-tree。

觸發下溢合併：

```sql
DELETE FROM t WHERE id > 100;
PRAGMA freelist_count;
PRAGMA integrity_check;
```

`freelist_count` 增加，代表 balancing 把空出來的 page 還給了 freelist（`FreePages` 狀態）。

用 SQLite 交叉驗證結構：

```bash
sqlite3 /tmp/test.db "PRAGMA integrity_check;"
```

sqlite3 能通過完整性檢查，就證明 Turso 產生的 B-tree 結構完全符合格式規範。

追 source：

```bash
rg -n "fn balance\b|fn balance_root|fn balance_non_root" core/storage/btree.rs
rg -n "enum BalanceSubState|struct BalanceState" core/storage/btree.rs
rg -n "MAX_SIBLING_PAGES_TO_BALANCE" core/storage/btree.rs
```

---

## 自我檢查

1. Turso 的 balancing 按「cell 數量」平分而不是按「位元組數」。這造成什麼影響？是正確性問題嗎？
2. 觸發 balancing 的兩個條件是什麼？第二個條件在處理什麼情況？
3. `free_space * 3 <= usable_space * 2` 為什麼不寫成浮點除法？
4. root page 為什麼不套用下溢（free space > 2/3）規則？
5. 這裡的 "overflow cell" 和 `06a` 講的 "overflow page" 是同一件事嗎？
6. 為什麼選 3 個 sibling 而不是 2 個？
7. 3 個來源 page 為什麼會產生「1 到 5 個」page？什麼情況變少、什麼情況變多？
8. `FreePages` 狀態如果漏掉會發生什麼？
9. `pending_sibling_load_completions` 為什麼必須存在狀態機裡而不是區域變數？不存會造成什麼後果？
10. `reusable_cell_payloads` 的 `&'static mut [u8]` 顯然不是真的 static。它靠什麼保證安全？如果 page 被提早 evict 會怎樣？
11. root page 分裂為什麼不能直接產生兩個新 page？限制來自哪裡？
12. `balance_root` 是 B-tree 的哪個維度成長的唯一途徑？
13. `move_to_right_state.1.take()` 在清什麼？為什麼結構改變前必須清？
14. `turso_assert_eq!(offset, root_contents.offset())` 這個斷言在驗證什麼？為什麼有價值？
15. 複製 header 時，來源用 `root_buf[offset..]` 而目標用 `child_buf[0..]`。為什麼偏移量不同？
16. 為什麼 balancing 的 bug 特別難發現？專案用哪些機制來抓它們？

---

## 06 系列結束

- `06a` —— 磁碟上的 bytes（header、page type、cell、overflow）
- `06b` —— cursor 如何移動、Pager 如何管理 page
- `06c` —— B-tree 結構如何在寫入時維持平衡

接下來 `07a-source-code-learn-wal-transactions.md` 講這些修改如何安全地持久化。
