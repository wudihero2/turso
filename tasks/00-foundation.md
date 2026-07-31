# 00. Foundation Tasks

這一組先建立地圖與閱讀習慣。不要追太深，目標是知道每一層大概在哪裡，之後才有能力把 parser、VM、B-tree 串起來。

- [ ] T001. **Workspace skeleton**: read `Cargo.toml`, `learn/README.md`; output workspace members map and the main SQL pipeline in your own words.
- [ ] T002. **Repo product map**: read `learn/00-repo-map.md`, `README.md`; output which directories are engine, bindings, tests, sync, Postgres, and performance tooling.
- [ ] T003. **SQLite architecture comparison**: read `learn/README.md`, `learn/01-sql-lifecycle.md`; output Turso-to-SQLite layer mapping: interface, compiler, VM, B-tree, pager, VFS.
- [ ] T004. **Core crate entrypoints**: read `core/lib.rs`, `core/connection.rs`, `core/statement.rs`; output the roles of `Database`, `Connection`, and `Statement`.
- [ ] T005. **Source navigation habit**: use `rg -n "prepare_with_origin|normal_step|op_column|begin_write_tx"`; output a table of source coordinates and why each is important.
- [ ] T006. **Glossary baseline**: read `learn/00-5-glossary.md`; output one-sentence definitions for AST, VDBE, register, cursor, page, pager, WAL, checkpoint, IOResult.
- [ ] T007. **Rust enum reading**: read `sqlite/parser/src/ast.rs`, `core/vdbe/insn.rs`; output how large Rust enums encode SQL syntax and VM instructions.
- [ ] T008. **Rust trait reading**: read `core/io/mod.rs`, `core/vtab.rs`; output why database code uses traits for I/O and virtual tables.
- [ ] T009. **Rust ownership shells**: read `core/lib.rs`, `core/connection.rs`; output where `Arc`, locks, and shared state appear before SQL execution starts.
- [ ] T010. **Error model**: read `core/error.rs`, `sqlite/parser/src/error.rs`; output how parser errors differ from engine runtime errors.
- [ ] T011. **Debug commands**: run `scripts/diff.sh "SELECT 1 + 1"` and `cargo run -q --bin tursodb -- -q`; output what each command is good for during learning.
- [ ] T012. **EXPLAIN first look**: use the CLI on `EXPLAIN SELECT 1`; output how SQL becomes rows of bytecode.
- [ ] T013. **Learn docs survey**: read headings in `learn/*.md`; output which chapter you would open for parser, planner, VM, schema, storage, WAL, and I/O.
- [ ] T014. **Source vs guide distinction**: read one guide chapter and one source-code-learn chapter; output how the two layers differ and when to use each.
- [ ] T015. **Database pipeline sketch**: trace `SELECT * FROM t` conceptually from SQL text to page read; output a hand-written pipeline with source path at each edge.
- [ ] T016. **Write pipeline sketch**: trace `INSERT INTO t VALUES (1)` conceptually from SQL text to WAL append; output the same pipeline with transaction boundaries.
- [ ] T017. **Compatibility mindset**: read `COMPAT.md`, `CONTRIBUTING.md`; output why Turso repeatedly compares behavior with SQLite.
- [ ] T018. **Testing map**: read `docs/agent-guides/testing.md`, `testing/README.md`; output which harness to use for SQL conformance, Rust integration, CLI, simulator, and fuzz work.
- [ ] T019. **Correctness map**: read `docs/agent-guides/code-quality.md`, `docs/agent-guides/transaction-correctness.md`; output the invariants that matter most for a database.
- [ ] T020. **First milestone review**: reread `learn/01-sql-lifecycle.md`; output a one-page explanation of the whole database stack before touching individual subsystems.

