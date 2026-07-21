# 05. 源碼精讀：Schema、Value、Record、Affinity

本篇對應 `05-schema-values-records.md`，把「SQL 的 metadata 與值如何在 engine 內表示」攤開來讀。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 75–90 分鐘（約 19k 字，其中 39% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/schema.rs      SCHEMA_TABLE_NAME 等常數、Schema、BTreeTable、Column
  └─> core/util.rs      parse_schema_rows ── 從 sqlite_schema 重建記憶體 schema
        └─> core/connection.rs   誰呼叫它
core/types.rs       Value / ValueRef ── 執行期的值
core/vdbe/affinity.rs   Affinity ── SQLite 的型別傾向規則
```

本篇要建立的核心區分是**四個容易混淆的「型別」概念**：

| 概念 | 是什麼 | 存在於 |
|---|---|---|
| declared type | 使用者在 CREATE TABLE 寫的字串（`VARCHAR(20)`） | schema |
| affinity | 從 declared type 推出的儲存／比較傾向 | schema，編譯期算出 |
| runtime `Value` | 某個 register 此刻真正持有的東西 | 執行期 |
| serial type | record 寫進 B-tree payload 時的編碼 | 磁碟 |

這四者**不是同一件事**。SQLite 相容性的細節有很大一部分卡在它們的轉換規則上。

---

## sqlite_schema：schema 存在資料庫裡

### 表名常數

**`core/schema.rs:171-175`** — 完整貼出：

```rust
pub const SCHEMA_TABLE_NAME: &str = "sqlite_schema";
pub const SCHEMA_TABLE_NAME_ALT: &str = "sqlite_master";
pub const TEMP_SCHEMA_TABLE_NAME: &str = "sqlite_temp_schema";
pub const TEMP_SCHEMA_TABLE_NAME_ALT: &str = "sqlite_temp_master";
pub const SQLITE_SEQUENCE_TABLE_NAME: &str = "sqlite_sequence";
```

`sqlite_master` 是舊名，`sqlite_schema` 是新名，兩者都要接受——這是相容性的基本要求。

**最重要的觀念**：`sqlite_schema` 本身就是一張普通的 B-tree table，root page 固定是 1。schema 不只存在記憶體，它**存在資料庫檔案裡**，而且用的是和使用者資料完全相同的儲存機制。

這帶來一個雞生蛋問題：要讀 schema 得先能讀表，要讀表得先知道 schema。解法是 `sqlite_schema` 的結構**寫死在程式碼裡**（固定五欄：type、name、tbl_name、rootpage、sql），root page 固定為 1。有了這個起點，就能把其餘 schema 讀出來。

### parse_schema_rows：重建記憶體 schema

**`core/util.rs:196-201`** — 函式的說明註解：

```rust
/// Non-blocking schema-row parser: steps the schema-scan statement held in
/// `state`, feeding each row to `handle_schema_row`, and yields IO instead of
/// pumping it. Re-invoke after each yielded completion; accumulators persist in
/// `state`. On completion, populates indices and materialized views.
```

這段註解本身就是一堂 I/O 重入的課。三個要點：

- **non-blocking** —— 它不自己驅動 I/O，而是把 I/O 往上拋（`yields IO instead of pumping it`）。
- **可重入** —— 呼叫者要在每次 I/O 完成後重新呼叫。
- **狀態保存在 `state`** —— 累積到一半的結果放在參數帶進來的 state 裡，這樣重入時不會丟失。

為什麼 schema 解析要這麼麻煩？因為它要**掃一整張表**，而表可能很大、page 可能不在 cache，隨時可能需要 I/O。

**`core/util.rs:201-245`** — 完整貼出主體：

```rust
pub fn parse_schema_rows(
    state: &mut ParseSchemaRowsState,
    schema: &mut Schema,
    syms: &SymbolTable,
    resolve_attached_db: &dyn Fn(&str) -> Option<usize>,
    dialect: &dyn crate::dialect::Dialect,
) -> Result<IOResult<()>> {
    {
        let inner = state
            .inner
            .as_mut()
            .expect("ParseSchemaRowsState not initialized");
        // Destructure so the statement (receiver) and the accumulators (captured
        // by the closure) are borrowed as disjoint fields.
        let ParseSchemaRowsInner {
            rows,
            from_sql_indexes,
            automatic_indices,
            dbsp_state_roots,
            dbsp_state_index_roots,
            materialized_view_info,
        } = inner;
        crate::return_if_io!(rows.run_with_row_callback_nonblock(|row| {
            let ty = row.get::<&str>(0)?;
            let name = row.get::<&str>(1)?;
            let table_name = row.get::<&str>(2)?;
            let root_page = row.get::<i64>(3)?;
            let sql = row.get::<&str>(4).ok();
            schema.handle_schema_row(
                ty,
                name,
                table_name,
                root_page,
                sql,
                syms,
                from_sql_indexes,
                automatic_indices,
                dbsp_state_roots,
                dbsp_state_index_roots,
                materialized_view_info,
                resolve_attached_db,
                dialect,
            )
        }));
    }
```

幾個重點：

**`row.get::<&str>(0..4)`** —— 這五欄就是 `sqlite_schema` 的固定結構：type、name、tbl_name、rootpage、sql。`sql` 用 `.ok()` 因為某些內部項目（例如自動建立的 index）沒有 SQL 文字。

**`return_if_io!`** —— 掃描過程隨時可能需要讀 page，直接把 I/O 往上拋。這是 `01-source-code-learn-5-cursor-storage.md` 講過的機制。

**那段解構的註解值得注意**：

> Destructure so the statement (receiver) and the accumulators (captured by the closure) are borrowed as disjoint fields.

`rows.run_with_row_callback_nonblock(|row| { ... })` 這個呼叫同時需要：可變借用 `rows`（作為接收者），以及可變借用其他累積欄位（在 closure 裡用）。如果直接寫 `inner.rows.run_with(...|row| inner.from_sql_indexes...)`，borrow checker 會拒絕——它看不出這是兩個不相交的欄位。

**先解構成獨立變數**，borrow checker 就能分別追蹤。這是 Rust 裡很常見的手法，不是為了好看，是為了通過編譯。

**`core/util.rs:246-265`** — 完整貼出收尾：

```rust
    // Scan complete: finalize. Take ownership of the accumulators.
    let inner = state
        .inner
        .take()
        .expect("ParseSchemaRowsState not initialized");
    let has_mv_store = inner.rows.mv_store().is_some();
    schema.populate_indices(
        syms,
        inner.from_sql_indexes,
        inner.automatic_indices,
        has_mv_store,
    )?;
    schema.populate_materialized_views(
        inner.materialized_view_info,
        inner.dbsp_state_roots,
        inner.dbsp_state_index_roots,
    )?;

    Ok(IOResult::Done(()))
}
```

**為什麼 index 要等掃完才處理？** 因為 index 依附於表。`sqlite_schema` 的列順序不保證表一定在它的 index 之前，所以要先把所有列收集完，再統一建立關聯。

`state.inner.take()` —— 取走所有權，同時把 state 標記為已完成。如果有人重複呼叫，`expect` 會 panic 而不是產生錯誤結果。**用型別狀態表達「這個操作只能完成一次」。**

### 誰呼叫它

**`core/connection.rs:1400`** — 節錄：

```rust
                    crate::return_if_io!(crate::util::parse_schema_rows(
```

在 `Connection` 的 schema reparse 狀態機裡。注意這裡又是一個 `return_if_io!` —— I/O 從 `parse_schema_rows` 冒泡到 connection，再冒泡到更上層。

**重要更正（原 `05-schema-values-records.md` 曾寫錯）**：`parse_schema_rows` **不是** `Schema` 的方法，它是 `core/util.rs` 的自由函式。`Schema` 上的方法是 `handle_schema_row`（處理單列）和 `populate_indices` / `populate_materialized_views`（收尾）。

---

## Schema：編譯器的 metadata 來源

**`core/schema.rs:759-789`** — 完整貼出主要欄位：

```rust
pub struct Schema {
    pub tables: HashMap<String, Arc<Table>>,
    #[cfg(feature = "conn_raw_api")]
    pub(crate) table_names_by_root_page: HashMap<i64, String>,

    /// Track which tables are actually materialized views
    pub materialized_view_names: HashSet<String>,
    /// Store original SQL for materialized views (for .schema command)
    pub materialized_view_sql: HashMap<String, String>,
    /// The incremental view objects (DBSP circuits)
    pub incremental_views: HashMap<String, Arc<Mutex<IncrementalView>>>,

    pub views: ViewsMap,

    /// table_name to list of triggers
    pub triggers: HashMap<String, VecDeque<Arc<Trigger>>>,

    /// table_name to list of indexes for the table
    pub indexes: HashMap<String, VecDeque<Arc<Index>>>,
    pub has_indexes: HashSet<String>,
    pub schema_version: u32,
    /// Statistics collected via ANALYZE for regular B-tree tables and indexes.
    pub analyze_stats: AnalyzeStats,

    /// Mapping from table names to the materialized views that depend on them
    pub table_to_materialized_views: HashMap<String, Vec<String>>,

    /// Track views that exist but have incompatible versions
    pub incompatible_views: HashSet<String>,
```

```rust
    // ── 省略（core/schema.rs:790-830 附近）：解析失敗的 view 記錄、
    //    custom types / domains、sequences 等其餘欄位 ──
```

幾個觀察：

**大量 `HashMap<String, ...>`** —— schema 的核心工作就是「用名字查東西」。編譯器問「users 這張表存在嗎」，就是一次 HashMap 查詢。

**`Arc<Table>`** —— 表的定義被 `Arc` 包起來，因為它會被多個 `Program` 共享。`01-source-code-learn-3-translate.md` 提過 `compile_cmd` 會 `self.schema.read().clone()` 拿一份快照——這個 clone 之所以可接受，就是因為裡面存的都是 `Arc`，clone 只複製指標。

**`schema_version`** —— 對應 database header 的 schema cookie。`01-source-code-learn-4-step-vm.md` 講過的 reprepare 機制就靠它偵測 schema 是否變過。

**`analyze_stats`** —— `ANALYZE` 收集的統計資料。`03-source-code-learn-1-planner.md` 講的 optimizer 靠它估算成本。沒有統計資料時 optimizer 用預設啟發式；有了之後選擇會更準。

**`incompatible_views`** —— 「存在但版本不相容的 view」。這反映一個現實：schema 可能是舊版本的 Turso 或 SQLite 寫的，其中某些項目當前版本處理不了。做法是**記錄下來而不是整個開啟失敗**——不能因為一個 view 不認得就讓整個資料庫打不開。

---

## BTreeTable：一張表的完整定義

**`core/schema.rs:3233-3250`** — 完整貼出：

```rust
pub struct BTreeTable {
    pub root_page: i64,
    pub name: String,
    pub primary_key_columns: Vec<(String, SortOrder)>,
    columns: Vec<Column>,
    pub has_rowid: bool,
    pub is_strict: bool,
    pub has_autoincrement: bool,
    pub unique_sets: Vec<UniqueSet>,
    pub foreign_keys: Vec<Arc<ForeignKey>>,
    pub check_constraints: Vec<CheckConstraint>,
    /// ON CONFLICT clause for the INTEGER PRIMARY KEY constraint.
    /// Stored here because rowid-alias PKs have their UniqueSet removed.
    pub rowid_alias_conflict_clause: Option<ResolveType>,
    pub has_virtual_columns: bool,
    pub logical_to_physical_map: Vec<usize>,
    column_dependencies: ResetOnClone<OnceLock<GeneratedColGraph>>,
}
```

逐欄的重點：

**`root_page`** —— 連接 SQL 世界與儲存世界的那一個數字。`01-source-code-learn-5-cursor-storage.md` 看過：`OpenRead` 指令只帶 root_page，storage 層完全不知道表叫什麼名字。

**`columns` 是私有的**（沒有 `pub`）。其他欄位大多公開，唯獨欄位列表要透過方法存取。原因是修改欄位需要連帶更新 `logical_to_physical_map` 等衍生資料，直接開放會讓兩者不同步。**用可見性強制不變量。**

**`has_rowid`** —— 區分一般表和 `WITHOUT ROWID` 表。兩者的 B-tree key 完全不同（前者是 rowid 整數，後者是主鍵欄位組合），影響幾乎所有存取路徑。

**`is_strict`** —— SQLite 3.37+ 的 `STRICT` 表，型別檢查嚴格化。它會改變 affinity 行為（下面會看到）。

**`logical_to_physical_map`** —— 這個欄位值得解釋。「邏輯欄位序號」是使用者看到的順序，「實體欄位序號」是 record 裡實際的位置。兩者何時會不同？當表有**虛擬欄位（generated columns）**時——虛擬欄位不佔 record 空間，是讀取時算出來的。所以邏輯第 3 欄可能是實體第 2 個儲存位置。

`Column` 指令拿到的是實體位置，這個 map 就是編譯期做轉換用的。

**`rowid_alias_conflict_clause`** 的註解揭露了一個特例：

> Stored here because rowid-alias PKs have their UniqueSet removed.

`INTEGER PRIMARY KEY` 是 rowid 的別名，它的唯一性由 B-tree 結構本身保證，不需要額外的唯一性檢查，所以對應的 `UniqueSet` 被移除了。但 `ON CONFLICT` 子句仍需要保存，於是單獨拉一個欄位放。**這種「特例欄位」通常標記著一個相容性細節。**

**`column_dependencies: ResetOnClone<OnceLock<...>>`** —— 虛擬欄位的相依圖，惰性計算（`OnceLock`）。`ResetOnClone` 表示 clone 時要重置這個快取，因為它是衍生資料，複製過去可能對應不到新的上下文。

---

## Value：執行期的值

**`core/types.rs:334-341`** — 完整貼出：

```rust
#[derive(Debug, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum Value {
    Null,
    Numeric(Numeric),
    Text(Text),
    Blob(#[cfg_attr(feature = "serde", serde(with = "value_blob_serde"))] ValueBlob),
}
```

只有四個變體，對應 SQLite 的四種儲存類別。注意**整數和浮點合併成 `Numeric`**，而不是分開的 `Integer` / `Float`。這反映 SQLite 的數值處理：整數可能因為運算溢位而變成浮點，兩者在很多路徑上要統一處理。

型別標籤則是分開的：

**`core/types.rs:38-45`** — 完整貼出：

```rust
pub enum ValueType {
    Null,
    Integer,
    Float,
    Text,
    Blob,
    Error,
}
```

這裡整數與浮點是分開的，因為 `typeof()` 函式要能區分它們。多一個 `Error` 變體用於錯誤傳播。

### ValueRef：避免複製

**`core/types.rs:343-350`** — 完整貼出：

```rust
#[derive(Clone, Copy)]
pub enum ValueRef<'a> {
    Null,
    Numeric(Numeric),
    Text(TextRef<'a>),
    Blob(&'a [u8]),
}
```

和 `Value` 平行，但 `Text` 和 `Blob` 是**借用**而非擁有。而且是 `Copy`。

為什麼需要這個？因為從 record 讀出一個文字欄位時，資料已經在 page buffer 裡了。如果每次讀取都複製一份 `String`，掃描百萬列就是百萬次配置。用 `ValueRef` 直接指向 page 裡的 bytes，零複製。

代價是 lifetime 管理：`ValueRef` 不能活得比它借用的 buffer 久。所以在需要保存時（例如放進 register 跨越指令）才轉成擁有的 `Value`。

**這組 owned/borrowed 對偶在資料庫程式碼裡非常典型**：熱路徑用借用版，需要保存時才轉擁有版。

---

## Affinity：SQLite 最反直覺的設計

SQL 標準是靜態型別：宣告 `INTEGER` 的欄位就只能存整數。SQLite 不是——它是**動態型別加上「傾向」**。宣告 `INTEGER` 只表示「盡量存成整數」，但實際上存文字進去也可以。

### 五種 affinity

**`core/vdbe/affinity.rs:77-83`** — 完整貼出：

```rust
pub enum Affinity {
    Blob = 0,
    Text = 1,
    Numeric = 2,
    Integer = 3,
    Real = 4,
}
```

**`core/vdbe/affinity.rs:85-89`** — 對應的字元編碼：

```rust
pub const SQLITE_AFF_NONE: char = 'A'; // Historically called NONE, but it's the same as BLOB
pub const SQLITE_AFF_TEXT: char = 'B';
pub const SQLITE_AFF_NUMERIC: char = 'C';
pub const SQLITE_AFF_INTEGER: char = 'D';
pub const SQLITE_AFF_REAL: char = 'E';
```

為什麼要有字元編碼？因為 bytecode 指令要攜帶 affinity 資訊。註解解釋了用途：

**`core/vdbe/affinity.rs:92-97`**

```rust
    /// This is meant to be used in opcodes like Eq, which state:
    ///
    /// "The SQLITE_AFF_MASK portion of P5 must be an affinity character - SQLITE_AFF_TEXT, SQLITE_AFF_INTEGER, and so forth.
    /// An attempt is made to coerce both inputs according to this affinity before the comparison is made.
    /// If the SQLITE_AFF_MASK is 0x00, then numeric affinity is used.
    /// Note that the affinity conversions are stored back into the input registers P1 and P3.
```

**比較之前要先做 affinity 轉換**。這就是為什麼 `Eq` 指令需要知道 affinity——`WHERE text_col = 5` 的比較方式，取決於欄位的 affinity。

`'A'` 到 `'E'` 這種編碼是直接抄 SQLite 的，為了 bytecode 層級的相容。

### 從 declared type 推出 affinity 的五條規則

**`core/vdbe/affinity.rs:178-203`** — 完整貼出：

```rust
    pub fn affinity(datatype: &str) -> Self {
        let datatype = datatype.to_ascii_uppercase();

        // Rule 1: INT -> INTEGER affinity
        if datatype.contains("INT") {
            return Affinity::Integer;
        }

        // Rule 2: CHAR/CLOB/TEXT -> TEXT affinity
        if datatype.contains("CHAR") || datatype.contains("CLOB") || datatype.contains("TEXT") {
            return Affinity::Text;
        }

        // Rule 3: BLOB or empty -> BLOB affinity (historically called NONE)
        if datatype.contains("BLOB") || datatype.is_empty() {
            return Affinity::Blob;
        }

        // Rule 4: REAL/FLOA/DOUB -> REAL affinity
        if datatype.contains("REAL") || datatype.contains("FLOA") || datatype.contains("DOUB") {
            return Affinity::Real;
        }

        // Rule 5: Otherwise -> NUMERIC affinity
        Affinity::Numeric
    }
```

這是整個 SQLite 型別系統最出名（也最被詬病）的部分：**用子字串比對決定型別**。

規則的**順序是語義的一部分**，不能重排。舉例：

- `"VARCHAR(20)"` —— 不含 INT，含 CHAR → **Text**。
- `"POINT"` —— **含 INT**（"po-INT"）→ **Integer**！

`POINT` 這個例子不是我編的，它是 SQLite 社群著名的陷阱。因為規則 1 最先檢查且用子字串比對，任何包含 "int" 的型別名都會得到 INTEGER affinity。

Turso 必須**完整複製這個行為**，包括它的怪異之處。這就是「相容性」的真實代價：你要複製的不只是正確的部分。

也注意 `datatype.is_empty()` → Blob。SQLite 允許 `CREATE TABLE t(a)`（不寫型別），這時得到 BLOB affinity（也叫 NONE），意思是「不做任何轉換」。

### 自訂型別的覆寫

**`core/schema.rs:5149-5163`** — 完整貼出：

```rust
impl Column {
    pub fn affinity(&self) -> Affinity {
        let v = ((self.raw & BASE_AFF_MASK) >> BASE_AFF_SHIFT) as u8;
        if v > 0 {
            // Custom type column: use the base type's affinity
            match v {
                1 => Affinity::Integer,
                2 => Affinity::Text,
                3 => Affinity::Blob,
                4 => Affinity::Real,
                _ => Affinity::Numeric,
            }
        } else {
            Affinity::affinity(&self.ty_str)
        }
    }
```

Turso 支援 `CREATE TYPE` 自訂型別。如果欄位用的是自訂型別，就用它的**基底型別**的 affinity，而不是把自訂型別名丟去跑那五條規則。

註解說明了理由：

> This ensures affinity rules use the custom type's BASE type rather than applying SQLite name-based rules to the type name.

想想如果不這樣做：使用者定義 `CREATE TYPE cents AS INTEGER`，然後宣告 `amount cents`。跑名稱規則的話，"cents" 不含 INT/CHAR/BLOB/REAL → NUMERIC affinity，而不是預期的 INTEGER。**名稱規則只對 SQLite 的內建型別名有意義，對自訂名稱套用是沒道理的。**

### 位元打包

注意 affinity 是從 `self.raw` 用位移和遮罩取出來的：

**`core/schema.rs:5140-5147`** — 節錄：

```rust
// 0 = not set (use ty_str-based affinity), 1-5 = Affinity value + 1
const BASE_AFF_SHIFT: u32 = COLL_SHIFT + 12;
const BASE_AFF_MASK: u32 = 0b111 << BASE_AFF_SHIFT;

// Bits 23-25: array dimensions (0 = scalar, 1-7 = number of [] dimensions)
const ARRAY_DIM_SHIFT: u32 = BASE_AFF_SHIFT + 3;
const ARRAY_DIM_MASK: u32 = 0b111 << ARRAY_DIM_SHIFT;
```

`Column` 把多個小欄位（NOT NULL、primary key、collation、base affinity、array 維度……）打包進一個 `u32`。

為什麼？因為一個資料庫可能有數千個欄位定義常駐記憶體，每個欄位省下十幾個 bytes 是有意義的。代價是可讀性——所以才需要 `set_base_affinity` 這類存取方法把位元操作封裝起來。

`0 = not set` 的設計也值得注意：用 0 表示「沒有覆寫，走名稱規則」，1-5 表示實際的 affinity（值 +1）。**用一個值域外的值表示「未設定」**，省下一個 `Option`。

### STRICT 表的例外

**`core/schema.rs:5178-5184`** — 完整貼出：

```rust
    pub fn affinity_with_strict(&self, is_strict: bool) -> Affinity {
        if is_strict && self.ty_str.eq_ignore_ascii_case("ANY") {
            Affinity::Blob
        } else {
            self.affinity()
        }
    }
```

在 `STRICT` 表裡，`ANY` 型別的欄位得到 BLOB affinity——也就是**完全不做轉換**，原樣保存。

這是 SQLite 3.37 的規定：STRICT 表的 `ANY` 欄位要保留值的原始型別，不能因為 affinity 而悄悄轉換。這是一個很細的相容性細節，但寫錯了就會在特定情境產生型別不一致。

---

## Record：值如何變成磁碟上的 bytes

SQLite 的 record 格式：

```text
header_size    varint
serial_type_1  varint
serial_type_2  varint
...
data_1
data_2
...
```

header 記錄每個欄位的 **serial type**（第四個型別概念），它同時編碼「型別」與「長度」：

| serial type | 意義 |
|---|---|
| 0 | NULL |
| 1-6 | 整數（1、2、3、4、6、8 bytes） |
| 7 | 8-byte 浮點 |
| 8 | 常數 0（不佔資料空間） |
| 9 | 常數 1（不佔資料空間） |
| N≥12 偶數 | BLOB，長度 (N-12)/2 |
| N≥13 奇數 | TEXT，長度 (N-13)/2 |

兩個設計值得注意：

**整數用最少的 bytes。** 值為 5 的整數只佔 1 byte，不是 8。所以同一欄在不同列可能有不同的 serial type。

**常數 0 和 1 有專屬編碼**（8 和 9），完全不佔資料空間。布林值密集的表因此大幅省空間。

這解釋了 `01-source-code-learn-5-cursor-storage.md` 看到的 `nth_into_register` 為什麼是**增量解析** header：要取第 5 欄，得先知道前 4 欄各佔幾個 byte 才能算出偏移量——但只需要解析到第 5 個 serial type，後面的可以不管。

也解釋了另外三件事：

- **ALTER TABLE ADD COLUMN 的 short record**：舊列是用舊 schema 寫的，header 裡就是少幾個 serial type。讀取時發現欄位數不足，就套用 DEFAULT。
- **index key 是 record-like 格式**：index 的 key 也是用同一套編碼，所以比較邏輯可以共用。
- **affinity 影響儲存**：`INTEGER` affinity 的欄位存入文字 `"123"` 時會先轉成整數再編碼，於是實際存的是 serial type 1 而非 TEXT。

編碼與解碼的實作在 `core/types.rs` 與 `core/storage/sqlite3_ondisk.rs`，完整的 page 與 cell 格式見 `06a`。

---

## DDL 的完整路徑

`CREATE TABLE` 不是「在記憶體 map 插一筆」，而是：

```text
1. parser 產生 Stmt::CreateTable                sqlite/parser/src/parser.rs
2. translate_create_table 驗證欄位/約束/預設值   core/translate/schema.rs
3. emit Insn::CreateBtree（配置 root page）      core/vdbe/insn.rs
4. emit Insn::Insert（寫一列進 sqlite_schema）
5. emit Insn::SetCookie（更新 schema 版本）
6. 觸發 schema reparse 或就地更新記憶體 schema   core/util.rs::parse_schema_rows
```

**DDL 的正確性核心是四者必須一致**：

- 磁碟上的 `sqlite_schema` 列
- 配置出來的 root page
- database header 裡的 schema cookie
- 記憶體裡的 `Schema`

任何一項不同步都會出問題。例如 cookie 沒更新，其他 connection 就不知道 schema 變了，會繼續用過期的 bytecode（`01-source-code-learn-4-step-vm.md` 講的 reprepare 機制靠的就是 cookie）。

---

## 動手驗證

看 schema 真的存在資料庫裡：

```bash
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE INDEX users_name_idx ON users(name);
SELECT type, name, tbl_name, rootpage, sql FROM sqlite_schema;
```

你會看到兩列（table 與 index），`sql` 欄位存著你剛才打的原始 SQL 文字，`rootpage` 是各自 B-tree 的 root。

驗證 affinity 的怪異之處：

```sql
CREATE TABLE aff(a POINT, b VARCHAR(10), c BLOB, d);
INSERT INTO aff VALUES ('123', 456, '789', '000');
SELECT typeof(a), typeof(b), typeof(c), typeof(d) FROM aff;
```

- `a POINT` —— 含 "INT" → INTEGER affinity → 文字 `'123'` 被轉成整數。
- `b VARCHAR(10)` —— 含 "CHAR" → TEXT affinity → 數字 456 被轉成文字。
- `c BLOB` —— BLOB affinity → 不轉換。
- `d`（無型別）—— 空字串 → BLOB affinity → 不轉換。

這個實驗直接對應上面那五條規則。

驗證 serial type 的空間效率：

```sql
CREATE TABLE small(v INTEGER);
INSERT INTO small VALUES (0), (1), (5), (100000);
```

值 0 和 1 用專屬 serial type 完全不佔資料空間；5 佔 1 byte；100000 佔 3 bytes。同一欄，不同列，不同編碼。

追 source：

```bash
rg -n "SCHEMA_TABLE_NAME|pub struct Schema \{|pub struct BTreeTable" core/schema.rs
rg -n "pub fn parse_schema_rows" core/util.rs
rg -n "parse_schema_rows\(" core/connection.rs
rg -n "pub enum Value|pub enum ValueRef|pub enum ValueType" core/types.rs
rg -n "pub enum Affinity|pub fn affinity" core/vdbe/affinity.rs
```

---

## 自我檢查

1. `sqlite_schema` 本身也是一張 B-tree table。這造成什麼雞生蛋問題？怎麼解決？
2. `parse_schema_rows` 在哪個檔案？它是 `Schema` 的方法嗎？誰呼叫它？
3. 為什麼 index 要等所有 schema 列掃完才 `populate_indices`，不能邊掃邊建？
4. `parse_schema_rows` 為什麼要先解構 `inner` 再用？和 borrow checker 有什麼關係？
5. `BTreeTable.columns` 為什麼是私有欄位，而其他欄位大多公開？
6. `logical_to_physical_map` 在什麼情況下不是恆等映射？
7. `Value` 把整數和浮點合併成 `Numeric`，但 `ValueType` 把它們分開。為什麼？
8. `ValueRef` 相對於 `Value` 的好處是什麼？代價是什麼？
9. 宣告成 `POINT` 的欄位會得到什麼 affinity？為什麼？
10. 自訂型別為什麼不能直接套用名稱規則？舉一個會出錯的例子。
11. `Column` 為什麼要把多個屬性位元打包進一個 `u32`？`0 = not set` 的設計省下了什麼？
12. declared type、affinity、runtime `Value`、serial type 四者的差別是什麼？
13. 值 0 的整數在 record 裡佔幾個 byte？為什麼？
14. DDL 必須讓哪四樣東西保持一致？漏掉 schema cookie 會出什麼問題？

---

下一篇 `05b-source-code-learn-functions-expressions.md`：表達式如何編譯成 register 操作、純量／聚合／視窗函式的差別。
