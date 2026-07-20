# Turso Source Learning Guide

這份 `learn/` 是給「資料庫新手，但想真正讀懂 SQL database source code」的 top-down 讀書路線。它參考 SQLite 官方 architecture 頁面的分層方式：外部介面、SQL compiler、bytecode VM、B-tree、pager、OS/VFS、測試。但這個 repo 不是 SQLite C code，而是 Turso 的 Rust SQLite rewrite，所以路線會把 Rust workspace、explicit async I/O state machine、sync/MVCC、extension/binding 也一起放進來。

正式讀源碼前，建議先花 30 分鐘看 SQLite 官方 architecture 頁面：https://sqlite.org/arch.html 。不用背細節，只要先知道 interface、SQL compiler、virtual machine、B-tree、pager、OS interface 這幾層。

先記住一條主線：

```text
使用者 SQL
  -> CLI / binding / SDK API
  -> Connection::prepare
  -> dialect parser / AST
  -> translate / planner / emitter
  -> VDBE Program + Insn
  -> Statement::step / Program::normal_step
  -> Cursor / BTree / Pager
  -> WAL / DatabaseStorage / IO backend
  -> .db / .db-wal / memory / custom VFS / sync storage
```

如果你曾看過 SQLite architecture，Turso 也大致是「SQL 先編譯成 bytecode，再由 virtual machine 執行」。SQLite 官方頁面說明了 prepare/step、tokenizer/parser、code generator、bytecode engine、B-tree、pager、OS interface 這些層次；Turso 的對應檔案主要分布在 `bindings/`、`cli/`、`sqlite/parser/`、`core/translate/`、`core/vdbe/`、`core/storage/`、`core/io/`。

## 建議閱讀順序

每一篇都設計成「大約一小時」的源碼閱讀單元。不是要求你一次看完整個檔案，而是每章都會給「檔案 + symbol/區塊 + 預估分鐘」。如果某個檔案很大，例如 `core/vdbe/execute.rs`、`core/storage/btree.rs`、`core/storage/wal.rs`，只看該章指定的 symbol。

1. `00-repo-map.md`
   先認識 repo 的產品形狀、workspace、每個 top-level 目錄與重要檔案。這章不要急著鑽細節，目標是知道「我要找某個概念時該去哪」。

2. `00-5-glossary.md`
   補資料庫新手最容易卡住的名詞：AST、VDBE、register、cursor、rowid、affinity、record、page、B-tree、pager、WAL、checkpoint、snapshot、fsync、I/O yield、re-entry。

3. `01-sql-lifecycle.md`
   從一條 `SELECT * FROM t WHERE id = ?` 的生命週期看起：誰接 SQL、誰 parse、誰 compile、誰 step、誰回 row。

4. `02-parser-and-ast.md`
   看 SQL 文字如何變 AST。重點是 `sqlite/parser/src/parser.rs`、`lexer.rs`、`ast.rs`，以及 Turso 和 SQLite 在 parser 實作風格上的差異。

5. `03-compiler-planner.md`
   看 AST 如何變成 VDBE bytecode。重點是 `core/translate/mod.rs`、`select.rs`、`planner.rs`、`plan.rs`、`emitter/`、`vdbe/builder.rs`。

6. `04-vdbe-execution.md`
   看 bytecode VM 如何執行。重點是 `core/vdbe/mod.rs`、`insn.rs`、`execute.rs`、`statement.rs`。

7. `05-schema-values-records.md`
   看 `sqlite_schema`、table/index metadata、`Value`、record、affinity。這章把「SQL 世界的 metadata/value」和「磁碟上的 record」接起來。

8. `05b-functions-expressions.md`
   把 function system 從 schema 章移出來，專心看 scalar/aggregate/window function 如何被 resolver、expression compiler、VDBE 串起來。

9. `06a-file-format-pages.md`
   只看 SQLite-compatible file format 與 page layout：database header、page type、cell、overflow、freelist。

10. `06b-btree-cursor-pager.md`
    看 B-tree cursor 與 Pager 如何把 page layout 變成可 seek/scan/insert/delete 的 storage API。

11. `07a-wal-transactions-checkpoint.md`
    看 Pager transaction、WAL commit、rollback、checkpoint、autocommit/explicit transaction 的分層。

12. `07b-ioresult-reentry.md`
    看 Turso 最獨特的 explicit `IOResult`、completion、re-entry correctness。這章獨立出來，因為它是讀懂 async storage/VM 的分水嶺。

13. `08-extensions-sync-testing.md`
   看 extension、custom VFS、sync engine、Postgres frontend、測試工具如何包在核心之外。

14. `09-reading-projects.md`
    用小任務學源碼。這章不是一小時讀完九個 project；每個 project 都是獨立 30-60 分鐘 session。

## 預備知識

Rust 方面，你至少要能讀懂 `enum`、`trait`、`Result<T, E>`、`Arc<T>`、`Mutex/RwLock`、macro 呼叫，以及 `match` 狀態機。你不需要先會寫完整 async runtime，但要知道 Turso core 很多地方不是 `async fn`，而是用 `IOResult` 明確表示「現在要等 I/O」。

資料庫方面，先懂 SQL 基本語法即可。B-tree、WAL、checkpoint、record format 會在後面逐步補。遇到不懂的詞，先回 `00-5-glossary.md`。

## 讀源碼的節奏

每章建議照這個節奏：

1. 先看本章的「先建立心智模型」。
2. 打開「本章必讀檔案」，只看導讀指定的 struct/enum/function。
3. 用 `rg` 找一個關鍵字往下追，例如 `translate_select`、`Insn::Column`、`begin_write_tx`。
4. 用 `cargo run -q --bin tursodb -- -q` 或 `scripts/diff.sh "SQL"` 觀察實際行為。
5. 只在你能講出「上一層呼叫下一層是為了什麼」時，再進下一章。

## 路徑與 symbol 可能漂移

這份教材以目前 checkout 的 `rg` 結果為準。Turso source 會變動，文件裡的 symbol 可能漂移；深入讀某章前，先跑：

```bash
bash learn/lint-learn-docs.sh
```

如果某個 symbol 不在原檔，先用 `rg -n "symbol_name"` 找新位置，再回到章節主線。

## 你要先接受的三個事實

第一，這不是一個從零教 Rust 的路線。遇到 `Arc`、`RwLock`、trait object、feature flag 時，先把它們當工程上的外殼，不要在第一輪卡太久。

第二，這不是一個只讀 happy path 的路線。資料庫真正的困難常在錯誤、rollback、I/O yield、schema reparse、cursor invalidation、checkpoint。文件會一直提醒你哪些地方是 correctness 核心。

第三，這個 repo 同時叫 Turso 和 Limbo。`Cargo.toml` 的 crate 名是 `turso_core`、`turso_parser` 等，但一些舊註解和 module doc 還會說 Limbo。讀的時候把 Limbo 理解成核心 engine 的歷史名稱即可。

## 常用命令

```bash
cargo build
cargo test
cargo fmt
cargo clippy --workspace --all-features --all-targets -- --deny=warnings
cargo run -q --bin tursodb -- -q
scripts/diff.sh "SELECT 1 + 1"
make -C sqlite/conformance run-rust ARGS='--snapshot-filter __never__'
```

不要用 `--release` 讀源碼行為；debug build 的 assert、trace、錯誤更適合學習。
