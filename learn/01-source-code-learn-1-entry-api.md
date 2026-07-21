# 01-1. 源碼精讀：從使用者 API 到 core::Connection

本篇對應 `01-sql-lifecycle.md` 的**第一層與第二層**：使用者呼叫的 API 長什麼樣、經過幾層 wrapper 才進到 engine，以及 `Database` / `Connection` / `Statement` 三個型別為什麼要分開。

> **閱讀時間**：約 60–75 分鐘（約 14k 字，其中 39% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 這系列怎麼讀

`01-sql-lifecycle.md` 是地圖，這系列是實地走一遍。每段程式碼都會標出處，格式是 `檔案:行號`。三種引用深度：

- **完整貼出**：本篇主線函式，你不開編輯器也應該能完整跟上。
- **節錄**：函式太長時只貼決定控制流的骨架，省略處用 `// ── 省略：<內容> ──` 標明，讓你知道自己漏看了什麼。
- **只給座標**：支線或其他章的主題，給一句話說明它負責什麼。

> **行號會漂移。** 本篇行號以撰寫當下的 checkout 為準。源碼演進後行號會變，但 symbol 名稱通常穩定。找不到時用 `rg -n "symbol_name" <file>` 重新定位，並可跑 `bash learn/lint-learn-docs.sh` 檢查文件引用的檔案是否還在。

## 本篇的檔案跳轉路線

我們會依序經過四個檔案。先把這張圖記著，後面每次跳轉我都會說明「為什麼現在要跳」：

```text
bindings/rust/src/lib.rs        使用者看到的 Builder / Database
  └─> bindings/rust/src/connection.rs   高階 async Connection::prepare
        └─> sdk-kit/src/rsapi.rs        TursoConnection::prepare_single
              └─> core/connection.rs    core::Connection::prepare  ← 真正的 engine 入口
```

一句話總結本篇結論：**前三層幾乎沒有 SQL engine 邏輯**，它們處理 async 包裝、handle 追蹤、錯誤轉換。真正的工作從第四層開始。知道這件事，你以後追 bug 就不會在 binding 層浪費時間。

---

## 第一站：使用者寫的程式碼

一段典型的 Rust binding 用法：

```rust
let db = turso::Builder::new_local(":memory:").build().await?;
let conn = db.connect()?;
let mut stmt = conn.prepare("SELECT name FROM users WHERE id = ?1").await?;
```

三行分別對應三件事：開啟 database、建立 connection、編譯 SQL。我們一行一行往下追。

### Builder 只是設定收集器

**`bindings/rust/src/lib.rs:141`**

```rust
pub struct Builder {
```

**`bindings/rust/src/lib.rs:160`**

```rust
    pub fn new_local(path: &str) -> Self {
```

`Builder` 的角色就是收集開檔參數（路徑、flags、加密金鑰等），到 `build()` 才真的動作。這是 Rust 生態常見的 builder pattern，和資料庫原理無關，第一輪略過即可。

### connect：一層極薄的包裝

**`bindings/rust/src/lib.rs:334-340`** — 完整貼出，因為它短到能說明整個 binding 層的性質：

```rust
impl Database {
    /// Connect to the database.
    pub fn connect(&self) -> Result<Connection> {
        let conn = self.inner.connect()?;
        Ok(Connection::create(conn, None))
    }
}
```

注意 `self.inner`。這個 `Database` 不是 engine 的 `Database`，它只是持有 `turso_sdk_kit` 型別的殼。`self.inner.connect()` 才往下一層走。

**第一個要建立的判斷力**：當你看到一個函式的本體只有「呼叫 inner 的同名方法 + 包一層自己的型別」，那它就是 wrapper，不要在這裡找 bug。

---

## 第二站：高階 async Connection::prepare

現在跳到 `bindings/rust/src/connection.rs`，因為 `Connection::create` 建立的是這個檔案裡的型別。

**`bindings/rust/src/connection.rs:137-147`** — 完整貼出：

```rust
    /// Prepare a SQL statement for later execution.
    pub async fn prepare(&self, sql: impl AsRef<str>) -> Result<Statement> {
        let conn = self.get_inner_connection()?;
        let stmt = conn.prepare_single(sql)?;

        #[allow(clippy::arc_with_non_send_sync)]
        let statement = Statement {
            conn: self.clone(),
            inner: Arc::new(Mutex::new(stmt)),
        };
        Ok(statement)
    }
```

