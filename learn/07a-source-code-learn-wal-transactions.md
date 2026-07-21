# 07a. 源碼精讀：WAL、交易、Checkpoint

本篇對應 `07a-wal-transactions-checkpoint.md`：WAL 檔案結構、交易的 begin/commit、checkpoint 的四種模式，以及「已提交」到底由什麼決定。

**I/O 重入的機制留給 `07b`**，本篇專注在交易正確性。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 75–90 分鐘（約 19k 字，其中 42% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/storage/sqlite3_ondisk.rs
  ├─ WalHeader        WAL 檔案的前 32 bytes
  └─ WalFrameHeader   每個 frame 的前 24 bytes
core/storage/wal.rs
  ├─ WalAutoActions   誰可以自動 checkpoint／restart
  └─ CheckpointMode   四種 checkpoint 強度
core/storage/pager.rs
  ├─ begin_read_tx    讀交易
  ├─ begin_write_tx   寫交易
  └─ commit_tx        提交（含 auto-checkpoint 的錯誤處理）
```

**本篇最重要的一句話**：交易是否已提交，取決於 **commit frame 是否已經 durable 地寫進 WAL**。之後的 checkpoint 只是搬運工作，失敗不影響已提交的事實。

---

## WAL 的基本模型

傳統的 rollback journal：寫入前先把舊資料備份到 journal，直接改主檔案，失敗時從 journal 還原。

WAL 反過來：**主檔案不動，新資料 append 到 `.db-wal`**。讀者要看某個 page 時，先查 WAL 有沒有較新的版本，沒有才讀主檔案。

好處是寫入變成循序 append（快），而且讀者不會被寫者擋住（讀者看舊 snapshot 即可）。

代價是 WAL 會一直長大，需要定期把它的內容搬回主檔案——這就是 **checkpoint**。

---

## WAL 檔案結構

### WalHeader：前 32 bytes

**`core/storage/sqlite3_ondisk.rs:417-443`** — 完整貼出：

```rust
pub struct WalHeader {
    /// Magic number. 0x377f0682 or 0x377f0683
    /// If the LSB is 0, checksums are native byte order, else checksums are serialized
    pub magic: u32,

    /// WAL format version. Currently 3007000
    pub file_format: u32,

    /// Database page size in bytes. Power of two between 512 and 65536 inclusive
    pub page_size: u32,

    /// Checkpoint sequence number. Increases with each checkpoint
    pub checkpoint_seq: u32,

    /// Random value used for the first salt in checksum calculations
    /// TODO: Incremented with each checkpoint
    pub salt_1: u32,

    /// Random value used for the second salt in checksum calculations.
    /// TODO: A different random value for each checkpoint
    pub salt_2: u32,

    /// First checksum value in the wal-header
    pub checksum_1: u32,

    /// Second checksum value in the wal-header
    pub checksum_2: u32,
```

兩個欄位需要特別理解：

**`checkpoint_seq`** —— 每次 checkpoint 遞增。它是「WAL 世代」的編號。

**`salt_1` / `salt_2`** —— 隨機值，參與所有 frame 的 checksum 計算。

**salt 的用途是判斷 frame 是否屬於當前世代。** WAL 被 restart 之後，新 frame 從檔案開頭覆寫舊 frame。但舊 frame 的 bytes 可能還在（如果新資料比較短）。怎麼區分「這是新寫的」和「這是上一輪殘留的」？

答案就是 salt：restart 時換一組新的 salt，舊 frame 的 checksum 是用舊 salt 算的，用新 salt 驗證必然失敗。**於是殘留的舊 frame 自然被判定為無效**，不需要清空整個檔案。

`magic` 的最低位元決定 checksum 用原生位元組序還是序列化位元組序——這是 SQLite 的效能取捨，允許 checksum 計算走本機最快的路徑。

### WalFrameHeader：每個 frame 前 24 bytes

**`core/storage/sqlite3_ondisk.rs:477-496`** — 完整貼出：

```rust
pub struct WalFrameHeader {
    /// Page number
    pub(crate) page_number: u32,

    /// For commit records, the size of the database file in pages after the commit.
    /// For all other records, zero.
    pub(crate) db_size: u32,

    /// Salt-1 copied from the WAL header
    pub(crate) salt_1: u32,

    /// Salt-2 copied from the WAL header
    pub(crate) salt_2: u32,

