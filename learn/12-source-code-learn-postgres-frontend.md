# 12. 源碼精讀：PostgreSQL Frontend

`postgres/` 有 30,274 行，讓 Turso 能接受 PostgreSQL 的 SQL 方言與線路協定——**但底下是同一個 engine**。

`01-source-code-learn-2-prepare-parse.md` 講 `parse_sql` 時提過那層 `Dialect` 間接：

```rust
    pub(crate) fn parse_sql(&self, sql: &str) -> Result<(Option<Cmd>, usize)> {
        self.db.dialect().parse(sql)
    }
```

當時只說「Turso 還支援 PostgreSQL frontend」。本篇看那個抽象實際上如何被使用。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 45–60 分鐘（約 12k 字，其中 38% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
postgres/frontend/catalog.rs    PostgresDialect ── Dialect trait 的 PG 實作
postgres/parser/translator.rs   PostgreSQLTranslator ── PG AST → Turso AST（6,711 行）
postgres/parser/parser.rs       PG 語法解析（2,904 行）
postgres/server/                線路協定
postgres/regress/               PG 官方回歸測試
```

## 目錄結構

```text
postgres/
├── parser/     PG SQL → Turso AST
├── frontend/   Dialect 實作、catalog（pg_catalog 模擬）
├── server/     PostgreSQL wire protocol
├── cli/        tursopg 命令列工具
├── conformance/ 相容性測試
├── regress/    PG 官方 regression suite
└── tests/      整合測試
```

**注意 `postgres/` 不含任何儲存或執行程式碼。** 它全部是「翻譯層」——把 PG 的東西轉成 Turso core 認得的形式。

---

## 接入點：Dialect trait

**`postgres/frontend/catalog.rs:21-24`** — 完整貼出開頭：

```rust
impl Dialect for PostgresDialect {
    fn name(&self) -> &'static str {
        "postgres"
    }
```

`01-source-code-learn-2-prepare-parse.md` 看過 SQLite 的實作（`core/dialect/sqlite.rs`）。這裡是平行的另一個實作。

**整個 PG 支援就掛在這一個 trait 上。** core 完全不知道 PG 的存在——它只知道「有一個 dialect，我呼叫它的 `parse`」。

---

## parse：兩層 fallback

**`postgres/frontend/catalog.rs:26-50`** — 完整貼出：

```rust
    fn parse(&self, sql: &str) -> Result<(Option<turso_parser::ast::Cmd>, usize)> {
        // Engine-generated helper statements and pragmas are canonical SQLite
        // text that pg_query rejects, so anything the PostgreSQL parser cannot
        // handle falls back to SQLite parsing.
        let Ok(parse_result) = turso_pg_parser::parse(sql) else {
            return turso_core::dialect::sqlite::parse(sql);
        };
        let stmts = &parse_result.protobuf.stmts;
        if stmts.is_empty() {
            return Ok((None, sql.len()));
        }
        // The translator consumes the first statement only; report how many
        // input bytes it covers so multi-statement iteration can resume after
        // it. pg_query records where the next statement starts, which also
        // accounts for the semicolon and any trailing whitespace in between.
        let consumed = match stmts.get(1) {
            Some(next) => next.stmt_location as usize,
            None => sql.len(),
        };
        let translator = turso_pg_parser::translator::PostgreSQLTranslator::new();
        match translator.translate(&parse_result) {
            Ok(stmt) => Ok((Some(turso_parser::ast::Cmd::Stmt(stmt)), consumed)),
            Err(_) => turso_core::dialect::sqlite::parse(sql),
        }
    }
```

**這 25 行是整個 PG frontend 的核心，值得逐段拆。**

### 第一層 fallback：PG parser 不認得

```rust
        // Engine-generated helper statements and pragmas are canonical SQLite
        // text that pg_query rejects, so anything the PostgreSQL parser cannot
        // handle falls back to SQLite parsing.
        let Ok(parse_result) = turso_pg_parser::parse(sql) else {
            return turso_core::dialect::sqlite::parse(sql);
        };
