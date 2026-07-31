# 10. Testing, Fuzzing, And Performance Tasks

這一組教你如何驗證 database correctness。每個功能讀懂之後，都要能知道該放哪一層測試。

- [ ] T336. **Testing guide**: read `docs/agent-guides/testing.md`; output the decision tree for `.sqltest`, integration tests, simulator, and fuzzing.
- [ ] T337. **SQL conformance runner**: read `sqlite/conformance/Makefile`, `testing/sqltest`; output how `.sqltest` is discovered and executed.
- [ ] T338. **SQL test DSL**: inspect `sqlite/conformance/sqlite-sqltests/select/default.sqltest`; output statement, query, result, and snapshot patterns.
- [ ] T339. **Planner snapshot tests**: inspect `sqlite/conformance/sqlite-sqltests/snapshots/`; output when a plan snapshot is useful and risky.
- [ ] T340. **Compatibility diff**: run `scripts/diff.sh "SELECT 1"`; output how SQLite and Turso differences are surfaced.
- [ ] T341. **Rust integration tests**: read `tests/integration/common.rs`, `tests/integration/mod.rs`; output helpers for opening databases and asserting results.
- [ ] T342. **Query processing tests**: inspect `tests/integration/query_processing/`; output which storage/compiler cases moved beyond `.sqltest`.
- [ ] T343. **WAL integration tests**: read `tests/integration/wal/test_wal.rs`; output transaction and checkpoint test patterns.
- [ ] T344. **Abandoned statement tests**: read `tests/integration/abandoned_statement_pager.rs`; output why dropped statements are a correctness boundary.
- [ ] T345. **CLI tests**: read `testing/cli_tests`, `cli/tests`; output shell behavior versus core behavior testing.
- [ ] T346. **TCL compatibility tests**: read `bindings/tcl/turso_tcl.c`, `bindings/tcl/test_probes.tcl`; output why legacy SQLite tests need a TCL adapter.
- [ ] T347. **Simulator overview**: read `testing/simulator/README.md`, `learn/14-source-code-learn-simulator.md`; output deterministic simulation goals.
- [ ] T348. **Simulator model**: read `testing/simulator/model/mod.rs`, `testing/simulator/model/property.rs`; output what properties are checked.
- [ ] T349. **Simulator generation**: read `testing/simulator/generation/plan.rs`, `testing/simulator/generation/query.rs`; output how random interaction plans are produced.
- [ ] T350. **Simulator runner**: read `testing/simulator/runner/execution.rs`; output how Turso and SQLite/rusqlite executions are compared.
- [ ] T351. **Simulator shrinking**: read `testing/simulator/shrink/plan.rs`; output how a failing plan becomes smaller.
- [ ] T352. **Bugbase**: read `testing/simulator/runner/bugbase.rs`; output how failing cases are persisted for regression.
- [ ] T353. **Concurrent simulator overview**: read `testing/concurrent-simulator/README.md`, `testing/concurrent-simulator/lib.rs`; output concurrency scenarios covered.
- [ ] T354. **Concurrent operations**: read `testing/concurrent-simulator/operations.rs`; output operation model and transaction state.
- [ ] T355. **Yield injection tests**: read `testing/concurrent-simulator/yield_injection.rs`, `docs/agent-guides/async-io-model.md`; output how controlled yields expose re-entry bugs.
- [ ] T356. **Multiprocess simulator**: read `testing/concurrent-simulator/multiprocess.rs`; output process, worker, and history model.
- [ ] T357. **Differential oracle fuzzer**: read `testing/differential-oracle/fuzzer/main.rs`, `testing/differential-oracle/fuzzer/oracle.rs`; output how random SQL compares Turso to SQLite.
- [ ] T358. **SQL generation model**: read `sql_generation/model/mod.rs`, `sql_generation/generation/mod.rs`; output how schema-aware SQL generation works.
- [ ] T359. **SQL gen prop tests**: inspect `testing/differential-oracle/sql_gen_prop/`; output property-test structure by statement type.
- [ ] T360. **Fuzz regressions**: inspect `tests/fuzz`; output how minimized cases are preserved.
- [ ] T361. **Stress tooling**: read `testing/stress`, `testing/stress-go`; output when long-running stress is more useful than unit tests.
- [ ] T362. **Memory benchmark**: read `perf/memory/Cargo.toml`, `perf/memory/src/main.rs`, `perf/memory/src/workload.rs`; output workload, dhat, and report flow.
- [ ] T363. **Throughput and TPC benchmarks**: read `perf/throughput/README.md`, `perf/tpc-h/README.md`; output benchmark input, workload, and measurement goal.
- [ ] T364. **Criterion and Divan naming**: inspect benchmark attributes in `core/benches`; output why CodSpeed benchmark naming matters.
- [ ] T365. **Validation milestone**: for one hypothetical bug in parser, planner, VDBE, B-tree, WAL, and binding, choose the narrowest correct test harness and justify it.
