# 08. 源碼精讀：Extension、VFS、Sync Engine、測試架構

本篇對應 `08-extensions-sync-testing.md`：核心之外的系統如何接上 engine，以及測試架構如何驗證正確性。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 45–60 分鐘（約 13k 字，其中 37% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
extensions/core/src/lib.rs          ExtensionApi ── C ABI 註冊表
extensions/core/src/vtabs.rs        VTabModule / VTable / VTabCursor
extensions/core/src/vfs_modules.rs  VfsExtension / VfsFile
core/vtab.rs                        VirtualTable ── core 這側的橋
sync/engine/src/wal_session.rs      WalSession ── sync 如何操作 WAL
sqlite/conformance/sqlite-sqltests/ .sqltest 格式
```

**本篇的核心觀念**：這些系統都是**插進既有抽象點**，而不是繞過核心。extension 函式接進 function resolver、虛擬表接進 cursor 介面、VFS 接進 `IO`/`File` trait、sync 接進 WAL。

---

## Extension API：跨越 C ABI 的註冊表

**`extensions/core/src/lib.rs:35-50`** — 完整貼出：

```rust
pub struct ExtensionApi {
    pub ctx: *mut c_void,
    pub register_scalar_function: RegisterScalarFn,
    pub register_aggregate_function: RegisterAggFn,
    pub unregister_function: UnregisterFunctionFn,
    pub register_vtab_module: RegisterModuleFn,
    #[cfg(feature = "vfs")]
    pub vfs_interface: VfsInterface,
}

unsafe impl Send for ExtensionApi {}
unsafe impl Send for ExtensionApiRef {}

#[repr(C)]
pub struct ExtensionApiRef {
    pub api: *const ExtensionApi,
}
```

這是 extension 能對 engine 做的**所有事情**的完整清單：註冊純量函式、註冊聚合函式、反註冊、註冊虛擬表模組、（選擇性）提供 VFS。

幾個設計重點：

**`ctx: *mut c_void`** —— 不透明的指標，指向 engine 這側的狀態。extension 呼叫註冊函式時要把它傳回來。這是 C 風格 callback API 的標準做法：extension 不需要知道 engine 內部型別。

**函式指標欄位。** 每個 `RegisterXxxFn` 都是函式指標型別。**這整個 struct 是刻意設計成能跨越 C ABI 的**——extension 可以是動態載入的 `.so` / `.dylib`，甚至可以用其他語言寫。

**`#[repr(C)]`** 在 `ExtensionApiRef` 上，確保記憶體佈局符合 C 慣例，不受 Rust 編譯器重排欄位的影響。

**`unsafe impl Send`** —— 因為裡面有裸指標，Rust 預設不認為它是 `Send`。這裡手動保證：實際使用時 engine 會確保執行緒安全。**每個 `unsafe impl` 都是一個需要人工維護的承諾。**

**`unregister_function` 的存在很重要**：extension 可以被卸載。這意味著 engine 必須追蹤「哪些函式來自哪個 extension」，卸載時要能清乾淨——而且要確保沒有 prepared statement 還在用那些函式。這就是 `01-source-code-learn-3-translate.md` 講的 `prepare_context` 要記錄 extension 狀態的原因之一。

---

## 虛擬表：用 trait 接進 cursor 模型

### 三層 trait

**`extensions/core/src/vtabs.rs:135-144`** — 完整貼出：

```rust
pub trait VTabModule: 'static {
    type Table: VTable;
    const VTAB_KIND: VTabKind;
    const NAME: &'static str;
    const READONLY: bool = true;

    /// Creates a new instance of a virtual table.
    /// Returns a tuple where the first element is the table's schema.
    fn create(args: &[Value]) -> Result<(String, Self::Table), ResultCode>;
}
```

**`create` 回傳的第一個元素是「schema」，而且是 `String`。**

這個設計很巧妙：虛擬表用**一段 `CREATE TABLE` SQL 文字**告訴 engine 自己有哪些欄位。engine 拿去 parse，就得到欄位定義。

**好處是虛擬表不需要理解 engine 內部的 `Column` 型別**——它只要會產生 SQL 文字。這讓 extension 的 ABI 表面積小很多，也讓 engine 內部型別可以自由演進。

