# 00. Repo Map: 先知道這個資料庫長什麼樣

本章目標：你不需要立刻懂每個 module 的細節，但要能回答三個問題：

1. 這個 repo 哪裡是 database engine 主體？
2. 一條 SQL 會經過哪些 crate 和檔案？
3. 測試、binding、extension、sync、Postgres compatibility 分別放在哪？

## 一句話介紹這個 repo

這是 Turso 的 SQLite-compatible SQL database engine，用 Rust 重寫 SQLite 的核心架構。它的目標不是只做一個 parser 或 shell，而是一個完整 in-process database：有 SQL parser、schema catalog、query compiler、register-based bytecode VM、B-tree storage、WAL durability、多語言 bindings、extension API、sync engine、測試與 fuzz/simulation tooling。

可以把它分成四圈：

```text
外圈產品介面:
  cli/, bindings/, sdk-kit/, postgres/

核心 SQL engine:
  sqlite/parser/, core/connection.rs, core/statement.rs,
  core/translate/, core/vdbe/, core/schema.rs, core/types.rs

核心 storage engine:
  core/storage/, core/io/, core/mvcc/

工程支撐:
  tests/, testing/, sqlite/conformance/, scripts/, perf/, docs/, extensions/
```

## 60 分鐘閱讀範圍

| 時間 | 讀什麼 | 目標 |
|---:|---|---|
| 10 分鐘 | `Cargo.toml` 的 workspace members | 知道 crate 名稱和 top-level 目錄怎麼對應 |
| 10 分鐘 | `README.md`、`AGENTS.md` | 知道產品入口、常用命令、correctness 原則 |
| 20 分鐘 | 本章 `Top-level 目錄` 的前半 | 找出 parser、core、cli、bindings、testing |
| 10 分鐘 | 本章 `core/` 導覽 | 建立 engine 內部地圖 |
| 10 分鐘 | 自我檢查 | 能把一個 bug 大致定位到目錄 |

## Top-level 檔案: 第一輪只看這些

`Cargo.toml`
: Rust workspace 的總入口。這裡列出 40+ members，例如 `core`、`cli`、`bindings/rust`、`sqlite/parser`、`sync/engine`、`testing/sqltest`。讀源碼時先從這裡知道 crate 名稱和路徑怎麼對應。

`README.md`
: 專案使用說明、CLI、bindings、MCP 等面向使用者的文件。它不是 source architecture guide，但能幫你知道 Turso 對外提供什麼。

`AGENTS.md`
: 給 coding agent 的 repo 規則。對你也有用，因為它整理了常用測試命令、主要目錄、correctness 原則。

`CONTRIBUTING.md`
: 貢獻流程與 commit message 風格。改 code 前要看。

`COMPAT.md`
: SQLite compatibility 相關資訊。看行為差異時有用。

`Makefile`
: 聚合測試命令，尤其是 conformance、TCL、MVCC、extensions。

`docs/agent-guides/*.md`
: repo 內的主題導讀。讀 storage/WAL/async I/O 前，先看對應 guide 可以少走很多彎路。

`scripts/diff.sh`
: 不是 top-level 檔案，但值得在第一輪記住。它是比較 SQLite 和 Turso SQL output 的最快工具。

其餘像 `Cargo.lock`、`CHANGELOG.md`、`PERF.md`、`LICENSE.md`、`NOTICE.md`、`VOUCHED.td`、`deny.toml`、`dist-workspace.toml`、`rust-toolchain.toml`、`flake.nix`、Dockerfile、Python lockfiles、CI 設定、devcontainer 設定，第一輪都當工程配置。知道它們存在即可，不要在這章細讀。

## Top-level 目錄

`.aristo/`
: Aristo correctness intent/verification 相關輸出或匹配資料，搭配 `aristo.toml` 與 source 內的 `#[aristo::intent]` 使用。

`.cargo/`
: Cargo 本地設定，例如 target-dir 或 build runner 相關 config。

`.claude/`
: repo-local agent skills。這些文件不是 engine runtime，但整理了 storage、WAL、testing、debugging 等工作規則。

`.codex/`
: Codex/agent 本地狀態。不是 Turso 產品 source。

`.config/`
: 開發工具設定，例如 nextest。

`.devcontainer/`
: VS Code/devcontainer、Docker、squid/firewall 初始化設定。

