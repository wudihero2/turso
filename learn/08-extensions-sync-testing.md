# 08. Extensions、Sync、Testing: 核心之外的系統

本章目標：知道哪些目錄不是 SQL execution 主線，但對產品能力與 correctness 很重要。

## 心智模型

核心 engine 是：

```text
parser -> translate -> VDBE -> btree/pager/wal/io
```

周邊系統提供：

```text
bindings:
  把 core 包成各語言 API

extensions:
  讓外部 function/vtab/VFS 進入 engine

sync:
  把 database/WAL/logical state 和遠端同步

postgres:
  讓 PostgreSQL protocol/parser frontend 使用 Turso core

testing:
  用 conformance、simulator、fuzzer、stress 驗證 correctness
```

## 60 分鐘閱讀範圍

| 時間 | 檔案 / 目錄 | 只讀這些 symbol / 區塊 |
|---:|---|---|
| 10 分鐘 | `extensions/core/src/lib.rs` | extension crate 的 module 與 public API 入口 |
| 8 分鐘 | `extensions/core/src/functions.rs`、`types.rs` | scalar/aggregate function API 的形狀 |
| 8 分鐘 | `extensions/core/src/vtabs.rs`、`core/vtab.rs` | virtual table trait 的角色 |
| 8 分鐘 | `core/io/vfs.rs` | extension VFS 如何接到 core I/O |
| 8 分鐘 | `bindings/rust/src/connection.rs`、`sdk-kit/src/rsapi.rs` | binding 到 core 的包裝層 |
| 10 分鐘 | `sync/engine/src/database_sync_engine.rs`、`wal_session.rs` | sync 與 WAL/session 的接點 |
| 8 分鐘 | `sqlite/conformance/sqlite-sqltests/`、`tests/integration/` | 選 test harness 的規則 |

這章只建立「外圍系統怎麼接 core」的地圖，不要求你讀完 sync engine 或所有 bindings。

## Extensions

必讀：

```text
extensions/core/src/lib.rs
extensions/core/src/functions.rs
extensions/core/src/types.rs
extensions/core/src/vtabs.rs
extensions/core/src/vfs_modules.rs
core/ext/
core/vtab.rs
core/io/vfs.rs
```

Extension 系統讓外部提供：

- scalar functions。
- aggregate functions。
- virtual tables。
- VFS implementations。

`core/io/vfs.rs` 很值得看，因為它把 extension-provided VFS 接到 core `IO`/`File` traits。這表示 storage 不一定是本地檔案，也可以是 extension 控制的 backend。

範例 extensions：

```text
extensions/crypto
extensions/csv
extensions/regexp
extensions/fuzzy
extensions/ipaddr
extensions/completion
```

第一輪只需知道：extension 是 compiler/function resolver/virtual table/IO backend 的擴展點，不是 SQL 主 loop 的替代品。

## Bindings

`bindings/` 的任務是把 Turso core 暴露給不同語言：

```text
bindings/rust
bindings/c
bindings/javascript
bindings/python
bindings/java
bindings/go
bindings/dotnet
bindings/react-native
bindings/tcl
```

Rust binding 是最適合讀的高階 API：

```text
bindings/rust/src/lib.rs
bindings/rust/src/connection.rs
bindings/rust/src/rows.rs
bindings/rust/src/transaction.rs
bindings/rust/src/value.rs
```

C binding 追 SQLite compatibility：

```text
bindings/c/src/lib.rs
bindings/c/include/sqlite3.h
```

如果你想知道 `sqlite3_prepare_v2`、`sqlite3_step` 類 API 如何映射到 Turso，可以看 C binding。但第一輪讀 engine 時，Rust binding + sdk-kit 足夠。

## sdk-kit

`sdk-kit/src/rsapi.rs` 是 binding 和 core 之間的重要橋：

```text
TursoDatabaseConfig
TursoDatabase
TursoConnection
TursoStatement
TursoStatusCode
```

它處理：

- open database。
- async_io mode。
- connection prepare/prepare_cached。
- statement step/execute。
- error mapping。
- statement caching。
- sync busy gate。

高階 binding 通常不用直接碰 `core::Statement`，而是經過 `TursoStatement`。所以追外部 API bug 時，路線會是：

```text
binding language API
  -> sdk-kit rsapi/capi
  -> core
```

## Sync engine

必讀入口：

```text
sync/engine/src/lib.rs
sync/engine/src/database_sync_engine.rs
sync/engine/src/database_sync_operations.rs
sync/engine/src/database_sync_engine_io.rs
sync/engine/src/wal_session.rs
sync/engine/src/client_proto.rs
sync/engine/src/server_proto.rs
```