`READONLY: bool = true` 有預設值——大多數虛擬表（例如 CSV 讀取器、序列產生器）是唯讀的，只有需要寫入的才覆寫。

**`extensions/core/src/vtabs.rs:146-157`** — 完整貼出：

```rust
pub trait VTable {
    type Cursor: VTabCursor<Error = Self::Error>;
    type Error: std::fmt::Display;

    /// 'conn' is an Option to allow for testing. Otherwise a valid connection to the core database
    /// that created the virtual table will be available to use in your extension here.
    fn open(&self, _conn: Option<Arc<Connection>>) -> Result<Self::Cursor, Self::Error>;
    fn begin(&mut self) -> Result<(), Self::Error> {
        Ok(())
    }
    fn commit(&mut self) -> Result<(), Self::Error> {
        Ok(())
```

三層對應關係：

| trait | 對應概念 | 生命週期 |
|---|---|---|
| `VTabModule` | 模組（`CREATE VIRTUAL TABLE USING csv`） | 註冊一次 |
| `VTable` | 一個表實例 | 每次 CREATE |
| `VTabCursor` | 一次掃描 | 每次查詢 |

這和 `01-source-code-learn-1-entry-api.md` 講的 `Database` / `Connection` / `Statement` 是同一種分層思路：**共享的、實例的、單次操作的**。

`begin` / `commit` 有預設實作（no-op），因為多數虛擬表沒有交易語義。有的（例如包裝遠端資料庫的虛擬表）就覆寫它們，參與 engine 的交易流程。

`open` 收到 `Option<Arc<Connection>>` 讓虛擬表能回頭查詢資料庫本身。註解說明 `Option` 是為了測試方便——單元測試時可以傳 `None`。

### core 這側的橋

**`core/vtab.rs:20-32`** — 完整貼出：

```rust
pub struct VirtualTable {
    pub(crate) name: String,
    pub(crate) columns: Vec<Column>,
    pub(crate) kind: VTabKind,
    pub(crate) vtab_type: VirtualTableType,
    // identifier to tie a cursor to a specific instantiated virtual table instance
    pub(crate) vtab_id: u64,
    /// Whether `DROP TABLE` may remove this table from its schema.
    pub(crate) is_droppable: bool,
    // Whether this virtual table is safe to use from within triggers and views.
    // Corresponds to SQLite's SQLITE_VTAB_INNOCUOUS flag.
    pub(crate) innocuous: bool,
}
```

`columns: Vec<Column>` —— 這就是把 extension 給的 SQL 文字 parse 之後的結果。**從這裡開始，虛擬表在 compiler 眼中和普通表沒有差別**，都是有欄位定義的東西。

**`innocuous` 這個欄位是安全機制**，註解點明對應 SQLite 的 `SQLITE_VTAB_INNOCUOUS`：

`03-source-code-learn-1-planner.md` 看過 `translate_select` 裡的檢查：

```rust
    if program.trigger.is_some() {
        if let Some(virtual_table) = plan_first_virtual_table_name(&plan) {
            crate::bail_parse_error!("unsafe use of virtual table \"{}\"", virtual_table);
        }
    }
```

**為什麼 trigger 裡不能隨便用虛擬表？** 因為虛擬表會執行 extension 的程式碼。如果攻擊者能建立一個 trigger，就能讓受害者的普通 INSERT 觸發任意程式碼執行。標記為 `innocuous` 的虛擬表（例如純計算的序列產生器）才被信任。

`vtab_id` 把 cursor 綁定到特定的表實例——同一個模組可能有多個實例（`CREATE VIRTUAL TABLE a USING csv(...)` 和 `b USING csv(...)`），cursor 必須知道自己屬於哪一個。

---

## VFS：連檔案系統都能換掉

**`extensions/core/src/vfs_modules.rs:18-37`** — 完整貼出：

```rust
pub trait VfsExtension: Default + Send + Sync {
    const NAME: &'static str;
    type File: VfsFile;
    fn open_file(&self, path: &str, flags: i32, direct: bool) -> ExtResult<Self::File>;
    fn remove_file(&self, path: &str) -> ExtResult<()>;
    fn run_once(&self) -> ExtResult<()> {
        Ok(())
    }
    fn close(&self, _file: Self::File) -> ExtResult<()> {
        Ok(())
    }
    fn generate_random_number(&self) -> i64 {
        let mut buf = [0u8; 8];
        getrandom::fill(&mut buf).expect("failed to generate random bytes");
        i64::from_ne_bytes(buf)
    }
    fn get_current_time(&self) -> String {
        chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string()
    }
}
```

