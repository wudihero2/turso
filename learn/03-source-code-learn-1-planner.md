# 03. 源碼精讀：Planner、Optimizer、Emitter

本篇對應 `03-compiler-planner.md`，把「AST → query plan → 最佳化 → bytecode」這條編譯主線攤開來讀。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，設計成不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定，找不到時用 `rg -n "symbol_name" <file>`。

> **閱讀時間**：約 90–120 分鐘（約 24k 字，其中 49% 是原始碼）。建議分 **2 個 session**，文中有標示休息點。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/translate/select.rs        translate_select ── 三階段的總指揮
  ├─ prepare_select_plan        AST → Plan       （planner）
  ├─ core/translate/optimizer/mod.rs  optimize_plan ── Plan → 更好的 Plan
  └─ core/translate/emitter/select.rs emit_program_for_select ── Plan → Insn
        └─> core/translate/plan.rs   SelectPlan / Operation / Search / WhereTerm
```

**先建立本篇最重要的區分**：編譯器有**三種**中間表示，不要混為一談。

| 表示 | 定義位置 | 回答什麼問題 |
|---|---|---|
| `ast::Stmt` | `sqlite/parser/src/ast.rs` | 使用者寫了什麼 |
| `Plan` / `SelectPlan` | `core/translate/plan.rs` | 要用什麼策略取資料 |
| `Insn` | `core/vdbe/insn.rs` | VM 要執行哪些指令 |

`02-source-code-learn-parser-and-ast.md` 講完了第一種，`04-source-code-learn-1-insn-dispatch.md` 講第三種，本篇講中間那層以及兩次轉換。

---

## translate_select：三階段一目瞭然

**`core/translate/select.rs:37-58`** — 完整貼出：

```rust
pub fn translate_select(
    select: ast::Select,
    resolver: &Resolver,
    program: &mut ProgramBuilder,
    query_destination: QueryDestination,
    connection: &Arc<crate::Connection>,
) -> Result<usize> {
    let plan = prepare_select_plan(
        select,
        resolver,
        program,
        &[],
        query_destination,
        connection,
    )?;
    if program.trigger.is_some() {
        if let Some(virtual_table) = plan_first_virtual_table_name(&plan) {
            crate::bail_parse_error!("unsafe use of virtual table \"{}\"", virtual_table);
        }
    }
    emit_select_plan(plan, resolver, program, connection)
}
```

整個 SELECT 編譯器的骨架只有兩步：`prepare_select_plan` 產生計畫，`emit_select_plan` 產生程式碼。

中間插了一個安全檢查值得注意：**trigger 裡不允許使用虛擬表**。為什麼？虛擬表的實作來自 extension，可能執行任意程式碼。如果允許在 trigger 裡用，使用者的一次普通 INSERT 就可能觸發第三方程式碼執行——這是權限提升的路徑。SQLite 也有同樣限制。

`QueryDestination` 這個參數說明 SELECT 的結果不一定是「回傳給使用者」。它也可能寫進 sorter、寫進 co-routine、或是 `INSERT INTO ... SELECT` 的資料來源。同一套 SELECT 編譯器服務多種去向。

### emit_select_plan：最佳化與規模預估

**`core/translate/select.rs:60-77`** — 完整貼出前半：

```rust
/// Optimize and emit bytecode for an already-prepared select plan.
#[turso_macros::trace_stack]
pub fn emit_select_plan(
    mut plan: Plan,
    resolver: &Resolver,
    program: &mut ProgramBuilder,
    connection: &Arc<crate::Connection>,
) -> Result<usize> {
    optimize_plan(program, &mut plan, resolver)?;
    let num_result_cols;
    let opts = match &plan {
        Plan::Select(select) => {
            num_result_cols = select.result_columns.len();
            ProgramBuilderOpts {
                num_cursors: count_required_cursors_for_simple_select(select),
                approx_num_insns: estimate_num_instructions_for_simple_select(select),
                approx_num_labels: estimate_num_labels_for_simple_select(select),
            }
```

```rust
            // ── 省略（core/translate/select.rs:78-110 附近）：CompoundSelect 等其他
            //    Plan 變體的 opts 計算，然後 program.extend(opts) 與 emit_program 呼叫 ──
```

`optimize_plan` 在 emit **之前**執行——這是必然的順序，因為最佳化會改變計畫（換 index、改 join 順序、消除條件），必須先定案才能產生對應的指令。

`ProgramBuilderOpts` 那三個估算函式很有意思：在真正 emit 之前，先**估算**這個計畫大概需要幾個 cursor、幾條指令、幾個 label，然後預先配置容量。這純粹是效能考量——避免 emit 過程中 `Vec` 反覆重新配置。估錯了也不影響正確性，只影響配置次數。

---

## 第一階段：Planner

`prepare_select_plan` 把 AST 轉成 `SelectPlan`。它的產物結構本身就是最好的教材。

### SelectPlan：一個查詢的完整描述

**`core/translate/plan.rs:668-708`** — 完整貼出（省略註解較長的尾段欄位）：

```rust
pub struct SelectPlan {
    pub table_references: TableReferences,
    /// The order in which the tables are joined. Tables have usize Ids (their index in joined_tables)
    pub join_order: Vec<JoinOrderMember>,
    /// the columns inside SELECT ... FROM
    pub result_columns: Vec<ResultSetColumn>,
    /// where clause split into a vec at 'AND' boundaries. all join conditions also get shoved in here,
    /// and we keep track of which join they came from (mainly for OUTER JOIN processing)
    pub where_clause: Vec<WhereTerm>,
    /// group by clause
    pub group_by: Option<GroupBy>,
    /// order by clause
    pub order_by: Vec<(Box<ast::Expr>, SortOrder, Option<ast::NullsOrder>)>,
    /// all the aggregates collected from the result columns, order by, and (TODO) having clauses
    pub aggregates: Vec<Aggregate>,
    /// limit clause
    pub limit: Option<Box<Expr>>,
    /// offset clause
    pub offset: Option<Box<Expr>>,
    /// query contains a constant condition that is always false
    pub contains_constant_false_condition: bool,
    /// the destination of the resulting rows from this plan.
    pub query_destination: QueryDestination,
    /// whether the query is DISTINCT
    pub distinctness: Distinctness,
    /// values: https://sqlite.org/syntax/select-core.html
    pub values: Vec<Vec<Expr>>,
    /// The window definition and all window functions associated with it. There is at most one
    /// window per SELECT. If the original query contains more, they are pushed down into subqueries.
    pub window: Option<Window>,
    /// Subqueries that appear in any part of the query apart from the FROM clause
    pub non_from_clause_subqueries: Vec<NonFromClauseSubquery>,
    /// Estimated number of times this SELECT will be invoked by its parent scope.
    ///
    /// Top-level queries and standalone FROM-subqueries default to 1. Correlated
    /// non-FROM subqueries may be re-optimized after their parent join order is
    /// known so their inner FROM-subqueries can cost repeated probes correctly.
    pub input_cardinality_hint: Option<f64>,
    /// Estimated output rows from the optimizer's join order computation.
    /// Used to propagate cardinality estimates for CTE/subquery tables.
    pub estimated_output_rows: Option<f64>,
```

對照 AST，三個結構性差異最值得注意：

**一、`where_clause` 從一棵樹變成一個 `Vec<WhereTerm>`。**

註解說明了：以 `AND` 為邊界拆開，而且**所有 join 條件也塞進同一個 vec**。

為什麼要拆？因為 `WHERE a.x = 1 AND b.y = 2` 的兩個條件可以在**不同時機**求值——`a.x = 1` 只依賴 a，可以在掃 a 的迴圈裡就過濾掉；`b.y = 2` 要等 b 開始掃。保持成一棵 `AND` 樹的話，只能等所有表都開了才整棵求值，白白多掃很多列。

拆成扁平列表後，optimizer 可以逐項判斷「這個條件最早能在哪裡求值」，把過濾往前推（predicate pushdown）。

**二、`join_order` 是獨立欄位。**

使用者寫 `FROM a JOIN b JOIN c`，但實際執行未必照這個順序。optimizer 會依成本估算重排。AST 保留使用者寫的順序，`join_order` 記錄實際要用的順序。

**三、多了成本估算欄位。**

`input_cardinality_hint`、`estimated_output_rows` 這類欄位在 AST 完全不存在。它們是**優化決策的依據**：要選 index 還是全表掃描、join 用什麼順序，都取決於「大概有幾列」。

註解裡提到的細節很實際：關聯子查詢（correlated subquery）可能被外層執行很多次，所以它內部的成本要乘上「被呼叫幾次」。這個次數只有在外層 join 順序定了之後才知道——所以會有**二次最佳化**。

### WhereTerm：為什麼一個條件需要這麼多 metadata

**`core/translate/plan.rs:198-216`** — 完整貼出（註解就是課程內容）：

```rust
pub struct WhereTerm {
    /// The original condition expression.
    pub expr: ast::Expr,
    /// For normal JOIN conditions (ON or WHERE clauses), we break them up into individual [WhereTerm] conditions
    /// and let the optimizer determine when each should be evaluated based on the tables they reference.
    /// See e.g. [EvalAt].
    /// For example, in "SELECT * FROM x JOIN y WHERE x.a = 2", we want to evaluate x.a = 2 right after opening x
    /// since it only depends on x.
    ///
    /// However, OUTER JOIN conditions require special handling. Consider:
    ///   SELECT * FROM t LEFT JOIN s ON t.a = 2
    ///
    /// Even though t.a = 2 only references t, we cannot evaluate it during t's loop and skip rows where t.a != 2.
    /// Instead, we must:
    /// 1. Process ALL rows from t
    /// 2. For each t row where t.a != 2, emit NULL values for s's columns
    /// 3. For each t row where t.a = 2, emit the actual s values
    ///
    /// This means the condition must be evaluated during s's loop, regardless of which tables it references.
```

這段註解值得完整讀兩遍，它示範了「看似顯然的最佳化為什麼會出錯」。

一般情況：`SELECT * FROM x JOIN y WHERE x.a = 2` —— 條件只提到 `x`，所以在掃 x 的迴圈裡就過濾掉，越早過濾越好。

但 OUTER JOIN 破壞了這個推論：`SELECT * FROM t LEFT JOIN s ON t.a = 2`。條件一樣只提到 `t`，但**不能**在 t 的迴圈裡過濾掉不符的列。因為 LEFT JOIN 的語義是「t 的每一列都要出現在結果裡」，不符條件的列要輸出 `s` 欄位為 NULL 的版本，而不是消失。

所以這個條件必須延後到 s 的迴圈裡求值。

**結論**：「這個條件依賴哪些表」不足以決定求值時機，還要看它來自哪種 join。這就是為什麼 `WhereTerm` 除了表達式本身，還要記錄來源 join 的資訊。

**這是資料庫最佳化的通則**：任何「把過濾往前推」的最佳化，都必須先確認語義允許。OUTER JOIN、聚合、視窗函式、`LIMIT` 都會造成例外。

### Operation：取資料的策略

**`core/translate/plan.rs:2182-2201`** — 完整貼出：

```rust
pub enum Operation {
    // Scan operation
    // This operation is used to scan a table.
    Scan(Scan),
    // Search operation
    // This operation is used to search for a row in a table using an index
    // (i.e. a primary key or a secondary index)
    Search(Search),
    // Access through custom index method query
    IndexMethodQuery(IndexMethodQuery),
    // Hash join operation
    // This operation is used on the probe side of a hash join.
    // The build table is accessed normally (via Scan), and the probe table
    // uses this operation to indicate it should probe the hash table.
    HashJoin(HashJoinOp),
    // Multi-index scan operation for OR-by-union optimization.
    // This operation scans multiple indexes (one per OR branch) and combines
    // results using RowSet deduplication.
    MultiIndexScan(MultiIndexScanOp),
}
```

這個 enum 就是「optimizer 能做的選擇」的完整清單：

- **`Scan`** —— 從頭掃到尾。
- **`Search`** —— 用 index 直接定位。
- **`HashJoin`** —— 建 hash table，另一邊來探測。
- **`MultiIndexScan`** —— `WHERE a = 1 OR b = 2` 時，兩個條件各用各的 index，結果去重合併。
- **`IndexMethodQuery`** —— 自訂索引方法（extension 提供）。

**`core/translate/plan.rs:2203-2212`** — 預設值：

```rust
impl Operation {
    pub fn default_scan_for(table: &Table) -> Self {
        match table {
            Table::BTree(_) => Operation::Scan(Scan::BTreeTable {
                iter_dir: IterationDirection::Forwards,
                index: None,
            }),
            Table::Virtual(_) => Operation::Scan(Scan::VirtualTable {
                idx_num: -1,
                idx_str: None,
```

**planner 的預設一律是全表掃描**（`index: None`）。用 index 是 optimizer 之後才做的**升級**。

這個設計很重要：**預設必須是永遠正確的那個選項**。全表掃描一定能得到正確答案，只是慢。optimizer 若判斷可以用 index 就換掉；判斷不了就維持預設。這樣即使 optimizer 有 bug 或遇到不認識的情況，結果仍然正確——**最壞情況是慢，不是錯**。

### Search：三種 index 存取

**`core/translate/plan.rs:2934-2948`** — 完整貼出：

```rust
pub enum Search {
    /// A rowid equality point lookup. This is a special case that uses the SeekRowid bytecode instruction and does not loop.
    RowidEq { cmp_expr: ast::Expr },
    /// A search on a table btree (via `rowid`) or a secondary index search. Uses bytecode instructions like SeekGE, SeekGT etc.
    Seek {
        index: Option<Arc<Index>>,
        seek_def: SeekDef,
    },
    /// An IN-driven index seek. Iterates an ephemeral B-tree of IN values and
    /// for each value seeks into the real index (or table, if seek by rowid).
    InSeek {
        index: Option<Arc<Index>>,
        source: InSeekSource,
    },
}
```

三種各對應不同的 bytecode 形狀：

**`RowidEq`** —— `WHERE id = 5`。註解點出關鍵：**「does not loop」**。rowid 是唯一的，最多一列，所以產生的 bytecode 沒有迴圈，只有一條 `SeekRowid`。這就是 `01-source-code-learn-3-translate.md` 裡 EXPLAIN 輸出「`Rewind`/`Next` 迴圈消失」的原因。

**`Seek`** —— 範圍或非唯一的查找，用 `SeekGE`/`SeekGT` 等定位起點，然後迴圈往前直到超出範圍。`index: Option<...>` 為 `None` 時代表用 table 自己的 rowid B-tree。

**`InSeek`** —— `WHERE x IN (1,2,3)`。作法是把 IN 的值放進一棵臨時 B-tree，逐一取出去 seek 真正的 index。等於「對每個值做一次 Seek」。

`InSeekSource` 的兩個變體（`LiteralList` 與已物化的子查詢）說明 `IN` 的右邊可以是常值列表或子查詢，兩者的準備方式不同但 seek 邏輯共用。

---

---

> ### ⏸ Session 1 到此
>
> 目前為止涵蓋了：translate_select 的三階段骨架，以及 planner 產出的 SelectPlan/Operation/Search。
>
> 休息之前，先確認你能說出這幾件事；說不出來就往回翻，不要硬推進——後半段會用到它們。
>
> **Session 2** 從下一節開始：optimizer 的步驟順序與 emitter 的迴圈骨架。

---

## 第二階段：Optimizer

### 分派

**`core/translate/optimizer/mod.rs:539-560`** — 完整貼出：

```rust
pub fn optimize_plan(
    program: &mut ProgramBuilder,
    plan: &mut Plan,
    resolver: &Resolver,
) -> Result<()> {
    match plan {
        Plan::Select(plan) => optimize_select_plan(plan, resolver)?,
        Plan::Delete(plan) => optimize_delete_plan(plan, resolver)?,
        Plan::Update(plan) => optimize_update_plan(program, plan, resolver)?,
        Plan::CompoundSelect {
            left, right_most, ..
        } => {
            optimize_select_plan(right_most, resolver)?;
            for (plan, _) in left {
                optimize_select_plan(plan, resolver)?;
            }
        }
    }
    // When debug tracing is enabled, print the optimized plan as a SQL string for debugging
    tracing::debug!(plan_sql = plan.to_string());
    Ok(())
}
```

`plan: &mut Plan` —— optimizer **原地修改**計畫，不產生新的。

最後那行 `tracing::debug!(plan_sql = plan.to_string())` 很實用：開啟 debug tracing 時，會把最佳化後的計畫**印回 SQL 文字**。除錯時可以直接看到「optimizer 把你的查詢變成了什麼」。`Plan` 實作了 `Display`（在 `core/translate/display.rs`）就是為了這個。

`DELETE` 和 `UPDATE` 也需要最佳化，因為 `DELETE FROM t WHERE id = 5` 一樣要決定「怎麼找到那一列」。

### optimize_select_plan：最佳化的順序就是知識

**`core/translate/optimizer/mod.rs:737-782`** — 完整貼出：

```rust
pub fn optimize_select_plan(plan: &mut SelectPlan, resolver: &Resolver) -> Result<()> {
    let schema = resolver.schema();
    // Transform MATCH expressions to fts_match() for FTS optimizer recognition
    #[cfg(all(feature = "fts", not(target_family = "wasm")))]
    transform_match_to_fts_match(&mut plan.where_clause, schema, &plan.table_references)?;

    unnest::unnest_exists_subqueries(plan)?;
    // EXISTS only needs 1 row. Add LIMIT 1 to surviving (non-unnested) EXISTS
    // subqueries. This is done here rather than in the subquery planner so that
    // unnesting sees the plan without an artificial LIMIT.
    for sub in &mut plan.non_from_clause_subqueries {
        if matches!(sub.query_type, ast::SubqueryType::Exists { .. }) {
            if let SubqueryState::Unevaluated {
                plan: Some(inner), ..
            } = &mut sub.state
            {
                if let Plan::Select(ref mut inner) = inner.as_mut() {
                    if inner.limit.is_none() {
                        inner.limit = Some(Box::new(Expr::Literal(ast::Literal::Numeric(
                            "1".to_string(),
                        ))));
                    }
                }
            }
        }
    }
    optimize_subqueries(plan, resolver)?;
    let available_indexes =
        AvailableIndexes::for_table_references(resolver, &plan.table_references);
    lift_common_subexpressions_from_binary_or_terms(&mut plan.where_clause)?;
    if let ConstantConditionEliminationResult::ImpossibleCondition =
        eliminate_constant_conditions(&mut plan.where_clause)?
    {
        plan.contains_constant_false_condition = true;
        return Ok(());
    }

    plan.simple_aggregate = detect_simple_aggregate(plan);
    let best_join_order = optimize_table_access(
        schema,
        resolver.dialect.as_ref(),
        &mut plan.result_columns,
        &mut plan.table_references,
        &available_indexes,
        &mut plan.where_clause,
        &mut plan.order_by,
```

```rust
        // ── 省略（core/translate/optimizer/mod.rs:783-850 附近）：optimize_table_access
        //    的其餘參數、join order 寫回 plan、以及後續的 ORDER BY 消除等步驟 ──
```

**最佳化的順序不是隨意的**，每一步都為後一步鋪路。逐步看：

**1. `transform_match_to_fts_match`** —— 把 `MATCH` 語法改寫成函式呼叫，讓後面的 optimizer 能用統一方式辨識全文檢索。**正規化先行**：先把多種寫法收斂成一種，後面的規則就只需處理一種。

**2. `unnest_exists_subqueries`** —— 把 `EXISTS (SELECT ...)` 子查詢攤平成 join。這是效益最大的改寫之一：子查詢對外層每一列執行一次，變成 join 後只要掃一次。

**3. EXISTS 加 `LIMIT 1`** —— 這裡的註解說明了**為什麼順序重要**：

> This is done here rather than in the subquery planner so that unnesting sees the plan without an artificial LIMIT.

`EXISTS` 只需要知道「有沒有列」，所以加 `LIMIT 1` 是安全的最佳化。但如果在 planner 階段就加上，**unnest 步驟會看到一個帶 LIMIT 的子查詢而不敢攤平**（帶 LIMIT 的子查詢攤平會改變語義）。

所以順序必須是：先 unnest，沒被攤平的才加 LIMIT 1。**一個過早施加的最佳化會阻擋另一個更有價值的最佳化。**

**4. `optimize_subqueries`** —— 遞迴最佳化剩下的子查詢。

**5. `AvailableIndexes::for_table_references`** —— 蒐集可用的 index。注意這在條件消除**之前**做，因為後面選 index 需要這份清單。

**6. `lift_common_subexpressions_from_binary_or_terms`** —— 從 OR 條件中提出共同因子。例如 `(a = 1 AND b = 2) OR (a = 1 AND c = 3)` 可以提出 `a = 1`，而 `a = 1` 可能剛好能用 index。

**7. `eliminate_constant_conditions`** —— 消除常數條件。這一步有個特別的早退：

```rust
    if let ConstantConditionEliminationResult::ImpossibleCondition =
        eliminate_constant_conditions(&mut plan.where_clause)?
    {
        plan.contains_constant_false_condition = true;
        return Ok(());
    }
```

如果發現 `WHERE 1 = 0` 這種**永遠為假**的條件，就標記起來**直接 return**，不做後續任何最佳化。因為結果必定是空集合，再怎麼選 index 都沒意義。emitter 之後會為這個標記產生「直接跳到結束」的 bytecode。

**8. `detect_simple_aggregate`** —— 偵測 `SELECT count(*) FROM t` 這種無 GROUP BY 的簡單聚合，可以用更精簡的 bytecode。

**9. `optimize_table_access`** —— **這是 optimizer 的核心**：同時決定 join 順序與每張表的存取方式。

為什麼這兩件事要一起決定？因為它們互相影響。join 順序決定了哪張表先掃、哪張表被重複探測；而某張表能不能用 index，又取決於它在 join 裡的位置（外層提供的值可以當作 index 的查找鍵）。分開決定會得到次佳解。

參數列表裡有 `&mut plan.order_by`——因為選對 index 可能讓資料**天然有序**，那 ORDER BY 就完全不需要排序了。這是 index 最大的價值之一，也是為什麼 ORDER BY 要參與 index 選擇。

---

## 第三階段：Emitter

### 分派

**`core/translate/emitter/mod.rs:1060-1075`** — 完整貼出：

```rust
pub fn emit_program(
    connection: &Arc<Connection>,
    resolver: &Resolver,
    program: &mut ProgramBuilder,
    plan: Plan,
    after: impl FnOnce(&mut ProgramBuilder),
) -> Result<()> {
    match plan {
        Plan::Select(plan) => emit_program_for_select(program, resolver, *plan),
        Plan::Delete(plan) => emit_program_for_delete(connection, resolver, program, *plan),
        Plan::Update(plan) => emit_program_for_update(connection, resolver, program, *plan, after),
        Plan::CompoundSelect { .. } => {
            emit_program_for_compound_select(program, resolver, plan).map(|_| ())
        }
    }
}
```

注意 `plan: Plan` 是**傳值**（optimizer 那邊是 `&mut`）。emit 階段會消耗掉計畫——計畫的欄位會被移進 `ProgramBuilder`（例如 `result_columns`），之後不再需要。

### emit_program_for_select

**`core/translate/emitter/select.rs:36-75`** — 完整貼出：

```rust
pub fn emit_program_for_select(
    program: &mut ProgramBuilder,
    resolver: &Resolver,
    plan: SelectPlan,
) -> Result<()> {
    emit_program_for_select_with_resolver(program, resolver.fork(), plan)
}

pub fn emit_program_for_select_with_resolver(
    program: &mut ProgramBuilder,
    resolver: Resolver,
    mut plan: SelectPlan,
) -> Result<()> {
    let materialized_build_inputs = emit_materialized_build_inputs(program, &resolver, &mut plan)?;
    emit_program_for_select_with_inputs(program, &resolver, plan, materialized_build_inputs)
}

fn emit_program_for_select_with_inputs(
    program: &mut ProgramBuilder,
    resolver: &Resolver,
    mut plan: SelectPlan,
    materialized_build_inputs: HashMap<usize, MaterializedBuildInput>,
) -> Result<()> {
    let result_cols_start = program.with_scoped_result_cols_start(|program| {
        // Boxed to keep ~960 B off the prepare-path stack; see TranslateCtx size.
        let mut t_ctx = Box::new(TranslateCtx::new(
            program,
            resolver.fork_with_expr_cache(),
            plan.table_references.joined_tables().len(),
            false,
        ));
        t_ctx.materialized_build_inputs = materialized_build_inputs;
        emit_query(program, &mut plan, &mut t_ctx)
    })?;

    program.result_columns = plan.result_columns;
    program.table_references.extend(plan.table_references);
    program.reg_result_cols_start = Some(result_cols_start);
    Ok(())
}
```

三個技術點：

**`resolver.fork()`** —— emit 階段用一個分叉的 resolver。為什麼？因為 emit 會累積表達式快取（`fork_with_expr_cache`），而這些快取只在當前查詢範圍有效。子查詢需要自己的快取範圍，不能污染外層。

**`Box::new(TranslateCtx::new(...))`** —— 又是 `Box`，註解說明 `TranslateCtx` 約 960 bytes。和 `01-source-code-learn-3-translate.md` 看到的 `ProgramBuilder` 一樣的理由：**編譯是遞迴的**（子查詢、trigger），每層多接近 1 KB 就容易爆 stack。

**`with_scoped_result_cols_start`** —— result column 的 register 起點是有範圍的。子查詢的結果欄位有自己的 register 區段，離開範圍要還原。

### emit_query：從這裡開始產生指令

**`core/translate/emitter/select.rs:77-85`** — 節錄開頭：

```rust
#[instrument(skip_all, level = Level::DEBUG)]
pub fn emit_query<'a>(
    program: &mut ProgramBuilder,
    plan: &'a mut SelectPlan,
    t_ctx: &mut TranslateCtx<'a>,
) -> Result<usize> {
    let after_main_loop_label = program.allocate_label();
    t_ctx.label_main_loop_end = Some(after_main_loop_label);
```

```rust
    // ── 省略（core/translate/emitter/select.rs:86-300 附近）：
    //    子查詢物化 → init_loop（開 cursor）→ open_loop（發 Rewind/Seek）
    //    → inner_loop（求值 WHERE、產生結果列）→ close_loop（發 Next）
    //    → GROUP BY / ORDER BY / LIMIT 的後續處理 ──
```

第一行就 `allocate_label()`。這是 `01-source-code-learn-3-translate.md` 講過的 label／回填機制：現在還不知道「主迴圈結束後」是第幾條指令，先配置一個 label，等結構確定再回填。

emit 的整體結構是一個「迴圈骨架」：

```text
init_loop    開 cursor（OpenRead / OpenWrite）
open_loop    定位起點（Rewind 或 SeekGE/SeekRowid）
inner_loop   求值 WHERE、算 result columns、ResultRow
close_loop   前進（Next）並跳回 inner_loop
```

對照 `01-source-code-learn-4-step-vm.md` 那份 EXPLAIN 輸出，addr 1 是 init/open（`OpenRead`）、addr 2 是 open（`Rewind`）、addr 3-4 是 inner（`Column`、`ResultRow`）、addr 5 是 close（`Next`）。**bytecode 的形狀直接來自 emitter 的函式結構。**

而 `Operation` 的選擇決定了 open_loop 發什麼指令：

| Plan 裡的 Operation | open_loop 產生的指令 |
|---|---|
| `Scan` | `Rewind` + `Next` 迴圈 |
| `Search(RowidEq)` | `SeekRowid`，無迴圈 |
| `Search(Seek)` | `SeekGE`/`SeekGT` + `IdxGT` 邊界檢查 + `Next` |
| `Search(InSeek)` | 臨時 B-tree 迴圈，內層再 seek |

**這就是「為什麼同一句 SQL 在不同 index 下 EXPLAIN 不同」的完整答案**：planner 給預設（Scan），optimizer 依 index 與成本改成 Search，emitter 依 Operation 種類發出不同指令。

---

## 三種表示的完整對照

用 `SELECT name FROM users WHERE id = 1` 走一遍：

```text
【AST】 sqlite/parser/src/ast.rs
Stmt::Select(Select {
  body: OneSelect {
    columns: [Expr::Id("name")],
    from: Some(users),
    where_clause: Some(Expr::Binary(Id("id"), Equals, Literal(1))),
  }
})
        ↓ prepare_select_plan（core/translate/select.rs:44）
【Plan】 core/translate/plan.rs
SelectPlan {
  table_references: [users],
  result_columns: [users.name],
  where_clause: [WhereTerm { expr: id = 1, ... }],
  joined_tables[0].op: Operation::Scan(...)      ← 預設全表掃描
}
        ↓ optimize_plan（core/translate/optimizer/mod.rs:539）
SelectPlan {
  ...
  joined_tables[0].op: Operation::Search(Search::RowidEq { ... })   ← 升級成 rowid 定位
  where_clause: []                                ← 條件已被 Search 吸收
}
        ↓ emit_program_for_select（core/translate/emitter/select.rs:36）
【Insn】 core/vdbe/insn.rs
  Init → Transaction → OpenRead → Integer(1) → SeekRowid → Column → ResultRow → Halt
```

注意 optimize 之後 `where_clause` 變空了：條件 `id = 1` 被**吸收進 Search 裡**，成為 seek 的鍵。所以最終 bytecode 沒有比較指令——不需要，因為 seek 本身就保證了條件成立。

**這是 index 最佳化的本質**：把「掃描後過濾」變成「直接定位」。

---

## 各語句的編譯器位置

| 語句 | 檔案 |
|---|---|
| SELECT | `core/translate/select.rs` |
| INSERT | `core/translate/insert.rs` |
| UPDATE | `core/translate/update.rs` |
| DELETE | `core/translate/delete.rs` |
| CREATE/DROP TABLE、INDEX、VIEW | `core/translate/schema.rs` |
| BEGIN/COMMIT/ROLLBACK | `core/translate/transaction.rs` |
| PRAGMA | `core/translate/pragma.rs` |
| ALTER TABLE | `core/translate/alter.rs` |
| trigger | `core/translate/trigger.rs` |
| 聚合 / GROUP BY | `core/translate/aggregation.rs`、`group_by.rs` |
| 視窗函式 | `core/translate/window.rs` |
| 子查詢 | `core/translate/subquery.rs` |
| 主迴圈骨架 | `core/translate/main_loop/` |
| optimizer | `core/translate/optimizer/` |

遇到某類語句編譯有問題，直接去對應檔案。

---

## 動手驗證

看 optimizer 如何改變存取方式：

```bash
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, age INT);
EXPLAIN SELECT name FROM users WHERE id = 1;
EXPLAIN SELECT name FROM users WHERE age = 30;
CREATE INDEX users_age ON users(age);
EXPLAIN SELECT name FROM users WHERE age = 30;
```

三次輸出：第一次 `SeekRowid`（rowid 定位，無迴圈）；第二次 `Rewind`/`Next`（沒有 index，只能全掃）；建了 index 之後第三次應該出現 index cursor 的 seek。

**同一句 SQL，只因為多了一個 index，bytecode 就完全不同**——這就是 optimizer 的工作。

看常數條件消除：

```sql
EXPLAIN SELECT * FROM users WHERE 1 = 0;
```

應該產生極短的程式（直接跳到結束），因為 `eliminate_constant_conditions` 判定不可能成立。

看最佳化後的計畫（需要 debug tracing）：

```bash
RUST_LOG=turso_core::translate::optimizer=debug cargo run -q --bin tursodb -- -q
```

追 source：

```bash
rg -n "pub fn translate_select|pub fn emit_select_plan" core/translate/select.rs
rg -n "pub fn optimize_plan|pub fn optimize_select_plan" core/translate/optimizer/mod.rs
rg -n "pub fn emit_program\b" core/translate/emitter/mod.rs
rg -n "pub struct SelectPlan|pub enum Operation|pub enum Search|pub struct WhereTerm" core/translate/plan.rs
```

---

## 自我檢查

1. AST、Plan、Insn 三種表示各回答什麼問題？為什麼需要中間那層？
2. `where_clause` 為什麼從一棵 AND 樹拆成 `Vec<WhereTerm>`？拆了之後 optimizer 能做什麼原本做不到的事？
3. `SELECT * FROM t LEFT JOIN s ON t.a = 2` 裡，`t.a = 2` 只提到 `t`，為什麼不能在 t 的迴圈裡就過濾掉？
4. `Operation::default_scan_for` 為什麼預設是全表掃描而不是「最好的方式」？這個設計對 optimizer 的 bug 有什麼保護作用？
5. `Search::RowidEq` 的註解說「does not loop」。為什麼 rowid 相等查找不需要迴圈？
6. EXISTS 加 `LIMIT 1` 為什麼要放在 unnest **之後**？先加會怎樣？
7. `eliminate_constant_conditions` 發現不可能條件時為什麼直接 return，不做後續最佳化？
8. 為什麼 join 順序和 index 選擇要在 `optimize_table_access` 裡**一起**決定，而不是先後分開決定？
9. `optimize_table_access` 的參數為什麼包含 `&mut plan.order_by`？index 和排序有什麼關係？
10. 最佳化後 `where_clause` 變成空的，但查詢仍然正確。條件跑到哪裡去了？

---

下一篇 `04-source-code-learn-1-insn-dispatch.md`：VDBE 指令集的結構、register 機制、cursor 操作、以及 EXPLAIN 如何運作。