Sync engine 會接觸：

- database pages。
- WAL session。
- sparse I/O。
- client/server protocol。
- lazy storage。
- replay generator。

讀 sync 前要先懂第 7 章 WAL。因為 sync engine 對 WAL auto restart/checkpoint 很敏感，不能讓一般 connection 的自動維護破壞它的 watermark。

## MVCC

`core/mvcc/` 是 experimental。入口：

```text
core/mvcc/mod.rs
core/mvcc/database/mod.rs
core/mvcc/cursor.rs
core/mvcc/persistent_storage/logical_log.rs
```

MVCC 和 WAL 的差異：

```text
WAL:
  page-level snapshot through WAL frames

MVCC:
  row versions, snapshot isolation, logical log
```

第一輪學 SQLite-like architecture 時，先以 WAL path 為主。MVCC 可以當進階章節。

## Postgres frontend

`postgres/` 不是把 storage 換成 Postgres，而是提供 PostgreSQL-facing frontend：

```text
postgres/parser
postgres/frontend
postgres/server
postgres/cli
postgres/tests
```

概念上：

```text
Postgres protocol / SQL dialect
  -> translate/adapt to Turso core concepts
  -> core execution
```

如果你想學 SQLite architecture，先略過。等懂 core 後，再研究 dialect/frontend 如何共用 engine。

## Tests: 你學 source 的導航系統

資料庫 source 不能只靠看，必須靠 tests 驗證理解。

主要測試位置：

`sqlite/conformance/sqlite-sqltests/`
: preferred SQL compatibility tests。Parser/planner/executor semantics 的第一選擇。

`sqlite/conformance/turso-sqltests/`
: Turso-specific SQL feature tests，例如 custom types、MVCC、arrays、materialized views。

`tests/integration/`
: Rust integration tests。適合多 connection、I/O、storage assertions、statement lifecycle。

`tests/fuzz/`
: minimized fuzz regressions。

`testing/sqltest/`
: `.sqltest` runner。

`testing/simulator/`
: deterministic simulation。

`testing/concurrent-simulator/`
: concurrency/failure interleaving。

`testing/stress/`
: long-running stress。

`testing/sqlancer/`, `testing/sqlright/`
: differential/random SQL testing。

`testing/cli_tests/`
: CLI behavior tests。

`testing/system/`
: legacy TCL system tests and test databases。

## scripts

高頻工具：

```text
scripts/diff.sh
scripts/run-sim
scripts/run-sqlancer.sh
scripts/run-until-fail.sh
scripts/corruption-debug-tools/
```

`scripts/diff.sh "SQL"` 對新手特別有用，因為它快速比較 sqlite3 和 tursodb output。學 planner/executor 時，用它檢查你的直覺。

## Perf

`perf/` 不適合第一輪學 correctness，但適合第二輪看 hot path：

```text
perf/throughput
perf/memory
perf/tpc-h
perf/tpc-c
perf/clickbench
perf/query-batch
perf/checkpoint-bench
```

等你知道 `VDBE -> BTreeCursor -> Pager -> WAL` 熱路徑後，再用 perf 看成本在哪。

## 本章練習

1. 找一個 SQL conformance test：

```bash
ls sqlite/conformance/sqlite-sqltests | head
```

2. 跑不含 snapshot 的 runner：

```bash
make -C sqlite/conformance run-rust ARGS='--snapshot-filter __never__'
```

預期 runner 會編譯並執行 SQL conformance tests；如果你的機器缺少某些測試依賴，先記下錯誤，不要把這當成 SQL engine 概念讀不懂。

3. 找一個 integration test 讀：

```bash
rg -n "prepare|execute|step|BEGIN|COMMIT" tests/integration
```

4. 找 C binding 的 prepare/step：

```bash
rg -n "sqlite3_prepare_v2|sqlite3_step" bindings/c/src/lib.rs
```

你要能回答：某個 bug 應該加 `.sqltest`、Rust integration test、simulator test、還是 binding test？

## 自我檢查

1. Extension function、virtual table、VFS 分別從哪個方向擴充 engine？
2. Binding 層通常處理什麼？哪些事情不該放在 binding 層？
3. 為什麼讀 sync 前要先懂 WAL/checkpoint？
4. Parser/planner/executor semantics bug 第一優先應該放哪種測試？
5. 多 connection、I/O yield、failure injection 這類 bug 為什麼通常不適合只寫 `.sqltest`？