```

註解點出了一個實際問題：**engine 內部產生的 SQL 是 SQLite 語法**。

`01-source-code-learn-2-prepare-parse.md` 講過 `StatementOrigin::InternalHelper`——schema reparse 要跑 `SELECT * FROM sqlite_schema`。還有 `PRAGMA` 語句。這些是 Turso 自己寫死的 SQLite 文字，PG parser 當然不認得。

**解法是 fallback**：PG parser 失敗就用 SQLite parser 再試一次。

這比另一個做法（在每個內部呼叫點指定用哪個 parser）簡單得多。而且它也順帶處理了使用者輸入 SQLite 專有語法的情況。

`03-source-code-learn-1-planner.md` 講的 `translate` 裡那段條件也呼應這件事：

```rust
        // Engine-generated helper statements are always SQLite text and
        // must resolve functions with SQLite semantics regardless of the
        // database's dialect
        if matches!(origin, crate::statement::StatementOrigin::InternalHelper) {
            Arc::new(crate::dialect::SqliteDialect) as Arc<dyn crate::dialect::Dialect>
```

**兩處是同一個問題的兩面**：parse 用 fallback 處理，函式解析用 origin 判斷強制走 SQLite 語義。

### 第二層 fallback：翻譯失敗

```rust
        match translator.translate(&parse_result) {
            Ok(stmt) => Ok((Some(turso_parser::ast::Cmd::Stmt(stmt)), consumed)),
            Err(_) => turso_core::dialect::sqlite::parse(sql),
        }
```

**PG parser 成功但翻譯失敗，也退回 SQLite parser。**

什麼時候會這樣？某些 SQL 兩種方言都合法但語義不同，或者 PG 有而 Turso 尚未支援的構造。退回去試試看，說不定 SQLite 路徑能處理。

**這種「盡量讓它能跑」的策略在相容層很常見**，代價是錯誤訊息可能變得難懂——使用者寫了 PG 語法卻收到 SQLite parser 的錯誤。

### byte offset 的處理

```rust
        // The translator consumes the first statement only; report how many
        // input bytes it covers so multi-statement iteration can resume after
        // it. pg_query records where the next statement starts, which also
        // accounts for the semicolon and any trailing whitespace in between.
        let consumed = match stmts.get(1) {
            Some(next) => next.stmt_location as usize,
            None => sql.len(),
        };
```

**這是 `Dialect::parse` 契約的一部分**。`01-source-code-learn-2-prepare-parse.md` 講過那個 `usize` 回傳值的兩個用途：切出 `input` 原文，以及當作 `tail_offset` 支援多語句 SQL。

SQLite parser 是自己追蹤 offset（`Parser::offset()`，還要處理 peek 未消耗的修正）。PG 這邊用的是 `pg_query` 函式庫，它直接記錄了「下一條語句從哪開始」，所以拿第二條語句的位置即可。

**兩種 parser，同一個契約，不同的實作方式。** 這就是抽象的價值。

---

## 翻譯：PG AST → Turso AST

**`postgres/parser/translator.rs:14-31`** — 完整貼出：

```rust
/// Result of translating a PostgreSQL statement, which may include
/// prerequisite statements (e.g., implicit CREATE SEQUENCE for serial columns).
pub struct TranslateResult {
    /// Prerequisite statements that must be executed before the main statement.
    /// For example, serial columns generate implicit CREATE SEQUENCE statements.
    pub prereqs: Vec<ast::Stmt>,
    /// The main translated statement.
    pub stmt: ast::Stmt,
}

/// Translates a PostgreSQL query into Turso's AST
#[derive(Default)]
pub struct PostgreSQLTranslator {
    // TODO: Add schema information, type mappings, etc.
}
```

**`prereqs` 這個欄位揭露了一個重要的不對稱：一條 PG 語句可能需要展開成多條。**

註解給的例子是 `SERIAL`：

```sql
-- PostgreSQL:
CREATE TABLE t(id SERIAL PRIMARY KEY, name TEXT);

-- 翻譯成:
CREATE SEQUENCE t_id_seq;                                    ← prereq
CREATE TABLE t(id INTEGER PRIMARY KEY DEFAULT nextval('t_id_seq'), name TEXT);
```

PG 的 `SERIAL` 是語法糖，實際上是「建一個 sequence + 用它當預設值」。Turso 有 sequence 支援（`core/translate/sequence.rs`），所以可以照著展開。

**`#[derive(Default)]` 加上那個 TODO** —— translator 目前是無狀態的。TODO 說明未來需要 schema 資訊才能做更準確的翻譯（例如型別推導需要知道欄位定義）。**又一個誠實標註的限制。**

### 名稱與型別的映射

**`postgres/parser/translator.rs:36-45`** — 節錄：

```rust
    /// Build a `QualifiedName` from a PG `RangeVar`, preserving schema qualifier.
    fn qualified_name_from_range_var(
        &self,
        range_var: &pg_query::protobuf::RangeVar,
    ) -> ast::QualifiedName {
        let mapped_name = self.map_table_name(&range_var.relname);
        let name = ast::Name::from_string(mapped_name);
```

`map_table_name` 處理**命名空間的差異**：PG 有 schema（`public.users`），SQLite 有 attached database（`main.users`）。兩者概念相近但不完全相同，需要映射。

**`postgres/parser/translator.rs:3736` 與 `postgres/parser/translator.rs:3783`** — 型別映射：

```rust
pub struct PgTypeMapping {
...
pub fn map_pg_type(pg_type: &str, params: &[i64]) -> Option<PgTypeMapping> {
```

PG 有嚴格的型別系統（`int4`、`varchar(n)`、`timestamptz`…），SQLite 是 affinity（`05-source-code-learn-schema-values-records.md`）。

**這是最根本的阻抗不匹配。** `int4` 可以映射成 `INTEGER`（得到 INTEGER affinity），但 PG 會拒絕存入字串而 SQLite 會嘗試轉換。**行為無法完全一致**，只能盡量接近。

`postgres/COMPAT.md` 應該記錄了這些已知差異。

### PG 專有語句的處理

**`postgres/parser/translator.rs:4157-4247`** — 一組 `try_extract_*` 函式：

```rust
pub struct PgSetStmt {
...
pub struct PgShowStmt {
...
pub fn try_extract_set(parse_result: &ParseResult) -> Option<PgSetStmt> {
...
pub fn try_extract_show(parse_result: &ParseResult) -> Option<PgShowStmt> {
...
pub struct PgCreateSchemaStmt {
...
pub struct PgDropSchemaStmt {
...
pub fn try_extract_create_schema(parse_result: &ParseResult) -> Option<PgCreateSchemaStmt> {
...
pub fn try_extract_drop_schema(parse_result: &ParseResult) -> Option<PgDropSchemaStmt> {
```

**`SET`、`SHOW`、`CREATE SCHEMA` 這些在 SQLite 裡沒有對應物**，所以不能翻譯成 `ast::Stmt`。

作法是用 `try_extract_*` 把它們**辨識出來單獨處理**——frontend 自己實作行為（例如 `SET` 改變 session 設定、`SHOW` 回傳一列結果），不進 core 的編譯流程。

`Option` 回傳值就是「這條語句是不是這一種」的判斷。

---

## catalog：模擬 pg_catalog

`postgres/frontend/catalog.rs` 有 4,093 行，是 `postgres/` 裡第二大的檔案。

**為什麼需要它？** 因為 PG 生態的工具（psql、ORM、驅動程式）會查詢 `pg_catalog` 系統目錄來探知 schema：

```sql
SELECT * FROM pg_catalog.pg_class WHERE relname = 'users';
SELECT * FROM information_schema.columns WHERE table_name = 'users';
```

Turso 的 schema 存在 `sqlite_schema`（`05-source-code-learn-schema-values-records.md`），結構完全不同。所以要**把 `sqlite_schema` 的內容偽裝成 `pg_class`、`pg_attribute`、`information_schema.columns` 等視圖**。

`Dialect` trait 的 `register_catalog` 方法（`01-source-code-learn-2-prepare-parse.md` 看過 SQLite 的版本）就是這個註冊點：

```rust
    fn register_catalog(
        &self,
        schema: &mut Schema,
        enable_custom_types: bool,
    ) -> crate::Result<()> {
```

**這決定了「PG 相容」有多深**：語法能跑只是第一步，工具能連上、能自動探知 schema 才算真的可用。

### 儲存的 SQL 要標記來源

**`postgres/frontend/catalog.rs:52-61`** — 完整貼出：

```rust
    fn parse_table_sql(&self, sql: &str, root_page: i64) -> Result<BTreeTable> {
        // Schema rows written by internal SQLite paths (e.g. sqlite_sequence)
        // carry no frontend marker and are plain SQLite SQL.
        let Some(raw_sql) = decode_stored_pg_schema_sql(sql) else {
            return BTreeTable::from_sql(sql, root_page);
        };

        let parse_result =
            turso_pg_parser::parse(raw_sql).map_err(|e| LimboError::ParseError(e.to_string()))?;
        let translator = turso_pg_parser::translator::PostgreSQLTranslator::new();
```

**這解決了一個很微妙的問題。**

`09-source-code-learn-reading-projects.md` 的 CREATE TABLE 演練看過：DDL 會把原始 SQL 存進 `sqlite_schema`：

```text
12    String8  ... 'CREATE TABLE x (a INTEGER, b TEXT)'   → sql 欄位
```

下次開啟資料庫時，`parse_schema_rows` 要把這段 SQL 讀回來重新解析（`05-source-code-learn-schema-values-records.md`）。

**問題是：那段 SQL 是 PG 語法還是 SQLite 語法？**

如果用 PG frontend 建表，存的是 PG 的 `CREATE TABLE`；但 `sqlite_sequence` 之類的內部表是 SQLite 路徑寫的，存的是 SQLite 語法。**用錯 parser 就解析失敗，資料庫打不開。**

解法是 `decode_stored_pg_schema_sql`：**PG 寫入的 schema 帶標記**，讀取時據此判斷。沒有標記就當 SQLite SQL 處理。

**這是「持久化資料要能自我描述」的原則**——存進磁碟的東西必須帶足夠資訊讓未來的自己正確解讀。

---

## 分層總結

```text
PostgreSQL client（psql / ORM / driver）
    │  PG wire protocol
    ↓
postgres/server/          協定處理
    ↓
postgres/parser/          PG SQL → PG AST → Turso AST
    ↓
postgres/frontend/        Dialect 實作、pg_catalog 模擬
    ↓
─────────────────────────────────────────
core/connection.rs        ← 從這裡開始完全相同
core/translate/           編譯器（01-source-code-learn-3）
core/vdbe/                VM（04-source-code-learn-*）
core/storage/             B-tree / Pager / WAL（06、07）
```

**分界線很清楚**：core 完全不知道 PG 的存在，它只看到 `Dialect` trait 和 `ast::Stmt`。

這和 `08-source-code-learn-extensions-sync-testing.md` 講的其他擴充點是同一個模式——**插進既有的抽象點，而不是繞過核心**：

| 子系統 | 接入點 |
|---|---|
| extension 函式 | function resolver |
| 虛擬表 | `CursorTrait` |
| VFS | `IO` / `File` trait |
| sync engine | WAL |
| **PG frontend** | **`Dialect` trait** |

---

## 動手驗證

```bash
cd /Users/stanhsu/projects/turso
ls postgres/cli/
cargo run -q --bin tursopg -- --help 2>&1 | head -20
```

看相容性文件（它記錄了已知的行為差異）：

```bash
head -60 postgres/COMPAT.md
```

看 PG 官方回歸測試如何被引用：

```bash
ls postgres/regress/
wc -l postgres/regress/main.rs
```

看型別映射表：

```bash
rg -n "fn map_pg_type" -A 40 postgres/parser/translator.rs | head -50
```

追 source：

```bash
rg -n "impl Dialect for PostgresDialect" postgres/frontend/catalog.rs
rg -n "pub struct TranslateResult|pub struct PostgreSQLTranslator" postgres/parser/translator.rs
rg -n "pub fn try_extract_set|pub fn try_extract_show|fn decode_stored_pg_schema_sql" postgres/
```

---

## 自我檢查

1. `postgres/` 目錄裡有儲存或執行引擎的程式碼嗎？它全部在做什麼？
2. 整個 PG 支援掛在哪一個 trait 上？core 需要知道 PG 的存在嗎？
3. `parse` 有兩層 fallback，各在什麼情況觸發？
4. 為什麼 engine 內部產生的 SQL 需要第一層 fallback？舉兩個例子。
5. `parse` 回傳的 `usize` 是什麼契約？SQLite parser 和 PG parser 用什麼不同方式算出它？
6. `TranslateResult.prereqs` 為什麼存在？用 `SERIAL` 舉例說明。
7. PG 的型別系統與 SQLite 的 affinity 是最根本的阻抗不匹配。舉一個行為無法完全一致的例子。
8. `SET`、`SHOW`、`CREATE SCHEMA` 為什麼不能翻譯成 `ast::Stmt`？它們怎麼處理？
9. `pg_catalog` 模擬為什麼重要？只做到「語法能跑」為什麼不夠？
10. `decode_stored_pg_schema_sql` 解決什麼問題？如果不標記來源，會發生什麼？
11. 「持久化資料要能自我描述」這個原則，在本篇的哪個地方體現？
12. PG frontend 的接入點，和 extension / 虛擬表 / VFS / sync 的接入點有什麼共同模式？

---

下一篇 `13-source-code-learn-sync-engine.md`：完整的同步協定。
