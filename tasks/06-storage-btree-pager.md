# 06. Storage, B-tree, And Pager Tasks

這一組是 SQLite-like database 的物理核心。先讀 file format，再讀 B-tree page，最後讀 pager 如何保護 page cache 與寫入流程。

- [ ] T191. **On-disk module map**: read `core/storage/sqlite3_ondisk.rs`, `learn/06a-file-format-pages.md`; output file-format responsibilities.
- [ ] T192. **Database header**: read `core/storage/sqlite3_ondisk.rs`; output the 100-byte header fields most relevant to page size, schema, WAL, and freelist.
- [ ] T193. **Page type enum**: read `core/storage/btree.rs`, `core/storage/sqlite3_ondisk.rs`; output table leaf, table interior, index leaf, index interior differences.
- [ ] T194. **Page 1 special case**: read `core/storage/btree.rs`, `core/storage/pager.rs`; output why page 1 has both database header and B-tree content.
- [ ] T195. **B-tree page header**: read `core/storage/btree.rs`; output cell count, cell content area, freeblock, fragmented bytes, and rightmost pointer.
- [ ] T196. **Cell pointer array**: read `core/storage/btree.rs`; output why cells are found through offsets rather than stored contiguously.
- [ ] T197. **Table leaf cell**: read `core/storage/btree.rs`, `core/storage/sqlite3_ondisk.rs`; output rowid plus payload layout.
- [ ] T198. **Index leaf cell**: read `core/storage/btree.rs`, `core/storage/sqlite3_ondisk.rs`; output key record layout and why rowid is part of index identity.
- [ ] T199. **Interior cells**: read `core/storage/btree.rs`; output child pointer plus separator key behavior.
- [ ] T200. **Overflow threshold**: read `payload_overflow_threshold_max` and related code in `core/storage/btree.rs`; output when payload spills.
- [ ] T201. **Overflow page chain**: read overflow code in `core/storage/btree.rs`; output how large records are read and written.
- [ ] T202. **Freelist basics**: read freelist code in `core/storage/btree.rs`, `core/storage/pager.rs`; output trunk, leaf, allocation, and reuse behavior.
- [ ] T203. **Cell defragmentation**: read defragmentation functions in `core/storage/btree.rs`; output why page-local free space must be compacted.
- [ ] T204. **Cell insertion primitives**: read `insert_into_cell`, `allocate_cell_space` in `core/storage/btree.rs`; output local page mutation steps.
- [ ] T205. **Cell deletion primitives**: read `drop_cell`, `free_cell_range` in `core/storage/btree.rs`; output how page free space is restored.
- [ ] T206. **BTreeCursor structure**: read `core/storage/btree.rs`; output identity, position, stack, state-machine, and cache fields.
- [ ] T207. **PageStack**: read `PageStack` in `core/storage/btree.rs`; output why cursor position is a path from root to leaf.
- [ ] T208. **Cursor rewind**: read rewind state machine in `core/storage/btree.rs`; output how first row is found and where IO can yield.
- [ ] T209. **Cursor next/prev**: read movement state machines in `core/storage/btree.rs`; output how leaf movement and parent climb work.
- [ ] T210. **Cursor seek**: read seek code in `core/storage/btree.rs`; output binary search within page and descent across pages.
- [ ] T211. **Cursor record read**: read record/payload read path in `core/storage/btree.rs`; output how VM `Column` reaches payload bytes.
- [ ] T212. **Cursor insert path**: read insert state machine in `core/storage/btree.rs`; output where page fullness is detected.
- [ ] T213. **Cursor delete path**: read delete state machine in `core/storage/btree.rs`; output how deleting a row affects cursor peers.
- [ ] T214. **Peer cursor notification**: read cursor registration code in `core/storage/pager.rs`, `core/storage/btree.rs`; output why one cursor mutation can invalidate another.
- [ ] T215. **Balance trigger**: read balance entry code in `core/storage/btree.rs`; output when insert/delete requires rebalancing.
- [ ] T216. **Balance root**: read `balance_root` code in `core/storage/btree.rs`; output how a tree grows taller.
- [ ] T217. **Sibling balancing**: read sibling collection and redistribution code in `core/storage/btree.rs`; output how pages split or merge.
- [ ] T218. **Interior balancing**: read balance code for interior pages; output how separator keys are rewritten.
- [ ] T219. **Balance state machine**: read balance states in `core/storage/btree.rs`; output saved fields and why re-entry safety matters.
- [ ] T220. **B-tree validation**: read integrity validation helpers in `core/storage/btree.rs`; output invariants checked for cell order and page coverage.
- [ ] T221. **Buffer pool**: read `core/storage/buffer_pool.rs`; output how reusable buffers reduce allocation churn.
- [ ] T222. **Page wrapper**: read `core/storage/pager.rs`; output `Page`, `PageInner`, dirty state, and borrow safety.
- [ ] T223. **Page cache**: read `core/storage/page_cache.rs`; output cache keys, replacement, dirty tracking, and pending read cases.
- [ ] T224. **Pager structure**: read `core/storage/pager.rs`; output pager fields grouped by cache, transaction, WAL, savepoint, and state-machine concerns.
- [ ] T225. **Pager read path**: read page read code in `core/storage/pager.rs`; output source priority: cache, WAL, database file.
- [ ] T226. **Pager write preparation**: read dirty-page and write transaction code in `core/storage/pager.rs`; output when a page becomes writable.
- [ ] T227. **Page allocation**: read allocation code in `core/storage/pager.rs`; output freelist reuse versus database growth.
- [ ] T228. **Autovacuum pointer map**: read pointer-map code in `core/storage/pager.rs`; output why moving pages requires reverse references.
- [ ] T229. **Encryption layer**: read `core/storage/encryption.rs`; output how page encryption is kept below logical database code.
- [ ] T230. **Storage milestone**: create a source trace for `CREATE TABLE`, `INSERT large blob`, and `SELECT`; output where header, page, B-tree, overflow, and pager are touched.