這裡有三個值得注意的細節：

**一、`async fn` 但函式體內沒有 `.await`。** 整個函式是同步的，`async` 只是為了讓 API 形狀符合使用者預期（其他方法如 `query`、`execute` 確實需要 await）。這也預告了一件重要的事：**Turso core 本身不是 async/await 架構**。core 用明確的 `IOResult` / `StepResult` 回傳值來表達「要等 I/O」，async 只存在於 binding 這層。這個設計是第 4 篇和 `07b-ioresult-reentry.md` 的主題。

**二、`Arc<Mutex<...>>` 包住 statement。** 因為使用者可能從多個 async task 碰同一個 statement，binding 層要自己處理同步。core 的 `Statement` 不是 `Sync` 的，這個鎖是 binding 的責任。

**三、真正往下的只有 `conn.prepare_single(sql)`。** 其餘都是型別包裝。

順帶看它的兄弟方法，理解 binding 層還做了什麼：

**`bindings/rust/src/connection.rs:108-119`**

```rust
    /// Query the database with SQL.
    pub async fn query(&self, sql: impl AsRef<str>, params: impl IntoParams) -> Result<Rows> {
        self.maybe_handle_dangling_tx().await?;
        let mut stmt = self.prepare(sql).await?;
        stmt.query(params).await
    }

    /// Execute SQL statement on the database.
    pub async fn execute(&self, sql: impl AsRef<str>, params: impl IntoParams) -> Result<u64> {
        self.maybe_handle_dangling_tx().await?;
        let mut stmt = self.prepare(sql).await?;
        stmt.execute(params).await
    }
```

`query` 和 `execute` 都是 `prepare` + 執行的組合。差別只在回傳值：`query` 給你 `Rows` 迭代器，`execute` 給你影響列數。這印證了開頭那句話——**所有 SQL 都走 prepare/step 兩段式**，沒有捷徑。

---

## 第三站：sdk-kit，多語言 binding 的共同底座

為什麼還有一層？因為 Python、JavaScript、Java、Go、.NET 這些 binding 不可能各自重寫一套 statement 生命週期管理。`sdk-kit` 就是它們共用的底座，透過 C ABI 暴露。Rust binding 雖然可以直接用 core，但為了行為一致也走同一條路。

**`sdk-kit/src/rsapi.rs:1067-1086`** — 完整貼出：

```rust
    /// prepares single SQL statement
    pub fn prepare_single(&self, sql: impl AsRef<str>) -> Result<Box<TursoStatement>, TursoError> {
        if self.sync_operation_active() {
            return Err(sync_busy_error());
        }
        let statement = self
            .connection
            .prepare(sql)
            .map_err(TursoError::from)
            .map_err(|error| self.map_sync_transient_error(error))?;
        let handle: StatementHandle = Arc::new(Mutex::new(Some(statement)));
        let stmt_id = self.track_stmt(&handle);
        Ok(Box::new(TursoStatement {
            concurrent_guard: self.concurrent_guard.clone(),
            async_io: self.async_io,
            sync_busy: self.sync_busy.clone(),
            handle,
            stmt_id,
            stmts: self.stmts.clone(),
        }))
    }
```

這一層終於做了幾件實質的事：

**`sync_operation_active()` 檢查。** 如果這個 connection 正在跟 Turso Cloud 同步，就拒絕新的 prepare。這是 sync engine 的併發保護，屬於 `08-extensions-sync-testing.md` 的主題。

**`track_stmt(&handle)`。** sdk-kit 記錄所有還活著的 statement。為什麼要記？因為 connection 關閉時必須先把所有未完成的 statement 收乾淨，否則會留下懸空的 transaction 或未釋放的 pager 資源。這是「資料庫 API 正確性」的一部分——SQLite 的 `sqlite3_close()` 也有同樣的約束。

**錯誤轉換 `map_err`。** core 的 `LimboError` 轉成對外的 `TursoError`。

**`self.connection.prepare(sql)`** —— 這行就是進入 engine 的門。`self.connection` 的型別是 `Arc<turso_core::Connection>`。