`.github/`
: GitHub Actions、PR template、labeler、bot configuration。

`core/`
: database engine 主體。這是你學源碼最重要的目錄。它包含 public core API、connection/statement lifecycle、schema、SQL translation、VDBE、B-tree、pager、WAL、I/O、MVCC、functions、JSON、custom types 等。

`sqlite/parser/`
: SQLite dialect parser crate `turso_parser`。SQL 文字會先由 lexer/token/parser 變成 AST，再交給 `core/translate`。

`cli/`
: `tursodb` interactive CLI、MCP server、sync server、manual command handling。若你想從可執行程式往核心追，從 `cli/main.rs` 開始。

`bindings/`
: 多語言 bindings。Rust binding 是高階 async API；C binding 追 SQLite C API compatibility；JavaScript、Python、Java、Go、.NET、React Native、TCL 都在這裡。

`sdk-kit/`
: 較底層 SDK abstraction 與 C ABI 橋接。很多語言 binding 不是直接碰 `core::Connection`，而是經過 `turso_sdk_kit::rsapi`。

`sync/`
: Turso Cloud sync 相關。`sync/engine` 是 sync protocol/engine；`sync/sdk-kit` 是 sync 低階 ABI。

`extensions/`
: extension framework 與 built-in examples。`extensions/core` 定義 extension API、scalar/aggregate/vtab/VFS traits；其他如 `crypto`、`csv`、`regexp` 是 extension crate。

`postgres/`
: PostgreSQL-facing compatibility layer。它不是 core SQLite execution 的第一入口，但會把 PG protocol / PG parser / frontend semantics 轉到 Turso core。

`tests/`
: Rust integration/fuzz regression tests。你要看 API-level 行為、MVCC、statement lifecycle、external API regression 時來這裡。

`testing/`
: 更大的測試工具區：simulator、concurrent simulator、sqltest runner、SQLancer、stress、legacy TCL tests、CLI Python tests。

`sqlite/conformance/`
: SQLite compatibility tests。`sqlite-sqltests/` 是 preferred SQL conformance coverage；`upstream/` 是 imported TCL upstream tests；`turso-sqltests/` 是 Turso-specific SQL 行為。

`docs/`
: 使用者與 agent guides。`docs/agent-guides/` 對讀 source 很有價值，尤其是 storage format、WAL、async I/O、testing。

`scripts/`
: 開發與 debugging 工具。`scripts/diff.sh` 可以快速比較 SQLite 與 Turso 的 SQL output；`scripts/corruption-debug-tools/` 對 WAL/page corruption 很重要。

`perf/`
: benchmarks。包含 throughput、latency、memory、TPC-H/TPC-C、ClickBench、checkpoint 等。

`tools/`
: 小型工具。目前高信號的是 `tools/dbhash`，用於 database hash/checking。

`sql_generation/`
: SQL generation model/tooling，供 simulator、differential testing、fuzz-like workload 使用。

`macros/`, `sdk-kit-macros/`
: workspace proc macros，例如 custom test macro、atomic enum、trace stack、benchmark name wrappers。

`fuzz/`
: cargo-fuzz targets。和 `tests/fuzz` 不同，這是 fuzz harness workspace。

`examples/`
: 各語言 binding 的基本使用範例。

`serverless/`, `packages/`
: package/serverless integration 周邊。

`assets/`, `licenses/`
: 圖片與第三方授權資料。

`tlaplus/`
: TLA+ transaction model。學 transaction correctness 到後期可以看。

`target/`
: Rust build output，不讀、不改。

## `core/` 高密度檔案導覽

`core/lib.rs`
: `turso_core` crate root。它 re-export `Database`、`Connection`、`Statement`、`Value`、`IOResult`、`Pager`、`Wal` 等核心 API，也定義 `Database` shared state、`DatabaseOpts`、open/connect 流程。

`core/connection.rs`
: 每個 connection 的狀態與 SQL prepare/execute/query 流程。`Connection::prepare`、`parse_sql`、`compile_cmd`、schema reparse、transaction state、attached/temp DB 都在這裡。

`core/statement.rs`
: prepared statement wrapper。負責 `Statement::step`、busy handling、query timeout、column metadata、statement lifecycle。

