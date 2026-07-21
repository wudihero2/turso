# 13. 源碼精讀：Sync Engine 與同步協定

`sync/engine/` 有 16,198 行，實作 Turso Cloud 的雙向同步：本機資料庫與遠端保持一致，且**支援離線寫入後再合併**。

`08-source-code-learn-extensions-sync-testing.md` 只講了接點（`WalSession`、`WalAutoActions`）。本篇看完整的協定與資料流。

**前置知識**：`07a-source-code-learn-wal-transactions.md`（WAL 與 checkpoint）、`10-source-code-learn-mvcc.md`（logical log 的概念）。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 60–75 分鐘（約 14k 字，其中 32% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
sync/engine/src/
  ├─ client_proto.rs               LogicalOp ── 同步的資料單位
  ├─ database_tape.rs              DatabaseTape ── 擷取與重放變更（3,024 行）
  ├─ database_sync_engine.rs       對外 API（4,361 行）
  ├─ database_sync_operations.rs   協定實作（5,432 行）
  ├─ database_replay_generator.rs  把變更轉回 SQL
  ├─ database_sync_lazy_storage.rs 按需下載 page
  └─ wal_session.rs                WAL 接點（08 講過）
```

---

## 兩種同步粒度

`08-source-code-learn-extensions-sync-testing.md` 看過 `WalSession`：

```rust
    pub fn begin(&mut self) -> Result<()> {
        assert!(!self.in_txn);
        self.conn.wal_insert_begin()?;
```

當時說它「直接插入 WAL frame 而不是重放 SQL」，因為 frame 是 page 層級的，重放結果**位元組級別完全相同**。

但這只適用於**單向**同步（遠端是唯一寫者）。如果本機也能寫入——離線編輯、多裝置——就會有衝突，page 層級的 frame 無法合併。

**所以 sync engine 有兩條路徑：**

| | 粒度 | 用途 | 能否合併 |
|---|---|---|---|
| **page 同步** | WAL frame | bootstrap、單向拉取 | 否（整份覆寫） |
| **logical 同步** | 列的操作 | 雙向同步、離線寫入 | 是 |

從函式名稱就能看出這個分野：

**`sync/engine/src/database_sync_operations.rs`** — 主要進入點：

```rust
pub async fn db_bootstrap<IO: SyncEngineIo, Ctx>(       // :1688  初次下載整份
pub async fn pull_updates_v1<IO: SyncEngineIo, Ctx>(    // :1814  拉取更新
pub async fn pull_pages_v1<IO: SyncEngineIo, Ctx>(      // :2100  拉取 page
pub async fn push_logical_changes<IO: SyncEngineIo, Ctx>( // :2756  推送邏輯變更
pub async fn bootstrap_db_file<IO: SyncEngineIo, Ctx>(  // :3149
```

**`pull_pages` 是 page 粒度，`push_logical_changes` 是邏輯粒度。**

為什麼推送用邏輯？因為本機的寫入必須**合併**進遠端已有的變更，不能覆寫。而拉取可以用 page（快、精確），因為遠端是權威。

---

## LogicalOp：同步的資料單位

**`sync/engine/src/client_proto.rs:3-16`** — 完整貼出：

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, prost::Enumeration)]
#[repr(i32)]
/// Logical operation kind decoded from the server's MVCC log.
pub enum LogicalOpType {
    Unspecified = 0,
    /// Insert or replace one row by rowid.
    UpsertRow = 1,
    /// Delete one row by rowid.
    DeleteRow = 2,
    /// Replay a schema create/drop/refresh/alter operation.
    Schema = 3,
    /// Replay database-header fields such as `user_version` and `application_id`.
    UpdateHeader = 4,
}
```

**只有四種操作**，而且注意兩件事：

**一、沒有 `UpdateRow`。** 更新用 `UpsertRow`（插入或取代）表示。

這和 `11-source-code-learn-incremental-views.md` 講的 DBSP `Delta` 用 delete+insert 表示 update 是同一個思路：**減少操作種類，讓重放邏輯更簡單**。`UpsertRow` 不需要知道那一列原本存不存在。

**二、`Unspecified = 0` 是 protobuf 的慣例。** 這個 enum 有 `prost::Enumeration` 屬性，代表它是 protobuf 定義的一部分。protobuf 要求 enum 的 0 值代表「未設定」，這樣新增欄位時舊版本的解碼器不會誤判。

**協定用 protobuf 表示 = 需要向前/向後相容。** 客戶端和伺服器可能版本不同，協定必須能演進。

### Schema 變更的四種動作

**`sync/engine/src/client_proto.rs:18-31`** — 完整貼出：

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, prost::Enumeration)]
#[repr(i32)]
/// Schema action represented by a logical schema operation.
pub enum LogicalSchemaAction {
    Unspecified = 0,
    /// Create the schema object if it does not already exist.
    Create = 1,
    /// Drop the schema object.
    Drop = 2,
    /// Replace the client-side schema object definition with the supplied SQL.
    Refresh = 3,
    /// Replay an ALTER statement exactly as supplied by the server.
    Alter = 4,
}
```

**`Refresh` 和 `Alter` 的差異揭露了一個實務難題。**

- **`Alter`** —— 「exactly as supplied by the server」，原封不動重放 ALTER 語句。
- **`Refresh`** —— 「Replace the client-side schema object definition」，直接用伺服器給的 SQL 覆蓋本機定義。

為什麼需要 `Refresh`？因為 ALTER 的重放可能失敗或產生歧義（本機狀態與伺服器不同步時）。`Refresh` 是「不要試著推導，直接告訴你最終狀態」的逃生門。

**`Create` 帶 "if it does not already exist"** —— 冪等。同步協定必須容忍**重複傳送**（網路重試），所以操作要盡量冪等。

### 為什麼 header 也要同步

```rust
    /// Replay database-header fields such as `user_version` and `application_id`.
    UpdateHeader = 4,
```

`06a-source-code-learn-file-format-pages.md` 講過 `DatabaseHeader` 有 `user_version` 和 `application_id`——這些是**應用程式自己用的欄位**（例如記錄 schema migration 版本）。

它們不在任何表裡，是 header 的一部分。所以同步協定要單獨處理。

### LogicalOp 的欄位設計

**`sync/engine/src/client_proto.rs:48-60`** — 完整貼出：

```rust
#[derive(prost::Message, Clone, PartialEq, Eq)]
/// One logical operation decoded from a portable MVCC logical-log frame.
///
/// Only the fields required by `op_type` are populated. Row operations use
/// `table_name`, `rowid`, and optionally `record`; schema operations use the
/// schema fields; header updates use `user_version` and/or `application_id`.
pub struct LogicalOp {
    /// Encoded [`LogicalOpType`].
    #[prost(enumeration = "LogicalOpType", tag = "1")]
    pub op_type: i32,
    /// User table affected by row operations.
    #[prost(string, tag = "2")]
    pub table_name: String,
```

**「Only the fields required by `op_type` are populated」** —— 這是 protobuf 的常見模式：一個扁平的訊息，依 type 欄位決定哪些欄位有意義。

Rust 的慣用寫法會是 enum with data（每個變體帶自己的欄位），但 protobuf 的 `oneof` 支援在跨語言時比較麻煩，所以用扁平結構加上約定。

**代價是型別系統無法強制正確性**——你可以建出一個 `op_type = DeleteRow` 卻填了 `user_version` 的訊息。所以註解要寫清楚哪些欄位對應哪個 type。

註解也點明了來源：「decoded from a **portable MVCC logical-log** frame」——這連回 `10-source-code-learn-mvcc.md` 講的 logical log，以及 `core/mvcc/portable_logical.rs`（192 行）那個「可攜格式」模組。

**伺服器端用 MVCC，客戶端可能用 WAL**，所以需要一個雙方都認得的中介格式。

---

## DatabaseTape：擷取與重放

**`sync/engine/src/database_tape.rs:21-30`** — 完整貼出：

```rust
/// Simple wrapper over [turso::Database] which extends its intereface with few methods
/// to collect changes made to the database and apply/revert arbitrary changes to the database
pub struct DatabaseTape {
    inner: Arc<turso_core::Database>,
    cdc_table: Arc<String>,
    pragma_query: String,
    cdc_version: std::sync::RwLock<Option<turso_core::CdcVersion>>,
    disable_auto_checkpoint: bool,
}
```

**「Tape」這個命名很貼切**：像錄音帶一樣，可以錄下變更、也可以倒帶重放。註解說的 "apply/**revert** arbitrary changes" ——**能反向套用**，這是衝突解決的基礎。

**`sync/engine/src/database_tape.rs:32-36`** — 常數：

```rust
const DEFAULT_CDC_TABLE_NAME: &str = "turso_cdc";
const DEFAULT_CDC_MODE: &str = "full";
const DEFAULT_CHANGES_BATCH_SIZE: usize = 100;
pub const CDC_PRAGMA_NAME: &str = "capture_data_changes_conn";
```

**CDC（Change Data Capture）的變更記錄在一張普通的表 `turso_cdc` 裡。**

這個設計很值得注意：**變更記錄本身也是資料庫資料**，因此自動獲得交易保證。如果交易 rollback，CDC 記錄也一起 rollback——不會出現「變更記錄說改了但資料沒改」的不一致。

如果 CDC 寫在資料庫外部（例如另一個檔案），就要自己處理原子性，而且幾乎不可能做對。

`DEFAULT_CDC_MODE = "full"` —— 「full」表示同時記錄舊值與新值。舊值是 revert 所必需的。

`03-source-code-learn-3-emitter-dml-ddl.md` 看過 CDC 在編譯期的掛勾：

```rust
                let prepared = prepare_cdc_if_necessary(
                    program,
                    t_ctx.resolver.schema(),
                    Some(changed_table.get_name()),
                )?;
```

**`04-source-code-learn-2-cursor-opcodes.md` 講的 `op_insert` 擷取舊值機制，同時服務 IVM 和 CDC。**

**`disable_auto_checkpoint`** —— 直接對應 `07a-source-code-learn-wal-transactions.md` 講的 `WalAutoActions`。sync engine 必須關掉自動 checkpoint，因為它用 WAL frame 編號當同步水位。

---

## Sync Engine 的對外 API

**`sync/engine/src/database_sync_engine.rs`** — 主要方法：

```rust
    pub async fn bootstrap_db<Ctx>(              // :2274  初次同步
    pub async fn open_db<Ctx>(                   // :2480
    pub async fn create_db<Ctx>(                 // :2578
    pub async fn checkpoint<Ctx>(                // :2758
    pub async fn wait_changes_from_remote<Ctx>(  // :2881  等待遠端變更
    pub async fn apply_changes_from_remote<Ctx>( // :3014  套用遠端變更
    pub async fn push_changes_to_remote<Ctx>(    // :4286  推送本機變更
    pub async fn sync<Ctx>(                      // :4322  完整雙向同步
    pub async fn pull_changes_from_remote<Ctx>(  // :4330
```

**`sync()` 是雙向的組合**（推送 + 拉取），而 `push` / `pull` 可以單獨呼叫。

注意所有方法都是 `async fn` 且帶 `Ctx` 泛型與 `coro: &Coro<Ctx>` 參數。

**這是一個協程抽象。** `07b-source-code-learn-ioresult-reentry.md` 講過 core 不用 async/await 而用 `IOResult`；但 sync engine 涉及**網路 I/O**，那和儲存 I/O 性質不同（延遲高、要處理逾時與重試），所以這一層用了不同的模型。

`Coro<Ctx>` 讓 sync engine 能在不同的執行環境（原生 async runtime、WASM、嵌入式）裡運作——`Ctx` 是環境提供的上下文。

`wait_changes_from_remote` 的存在說明支援**推送式更新**（伺服器主動通知有變更），而不是只能輪詢。

---

## 三種同步路徑

### 一、Bootstrap：初次下載

**`sync/engine/src/database_sync_operations.rs:1688-1696`** — 節錄：

```rust
pub async fn db_bootstrap<IO: SyncEngineIo, Ctx>(
    ...
    tracing::info!("db_bootstrap");
    ...
    tracing::info!("db_bootstrap: fetched db_info={db_info:?}");
    let content = db_bootstrap_http(ctx, db_info.current_generation).await?;
```

**`current_generation` 是一個關鍵概念。**

「generation」是資料庫的世代編號。遠端做了某些操作（例如完整重建、或 WAL restart）會遞增世代。客戶端記著自己的世代——**世代不同就代表增量同步不再有效，必須重新 bootstrap**。

這和 `07a-source-code-learn-wal-transactions.md` 講的 WAL salt 是同一個思路：**用一個標記讓「舊資料是否還有效」變成一次比較**。

**`sync/engine/src/database_sync_operations.rs:3149-3167`** — 完整貼出：

```rust
pub async fn bootstrap_db_file<IO: SyncEngineIo, Ctx>(
    ...
                    "can't bootstrap prefix of database with legacy protocol".to_string(),
            ...
            bootstrap_db_file_legacy(ctx, io, main_db_path).await
        ...
            bootstrap_db_file_v1(ctx, io, main_db_path, partial_sync, pull_bytes_threshold).await
```

**有 legacy 與 v1 兩個版本的協定**，而且錯誤訊息說明了差異：legacy 不支援「bootstrap prefix of database」（部分下載）。

`partial_sync` 和 `pull_bytes_threshold` 這兩個參數揭露了一個重要功能：**不必下載整個資料庫**。

### 二、Lazy storage：按需下載

`sync/engine/src/database_sync_lazy_storage.rs`（721 行）實作了這件事。

**原理**：資料庫檔案是 page 的陣列（`06a-source-code-learn-file-format-pages.md`），而 pager 透過 `DatabaseStorage` trait 讀取 page（`06b-source-code-learn-btree-cursor-pager.md`）。

**只要實作一個「讀 page 時如果本機沒有就去遠端抓」的 `DatabaseStorage`**，整個 engine 就能在只下載部分資料的情況下運作。

B-tree、pager、VM 完全不需要修改——它們只知道自己呼叫了 `read_page`。

**這是 `08-source-code-learn-extensions-sync-testing.md` 講的「插進既有抽象點」的又一個實例**，而且效果驚人：一個 10GB 的遠端資料庫，客戶端只查詢其中一小部分時，只會下載實際碰到的 page。

`sparse_io.rs`（219 行）處理稀疏檔案——本機檔案有「洞」（尚未下載的 page），需要作業系統層級的支援。

### 三、Push：推送本機變更

**`sync/engine/src/database_sync_operations.rs:2756`**

```rust
pub async fn push_logical_changes<IO: SyncEngineIo, Ctx>(
```

流程大致是：

```text
1. 從 turso_cdc 表讀出本機未同步的變更
2. 轉成 LogicalOp（UpsertRow / DeleteRow / Schema / UpdateHeader）
3. 送到伺服器
4. 伺服器合併進它的 MVCC log
5. 更新本機的同步水位
```

**為什麼推送必須用邏輯格式？** 因為伺服器上可能已經有別人的變更。page 層級的 frame 會整片覆寫，把別人的改動蓋掉；邏輯操作（「把 id=5 的列改成這樣」）才能合併。

### Replay generator：把變更轉回 SQL

`sync/engine/src/database_replay_generator.rs`（667 行）。

`08-source-code-learn-extensions-sync-testing.md` 說 sync 用「插入 WAL frame」而非「重放 SQL」——那是 page 路徑。**邏輯路徑則相反**：收到的 `LogicalOp` 要轉成實際的資料庫操作。

為什麼不直接寫 B-tree？因為要維護**索引、trigger、外鍵、materialized view**（`11-source-code-learn-incremental-views.md`）。直接寫 B-tree 會繞過所有這些機制，產生不一致的資料庫。

**走正常的執行路徑，所有既有機制自動生效。** 這是「不要繞過核心」原則在同步層的體現。

---

## 三個水位

同步的正確性繫於幾個「進度標記」：

| 水位 | 意義 | 出處 |
|---|---|---|
| **generation** | 資料庫世代；不同就要重新 bootstrap | `db_bootstrap` |
| **WAL frame 編號** | page 同步進度 | `07a` 的 `WalAutoActions` |
| **CDC 位置** | 本機哪些變更已推送 | `turso_cdc` 表 |

**`07a-source-code-learn-wal-transactions.md` 講的兩個保護機制在這裡得到解釋：**

**一、關閉 `WalAutoActions::Restart`**

```rust
        /// Restart the WAL header in `try_restart_log_before_write` when
        /// every frame has been backfilled, before starting a write tx.
        const Restart    = 0b10;
```

WAL restart 會讓 frame 編號歸零。sync engine 記的水位就指向錯誤的位置——**可能重送已同步的資料，或漏送未同步的**。

**二、條件式 Truncate**

```rust
    /// Extra parameter can be set in order to perform conditional TRUNCATE: database will be
    /// checkpointed and truncated only if max_frames equals to the parameter value
    /// this behaviour used by sync-engine which consolidate WAL before checkpoint and needs to
    /// be sure that no frames will be missed
    Truncate { upper_bound_inclusive: Option<u64> },
```

**「檢查 + 截斷」必須是原子的**。如果檢查之後、截斷之前有人又寫了新 frame，直接截斷就會遺失它們。條件參數把兩步合成一個 compare-and-swap。

---

## 分層總結

```text
應用程式
  ↓
DatabaseSyncEngine          sync / push / pull / bootstrap
  ├─ DatabaseTape           擷取變更（turso_cdc 表）、重放變更
  │     ↓ CDC 掛勾
  │   core/vdbe/execute.rs  op_insert / op_delete 的擷取邏輯
  │
  ├─ LogicalOp 協定         protobuf，跨版本相容
  │     ↕ HTTP
  │   遠端伺服器（MVCC log）
  │
  ├─ WalSession             page 路徑：直接插入 WAL frame
  │     ↓
  │   core/storage/wal.rs   WalAutoActions 控制自動維護
  │
  └─ LazyStorage            實作 DatabaseStorage，按需下載 page
        ↓
      core/storage/pager.rs  完全不知道 page 來自網路
```

**每一個接點都是既有的抽象**：CDC 掛在 VM 的寫入路徑、WalSession 掛在 WAL、LazyStorage 掛在 `DatabaseStorage` trait、replay 走正常的 SQL 執行路徑。

---

## 動手驗證

看 CDC 表：

```bash
cd /Users/stanhsu/projects/turso
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
PRAGMA capture_data_changes_conn('full');
INSERT INTO t VALUES (1, 'hello');
UPDATE t SET v = 'world' WHERE id = 1;
SELECT * FROM turso_cdc;
```

你應該看到變更被記錄下來，而且 UPDATE 帶著舊值——那是 revert 所需的。

看協定定義：

```bash
rg -n "pub enum LogicalOpType|pub enum LogicalSchemaAction|pub struct LogicalOp" sync/engine/src/client_proto.rs
wc -l sync/engine/src/*.rs
```

看 lazy storage 如何實作 `DatabaseStorage`：

```bash
rg -n "impl DatabaseStorage" sync/engine/src/database_sync_lazy_storage.rs
```

追 source：

```bash
rg -n "pub struct DatabaseTape|DEFAULT_CDC_TABLE_NAME|CDC_PRAGMA_NAME" sync/engine/src/database_tape.rs
rg -n "pub async fn sync<|pub async fn push_changes_to_remote|pub async fn pull_changes_from_remote" sync/engine/src/database_sync_engine.rs
rg -n "pub async fn db_bootstrap|pub async fn push_logical_changes|pub async fn pull_pages_v1" sync/engine/src/database_sync_operations.rs
```

---

## 自我檢查

1. 為什麼拉取可以用 page 粒度，但推送必須用邏輯粒度？
2. `LogicalOpType` 為什麼沒有 `UpdateRow`？這和 DBSP 的 `Delta` 有什麼共同思路？
3. 為什麼協定用 protobuf？`Unspecified = 0` 的慣例在防什麼？
4. `LogicalSchemaAction::Refresh` 和 `Alter` 的差別是什麼？為什麼需要 `Refresh`？
5. `Create` 為什麼要「if it does not already exist」？同步協定的什麼特性要求冪等？
6. `UpdateHeader` 同步的是什麼？它為什麼不能用一般的列操作表示？
7. `LogicalOp` 用扁平結構加 type 欄位，而不是 Rust 的 enum with data。原因與代價各是什麼？
8. CDC 的變更為什麼記錄在一張普通的資料庫表裡？這帶來什麼保證？
9. `DEFAULT_CDC_MODE = "full"` 記錄舊值與新值，舊值是為了什麼？
10. sync engine 的方法為什麼用 `async fn` 加 `Coro<Ctx>`，而 core 用 `IOResult`？
11. 「generation」是什麼？它和 WAL salt 有什麼共同思路？
12. Lazy storage 為什麼只要實作 `DatabaseStorage` trait 就能運作？B-tree 和 pager 需要修改嗎？
13. 收到 `LogicalOp` 後為什麼要轉成 SQL 執行，而不是直接寫 B-tree？
14. sync engine 為什麼要關閉 `WalAutoActions::Restart`？
15. `CheckpointMode::Truncate` 的條件參數解決什麼競態？

---

下一篇 `14-source-code-learn-simulator.md`：確定性模擬器如何找出並重現併發與 I/O 的 bug。
