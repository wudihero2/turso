# 06b. BTreeCursor 與 Pager: 如何走樹與管理 pages

本章目標：在已懂 page layout 後，看 cursor 如何掃描/seek/insert/delete，以及 Pager 如何管理 cache/dirty page/transaction 入口。

## 60 分鐘閱讀範圍

| 時間 | 檔案 | 只讀這些 symbol / 區塊 |
|---:|---|---|
| 10 分鐘 | `core/storage/btree.rs` | `CursorTrait` definition |
| 12 分鐘 | `core/storage/btree.rs` | `BTreeCursor` struct fields，不追所有 state enum |
| 10 分鐘 | `core/storage/btree.rs` | `new_table`、`new_index`、`rewind`、`next`、`seek` 入口 |
| 10 分鐘 | `core/storage/pager.rs` | `Pager` struct fields |
| 8 分鐘 | `core/storage/pager.rs` | `read_page`、`add_dirty`、`allocate_page` 搜尋入口 |
| 5 分鐘 | `core/storage/page_cache.rs` | 只看 cache role，不讀 eviction 細節 |
| 5 分鐘 | 自我檢查 | 用 opcode 對 cursor method |

## 心智模型

```text
VDBE opcode
  -> CursorTrait
  -> BTreeCursor
  -> Pager
  -> PageCache / WAL / DatabaseStorage
```

B-tree cursor 知道「怎麼在樹裡移動」。Pager 知道「page 從哪裡來、是否 dirty、如何提交」。

## CursorTrait

`core/storage/btree.rs` 的 `CursorTrait` 是 VM 看 cursor 的共同介面：

```text
last / next / prev / rewind
rowid
record
seek / seek_unpacked
insert
delete
exists
count
clear_btree
btree_destroy
```

VM opcode 不應該知道 B-tree 的全部細節；它透過 trait 做 cursor operation。

## BTreeCursor

`BTreeCursor` 持有：

- `pager`: page access。
- `root_page`: B-tree root。
- `stack`: traversal path。
- `state`: operation state machine。
- `balance_state`: page split/merge/rebalance state。
- `overflow_state`: overflow page handling。
- reusable record/payload buffers。
- cursor invalidation/peer-save state。

新手讀 B-tree 時，先不要直接看 balancing。第一輪只看：

```text
rewind
next
seek
record
insert
delete
```

等你知道 cursor 如何移動，再看 balance/overflow/freelist。

## Cursor stack

B-tree cursor 需要知道目前走到哪一層 page。Interior node 指向 child page；leaf node 有 record。Cursor stack 保存從 root 到 current page 的 path，讓 `next`、`prev`、delete rebalance 能往上/往下移動。

這跟一般 iterator 不同：B-tree iterator 的位置不是一個 index，而是一條 page path + cell index。

## Pager

`core/storage/pager.rs` 的 `Pager` 是 persistence layer interface。它持有：

- `db_file`: main database storage。
- `wal`: optional WAL。
- `page_cache`: cache pages。
- `dirty_pages`: modified pages bitmap。
- `savepoints`。
- `commit_info`。
- `checkpoint_state`。
- `allocate_page_state`。
- `io`。
- `io_ctx`: encryption/checksum context。
- `cursor_registry`: live BTreeCursors for invalidation。

Pager 負責：

```text
read page
cache page
mark dirty
allocate/free page
begin read/write transaction
commit dirty pages to WAL
rollback
checkpoint
savepoint/subjournal
schema cookie/page size metadata
```

B-tree 不應該自己直接寫檔案。它透過 Pager。

## Page cache

Page cache 讓 B-tree 操作不用每次都讀 disk。第一輪只要知道 cache correctness 的幾個方向：

- WAL snapshot 改變時，舊 page cache 可能失效。
- Dirty page 不能被錯誤 evict。
- Cursor pin page 時，不能在中途被 spill。
- Checkpoint/rollback 後 cache 狀態要一致。

不要在這章讀完整 eviction/spill。這是第二輪性能與 correctness 主題。

## 練習

用 table scan 的 EXPLAIN 對 cursor method：

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO t VALUES (1, 'a'), (2, 'b');
EXPLAIN SELECT name FROM t;
```

預期看到接近這些概念的 opcode：`OpenRead`、`Rewind`、`Column`、`ResultRow`、`Next`。實際輸出可能因版本與 optimizer 改變，但 table scan 一定需要 open cursor、定位第一列、讀 column、前進。

追 source：

```bash
rg -n "pub trait CursorTrait|pub struct BTreeCursor" core/storage/btree.rs
rg -n "fn rewind|fn seek\\(|fn next\\(|fn insert\\(|fn delete\\(" core/storage/btree.rs
rg -n "pub struct Pager|dirty_pages|page_cache|cursor_registry" core/storage/pager.rs
```

## 自我檢查

1. VM 為什麼透過 `CursorTrait`，而不是直接操作 page bytes？
2. `BTreeCursor.stack` 保存的是什麼？
3. Pager 和 BTreeCursor 誰負責 dirty page？
4. 為什麼第一輪不應該從 balancing 開始讀？