**`run_once` 是事件迴圈的鉤子。** 它有預設的 no-op 實作，但對非同步的 VFS 後端（例如網路儲存）很關鍵——engine 呼叫它來推進待處理的 I/O。這對應 `core/io/mod.rs` 的 `IO::step`，也就是 `01-source-code-learn-4-step-vm.md` 那個驅動迴圈裡的 `self.pager.io.step()?`。

**`generate_random_number` 和 `get_current_time` 為什麼在 VFS 裡？**

這是 SQLite 的傳統設計，但理由很實際：**確定性測試**。`testing/simulator/` 需要完全可重現的執行——同樣的種子產生同樣的隨機數、同樣的時間序列。把隨機數與時鐘放進可抽換的 VFS 層，模擬器就能提供確定性的版本。

如果這兩個功能直接呼叫作業系統，模擬測試就無法重現失敗。**可測試性是設計進抽象層的，不是事後加的。**

**`extensions/core/src/vfs_modules.rs:39-49`** — 完整貼出：

```rust
pub trait VfsFile: Send + Sync {
    fn lock(&mut self, _exclusive: bool) -> ExtResult<()> {
        Ok(())
    }
    fn unlock(&self) -> ExtResult<()> {
        Ok(())
    }
    fn read(&mut self, buf: BufferRef, offset: i64, cb: Callback) -> ExtResult<()>;
    fn write(&mut self, buf: BufferRef, offset: i64, cb: Callback) -> ExtResult<()>;
    fn sync(&self, cb: Callback) -> ExtResult<()>;
    fn truncate(&self, len: i64, cb: Callback) -> ExtResult<()>;
```

**注意 `read` / `write` / `sync` / `truncate` 都帶 `cb: Callback` 參數。**

這是**非同步介面**：操作不立即回傳結果，而是完成時呼叫 callback。這正好對應 `07b-source-code-learn-ioresult-reentry.md` 講的 `Completion` 機制——engine 這側把 callback 接到 `Completion`，於是 extension VFS 的非同步 I/O 能無縫融入 `IOResult` 模型。

`lock` / `unlock` 有預設 no-op，因為記憶體或單程序的 VFS 不需要檔案鎖。

**這個 trait 的存在意味著：資料庫檔案不一定是本機檔案。** 它可以在 S3、在 IndexedDB（WASM）、在自訂的網路協定上。B-tree、pager、WAL 的程式碼完全不需要改。

---

## Sync Engine：WalSession

**`sync/engine/src/wal_session.rs:7-27`** — 完整貼出：

```rust
pub struct WalSession {
    conn: Arc<turso_core::Connection>,
    in_txn: bool,
}

unsafe impl Send for WalSession {}
unsafe impl Sync for WalSession {}

impl WalSession {
    pub fn new(conn: Arc<turso_core::Connection>) -> Self {
        Self {
            conn,
            in_txn: false,
        }
    }
    pub fn conn(&self) -> &Arc<turso_core::Connection> {
        &self.conn
    }
    pub fn begin(&mut self) -> Result<()> {
        assert!(!self.in_txn);
        self.conn.wal_insert_begin()?;
```

**只有兩個欄位，但它是 sync engine 與 core 的主要接點。**

`wal_insert_begin()` 這個 API 名稱透露了 sync 的運作方式：**直接把 WAL frame 插進本機 WAL**，而不是重放 SQL。

為什麼？因為 frame 是 page 層級的，重放它得到的結果**位元組級別完全相同**。如果改成重放 SQL，任何細微的差異（浮點捨入、`random()`、`datetime('now')`）都會讓兩端分歧。

`assert!(!self.in_txn)` —— 用斷言表達「不能巢狀 begin」。這符合專案的原則：**斷言不變量，不要用 if 靜默容錯**。如果真的巢狀呼叫了，那是呼叫者的 bug，應該立刻爆而不是產生難以追查的行為。

