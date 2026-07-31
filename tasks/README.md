# Turso Source Learning Tasks

這個 `tasks/` 目錄是半年到一年使用的細切學習任務清單。目標不是把 Turso 文件再摘要一次，而是把「用 Rust 寫出一個 SQLite-like database」拆成很多約 45-75 分鐘可以完成的 source-reading 或小實作單元。

主線對齊 `learn/README.md`：

```text
API / CLI / binding
  -> SQL parser / AST
  -> translate / planner / optimizer / emitter
  -> VDBE bytecode runtime
  -> schema / value / record / function
  -> page format / B-tree / pager
  -> WAL / transaction / IOResult / VFS
  -> extensions / sync / MVCC / testing / performance
```

## 任務完成定義

每個 task 完成時，後續 agent 應該產出一份短筆記或小型實作紀錄，至少包含：

- 讀了哪些 source path 與 symbol。
- 這一層的 input、output、核心資料結構。
- 一個能驗證理解的 SQL、`EXPLAIN`、測試、或 toy Rust 實作片段。
- 一個「我現在能用自己的話說明」的心智模型。

如果某個 task 超過 75 分鐘，不要硬撐，應該把它拆成下一個 `tasks/*.md` 補充 task。這些 task 是規劃，不代表必須一次全部完成。

## 建議節奏

第一輪只做 `00` 到 `07`，建立 SQLite 核心路徑。第二輪做 `08` 到 `10`，補 ecosystem、進階架構與驗證工具。最後做 `11` 的 capstone，把 source reading 轉成自己的 Rust mini database。

每週 5 個 task 約一年完成 250 個 task；每週 8-10 個 task 約半年完成核心與多數進階 task。`T366` 以後是 capstone，可以與前面任務交錯做。

## 文件順序

1. `00-foundation.md`: repo 地圖、Rust 閱讀基礎、SQLite 架構。
2. `01-entry-api.md`: 使用者 API、CLI、SDK、core connection。
3. `02-parser-ast.md`: lexer、token、parser、AST。
4. `03-compiler-planner.md`: translate、resolver、planner、optimizer。
5. `04-emitter-vdbe.md`: emitter、bytecode builder、VDBE runtime。
6. `05-schema-values-sql-features.md`: schema、value、record、function、SQL features。
7. `06-storage-btree-pager.md`: file format、B-tree、pager、page cache。
8. `07-wal-io-transactions.md`: WAL、transaction、checkpoint、IOResult。
9. `08-extensions-bindings-cli.md`: extension API、binding、CLI。
10. `09-mvcc-sync-postgres-incremental.md`: MVCC、sync、Postgres frontend、incremental views。
11. `10-testing-fuzzing-perf.md`: conformance、simulator、fuzzer、benchmark。
12. `11-capstones.md`: 從零實作一個教學版 SQLite-like Rust database。

## 任務格式

每個項目都用同一種形狀：

```text
- [ ] TNNN. 任務名: read `source/path.rs`; output 要產出的筆記、圖、trace、測試或 toy code。
```

`read` 是主要 source，不是唯一 source。遇到不懂的名詞先回 `learn/00-5-glossary.md`，遇到路徑漂移先跑 `rg` 找 symbol。