    /// Checksum-1: Cumulative checksum up through and including this page
    pub(crate) checksum_1: u32,

    /// Checksum-2: Second half of the cumulative checksum
    pub(crate) checksum_2: u32,
}
```

WAL 的結構是：

```text
[WalHeader 32 bytes]
[FrameHeader 24 bytes][page 內容 page_size bytes]
[FrameHeader 24 bytes][page 內容 page_size bytes]
...
```

**`db_size` 這個欄位是整個交易機制的核心。** 註解說得很清楚：

> For commit records, the size of the database file in pages after the commit. For all other records, zero.

也就是說：**`db_size != 0` 的 frame 就是 commit frame**。

一個交易寫了 5 個 page，就產生 5 個 frame。前 4 個的 `db_size` 是 0，第 5 個是交易後的資料庫大小。

**恢復時的判斷因此變得極簡**：從頭掃描 WAL，只採用「到最後一個 db_size != 0 的 frame」為止的內容。之後的 frame 屬於未完成的交易，直接忽略。

沒有 commit frame，就沒有交易——**crash 時如果只寫了 3 個 frame，那 3 個會被忽略，資料庫維持交易前的狀態**。這就是原子性的實作，不需要額外的 undo 記錄。

**`checksum_1` / `checksum_2` 是累積式的**（cumulative through this page）。每個 frame 的 checksum 包含了它之前所有 frame 的內容。所以只要驗證最後一個 frame 的 checksum，就等於驗證了整條鏈的完整性。中間任何一個 frame 被截斷或損毀，後面的 checksum 都會對不上。

---

## begin_read_tx：讀交易與快取失效

**`core/storage/pager.rs:2923-2935`** — 完整貼出：

```rust
    pub fn begin_read_tx(&self) -> Result<()> {
        let Some(wal) = self.wal.as_ref() else {
            return Ok(());
        };
        let changed = wal.begin_read_tx()?;
        if changed {
            // Someone else changed the database -> assume our page cache is invalid (this is default SQLite behavior, we can probably do better with more granular invalidation)
            self.clear_page_cache(false);
            // Invalidate cached schema cookie to force re-read on next access
            self.set_schema_cookie(None);
        }
        Ok(())
    }
```

短，但每一行都關鍵。

`wal.begin_read_tx()` 建立這個 connection 的 **snapshot**（設定 read mark，記住「我看到 WAL 的第幾個 frame 為止」）。回傳的 `changed` 表示「自從上次以來，資料庫被別人改過了」。

改過了就要**清空整個 page cache**。註解很誠實：

> assume our page cache is invalid (this is default SQLite behavior, we can probably do better with more granular invalidation)

這是保守的做法——只要有任何改動就全清，即使實際上只有一個 page 變了。註解承認可以做得更細緻，但先確保正確。

**為什麼必須清？** 因為 cache 裡的 page 是舊 snapshot 的內容。如果不清，新交易會讀到混合了新舊資料的狀態——這是最嚴重的一類 bug，會產生邏輯上不可能的查詢結果。

schema cookie 也一起失效，因為別人可能改了 schema。

**注意這個函式回傳 `Result<()>` 而不是 `Result<IOResult<()>>`** —— 開始讀交易不需要 I/O，只是設定 read mark。

---

## begin_write_tx

**`core/storage/pager.rs:2969-2981`** — 完整貼出：

```rust
    pub fn begin_write_tx(&self, allowed_auto_actions: WalAutoActions) -> Result<IOResult<()>> {
        // TODO(Diego): The only possibly allocate page1 here is because OpenEphemeral needs a write transaction
        // we should have a unique API to begin transactions, something like sqlite3BtreeBeginTrans
        return_if_io!(self.maybe_allocate_page1());
        let Some(wal) = self.wal.as_ref() else {
            return Ok(IOResult::Done(()));
        };
        wal.begin_write_tx(allowed_auto_actions)?;
        // Must run after the upgrade (and any log restart it performed) so
        // the positions belong to the current WAL generation.
        self.materialize_savepoint_wal_positions();
        Ok(IOResult::Done(()))
    }
```

和讀交易的三個差異：

**一、回傳 `IOResult`** —— 因為 `maybe_allocate_page1()` 可能需要 I/O（全新的資料庫要先建立 page 1）。

**二、取得寫鎖** —— `wal.begin_write_tx()`。WAL 同時只允許一個寫者。

**三、`materialize_savepoint_wal_positions()`** —— 那段註解點出了順序的重要性：

> Must run after the upgrade (and any log restart it performed) so the positions belong to the current WAL generation.

savepoint 要記住「WAL 的哪個位置」才能 rollback 到那裡。但取得寫鎖的過程中**可能發生 WAL restart**（見下面的 `WalAutoActions::Restart`）——restart 之後 frame 編號會歸零，之前記的位置就失效了。

所以必須在 restart **之後**才記錄位置。順序錯了，rollback 會回到錯誤的位置——資料損毀等級的 bug。

`materialize_savepoint_wal_positions` 本身的註解也提到它是冪等的：

**`core/storage/pager.rs:2983-2986`**

```rust
    /// Fill in the WAL position of savepoints opened before this write
    /// transaction, mirroring SQLite's `sqlite3PagerOpenSavepoint` at
    /// write-transaction begin. Idempotent: only fills unmaterialized
    /// positions, so upgrade retry loops (Busy/BusySnapshot) are safe.
```

**冪等是必要的**，因為取得寫鎖可能失敗重試（`Busy` / `BusySnapshot`），這個函式會被呼叫多次。不冪等的話重試就會覆寫掉正確的位置。

---

## WalAutoActions：不是所有 caller 都一樣

**`core/storage/wal.rs:137-152`** — 完整貼出：

```rust
    pub struct WalAutoActions: u8 {
        /// Run an auto-checkpoint after commit when `should_checkpoint()`
        /// is true, and the truncate-checkpoint on connection shutdown.
        const Checkpoint = 0b01;
        /// Restart the WAL header in `try_restart_log_before_write` when
        /// every frame has been backfilled, before starting a write tx.
        const Restart    = 0b10;
    }
}