`in_txn` 這個布林值也是一種狀態機——確保 begin/commit 成對。

**這裡也回頭解釋了 `07a-source-code-learn-wal-transactions.md` 的 `WalAutoActions`**：sync engine 用 frame 編號當同步水位，所以絕不能讓一般 connection 的自動維護把 WAL restart 掉。它會關閉 `WalAutoActions::Restart`，自己在安全時機用 `CheckpointMode::Truncate { upper_bound_inclusive: Some(n) }` 做條件截斷。

**這是一個很好的例子**：同一套 WAL 機制，透過權限旗標與條件參數，同時服務「一般使用」與「外部管理水位」兩種需求。

---

## 測試架構

### .sqltest：優先選擇

**`sqlite/conformance/sqlite-sqltests/insert.sqltest:1-30`** — 完整貼出開頭：

```text
@database :memory:

setup dqs_dml {
    .dbconfig dqs_dml on
}

@cross-check-integrity
test basic-insert {
    create table temp (t1 integer, primary key (t1));
    insert into temp values (1);
    select * from temp;
}
expect {
    1
}

@cross-check-integrity
test must-be-int-insert {
    create table temp (t1 integer, primary key (t1));
    insert into temp values (1),(2.0),('3'),('4.0');
    select * from temp;
}
expect {
    1
    2
    3
    4
}
```

格式很直觀：`test` 區塊放 SQL，`expect` 區塊放預期輸出。

**但這個格式的價值不在語法，而在執行方式：同一個測試會同時跑 Turso 和真正的 SQLite，比對結果。** 這讓相容性 bug 無所遁形——你不需要自己判斷「SQLite 在這種情況會回什麼」，測試框架直接問它。

`@cross-check-integrity` 這個標記會在測試後執行完整性檢查，驗證 B-tree 結構沒有損壞。

第二個測試示範了 `05-source-code-learn-schema-values-records.md` 講的 affinity：插入 `1`、`2.0`、`'3'`、`'4.0'` 到 INTEGER 欄位，全部被轉成整數 `1,2,3,4`。**這正是 affinity 規則的行為，而測試證明 Turso 的行為和 SQLite 一致。**

### 各測試層的分工

| 位置 | 用途 | 何時用 |
|---|---|---|
| `sqlite/conformance/sqlite-sqltests/` | SQL 語義相容性 | **預設首選**。parser、planner、executor 的行為 |
| `sqlite/conformance/turso-sqltests/` | Turso 專屬功能 | 自訂型別、MVCC、陣列、materialized view |
| `sqlite/conformance/upstream/` | 匯入的 SQLite 官方測試 | 不要為了 Turso 的行為改動它們 |
| `tests/integration/` | Rust API 層 | 多 connection、注入失敗、逾時、storage 斷言 |
| `tests/fuzz/` | 最小化的 fuzz 回歸 | 從 fuzzer 找到的案例 |
| `testing/simulator/` | 確定性模擬 | 併發、排程、I/O 失敗注入 |
| `testing/concurrent-simulator/` | 併發交錯 | 多連線的交錯順序 |
| `testing/cli_tests/` | CLI 行為 | shell 命令、輸出格式 |
| `testing/stress/` | 長時間壓力 | 深入調查用 |

**選擇原則是「能用最窄的層表達就用最窄的」。** 一個 SQL 語義的 bug 用 `.sqltest` 三行就寫完了，寫成 Rust integration test 要幾十行還跑得慢。

反過來，需要「兩個 connection 交錯操作」或「在特定 I/O 點注入失敗」的情境，`.sqltest` 表達不了，就必須用 Rust 測試或 simulator。

### 確定性模擬與 yield injection

`07b-source-code-learn-ioresult-reentry.md` 提過重入 bug 的難處：只在特定 I/O 時機出現，一般測試碰不到。

對策有兩層：

**`core/io/memory_yield.rs`** —— 故意讓每次 I/O 都 yield 的測試後端，強制走過所有重入路徑。

**`testing/simulator/`** —— 確定性模擬。給定種子，重現完全相同的 I/O 交錯與失敗注入。發現 bug 時可以用同一個種子重現。

