# 07a. Pager Transaction、WAL、Checkpoint

本章目標：先看 transaction correctness，不看 explicit I/O re-entry 細節。I/O state machine 放到下一章。

## 60 分鐘閱讀範圍

| 時間 | 檔案 | 只讀這些 symbol / 區塊 |
|---:|---|---|
| 8 分鐘 | `docs/agent-guides/transaction-correctness.md` | WAL mechanics overview |
| 10 分鐘 | `core/storage/wal.rs` | `WalAutoActions`、`CheckpointMode` |
| 12 分鐘 | `core/storage/pager.rs` | `begin_read_tx`、`begin_write_tx` |
| 12 分鐘 | `core/storage/pager.rs` | `commit_tx` high-level loop，不追完整 `commit_wal_inner` |
| 8 分鐘 | `core/storage/pager.rs` | `rollback_tx` 入口 |
| 5 分鐘 | `core/vdbe/execute.rs` | 只讀 `op_transaction` 的狀態名與分支，不展開所有 branch |
| 5 分鐘 | 練習與自我檢查 | 跑 BEGIN/ROLLBACK |

## 心智模型

正確的 WAL 寫入路徑：

```text
begin write transaction
modify pages in pager cache
commit:
  collect dirty pages
  append WAL frames
  mark commit frame
  sync WAL if required
  publish committed frames
  maybe checkpoint
end transaction
```

讀取路徑：

```text
begin read transaction
  acquire snapshot/read mark
read page:
  check WAL frame visible in snapshot
  else read main db file
end read transaction
```

## WAL 基礎

Turso 主要使用 WAL mode。相關檔案：

```text
.db
.db-wal
```

和 SQLite 傳統 WAL 不同的一個重點：Turso 沒有 SQLite 那種 `.db-shm` shared memory file 作為 WAL-index；一般情況下使用 in-memory structures，例如 frame cache、read marks、locks。多程序 WAL 是 experimental/feature-gated 方向。

WAL frame 包含 page number、commit flag/db size、checksum 等。commit transaction 的可見性依賴 commit frame。

## Pager transaction entrypoints

`core/storage/pager.rs` 先看：

```text
begin_read_tx
begin_write_tx
commit_tx
rollback_tx
```

`begin_read_tx`：

- 讓 WAL 建立 connection snapshot。
- 如果偵測 DB changed，清 page cache。
- 清 schema cookie cache。

`begin_write_tx`：

- 確保 page 1 已初始化。
- 向 WAL 取得 write transaction。
- materialize savepoint WAL positions。

`commit_tx`：

- 如果是 nested statement，parent statement 會處理 commit。
- 呼叫 `commit_wal` flush dirty pages。
- end write/read transaction。
- schema changed 時更新 shared schema。
- 可能 auto-checkpoint。

## WalAutoActions

`core/storage/wal.rs` 定義 `WalAutoActions`：

```text
Checkpoint
Restart
```

普通 connection 可以讓 engine 自動 checkpoint/restart WAL；sync engine 這種外部管理 WAL watermark 的 caller 不能讓 engine 隨便 restart WAL header，否則水位會失效。

所以不是所有 caller 都用同一個 WAL maintenance policy。

## Checkpoint

Checkpoint 把 WAL frame backfill 回 main database file。`CheckpointMode` 有：

```text
Passive
Full
Restart
Truncate
```

概念：

- Passive 不等待讀者，能 checkpoint 多少算多少。
- Full/Restart/Truncate 更積極，可能等待或要求全部 backfill。
- Truncate 會把 WAL 截到 0。

Checkpoint failure 和 commit failure 的語義不同。若 commit frame 已經 durable，但 auto-checkpoint 失敗，transaction 仍然已提交。VM error handling 會把 checkpoint error 特別包裝，避免把已 durable 的 commit 當成可 rollback。

## VM 和 transaction 的交會

`core/vdbe/execute.rs` 的 `op_transaction` 是 VM 進入 pager/WAL 的入口。它會根據 `TransactionMode` 和目前 connection state 決定：

- start read transaction。
- upgrade to write transaction。
- handle pending upgrade。
- begin named savepoints。
- check schema cookie。
- MVCC branch。
- attached DB branch。

這一章只需要知道 `op_transaction` 會進入 Pager/WAL。完整 re-entry state machine 下一章再看。

## 練習

跑：

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
BEGIN;
INSERT INTO t VALUES (1, 'a');
SELECT * FROM t;
ROLLBACK;
SELECT * FROM t;
```

預期第一次 `SELECT` 看得到 `1|a`，rollback 後第二次 `SELECT` 看不到該 row。

追 source：

```bash
rg -n "pub struct WalAutoActions|pub enum CheckpointMode" core/storage/wal.rs
rg -n "begin_read_tx|begin_write_tx|commit_tx|rollback_tx" core/storage/pager.rs
rg -n "OpTransactionState|fn op_transaction" core/vdbe/execute.rs
```

## 自我檢查

1. SQL `COMMIT`、Pager `commit_tx`、WAL commit frame 是同一層嗎？
2. Reader snapshot 如何避免看到未提交 transaction？
3. auto-checkpoint 失敗時，為什麼 transaction 仍可能已提交？
4. `WalAutoActions::Restart` 為什麼可能影響 sync engine？