impl WalAutoActions {
    /// Default policy for ordinary connections: every auto action allowed.
    pub const fn all_enabled() -> Self {
        Self::from_bits_truncate(Self::Checkpoint.bits() | Self::Restart.bits())
    }
}
```

兩個獨立的權限位元：

**`Checkpoint`** —— 允許在 commit 後自動 checkpoint。

**`Restart`** —— 允許在所有 frame 都已回填後，把 WAL header 重置（frame 編號歸零，換新 salt），讓 WAL 檔案從頭重用而不是無限成長。

**為什麼需要關掉它們？** 因為 sync engine 用「WAL frame 編號」當作同步水位（watermark），記錄「我已經同步到第 N 個 frame」。

如果一般 connection 的自動維護把 WAL restart 了，frame 編號歸零，sync engine 記的水位就**指向錯誤的位置**——可能重送已同步的資料，或漏送未同步的資料。

所以 sync engine 持有的 connection 會關掉 `Restart`（甚至 `Checkpoint`），由它自己在安全的時機執行。

**這是一個很好的分層設計案例**：同一個 WAL 實作，透過權限旗標服務不同需求的 caller，而不是為 sync engine 另寫一套。

---

## CheckpointMode：四種強度

**`core/storage/wal.rs:156-171`** — 完整貼出（註解就是規格）：

```rust
pub enum CheckpointMode {
    /// Checkpoint as many frames as possible without waiting for any database readers or writers to finish, then sync the database file if all frames in the log were checkpointed.
    /// Passive never blocks readers or writers, only ensures (like all modes do) that there are no other checkpointers.
    ///
    /// Optional upper_bound_inclusive parameter can be set in order to checkpoint frames with number no larger than the parameter
    Passive { upper_bound_inclusive: Option<u64> },
    /// This mode blocks until there is no database writer and all readers are reading from the most recent database snapshot. It then checkpoints all frames in the log file and syncs the database file. This mode blocks new database writers while it is pending, but new database readers are allowed to continue unimpeded.
    Full,
    /// This mode works the same way as `Full` with the addition that after checkpointing the log file it blocks (calls the busy-handler callback) until all readers are reading from the database file only. This ensures that the next writer will restart the log file from the beginning. Like `Full`, this mode blocks new database writer attempts while it is pending, but does not impede readers.
    Restart,
    /// This mode works the same way as `Restart` with the addition that it also truncates the log file to zero bytes just prior to a successful return.
    ///
    /// Extra parameter can be set in order to perform conditional TRUNCATE: database will be checkpointed and truncated only if max_frames equals to the parameter value
    /// this behaviour used by sync-engine which consolidate WAL before checkpoint and needs to be sure that no frames will be missed
    Truncate { upper_bound_inclusive: Option<u64> },
}
```

四種模式是**遞增的**，每一種包含前一種再多做一點：

| 模式 | 阻塞寫者 | 等待讀者 | 保證全部回填 | 截斷檔案 |
|---|---|---|---|---|
| `Passive` | 否 | 否 | 否 | 否 |
| `Full` | 是 | 是 | 是 | 否 |
| `Restart` | 是 | 是（等到全部只讀主檔） | 是 | 否 |
| `Truncate` | 是 | 是 | 是 | 是 |

**`Passive` 是 auto-checkpoint 用的**：能搬多少算多少，絕不阻塞任何人。因為它是背景維護工作，不該影響使用者的查詢延遲。

**`Truncate` 的條件參數**值得注意：

> Extra parameter can be set in order to perform conditional TRUNCATE: database will be checkpointed and truncated only if max_frames equals to the parameter value. this behaviour used by sync-engine which consolidate WAL before checkpoint and needs to be sure that no frames will be missed

sync engine 需要「**確認 WAL 恰好是我預期的長度，才截斷**」。因為如果在它檢查之後、截斷之前有人又寫了新 frame，直接截斷就會**遺失那些 frame**。

用條件參數把「檢查」和「截斷」變成原子操作——這是典型的 compare-and-swap 思路應用在檔案操作上。

**`core/storage/wal.rs:173-184`** — 兩個輔助判斷：

```rust
impl CheckpointMode {
    pub(crate) fn should_restart_log(&self) -> bool {
        matches!(
            self,
            CheckpointMode::Truncate { .. } | CheckpointMode::Restart
        )
    }
    /// All modes other than Passive require a complete backfilling of all available frames
    /// from `shared.metadata.nbackfills + 1 -> shared.metadata.max_frame`
    fn require_all_backfilled(&self) -> bool {
        !matches!(self, CheckpointMode::Passive { .. })
    }
```

`nbackfills` 是「已回填到第幾個 frame」的水位。checkpoint 就是把 `nbackfills + 1` 到 `max_frame` 之間的 frame 搬進主檔案，然後推進水位。

---

## commit_tx：提交的完整流程

**`core/storage/pager.rs:3031-3059`** — 完整貼出開頭：

```rust
    pub fn commit_tx(
        &self,
        connection: &Connection,
        update_transaction_state: bool,
    ) -> Result<IOResult<()>> {
        if connection.is_nested_stmt() {
            // Parent statement will handle the transaction commit.
            return Ok(IOResult::Done(()));
        }
        let Some(wal) = self.wal.as_ref() else {
            // TODO: Unsure what the semantics of "end_tx" is for in-memory databases, ephemeral tables and ephemeral indexes.
            self.clear_savepoints()?;
            return Ok(IOResult::Done(()));
        };

        let complete_commit = || {
            if update_transaction_state {
                connection.set_tx_state(TransactionState::None);
            }
            self.commit_wal_end();
        };

        loop {
            let commit_state = self.commit_info.read().state;
            tracing::debug!("commit_state: {:?}", commit_state);
            // we separate auto-checkpoint from the commit in order for checkpoint to be able to backfill WAL till the end
            // (including new frames from current transaction)
            // otherwise, we will be unable to do WAL restart
            match commit_state {
```

**第一個檢查**：巢狀語句不自己 commit，交給父語句。這是 `01-source-code-learn-2-prepare-parse.md` 講的 `nestedness` 計數的用途——engine 內部執行 helper SQL 時，絕不能把使用者的交易提交掉。

**又是 `loop` + `match state`** —— commit 也是狀態機，因為它有大量 I/O。

那段註解解釋了為什麼 auto-checkpoint 要**分離成獨立狀態**：

> we separate auto-checkpoint from the commit in order for checkpoint to be able to backfill WAL till the end (including new frames from current transaction) otherwise, we will be unable to do WAL restart

checkpoint 必須在**本次交易的 frame 也寫完之後**才執行，這樣才能回填到 WAL 結尾，進而讓 restart 成為可能。如果在 commit 中途 checkpoint，WAL 尾端還有未寫的 frame，就永遠無法完全回填。

### 主要路徑：先寫 WAL

**`core/storage/pager.rs:3080-3107`** — 完整貼出：

```rust
                _ => {
                    return_if_io!(self.commit_wal(
                        connection.wal_auto_actions(),
                        connection.get_sync_mode(),
                        connection.get_data_sync_retry(),
                    ));

                    let schema_did_change = match connection.get_tx_state() {
                        TransactionState::Write { schema_did_change } => schema_did_change,
                        _ => false,
                    };

                    wal.end_write_tx();
                    wal.end_read_tx();
                    // we do not set TransactionState::None here - because caller can decide that nothing should be done for this connection
                    // and skip next calls of the commit_tx methods after IO

                    tracing::debug!("commit_tx: schema_did_change={schema_did_change}");
                    if schema_did_change {
                        let schema = connection.schema.read().clone();
                        connection.db.update_schema_if_newer(schema);
                    }

                    if self.commit_info.read().state != CommitState::AutoCheckpoint {
                        complete_commit();
                        self.clear_savepoints()?;
                        return Ok(IOResult::Done(()));
                    }
                }
```

順序很重要：

1. **`commit_wal(...)`** —— 把 dirty page 寫成 WAL frame，最後一個標記為 commit frame，依 sync mode 決定要不要 fsync。**這一步完成，交易就已提交。**
2. **釋放鎖** —— `end_write_tx` / `end_read_tx`。
3. **schema 變更時更新共享 schema** —— 讓其他 connection 看得到新 schema。
4. **收尾**。

`schema_did_change` 從交易狀態裡取出，然後 `connection.db.update_schema_if_newer(schema)` 把這個 connection 的 schema 推廣到 `Database`（共享層）。**這是 `01-source-code-learn-1-entry-api.md` 講的 Database/Connection 分工的具體運作**：DDL 在 connection 層編譯執行，提交後才發布到共享層。

那段註解說明了為什麼**不在這裡**設 `TransactionState::None`：

> we do not set TransactionState::None here - because caller can decide that nothing should be done for this connection and skip next calls of the commit_tx methods after IO

因為這個函式可能因 I/O 而多次進出，狀態轉換要放在真正確定完成的地方（`complete_commit()`）。

### auto-checkpoint 失敗的處理

**`core/storage/pager.rs:3060-3079`** — 完整貼出：

```rust
                CommitState::AutoCheckpoint => {
                    let checkpoint_result = self.checkpoint(
                        CheckpointMode::Passive {
                            upper_bound_inclusive: None,
                        },
                        connection.get_sync_mode(),
                        false,
                    );
                    match checkpoint_result {
                        Ok(IOResult::IO(io)) => return Ok(IOResult::IO(io)),
                        Ok(IOResult::Done(_)) => complete_commit(),
                        Err(err) => {
                            tracing::debug!("auto-checkpoint failed: {err}");
                            complete_commit();
                            self.cleanup_after_auto_checkpoint_failure();
                        }
                    }
                    self.clear_savepoints()?;
                    return Ok(IOResult::Done(()));
                }
```

**這是本篇最重要的一段。**

看 `Err(err)` 那個分支：checkpoint 失敗了，但仍然

```rust
                            complete_commit();
```

**照常完成提交，並且函式回傳 `Ok`。**

為什麼？因為到達這個狀態時，`commit_wal` 已經執行完畢——**commit frame 已經 durable 地寫進 WAL 了**。從資料庫語義上說，這個交易**已經提交**。checkpoint 只是把 WAL 內容搬回主檔案的維護工作，它失敗了，資料仍然安全地在 WAL 裡，下次還能再搬。

如果這裡把 checkpoint 錯誤當成交易失敗回傳給使用者，使用者會以為交易失敗而重做——但資料其實已經寫進去了，於是產生重複資料。**這是資料正確性等級的 bug。**

錯誤只被 `tracing::debug!` 記錄下來，然後執行 `cleanup_after_auto_checkpoint_failure()` 清理 checkpoint 的中間狀態。

這段程式碼和 `01-source-code-learn-4-step-vm.md` 講的 `normal_step` 裡那個 `CheckpointFailed` 包裝是**同一個原則的兩處實作**：

```rust
                    if pager.is_checkpointing() {
                        // ...so that abort() knows not to try to rollback the transaction,
                        // because the transaction is already durable in the WAL and hence committed.
                        let checkpoint_err = LimboError::CheckpointFailed(err.to_string());
```

VM 那邊處理的是「checkpoint 期間的 I/O 錯誤」，這邊處理的是「checkpoint 操作本身失敗」。兩者都必須確保**不會把已提交的交易當成可回滾的**。

**判斷「交易是否已提交」的唯一標準是：commit frame 是否已經 durable。** 其他任何後續步驟失敗都不改變這個事實。

---

## 讀取路徑：snapshot 如何運作

```text
begin_read_tx
  → wal.begin_read_tx()  設定 read mark = 當前的 max_frame
  → 若 DB 變過就清 page cache

讀 page N:
  1. page cache 有？→ 直接用
  2. WAL 裡有 page N 的 frame，且 frame 編號 <= 我的 read mark？→ 用最新的那個
  3. 否則 → 讀主檔案

end_read_tx
  → 釋放 read mark
```

**read mark 就是 snapshot。** 別人在我讀取期間提交了新交易，那些 frame 的編號會大於我的 read mark，所以我看不到——**讀者不會看到未提交或後來提交的資料，也不會被寫者阻塞**。

read mark 同時也是 checkpoint 的約束：checkpoint 不能回填「還有讀者可能需要的舊版本」。`Passive` 模式因此可能只回填一部分——有讀者卡在舊 snapshot 時，它就搬不動那之後的 frame。

**這解釋了一個實務現象**：如果有長時間開著的讀交易，WAL 會一直長大而 checkpoint 無效。長交易在 WAL 模式下的代價就在這裡。

---

## 動手驗證

觀察 WAL 檔案的成長與 checkpoint：

```bash
cd /tmp && rm -f w.db*
/Users/stanhsu/projects/turso/target/debug/tursodb w.db "CREATE TABLE t(a); INSERT INTO t VALUES (1);"
ls -la w.db*
```

會看到 `w.db` 和 `w.db-wal` 兩個檔案。

觀察交易的原子性：

```bash
/Users/stanhsu/projects/turso/target/debug/tursodb w.db
```

```sql
BEGIN;
INSERT INTO t VALUES (2);
SELECT * FROM t;   -- 看得到 2
ROLLBACK;
SELECT * FROM t;   -- 看不到 2
```

rollback 只是丟棄未寫入 commit frame 的資料，不需要 undo。

觀察 checkpoint：

```sql
PRAGMA wal_checkpoint(TRUNCATE);
```

執行後 `.db-wal` 應該變成 0 bytes——這就是 `CheckpointMode::Truncate`。

追 source：

```bash
rg -n "pub struct WalHeader|pub struct WalFrameHeader" core/storage/sqlite3_ondisk.rs
rg -n "WalAutoActions|pub enum CheckpointMode" core/storage/wal.rs
rg -n "pub fn begin_read_tx|pub fn begin_write_tx|pub fn commit_tx" core/storage/pager.rs
```

---

## 自我檢查

1. WAL 的 salt 有什麼用？WAL restart 之後，殘留的舊 frame 為什麼不會被誤判為有效？
2. `WalFrameHeader.db_size` 為什麼是交易機制的核心？如何用它判斷一個 frame 是不是 commit frame？
3. crash 時 WAL 裡有 3 個 frame 但沒有 commit frame，恢復時會怎麼處理？為什麼不需要 undo 記錄？
4. frame 的 checksum 是累積式的，這帶來什麼好處？
5. `begin_read_tx` 發現 `changed` 時為什麼要清空**整個** page cache？不清會出什麼問題？
6. `begin_write_tx` 為什麼回傳 `IOResult` 而 `begin_read_tx` 不用？
7. `materialize_savepoint_wal_positions` 為什麼必須在 WAL restart **之後**執行？順序反了會怎樣？
8. 這個函式為什麼必須冪等？
9. sync engine 為什麼要關掉 `WalAutoActions::Restart`？
10. 四種 `CheckpointMode` 的差別是什麼？auto-checkpoint 為什麼用 `Passive`？
11. `Truncate` 的 `upper_bound_inclusive` 參數解決什麼競態問題？
12. auto-checkpoint 失敗時，`commit_tx` 為什麼仍然 `complete_commit()` 並回傳 `Ok`？如果改成回傳錯誤會出什麼事？
13. 「交易已提交」的唯一判準是什麼？
14. 為什麼長時間開著的讀交易會讓 WAL 一直長大？

---

下一篇 `07b-source-code-learn-ioresult-reentry.md`：`IOResult` 的完整機制、狀態機的兩種寫法、重入正確性的常見錯誤。