專案的 `.claude/skills/yield-injections/SKILL.md` 描述了更精細的機制：在指定的 yield point 注入中斷（`CommitYieldPoint`、`CheckpointYieldPoint`、`CursorYieldPoint`），驗證重入後狀態仍然正確。

**如果你要改 storage 或 VM，這些測試是必須跑的。**

---

## 分層總結

所有這些系統的共同模式是**插進既有的抽象點**：

```text
extension 函式  → 接進 function resolver（core/function.rs）
虛擬表          → 接進 cursor 介面（core/vtab.rs → CursorTrait）
VFS             → 接進 IO/File trait（core/io/vfs.rs）
sync engine     → 接進 WAL（wal_insert_begin / WalAutoActions）
測試            → 接進 IO trait（memory_yield、simulator）
```

**沒有任何一個是繞過核心的旁路。** 這是為什麼核心的抽象邊界值得仔細設計——它們同時是擴充點與測試點。

而且注意：VFS 和測試用的是**同一個** `IO` trait。確定性模擬之所以可行，正是因為 I/O 本來就是可抽換的。**好的抽象同時服務擴充性與可測試性。**

---

## 動手驗證

看 extension 的實際使用：

```bash
cd /Users/stanhsu/projects/turso
ls extensions/
```

`crypto`、`csv`、`regexp`、`fuzzy`、`ipaddr`、`completion` 都是完整的 extension 範例。挑 `regexp` 看，它是最單純的純量函式 extension。

跑 SQL 相容性測試：

```bash
make -C sqlite/conformance run-rust ARGS='--snapshot-filter __never__'
```

看單一測試檔：

```bash
cat sqlite/conformance/sqlite-sqltests/affinity.sqltest | head -40
```

對照 `05-source-code-learn-schema-values-records.md` 講的 affinity 規則，看測試怎麼驗證它們。

用 `scripts/diff.sh` 手動比對：

```bash
scripts/diff.sh "CREATE TABLE t(a POINT); INSERT INTO t VALUES('123'); SELECT typeof(a) FROM t;"
```

它會同時跑 sqlite3 和 tursodb，顯示差異。**這是最快的相容性檢查工具。**

追 source：

```bash
rg -n "pub struct ExtensionApi" extensions/core/src/lib.rs
rg -n "pub trait VTabModule|pub trait VTable|pub trait VTabCursor" extensions/core/src/vtabs.rs
rg -n "pub trait VfsExtension|pub trait VfsFile" extensions/core/src/vfs_modules.rs
rg -n "pub struct VirtualTable" core/vtab.rs
rg -n "pub struct WalSession" sync/engine/src/wal_session.rs
```

---

## 自我檢查

1. `ExtensionApi` 為什麼要設計成能跨 C ABI？`ctx: *mut c_void` 的用途是什麼？
2. `unregister_function` 的存在對 prepared statement 快取有什麼影響？
3. `VTabModule::create` 回傳的 schema 為什麼是 `String` 而不是結構化的欄位定義？這個決定有什麼好處？
4. `VTabModule` / `VTable` / `VTabCursor` 三層各對應什麼生命週期？和 `Database`/`Connection`/`Statement` 有什麼相似之處？
5. `innocuous` 旗標在防什麼攻擊？為什麼 trigger 裡預設不能用虛擬表？
6. `VfsExtension` 為什麼要包含 `generate_random_number` 和 `get_current_time`？和測試有什麼關係？
7. `VfsFile` 的 `read`/`write` 為什麼帶 `Callback` 參數？這和 `Completion` 有什麼關係？
8. sync engine 為什麼用「插入 WAL frame」而不是「重放 SQL」來同步？
9. `WalSession::begin` 用 `assert!` 而不是回傳錯誤，為什麼？
10. sync engine 為什麼要關掉 `WalAutoActions::Restart`？（回顧 `07a`）
11. `.sqltest` 的真正價值是什麼？為什麼它應該是第一選擇？
12. 什麼情況下 `.sqltest` 不夠用，必須改用 Rust integration test 或 simulator？
13. 為什麼 VFS 抽象同時服務了「擴充性」和「可測試性」？

---

下一篇 `09-source-code-learn-reading-projects.md`：綜合追蹤練習，把前面各篇串成完整的除錯與閱讀方法。