`core/schema.rs`
: in-memory schema catalog。包含 `Schema`、`Table`、`BTreeTable`、`Index`、`View`、`Trigger`、`sqlite_schema` parsing 與 table/index metadata。

`core/types.rs`
: SQL runtime value、record、comparison、cursor enum、`IOResult`、`IOCompletions`。這是 VM 和 storage 之間的共享語言。

`core/translate/`
: SQL AST -> VDBE bytecode。`mod.rs` 是總 dispatcher；`select.rs`、`insert.rs`、`update.rs`、`delete.rs`、`schema.rs` 分別處理不同 statement；`planner.rs`/`plan.rs` 建立 query plan；`emitter/` 把 plan emit 成 `Insn`。

`core/vdbe/`
: bytecode VM。`insn.rs` 定義所有 instruction；`builder.rs` 幫 compiler 建 program；`mod.rs` 定義 `Program`、`ProgramState`、`StepResult`、step loop；`execute.rs` 是 opcode implementation。

`core/storage/`
: storage layer。`sqlite3_ondisk.rs` 是 SQLite file/WAL format；`btree.rs` 是 B-tree cursor、seek、insert、delete、balance；`pager.rs` 是 page cache、dirty pages、transaction、commit、checkpoint；`wal.rs` 是 WAL protocol。

`core/io/`
: OS/VFS abstraction。`mod.rs` 定義 `IO`/`File` traits；`completions.rs` 定義 completion/future/waker/group；`unix.rs`、`windows.rs`、`io_uring.rs`、`memory.rs`、`vfs.rs` 是不同 backend。

`core/mvcc/`
: experimental MVCC。`mod.rs` 是概念入口；`database/mod.rs` 是 row-version store；`cursor.rs` 把 MVCC rows 和 B-tree cursor 合併；`persistent_storage/` 處理 logical log。

`core/functions/`, `core/function.rs`
: built-in SQL scalar/aggregate/window function dispatch 與 implementation。

`core/json/`, `core/vector/`, `core/numeric/`, `core/time/`
: SQL type/function extension domains。

`core/ext/`, `core/vtab.rs`, `core/index_method/`
: extension、virtual table、custom index method integration。

`core/incremental/`
: materialized view / incremental computation related code。

`core/pragma.rs`, `core/parameters.rs`, `core/progress.rs`, `core/busy.rs`
: PRAGMA handling support、bind parameters、progress handler、busy handler。

`core/error.rs`, `core/assert.rs`, `core/fast_lock.rs`, `core/sync.rs`, `core/thread.rs`, `core/util.rs`
: engine-wide error/assert/sync/util infrastructure。

## 第一輪不要深讀的區域

第一輪目標是讀懂「一條 SQL 如何從文字變結果」。所以先不要深鑽：

- `postgres/`：除非你正在學 PG compatibility。
- `sync/`：除非你已懂 WAL/page lifecycle。
- `perf/`：等你知道熱路徑在哪再看。
- `fuzz/`、`testing/sqlancer/`：等你知道 correctness invariant 再看。
- `core/mvcc/`：MVCC 是 experimental，先懂 WAL path。

## 你現在應該能建立的地圖

當你看到一個 SQL feature，可以這樣定位：

- parser 語法不認得：先看 `sqlite/parser/src/parser.rs` 和 `ast.rs`。
- 語法認得但 compile 不出來：看 `core/translate/<statement>.rs`。
- compile 有 bytecode 但跑錯：看 `core/vdbe/execute.rs` 對應 opcode。
- cursor 掃描/seek/insert/delete 錯：看 `core/storage/btree.rs`。
- commit/rollback/WAL/checkpoint 錯：看 `core/storage/pager.rs` 和 `core/storage/wal.rs`。
- I/O yield、async wrapper、binding 卡住：看 `core/types.rs`、`core/io/completions.rs`、`sdk-kit/src/rsapi.rs`。

## 自我檢查

1. SQL parser、compiler、VM、storage 分別在哪些 top-level 目錄？
2. `core/connection.rs`、`core/statement.rs`、`core/vdbe/execute.rs` 各在生命週期哪一層？
3. 如果 `SELECT` 語義和 SQLite 不一致，第一輪會看哪些測試與 source？
4. 如果 crash 發生在 commit/checkpoint，為什麼不該先從 parser 查起？
5. 哪些 top-level 檔案第一輪可以略過？為什麼？
