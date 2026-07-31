# 11. Capstone Build Tasks

這一組把前面讀懂的東西轉成自己的 Rust mini database。這些不是要改 Turso，而是之後可以另開教學 crate 或筆記，逐步實作一個小型 SQLite-like engine。

- [ ] T366. **Toy crate scaffold**: output a tiny Rust project plan with modules `lexer`, `parser`, `ast`, `planner`, `vm`, `storage`, `tests`.
- [ ] T367. **Toy token enum**: implement or sketch tokens for identifiers, numbers, strings, punctuation, and keywords; compare with `sqlite/parser/src/token.rs`.
- [ ] T368. **Toy lexer**: implement or sketch a lexer for `SELECT 1`, `CREATE TABLE`, `INSERT`; compare with `sqlite/parser/src/lexer.rs`.
- [ ] T369. **Toy parser state**: implement or sketch `Parser { lexer, current }`; compare with `sqlite/parser/src/parser.rs`.
- [ ] T370. **Toy AST commands**: implement or sketch AST for `CREATE TABLE`, `INSERT`, `SELECT`; compare with `sqlite/parser/src/ast.rs`.
- [ ] T371. **Toy expression parser**: implement or sketch precedence parsing for literals, column refs, binary ops; compare with Turso expression parser.
- [ ] T372. **Toy name resolver**: implement or sketch table and column lookup; compare with `core/translate/expr/metadata.rs`.
- [ ] T373. **Toy schema catalog**: implement in-memory `Schema`, `Table`, `Column`; compare with `core/schema.rs`.
- [ ] T374. **Toy value enum**: implement `Value::{Null,Integer,Real,Text,Blob}`; compare with `core/vdbe/value.rs`.
- [ ] T375. **Toy record codec**: implement a simple length-prefixed record format; compare with `core/storage/sqlite3_ondisk.rs`.
- [ ] T376. **Toy instruction enum**: implement `OpenRead`, `Rewind`, `Column`, `ResultRow`, `Next`, `Halt`; compare with `core/vdbe/insn.rs`.
- [ ] T377. **Toy VM registers**: implement register array and row result handling; compare with `core/vdbe/mod.rs`.
- [ ] T378. **Toy ProgramBuilder**: implement labels, instruction push, and register allocation; compare with `core/vdbe/builder.rs`.
- [ ] T379. **Toy SELECT full scan compiler**: compile `SELECT * FROM t`; compare with `core/translate/select.rs` and emitter loop code.
- [ ] T380. **Toy WHERE compiler**: compile `WHERE col = literal`; compare with `core/translate/expr/condition.rs`.
- [ ] T381. **Toy INSERT compiler**: compile `INSERT INTO t VALUES (...)`; compare with `core/translate/insert.rs`.
- [ ] T382. **Toy CREATE TABLE compiler**: store table metadata in catalog; compare with `core/translate/schema.rs`.
- [ ] T383. **Toy in-memory table storage**: implement Vec-backed rows behind cursor trait; compare with `core/storage/btree.rs` cursor interface.
- [ ] T384. **Toy cursor API**: implement `rewind`, `next`, `record`, `insert`, `delete`; compare with Turso `Cursor` and `BTreeCursor`.
- [ ] T385. **Toy page abstraction**: implement fixed-size pages in memory; compare with `core/storage/pager.rs`.
- [ ] T386. **Toy page cache**: implement page lookup and dirty tracking; compare with `core/storage/page_cache.rs`.
- [ ] T387. **Toy B-tree leaf page**: store sorted rowid cells in a single page; compare with `core/storage/btree.rs`.
- [ ] T388. **Toy B-tree seek**: implement binary search in a leaf page; compare with Turso cursor seek.
- [ ] T389. **Toy B-tree split**: split a full leaf into two pages; compare with Turso balancing tasks.
- [ ] T390. **Toy index**: implement a secondary index from key to rowid; compare with `core/schema.rs` index metadata and `op_idx_insert`.
- [ ] T391. **Toy transaction flag**: implement begin/commit/rollback for in-memory dirty changes; compare with `core/storage/pager.rs`.
- [ ] T392. **Toy WAL log**: append page images or logical operations to a file; compare with `core/storage/wal.rs`.
- [ ] T393. **Toy recovery**: replay toy WAL after restart; compare with WAL and MVCC recovery docs.
- [ ] T394. **Toy IOResult**: refactor one storage method to return `Done` or `IO`; compare with `core/io/mod.rs`.
- [ ] T395. **Toy re-entry state machine**: make one cursor operation resumable; compare with `core/storage/btree.rs` state machines.
- [ ] T396. **Toy SQL tests**: write SQL input/output tests for create, insert, select, where; compare with `.sqltest` style.
- [ ] T397. **Toy differential tests**: compare toy output against SQLite for supported subset; compare with `scripts/diff.sh`.
- [ ] T398. **Toy EXPLAIN output**: print bytecode rows; compare with `core/vdbe/explain.rs`.
- [ ] T399. **Toy integration trace**: write one document tracing `INSERT` through lexer, parser, compiler, VM, storage, and WAL.
- [ ] T400. **Final synthesis**: output a design document explaining how to grow the toy database toward Turso: parser coverage, optimizer, B-tree correctness, WAL durability, MVCC, bindings, and tests.

