# 11. 源碼精讀：Materialized View 與 DBSP 增量計算

`core/incremental/` 有 21,858 行，實作**增量視圖維護**（Incremental View Maintenance, IVM）：當基礎表變動時，materialized view 不重算整個查詢，只根據「變了什麼」算出「結果變了什麼」。

前面章節已經數次碰到它的邊緣——`04-source-code-learn-2-cursor-opcodes.md` 講 `op_insert` 的 `MaybeCaptureRecord` 狀態時，那個「擷取舊值」就是為了餵給這個子系統。本篇補上完整的圖像。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 45–60 分鐘（約 13k 字，其中 37% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/incremental/dbsp.rs      Delta / HashableRow ── 「變更」的表示法
core/incremental/operator.rs  IncrementalOperator ── 運算元的統一介面
core/incremental/compiler.rs  SQL → 運算元電路（6,152 行）
core/incremental/view.rs      IncrementalView ── 視圖的生命週期
core/incremental/cursor.rs    讀取視圖時的 cursor
```

---

## 問題：為什麼不能重算

```sql
CREATE MATERIALIZED VIEW sales_by_region AS
  SELECT region, sum(amount) FROM orders GROUP BY region;
```

`orders` 有一億列。現在插入**一列**新訂單。

**重算的成本**：掃描一億列、重新聚合。一次插入要幾秒鐘。

**增量計算的成本**：新訂單屬於 region='east'，所以 `east` 那一組的 sum 加上這筆金額。**O(1)**。

這就是 IVM 的價值。難的地方在於：**不是所有查詢都能這樣增量更新**，而且要處理刪除、更新、以及運算元的組合（join 之上再聚合等）。

---

## 核心表示法：Delta 與 weight

DBSP（DataBase Stream Processor）的關鍵洞見是：**把「變更」表示成帶正負權重的列集合**。

**`core/incremental/dbsp.rs:202-207`** — 完整貼出：

```rust
pub struct Delta {
    /// Ordered list of changes: (row, weight) where weight is +1 for insert, -1 for delete
    /// It is crucial that this is ordered. Imagine the case of an update, which becomes a delete +
    /// insert. If this is not ordered, it would be applied in arbitrary order and break the view.
    pub changes: Vec<DeltaEntry>,
}
```

**`weight = +1` 是插入，`-1` 是刪除。**

這個表示法的威力在於：**UPDATE 可以拆成「刪除舊列 + 插入新列」**，於是所有變更都統一成同一種形式。

```text
UPDATE orders SET amount = 200 WHERE id = 5;   -- 原本是 100

Delta:
  ({id:5, amount:100}, -1)   ← 刪除舊的
  ({id:5, amount:200}, +1)   ← 插入新的