### 補充：prepare_cached 讓你看見 Program 是可以重用的

**`sdk-kit/src/rsapi.rs:1089-1114`** — 節錄前半段：

```rust
    pub fn prepare_cached(&self, sql: impl AsRef<str>) -> Result<Box<TursoStatement>, TursoError> {
        if self.sync_operation_active() {
            return Err(sync_busy_error());
        }
        let sql_str = sql.as_ref();

        // Check if we have a cached version
        if let Some(cached) = self.cached_statements.lock().unwrap().get(sql_str) {
            if cached.program.is_compatible_with(&self.connection) {
                let program = turso_core::Program::from_prepared(
                    cached.program.clone(),
                    self.connection.clone(),
                );
                let statement =
                    Statement::new(program, self.connection.get_pager(), cached.query_mode, 0);
                // ── 省略：包成 TursoStatement 並回傳，與 prepare_single 尾段相同 ──
            }
        }
        // ── 省略：cache miss 時走完整 prepare 並存入 cache ──
```

這段先看一眼就好，但它揭露了一個關鍵設計，後面第 3 篇會展開：

- **編譯結果（`program`）可以快取重用**，不必每次都重新 parse + compile。
- **但快取必須驗證** —— `cached.program.is_compatible_with(&self.connection)`。如果 connection 的設定變了（PRAGMA、attach 了新資料庫、載入了 extension），舊 bytecode 可能不再正確，必須重編。
- `Program::from_prepared` 把「編譯結果」和「當前 connection」重新綁定。這暗示 `Program` 內部其實分成兩塊：可共享的編譯產物，和綁定 connection 的執行殼。第 3 篇會看到 `PreparedProgram` 和 `Program` 正是這樣拆的。

---

## 第四站：core::Connection，engine 的真正入口

**`core/connection.rs:952-968`** — 完整貼出，你會發現這裡「什麼都沒做」：

```rust
    pub fn prepare(self: &Arc<Connection>, sql: impl AsRef<str>) -> Result<Statement> {
        self._prepare(sql)
    }

    pub fn prepare_sqlite(self: &Arc<Connection>, sql: impl AsRef<str>) -> Result<Statement> {
        self.prepare_with_origin(sql, StatementOrigin::Root)
    }

    #[doc(hidden)]
    pub fn prepare_internal(self: &Arc<Connection>, sql: impl AsRef<str>) -> Result<Statement> {
        self.prepare_with_origin(sql, StatementOrigin::InternalHelper)
    }

    #[instrument(skip_all, level = Level::DEBUG)]
    pub fn _prepare(self: &Arc<Connection>, sql: impl AsRef<str>) -> Result<Statement> {
        self.prepare_with_origin(sql, StatementOrigin::Root)
    }
```

四個函式全部收斂到 `prepare_with_origin`，差別只在傳入的 `StatementOrigin`：

- `prepare` / `_prepare` / `prepare_sqlite` → `StatementOrigin::Root`（使用者的 SQL）
- `prepare_internal` → `StatementOrigin::InternalHelper`（engine 自己要跑的 SQL）

**為什麼要區分？** 因為資料庫不只執行使用者給的 SQL。它自己也需要跑 SQL——最典型的是 schema reparse：當 schema 變動，engine 必須執行 `SELECT * FROM sqlite_schema` 把 metadata 讀回來。那條 SELECT 也要 prepare、也要 step，但它不該被算進「使用者有幾條 statement 正在執行」的統計，也不該觸發某些只對使用者 SQL 生效的檢查。

這個 enum 的定義很短：

**`core/statement.rs:53-57`**

```rust
pub(crate) enum StatementOrigin {
    Root,
    InternalHelper,
    Subprogram,
}
```

**`core/statement.rs:69-73`**

```rust
impl StatementOrigin {
    pub(crate) const fn needs_nested_guard(self) -> bool {
        matches!(self, Self::InternalHelper)
    }
}
```

第三個變體 `Subprogram` 指的是 trigger 或 foreign key action 產生的子程式——它不是另外 parse 的 SQL 文字，而是嵌在父程式裡的一段 bytecode。第 2 篇會看到這三者在 `prepare_with_origin` 裡造成的分歧。

到這裡，`prepare` 的呼叫鏈完整了：

