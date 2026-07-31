# 07. WAL, IOResult, And Transaction Tasks

這一組處理 durability、checkpoint、savepoint、I/O yield、re-entry correctness。這是 Turso 和一般 Rust async database 最大的差異之一。

- [ ] T231. **WAL module map**: read `core/storage/wal.rs`, `learn/07a-wal-transactions-checkpoint.md`; output core WAL responsibilities.
- [ ] T232. **WAL header**: read `core/storage/sqlite3_ondisk.rs`, `core/storage/wal.rs`; output WAL header fields and why salt/checksum exist.
- [ ] T233. **WAL frame**: read `core/storage/wal.rs`; output frame header, page image, commit marker, and checksum flow.
- [ ] T234. **WAL index or in-memory state**: read `core/storage/wal.rs`; output how readers find the newest frame for a page.
- [ ] T235. **Begin read transaction**: read `begin_read_tx` paths in `core/storage/wal.rs`, `core/storage/pager.rs`; output snapshot selection.
- [ ] T236. **Begin write transaction**: read write transaction start code in `core/storage/wal.rs`, `core/storage/pager.rs`; output writer exclusivity and locks.
- [ ] T237. **Commit state machine**: read commit code in `core/storage/pager.rs`, `core/storage/wal.rs`; output dirty page collection, WAL append, sync, and cleanup phases.
- [ ] T238. **Rollback path**: read rollback/end transaction code in `core/storage/pager.rs`; output how dirty pages and cursor state are restored.
- [ ] T239. **Auto-commit opcode bridge**: read `op_auto_commit` in `core/vdbe/execute.rs`; output how SQL transaction statements reach pager.
- [ ] T240. **Savepoints**: read savepoint code in `core/storage/pager.rs`, `op_savepoint` in `core/vdbe/execute.rs`; output savepoint stack and rollback scope.
- [ ] T241. **Statement journal**: read `core/translate/stmt_journal.rs`, `core/storage/subjournal.rs`; output why statement-level rollback exists.
- [ ] T242. **Checkpoint modes**: read checkpoint code in `core/storage/wal.rs`, `core/storage/pager.rs`; output PASSIVE, FULL, RESTART, TRUNCATE differences.
- [ ] T243. **Auto-checkpoint**: read `WalAutoActions` paths in `core/storage/pager.rs`, `core/storage/wal.rs`; output why callers can choose checkpoint behavior.
- [ ] T244. **Shared WAL coordination**: read `core/storage/shared_wal_coordination.rs`; output how multiprocess or shared readers/writers coordinate.
- [ ] T245. **Journal mode switching**: read `core/storage/journal_mode.rs`, `op_journal_mode` in `core/vdbe/execute.rs`; output how SQL PRAGMA changes storage mode.
- [ ] T246. **Busy handling**: read `core/busy.rs`, lock-related pager/WAL code; output when the engine waits, returns busy, or retries.
- [ ] T247. **I/O trait surface**: read `core/io/mod.rs`, `core/io/vfs.rs`; output required operations for a database storage backend.
- [ ] T248. **Completion object**: read `core/io/completions.rs`; output what a completion stores before and after I/O finishes.
- [ ] T249. **IOResult model**: read `core/io/mod.rs`, `learn/07b-ioresult-reentry.md`; output why Turso returns `IOResult` instead of using `async fn` in core.
- [ ] T250. **return_if_io macro pattern**: read call sites in `core/vdbe/execute.rs`, `core/storage/btree.rs`; output how a function pauses safely.
- [ ] T251. **Pending I/O in VM**: read `normal_step` handling in `core/vdbe/mod.rs`; output where pending completions resume.
- [ ] T252. **State-machine discipline**: read `core/state_machine.rs`, `core/storage/state_machines.rs`; output how saved enum phases prevent redoing side effects.
- [ ] T253. **Memory I/O backend**: read `core/io/memory.rs`; output a minimal in-memory file model.
- [ ] T254. **Yielding memory backend**: read `core/io/memory_yield.rs`; output how deterministic yielding tests re-entry boundaries.
- [ ] T255. **Unix and generic I/O**: read `core/io/unix.rs`, `core/io/generic.rs`; output how platform file I/O plugs into the trait.
- [ ] T256. **Windows I/O and locks**: read `core/io/windows.rs`, `core/io/windows_lock.rs`, `core/io/win_iocp.rs`; output platform-specific lock and completion concerns.
- [ ] T257. **Checksum and corruption boundaries**: read `core/storage/checksum.rs`, WAL checksum code; output what corruption can be detected.
- [ ] T258. **WAL/I/O milestone**: trace a one-row transaction from `BEGIN` to WAL frame sync to `COMMIT`; output every source boundary where crash safety matters.