```

聚合運算元收到這個 delta 時，只要做 `sum += (-100) + 200 = +100`——**不需要知道這是 UPDATE**，統一按權重累加即可。

### 為什麼順序至關重要

註解特別強調：

> **It is crucial that this is ordered.** Imagine the case of an update, which becomes a delete + insert. If this is not ordered, it would be applied in arbitrary order and break the view.

考慮一個有唯一約束的視圖。UPDATE 拆成 delete + insert：

- **正確順序**（先 delete 再 insert）：舊列消失，新列進來。
- **錯誤順序**（先 insert 再 delete）：中間狀態同時有兩列 → **違反唯一約束**，或者 delete 誤刪了剛插入的那列。

所以 `changes` 是 `Vec`（有序）而非 `HashSet` 或 `HashMap`。**用容器型別強制順序語義**。

**`core/incremental/dbsp.rs:216-222`** — 建構方法：

```rust
    pub fn insert(&mut self, row_key: i64, values: Vec<Value>) {
        let row = HashableRow::new(row_key, values);
        self.changes.push((row, 1));
    }

    pub fn delete(&mut self, row_key: i64, values: Vec<Value>) {
        let row = HashableRow::new(row_key, values);
```

`push` 而非 `insert into map`——順序由呼叫者決定並保留。

### 128-bit 雜湊：為什麼需要

**`core/incremental/dbsp.rs:9-27`** — 完整貼出：

```rust
/// A 128-bit hash value implemented as a UUID
/// We use UUID because it's a standard 128-bit type we already depend on
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Hash128 {
    // Store as UUID internally for efficient 128-bit representation
    uuid: uuid::Uuid,
}

impl Hash128 {
    /// Create a new 128-bit hash from high and low 64-bit parts
    pub fn new(high: u64, low: u64) -> Self {
        // Convert two u64 values to UUID bytes (big-endian)
        let mut bytes = [0u8; 16];
        bytes[0..8].copy_from_slice(&high.to_be_bytes());
        bytes[8..16].copy_from_slice(&low.to_be_bytes());
        Self {
            uuid: uuid::Uuid::from_bytes(bytes),
        }
    }
```

**為什麼是 128 位元而不是 64？**

因為這個雜湊要當作**視圖裡的 row key**。生日悖論告訴我們：64-bit 雜湊在約 2^32（40 億）個不同值時就有可觀的碰撞機率。對一個可能有數十億列的視圖，這不夠。

128-bit 把碰撞機率壓到可忽略。

**`core/incremental/dbsp.rs:29-48`** — 完整貼出：

```rust
    /// Get the low 64 bits as i64 (for when we need a rowid)
    pub fn as_i64(&self) -> i64 {
        let bytes = self.uuid.as_bytes();
        let low = u64::from_be_bytes([
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        ]);
        low as i64
    }

    /// Compute a 128-bit hash of the given values
    /// We serialize values to a string representation and use UUID v5 (SHA-1 based)
    /// to get a deterministic 128-bit hash
    pub fn hash_values(values: &[Value]) -> Self {
        // Build a string representation of all values
        // Use a delimiter that won't appear in normal values
        let mut s = String::new();
        for (i, value) in values.iter().enumerate() {
            if i > 0 {
                s.push('\x00'); // null byte as delimiter
            }
            // Add type prefix to distinguish between types
            match value {
```

三個實作細節值得注意：

**`as_i64()` 取低 64 位元當 rowid** —— 因為 B-tree table 的 key 必須是 `i64`（`06a-source-code-learn-file-format-pages.md`）。視圖的儲存還是普通的 B-tree，所以 128-bit 雜湊要壓成 64-bit 當 rowid。這裡碰撞機率就回到 64-bit 的水準了，但因為完整的 128-bit 值也存著，可以在讀取時做二次確認。

**`'\x00'` 當分隔符** —— 避免 `["ab", "c"]` 和 `["a", "bc"]` 雜湊成同一個值。這是序列化的經典陷阱：**沒有分隔符的串接會造成歧義**。

**「Add type prefix to distinguish between types」** —— 整數 `1` 和字串 `"1"` 必須雜湊成不同的值。`05-source-code-learn-schema-values-records.md` 講過 SQLite 是動態型別，同一欄可以存不同型別，所以型別必須參與雜湊。

**「deterministic」（UUID v5 / SHA-1）** —— 不能用 Rust 預設的 `HashMap` 雜湊器，因為那是每次程序啟動隨機種子的。視圖的 row key 要能**跨程序重啟保持一致**（它存在磁碟上），所以必須用確定性雜湊。

---

## 運算元介面

**`core/incremental/operator.rs:231-260`** — 完整貼出：

```rust
pub trait IncrementalOperator: Debug + Send {
    /// Evaluate the operator with a state, without modifying internal state
    /// This is used during query execution to compute results
    /// May need to read from storage to get current state (e.g., for aggregates)
    ///
    /// # Arguments
    /// * `state` - The evaluation state (may be in progress from a previous I/O operation)
    /// * `cursors` - Cursors for reading operator state from storage (table and optional index)
    ///
    /// # Returns
    /// The output delta from the evaluation
    fn eval(
        &mut self,
        state: &mut EvalState,
        cursors: &mut DbspStateCursors,
    ) -> Result<IOResult<Delta>>;

    /// Commit deltas to the operator's internal state and return the output
    /// This is called when a transaction commits, making changes permanent
    /// Returns the output delta (what downstream operators should see)
    /// The cursors parameter is for operators that need to persist state
    fn commit(
        &mut self,
        deltas: DeltaPair,
        cursors: &mut DbspStateCursors,
    ) -> Result<IOResult<Delta>>;

    /// Set computation tracker
    fn set_tracker(&mut self, tracker: Arc<Mutex<ComputationTracker>>);
}
```

**核心簽章是 `Delta → Delta`**：輸入變更，輸出變更。運算元可以串成電路，前一個的輸出接後一個的輸入。

`core/incremental/` 的運算元實作：

| 檔案 | 運算元 | 行數 |
|---|---|---|
| `filter_operator.rs` | WHERE 過濾 | 524 |
| `aggregate_operator.rs` | GROUP BY 聚合 | 3,172 |
| `join_operator.rs` | JOIN | 734 |

**聚合最複雜（3,172 行）**，因為它需要保存狀態（每組的當前值），而且刪除時要能正確減回去。

### eval 與 commit 的分工

註解說明了兩個方法的差異：

- **`eval`** —— 「without modifying internal state」，用於查詢執行時算出結果。
- **`commit`** —— 「making changes permanent」，交易提交時把變更寫進運算元的持久狀態。

**為什麼要分開？** 因為交易可能 rollback。執行期間算出的中間結果不能直接寫進視圖的持久狀態——必須等到 commit 才生效。這對應 `07a-source-code-learn-wal-transactions.md` 講的交易原子性。

### 又是 IOResult

```rust
    ) -> Result<IOResult<Delta>>;
```

**兩個方法都回傳 `IOResult`**，而且 `EvalState` 的註解寫明「may be in progress from a previous I/O operation」。

為什麼運算元需要 I/O？註解也答了：「May need to read from storage to get current state (e.g., for aggregates)」。

聚合的當前值存在磁碟上（一個內部的 DBSP state 表）。要更新 `sum`，得先讀出目前的值——那是一次 B-tree 讀取，可能 I/O。

**所以 `07b-source-code-learn-ioresult-reentry.md` 的重入規則在這裡完全適用**：`EvalState` 就是那個跨 yield 保存進度的狀態機。

`DbspStateCursors` 則是讀寫運算元狀態用的 cursor——**視圖的內部狀態也是存在 B-tree 裡的**，用的是和使用者資料完全相同的儲存機制（`06a`）。

---

## 與 VM 的接點

回顧 `04-source-code-learn-2-cursor-opcodes.md` 看過的 `op_insert`：

```rust
            OpInsertSubState::MaybeCaptureRecord => {
                let has_dependent_views = {
                    let schema = program.connection.schema.read();
                    !schema
                        .get_dependent_materialized_views(table_name)
                        .is_empty()
                };
```

**這就是 IVM 的觸發點。** 寫入時檢查「這張表有沒有依賴它的 materialized view」：

- **沒有** → 什麼都不做（絕大多數情況，零成本）。
- **有** → 擷取舊值，之後產生 `Delta` 餵給視圖的運算元電路。

`05-source-code-learn-schema-values-records.md` 看過的 `Schema` 欄位在這裡發揮作用：

```rust
    /// Mapping from table names to the materialized views that depend on them
    pub table_to_materialized_views: HashMap<String, Vec<String>>,
```

**這個反向索引讓「這張表有沒有視圖依賴」變成一次 HashMap 查詢**，而不是掃描所有視圖。因為它在每次寫入的熱路徑上。

`03-source-code-learn-3-emitter-dml-ddl.md` 也提過編譯期的準備：

```rust
                let prepared = prepare_cdc_if_necessary(
                    program,
                    t_ctx.resolver.schema(),
                    Some(changed_table.get_name()),
                )?;
```

而 `01-source-code-learn-4-step-vm.md` 講的 `normal_step` 裡有一個當時略過的方法：

```rust
    fn apply_view_deltas(
        &self,
        state: &mut ProgramState,
        rollback: bool,
        pager: &Arc<Pager>,
    ) -> Result<IOResult<()>> {
```

**交易提交（或回滾）時，累積的 view delta 在這裡被套用。** `rollback: bool` 參數讓同一個函式處理兩種情況——回滾時直接丟棄 delta。

---

## 編譯：SQL → 運算元電路

`core/incremental/compiler.rs` 有 6,152 行，把 `CREATE MATERIALIZED VIEW` 的 SELECT 編譯成運算元電路。

```text
SELECT region, sum(amount) FROM orders WHERE amount > 0 GROUP BY region

編譯成:
  orders 的 Delta
      ↓
  FilterOperator (amount > 0)
      ↓
  AggregateOperator (GROUP BY region, sum(amount))
      ↓
  視圖的 Delta
```

**這是另一套編譯器**，和 `03-source-code-learn-*.md` 講的 VDBE 編譯器並存：

| | VDBE 編譯器 | DBSP 編譯器 |
|---|---|---|
| 輸入 | `ast::Stmt` | 視圖定義的 SELECT |
| 輸出 | `Vec<Insn>` | 運算元電路 |
| 執行模型 | 掃描資料、產生結果 | 接收 Delta、產生 Delta |
| 位置 | `core/translate/` | `core/incremental/compiler.rs` |

**並非所有 SQL 都能編譯成增量電路。** 例如帶 `LIMIT` 的視圖——刪掉一列可能讓原本被排除的列進入結果，那需要重新查詢而非增量更新。這類查詢會被拒絕或退化成重算。

`02-source-code-learn-parser-and-ast.md` 提過的 `Expr::Register(usize)` 註解也在這裡得到解釋：

```rust
    /// Register reference for DBSP expression compilation
    /// This is not part of SQL syntax but used internally for incremental computation
    Register(usize),
```

DBSP 編譯器會**改寫 AST**，把欄位參照換成 register 編號。這就是為什麼 AST 裡會有一個不屬於 SQL 語法的變體。

---

## 儲存：視圖也是 B-tree

`05-source-code-learn-schema-values-records.md` 看過 `Schema` 的相關欄位：

```rust
    /// Track which tables are actually materialized views
    pub materialized_view_names: HashSet<String>,
    /// Store original SQL for materialized views (for .schema command)
    pub materialized_view_sql: HashMap<String, String>,
    /// The incremental view objects (DBSP circuits)
    pub incremental_views: HashMap<String, Arc<Mutex<IncrementalView>>>,
```

三個欄位分別存名稱、原始 SQL、以及編譯好的電路。

而 `core/util.rs` 的 `parse_schema_rows`（同篇講過）在收尾時：

```rust
    schema.populate_materialized_views(
        inner.materialized_view_info,
        inner.dbsp_state_roots,
        inner.dbsp_state_index_roots,
    )?;
```

**`dbsp_state_roots` 是運算元狀態表的 root page。** 開啟資料庫時，視圖的內容和運算元的中間狀態都要從 B-tree 讀回來。

`core/incremental/cursor.rs`（1,992 行）則實作讀取視圖的 cursor——它同樣實作 `CursorTrait`（`06b-source-code-learn-btree-cursor-pager.md`），所以 VM 查詢視圖時和查詢普通表沒有差別。這也是 `04-source-code-learn-2-cursor-opcodes.md` 看到 `Cursor::MaterializedView` 分支的原因。

---

## 動手驗證

```bash
cd /Users/stanhsu/projects/turso
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE orders(id INTEGER PRIMARY KEY, region TEXT, amount INTEGER);
INSERT INTO orders VALUES (1,'east',100),(2,'west',200),(3,'east',50);

CREATE MATERIALIZED VIEW sales AS
  SELECT region, sum(amount) AS total FROM orders GROUP BY region;

SELECT * FROM sales;
```

然後測試增量更新：

```sql
INSERT INTO orders VALUES (4,'east',25);
SELECT * FROM sales;     -- east 應該從 150 變成 175
```

測試 UPDATE 拆成 delete+insert：

```sql
UPDATE orders SET amount = 500 WHERE id = 1;
SELECT * FROM sales;     -- east: 175 - 100 + 500 = 575
```

看視圖的儲存：

```sql
SELECT type, name, tbl_name, rootpage FROM sqlite_schema;
```

你會看到視圖與它的 DBSP 狀態表都有各自的 root page——**它們是真的 B-tree**。

追 source：

```bash
rg -n "pub struct Delta\b|pub struct Hash128|fn hash_values" core/incremental/dbsp.rs
rg -n "pub trait IncrementalOperator" core/incremental/operator.rs
rg -n "get_dependent_materialized_views" core/vdbe/execute.rs core/schema.rs
rg -n "fn apply_view_deltas" core/vdbe/mod.rs
wc -l core/incremental/*.rs
```

---

## 自我檢查

1. 為什麼一億列的表插入一列時，materialized view 不應該重算？
2. `Delta` 的 weight 為什麼能讓 UPDATE 統一成 delete + insert？聚合運算元需要知道這是 UPDATE 嗎？
3. `changes` 為什麼是 `Vec` 而不是 `HashSet`？順序錯了會發生什麼？
4. 為什麼視圖的 row key 需要 128-bit 雜湊而不是 64-bit？
5. `as_i64()` 取低 64 位元當 rowid，這個限制來自哪裡？
6. 雜湊時為什麼要加 `'\x00'` 分隔符和型別前綴？各防止什麼問題？
7. 為什麼必須用確定性雜湊（UUID v5）而不能用 Rust 預設的 HashMap 雜湊器？
8. `IncrementalOperator` 的核心簽章是什麼？為什麼運算元可以串成電路？
9. `eval` 和 `commit` 為什麼要分開？和交易的什麼性質有關？
10. 為什麼運算元的方法要回傳 `IOResult`？聚合為什麼需要讀取儲存？
11. `op_insert` 的 `MaybeCaptureRecord` 如何避免對「沒有依賴視圖的表」造成成本？
12. `Schema.table_to_materialized_views` 這個反向索引為什麼重要？
13. DBSP 編譯器和 VDBE 編譯器的輸入輸出各是什麼？
14. 為什麼帶 `LIMIT` 的視圖難以增量更新？
15. `Expr::Register(usize)` 為什麼會出現在 AST 裡？
16. 視圖的內容和運算元狀態存在哪裡？開啟資料庫時怎麼恢復？

---

下一篇 `12-source-code-learn-postgres-frontend.md`：PostgreSQL frontend 如何共用同一個 engine。