```text
turso::Connection::prepare              bindings/rust/src/connection.rs:137
  -> TursoConnection::prepare_single    sdk-kit/src/rsapi.rs:1067
    -> core::Connection::prepare        core/connection.rs:952
      -> core::Connection::_prepare     core/connection.rs:966
        -> prepare_with_origin          core/connection.rs:971   ← 第 2 篇從這裡開始
```

---

## 第二層：Database、Connection、Statement 的分工

現在回頭看型別設計。這是資料庫 API 最基本、也最容易被新手搞混的一組概念。

### Database：跟「資料庫檔案」綁定

**`core/lib.rs:691`**

```rust
pub struct Database<A: alloc::ConcurrentAllocator = alloc::DynAllocator> {
```

`Database` 持有**所有 connection 共用**的東西：資料庫檔案 handle、WAL 的共享狀態、page cache、schema 快照、I/O backend。

**`core/lib.rs:2235-2237`**

```rust
    pub fn connect(self: &Arc<Database>) -> Result<Arc<Connection>> {
        self._connect(false, None, None)
    }
```

**`core/lib.rs:2250-2262`** — 節錄 `_connect` 開頭，重點是 pager 從哪來：

```rust
    fn _connect(
        self: &Arc<Database>,
        is_mvcc_bootstrap_connection: bool,
        pager: Option<Arc<Pager>>,
        encryption_key: Option<EncryptionKey>,
    ) -> Result<Arc<Connection>> {
        let pager = if let Some(pager) = pager {
            pager
        } else {
            // Pass encryption key to _init so it can set up encryption context
            // before reading page 1. This is required for reopening encrypted databases.
            Arc::new(self._init(encryption_key.as_ref())?)
        };
        // ── 省略：讀 cache size、建立 Connection 的其餘欄位、註冊到 Database ──
```

注意那段註解：加密金鑰必須在**讀 page 1 之前**設定好。因為 page 1 開頭就是 database header，如果檔案是加密的，連 header 都解不開。這是「初始化順序即正確性」的例子。

### Connection：跟「一次 session」綁定

`Connection` 持有的是 session 專屬狀態：目前的 transaction state、PRAGMA 設定、temp schema、attached databases、正在執行的 statement 計數。

兩個 connection 開同一個檔案，共用 `Database`，但各有各的 `Connection`。所以 A connection 開了 transaction，不影響 B connection 的 transaction state；但 A 寫進 WAL 的資料，B 透過共用的 `Database` 是看得到的（受 snapshot 規則約束，見 `07a`）。

### Statement：跟「一條編譯好的 SQL」綁定

**`core/statement.rs:286-316`** — 完整貼出，這個 struct 的欄位就是一堂課：

```rust
pub struct Statement {
    pub(crate) program: vdbe::Program,
    state: vdbe::ProgramState,
    pager: Arc<Pager>,
    /// indicates if the statement is a NORMAL/EXPLAIN/EXPLAIN QUERY PLAN
    query_mode: QueryMode,
    /// Flag to show if the statement was busy
    busy: bool,
    /// Busy handler state for tracking invocations and timeouts
    busy_handler_state: Option<BusyHandlerState>,
    /// Per-execution timeout override for this statement.
    /// - `None`: use connection default
    /// - `Some(Some(duration))`: override with a query-specific timeout
    /// - `Some(None)`: disable timeout for this execution
    query_timeout_override: Option<Option<Duration>>,
    /// True once step() has returned Row for a write statement (INSERT/UPDATE/DELETE
    /// with RETURNING). With ephemeral-buffered RETURNING, the first Row proves all
    /// DML completed — only the scan-back remains. Used by reset_internal to decide
    /// commit vs rollback when a statement is abandoned.
    has_returned_row: bool,
    /// Byte offset in the original SQL string where this statement ends.
    /// Used by sqlite3_prepare_v2 to set the *pzTail output parameter.
    tail_offset: usize,
    origin: StatementOrigin,
    /// True once this root statement has started executing and incremented
    /// `Connection::n_active_root_statements`.
    counted_as_active_root: bool,
    /// True if this statement called `Connection::start_nested()` during
    /// construction and therefore must call `end_nested()` on drop.
    nested_guard_active: bool,
}
```

逐欄看重點：

