# 06a. File Format 與 Page Layout

本章目標：只讀 SQLite-compatible on-disk format。BTreeCursor 和 Pager 操作放到下一章。

## 60 分鐘閱讀範圍

| 時間 | 檔案 | 只讀這些 symbol / 區塊 |
|---:|---|---|
| 10 分鐘 | `core/storage/mod.rs` | module doc，看 storage 分層 |
| 12 分鐘 | `core/storage/sqlite3_ondisk.rs` | `DatabaseHeader`、`DatabaseHeader::default` |
| 8 分鐘 | `core/storage/sqlite3_ondisk.rs` | `WalHeader`、WAL constants，只建立概念 |
| 10 分鐘 | `core/storage/btree.rs` | `offset` module 的 B-tree page header 註解 |
| 8 分鐘 | `core/storage/sqlite3_ondisk.rs` | `PageType`、`BTreeCell` 相關入口 |
| 7 分鐘 | `core/types.rs` | record/serial value 入口，不追完整比較器 |
| 5 分鐘 | 練習與自我檢查 | 用 PRAGMA 看 page_count |

## 心智模型

Storage 層看到的是：

```text
database file = fixed-size pages
page 1 = database header + sqlite_schema root btree
each table/index = one B-tree rooted at some page number
leaf cells = key + payload
overflow pages = large payload continuation
freelist pages = reusable free pages
```

本章只看 bytes layout，不看 cursor 如何走樹。

## Database header

`core/storage/sqlite3_ondisk.rs` 定義 `DatabaseHeader`。它是檔案前 100 bytes，重要欄位：

```text
magic: "SQLite format 3\0"
page_size
write_version/read_version
reserved_space
change_counter
database_size
freelist trunk/count
schema_cookie
schema_format
text_encoding
user_version
application_id
version_number
```

`DatabaseHeader::PAGE_ID` 是 1，`DatabaseHeader::SIZE` 是 100。Page 1 特別，因為前 100 bytes 是 database header，後面才是 B-tree page content。

這解釋了為什麼 `PageInner::offset()` 對 page 1 回 100，其他 page 回 0。

## Page type

SQLite B-tree page 有四種主要 page type：

```text
0x02 Index interior
0x05 Table interior
0x0a Index leaf
0x0d Table leaf
```

另外還有 overflow page、freelist trunk/leaf page。Turso 在 `sqlite3_ondisk.rs`、`btree.rs`、`pager.rs` 中讀寫這些格式。

## B-tree page header

`core/storage/btree.rs` 的 `offset` module 註解很值得讀。B-tree page header 大致有：

```text
page type
first freeblock offset
cell count
cell content area start
fragmented bytes count
right-most pointer for interior pages
```

Page 中 cell pointer array 從前面長，cell content 從後面往前放。中間空間就是 free space。這是 SQLite page layout 的核心。

## Table B-tree vs Index B-tree

Table B-tree:

```text
key = rowid
payload = row record
```

Index B-tree:

```text
key = indexed columns + rowid tie-breaker
payload usually part of key record
```

這也是為什麼 table cursor 和 index cursor 有不同邏輯。先懂 key/payload 差異，再去下一章看 cursor。

## Overflow page

如果 record payload 太大，leaf cell 只能放 local payload，剩下放 overflow page chain：

```text
cell local payload
  -> overflow page 1: next_page + bytes
  -> overflow page 2: next_page + bytes
```

所以 `Column` 讀某欄時可能要追 overflow chain，也就可能 I/O yield。這是 VM `op_column` 需要 state machine 的底層原因之一。

## 練習

跑：

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, data TEXT);
INSERT INTO t VALUES (1, 'small');
PRAGMA page_count;
PRAGMA freelist_count;
```

預期 `page_count` 至少有 page 1；實際數字會依 database 初始化與 page allocation 不同而不同。再插入大字串，觀察 page_count 是否增加。

追 source：

```bash
rg -n "pub struct DatabaseHeader|pub struct WalHeader|WAL_HEADER_SIZE" core/storage/sqlite3_ondisk.rs
rg -n "pub enum PageType|BTreeCell|TableLeafCell|IndexLeafCell" core/storage/sqlite3_ondisk.rs
rg -n "pub mod offset|BTREE_PAGE_TYPE|BTREE_CELL_COUNT" core/storage/btree.rs
```

## 自我檢查

1. 為什麼 page 1 的 B-tree content offset 是 100？
2. Table B-tree 和 Index B-tree 的 key 分別是什麼？
3. Overflow page 解決什麼問題？
4. `schema_cookie` 屬於 SQL compiler correctness 還是 storage bytes layout？答案是兩者都有關，為什麼？