**`program` 和 `state` 是分開的兩個欄位。** 這是整個 VDBE 設計的核心，值得現在就記住：`Program` 是**不可變的編譯產物**（bytecode 指令陣列、result column 定義、參數表），`ProgramState` 是**可變的執行狀態**（目前執行到第幾條指令、registers 內容、開了哪些 cursor、有沒有 pending I/O）。同一份 `Program` 可以配不同的 `ProgramState` 重複執行，這就是 `prepare_cached` 能運作的原因。第 4 篇會詳細展開。

**`tail_offset`。** 記錄這條 statement 在原始 SQL 字串裡結束於第幾個 byte。為什麼需要？因為使用者可能一次丟 `"SELECT 1; SELECT 2;"`，而 SQLite 的 `sqlite3_prepare_v2` API 契約是「只編譯第一條，並透過 `pzTail` 告訴呼叫者剩下的從哪開始」。註解直接寫明了這個相容性來源。

**`busy` / `busy_handler_state` / `query_timeout_override`。** 這三個和 SQL 語義無關，是併發控制：拿不到鎖時要等多久、要不要重試、單條查詢的逾時。

**`counted_as_active_root` / `nested_guard_active`。** 生命週期記帳。前者確保「正在執行的使用者 statement」計數只加一次；後者記住自己是否要在 drop 時呼叫 `end_nested()`。這種「建構時 +1、解構時 -1」的配對，只要有一條錯誤路徑漏掉就會洩漏，所以要用旗標明確記錄，而不是靠推論。

你在第 2 篇會看到 `prepare_with_origin` 用 closure + 錯誤檢查的寫法，正是為了保證這個配對不會漏。

### 一張判斷表

讀 source 時遇到一個狀態，問自己該放哪：

| 這個資料…… | 應該放在 |
|---|---|
| 同一個 DB 檔案的所有 connection 都該看到 | `Database` |
| 只屬於這個 session（transaction、PRAGMA、temp table） | `Connection` |
| 只屬於這一條編譯好的 SQL | `Statement` / `Program` |
| 只屬於這一次執行過程（PC、registers、cursor） | `ProgramState` |

放錯層會出什麼事？舉例：如果把 transaction state 放進 `Database`，那 A connection 開 transaction 會讓 B connection 也以為自己在 transaction 裡——這是嚴重的正確性 bug。反過來，如果把 page cache 放進 `Connection`，兩個 connection 會各自快取同一個 page，寫入後彼此看不到對方的修改。

---

## 動手驗證

用 `rg` 把本篇的四層 prepare 一次列出來：

```bash
rg -n "fn prepare" bindings/rust/src/connection.rs sdk-kit/src/rsapi.rs core/connection.rs | head -20
```

你應該會看到 binding 層的 `prepare` / `prepare_cached`、sdk-kit 的 `prepare_single` / `prepare_cached`、core 的 `prepare` / `_prepare` / `prepare_internal` / `prepare_with_origin`。

再確認「binding 層沒有 SQL 邏輯」這個判斷：

```bash
rg -n "translate|Insn|BTreeCursor|Pager" bindings/rust/src/connection.rs
```

應該搜不到（或只有無關的字串）。SQL 編譯與執行的型別完全不出現在 binding 層——這就是分層乾淨的證據。

---

## 自我檢查

1. `bindings/rust` 的 `Connection::prepare` 是 `async fn`，但函式體裡沒有任何 `.await`。為什麼？這對 core 的架構透露了什麼？
2. `sdk-kit` 的 `track_stmt` 為什麼必要？如果拿掉它，connection 關閉時會發生什麼問題？
3. `StatementOrigin::Root` 和 `InternalHelper` 差在哪？舉一個 engine 會用到 `InternalHelper` 的實際場景。
4. `Statement` 為什麼要把 `program` 和 `state` 拆成兩個欄位，而不是合成一個？
5. `tail_offset` 存在的理由是什麼？它對應到哪個 SQLite C API？
6. 如果有人把 transaction state 從 `Connection` 移到 `Database`，會出現什麼 bug？

---

下一篇 `01-source-code-learn-2-prepare-parse.md`：進入 `prepare_with_origin`，看它如何處理生命週期記帳、呼叫 parser、拿到 AST。
