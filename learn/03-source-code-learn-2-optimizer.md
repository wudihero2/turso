# 03-2. 源碼精讀：Optimizer——成本模型與 Join Order

`03-source-code-learn-1-planner.md` 講了 AST 如何變成 `SelectPlan`，並把 `optimize_select_plan` 的**步驟順序**走了一遍。本篇深入那一步裡真正困難的部分：**optimizer 怎麼決定用哪個 index、怎麼決定 join 順序**。

這是整個編譯器最數學、也最容易出效能問題的地方。`core/translate/optimizer/` 有 16,455 行，本篇聚焦其中的決策核心。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 90–120 分鐘（約 24k 字，其中 47% 是原始碼）。建議分 **2 個 session**，文中有標示休息點。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/translate/optimizer/
  ├─ constraints.rs    Constraint ── WHERE 條件如何變成「可用的約束」
  ├─ cost_params.rs    CostModelParams ── 所有可調參數
  ├─ cost.rs           estimate_scan_cost / estimate_index_cost ── 成本公式
  ├─ access_method.rs  AccessMethod ── 一張表的一種存取方式
  └─ join.rs           compute_best_join_order ── DP 列舉 + greedy 退化
```

## 先建立問題意識

optimizer 要回答的問題是：

```sql
SELECT * FROM a JOIN b ON a.x = b.x JOIN c ON b.y = c.y WHERE a.z = 10
```

- 三張表，先掃哪張？（3! = 6 種順序，還要考慮哪些是可行的）
- 每張表用全表掃描還是某個 index？
- `a.z = 10` 這個條件，是拿來當 index 的查找鍵，還是掃到之後再過濾？
- 如果有 `ORDER BY`，選某個 index 能不能順便省掉排序？

這些決定**互相影響**，不能分開做。而且搜尋空間會爆炸——所以需要成本模型與剪枝。

---

## 第一步：WHERE 條件變成 Constraint

`03-source-code-learn-1-planner.md` 看過 `WhereTerm`（planner 產生的扁平條件列表）。optimizer 的第一件事是把它們轉成**可用於 index 查找的約束**。

**`core/translate/optimizer/constraints.rs:40-66`** — 完整貼出（註解本身就是說明）：

```rust
pub struct Constraint {
    /// The position of the original `WHERE` clause term this constraint derives from,
    /// and which side of the [ast::Expr::Binary] comparison contains the expression
    /// that constrains the column.
    /// E.g. in SELECT * FROM t WHERE t.x = 10, the constraint is (0, BinaryExprSide::Rhs)
    /// because the RHS '10' is the constraining expression.
    ///
    /// This is tracked so we can:
    ///
    /// 1. Extract the constraining expression for use in an index seek key, and
    /// 2. Remove the relevant binary expression from the WHERE clause, if used as an index seek key.
    pub where_clause_pos: (usize, BinaryExprSide),
    /// The comparison operator (e.g., `=`, `>`, `<`) used in the constraint.
    pub operator: ConstraintOperator,
    /// The zero-based index of the constrained column within the table's schema.
    /// None for expression-index constraints.
    pub table_col_pos: Option<usize>,
    /// The expression constrained by this constraint, if it is not a simple column reference.
    pub expr: Option<ast::Expr>,
    /// For multi-index scan branches: the constraining expression and its affinity.
    /// When set, `get_constraining_expr` uses this instead of looking up in where_clause.
    /// This is needed because multi-index branches come from sub-expressions of an OR/AND,
    /// not directly from a top-level WHERE term.
    pub constraining_expr: Option<(ast::Operator, ast::Expr, Affinity)>,
    /// A bitmask representing the set of tables that appear on the *constraining* side
    /// of the comparison expression. For example, in SELECT * FROM t1,t2,t3 WHERE t1.x = t2.x + t3.x,
    /// the lhs_mask contains t2 and t3. Thus, this constraint can only be used if t2 and t3
```

```rust
    // ── 省略（core/translate/optimizer/constraints.rs:67-94）：lhs_mask 的
    //    其餘註解、selectivity 估算欄位等 ──
```

三個欄位是理解 optimizer 的關鍵。

### where_clause_pos：為了之後能移除條件

註解列出兩個用途，第二個特別重要：

> 2. Remove the relevant binary expression from the WHERE clause, if used as an index seek key.

`03-source-code-learn-1-planner.md` 的結尾提過一個現象：最佳化之後 `where_clause` 變空了，但查詢仍然正確。原因就在這裡——**條件被拿去當 index 的查找鍵，就不必再當成過濾條件求值了**。

`WHERE id = 1` 用 `SeekRowid` 定位後，那一列必然滿足 `id = 1`，再比較一次是浪費。所以要記住「這個約束來自第幾個 WHERE term」，用掉之後把它移除。

**記錯位置就會產生錯誤結果**：移除了沒被 index 涵蓋的條件，過濾就漏了。這是 `09-source-code-learn-reading-projects.md` 提到的「用了 index 就錯」最常見的成因。

### lhs_mask：約束什麼時候可用

註解的例子很清楚：

> in SELECT * FROM t1,t2,t3 WHERE t1.x = t2.x + t3.x, the lhs_mask contains t2 and t3. Thus, this constraint can only be used if t2 and t3 [已經在 join 順序中先出現]

**這是 join order 與 index 選擇互相糾纏的根源。**

`t1.x = t2.x + t3.x` 這個條件能不能拿來當 t1 的 index 查找鍵？**取決於 join 順序**：

- 如果順序是 `t2, t3, t1` —— 可以。掃到 t1 時，`t2.x + t3.x` 的值已經知道了，可以拿它去 seek。
- 如果順序是 `t1, t2, t3` —— 不行。掃 t1 時還不知道 t2、t3 的值。

所以「t1 能用哪個 index」不是固定的，而是**每種 join 順序下都不同**。這就是為什麼兩者必須一起決定（`03-source-code-learn-1-planner.md` 提過但沒展開的那句話）。

`lhs_mask` 是一個 bitmask，join 列舉時只要檢查「已排入的表集合是否涵蓋 lhs_mask」就知道這個約束可不可用。**bitmask 讓這個檢查是一次位元運算**，在 O(2^n) 的列舉裡這很重要。

### ConstraintOperator：不只是比較運算子

**`core/translate/optimizer/constraints.rs:95-99`** — 完整貼出：

```rust
pub enum ConstraintOperator {
    AstNativeOperator(ast::Operator),
    Like { not: bool },
    In { not: bool, estimated_values: f64 },
}
```

三種來源：

- **一般運算子**（`=`、`>`、`<`…）直接包裝 AST 的運算子。
- **`LIKE`** —— `x LIKE 'abc%'` 可以轉成範圍查找（`x >= 'abc' AND x < 'abd'`），所以它是可用的約束。但 `x LIKE '%abc'` 不行（前綴未知）。
- **`IN`** —— 帶 `estimated_values`（IN 列表有幾個值）。這個數字直接進成本估算：`x IN (1,2,3)` 要做 3 次 seek，成本是單次的三倍。這對應 `03-source-code-learn-1-planner.md` 看過的 `Search::InSeek`。

---

## 第二步：成本模型

### 所有參數集中在一處

**`core/translate/optimizer/cost_params.rs:1-14`** — 完整貼出：

```rust
/// Cost model parameters for query optimization.
///
/// These parameters control the heuristics used by the query optimizer for
/// cost estimation. They can be tuned to improve plan selection for specific
/// workloads (e.g., TPC-H).
///
/// # JSON Loading (requires `optimizer_params` feature)
///
/// When the `optimizer_params` feature is enabled, parameters can be loaded
/// from a JSON file via the `TURSO_OPTIMIZER_PARAMS` environment variable.
/// The JSON file does not need to specify all fields, and unspecified fields will use the default values.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(default))]
pub struct CostModelParams {
```

**所有魔術數字集中在一個 struct**，而且可以從 JSON 覆寫。這是很值得學的工程實踐：

optimizer 的參數（「沒有統計資料時假設一張表有幾列」、「等值條件的選擇率是多少」）本質上是**猜測**。把它們散在程式碼各處，調校時要改十幾個地方且無法比較；集中起來就能針對 TPC-H 之類的基準測試調參，甚至讓使用者針對自己的工作負載調整。

**`core/translate/optimizer/cost_params.rs:16-45`** — 完整貼出參數本身：

```rust
    // === Cardinality Fallbacks (when no ANALYZE stats) ===
    /// Assumed rows per table when statistics unavailable.
    pub rows_per_table_fallback: f64,

    /// Estimated rows per table B-tree page.
    pub rows_per_table_page: f64,

    // === Selectivity Fallbacks ===
    /// Selectivity for equality predicate on unindexed column (e.g., `x = 5`).
    pub sel_eq_unindexed: f64,

    /// Selectivity for equality predicate on indexed column.
    /// Should be <= sel_eq_unindexed since indexes imply higher selectivity.
    pub sel_eq_indexed: f64,

    /// Selectivity for range predicates (>, >=, <, <=).
    pub sel_range: f64,

    /// Selectivity for IS NULL predicate.
    pub sel_is_null: f64,

    /// Selectivity for IS NOT NULL predicate.
    pub sel_is_not_null: f64,

    /// Selectivity for LIKE predicate.
    pub sel_like: f64,

    /// Selectivity for NOT LIKE predicate.
    pub sel_not_like: f64,
```

**選擇率（selectivity）** 是「這個條件會留下多少比例的列」。`x = 5` 大概留下 1%，`x > 5` 大概留下 30%——這些都是猜的，除非有 `ANALYZE` 統計資料。

注意 `sel_eq_indexed` 的註解：

> Should be <= sel_eq_unindexed since indexes imply higher selectivity.

**這是一個參數之間的不變量**：有 index 的欄位，等值條件的選擇率應該更低（更有選擇性）。為什麼？因為人們傾向在高基數（值很分散）的欄位上建 index。這是一個**關於使用者行為的假設**，寫進了成本模型。

### 掃描成本

**`core/translate/optimizer/cost.rs:84-99`** — 完整貼出：

```rust
fn estimate_scan_cost(base_row_count: f64, num_scans: f64, params: &CostModelParams) -> Cost {
    let table_pages = (base_row_count / params.rows_per_table_page).max(1.0);

    // First scan reads all pages; subsequent scans benefit from caching
    let io_cost = if num_scans <= 1.0 {
        table_pages
    } else {
        // First scan + discounted cost for subsequent scans
        table_pages + (num_scans - 1.0) * table_pages * params.cache_reuse_factor
    };

    // CPU cost for processing all rows on each scan
    let cpu_cost = num_scans * base_row_count * params.cpu_cost_per_row;

    Cost(io_cost + cpu_cost)
}
```

**成本的單位是「page 讀取次數」**（CPU 成本折算成同一個尺度相加）。

`num_scans` 是關鍵參數：在 nested loop join 裡，內層表會被掃描「外層列數」那麼多次。

**`cache_reuse_factor` 是這裡最重要的建模。** 第一次掃描要真的讀磁碟，之後的掃描資料多半還在 page cache 裡，成本大幅降低。

如果沒有這個折扣會怎樣？optimizer 會嚴重高估 nested loop 的成本，於是**幾乎永遠選擇 hash join**——即使內層表很小、重複掃描其實幾乎免費。**成本模型漏掉快取效應，會系統性地選錯計畫。**

### Index 成本：這裡最容易出錯

**`core/translate/optimizer/cost.rs:101-113`** — 函式的說明註解：

```rust
/// Estimate IO and CPU cost for index-based access.
///
/// This properly separates the number of B-tree seeks from the number of rows
/// returned per seek. A range scan does ONE seek followed by sequential leaf
/// page reads, not one seek per row.
///
/// # Arguments
/// * `base_row_count` - Total rows in the table (for estimating tree depth and page counts)
/// * `tree_depth` - B-tree depth (number of pages to traverse per seek)
/// * `index_info` - Index properties (covering, unique, etc.)
/// * `num_seeks` - Number of B-tree traversals (typically = outer cardinality for joins)
/// * `rows_per_seek` - Expected rows returned per seek (1 for point lookup, more for range)
/// * `params` - Cost model parameters
```

註解裡的 "properly" 這個詞暗示這裡曾經寫錯過：

> A range scan does ONE seek followed by sequential leaf page reads, **not one seek per row**.

**這是 index 成本估算最常見的錯誤。** `WHERE x BETWEEN 10 AND 20` 回傳 1000 列，不是做 1000 次 B-tree seek——而是**一次** seek 定位到起點，然後沿著 leaf page 循序讀。

如果按「一列一次 seek」計算，成本會高估好幾個數量級，optimizer 就會拒絕使用完全合適的 index。

**`core/translate/optimizer/cost.rs:114-137`** — 完整貼出：

```rust
pub fn estimate_index_cost(
    base_row_count: f64,
    tree_depth: f64,
    index_info: IndexInfo,
    input_cardinality: f64,
    rows_per_seek: f64,
    params: &CostModelParams,
) -> Cost {
    // Detect full index scan: when rows_per_seek equals base_row_count, we're scanning
    // the entire index, not seeking to specific positions.
    let is_full_scan = (rows_per_seek - base_row_count).abs() < 1.0;

    // Cost of B-tree traversals: each seek traverses tree_depth pages.
    let seek_cost = if is_full_scan {
        // Full scan: one seek to start, then sequential reads.
        // When re-scanned (nested loop inner), first scan is cold, rest are cached.
        if input_cardinality <= 1.0 {
            tree_depth
        } else {
            tree_depth + (input_cardinality - 1.0) * tree_depth * params.cache_reuse_factor
        }
    } else {
        input_cardinality * tree_depth
    };
```

`tree_depth` 對應 `06b-source-code-learn-btree-cursor-pager.md` 講的 `PageStack` 深度——一次 seek 要從 root 往下走過 `tree_depth` 個 page，每個都可能是一次 I/O。

**`core/translate/optimizer/cost.rs:139-160`** — leaf 掃描成本：

```rust
    let index_leaf_pages_count = (rows_per_seek / index_info.rows_per_leaf_page).max(1.0);
    let leaf_scan_cost = if is_full_scan {
        // Full scan of all leaf pages. Repeated scans benefit from caching.
        if input_cardinality <= 1.0 {
            index_leaf_pages_count
        } else {
            index_leaf_pages_count
                + (input_cardinality - 1.0) * index_leaf_pages_count * params.cache_reuse_factor
        }
    } else if rows_per_seek <= 1.0 {
        // Point lookup: the leaf page is the last page of the B-tree traversal,
        // already counted in seek_cost.
        0.0
    } else if input_cardinality <= 1.0 {
        index_leaf_pages_count
    } else {
        // Range scan in a nested-loop join: after the first iteration the inner
        // table's pages are largely in the buffer pool.  Apply the same caching
        // discount as full scans.
        index_leaf_pages_count
            + (input_cardinality - 1.0) * index_leaf_pages_count * params.cache_reuse_factor
    };
```

注意點查找那個分支：

```rust
    } else if rows_per_seek <= 1.0 {
        // Point lookup: the leaf page is the last page of the B-tree traversal,
        // already counted in seek_cost.
        0.0
```

**不重複計算。** seek 走到底就已經在 leaf page 上了，那個 page 已經算在 `seek_cost` 裡（`tree_depth` 包含 leaf）。再加一次就是重複。

這種細節很容易寫錯，而錯了不會有明顯症狀——只會讓某些查詢選錯計畫，很難察覺。

### 回表成本：covering index 的價值

**`core/translate/optimizer/cost.rs:162-170`** — 完整貼出：

```rust
    // For non-covering indexes, we need to fetch from the table for each row.
    let table_lookup_cost = if index_info.covering {
        0.0
    } else {
        let table_pages_count = (base_row_count / params.rows_per_table_page).max(1.0);
        let selectivity = rows_per_seek / base_row_count.max(1.0);
        input_cardinality * selectivity * table_pages_count
    };
```

**covering index**（查詢要的欄位都在 index 裡）不需要回主表，成本是 0。

否則每一列都要用 rowid 回主表查一次——這就是 `01-source-code-learn-5-cursor-storage.md` 講的 `deferred_seeks` 機制在成本模型裡的體現。

**這解釋了一個實務現象**：在 index 裡多加一個欄位（讓它變成 covering），效能可能大幅提升。因為省掉的不是比較，是**每列一次的隨機 page 讀取**。

**`core/translate/optimizer/cost.rs:172-179`** — 收尾：

```rust
    let io_cost = seek_cost + leaf_scan_cost + table_lookup_cost;

    // CPU cost: key comparisons during seeks + row processing
    let total_rows = input_cardinality * rows_per_seek;
    let cpu_cost =
        input_cardinality * params.cpu_cost_per_seek + total_rows * params.cpu_cost_per_row;

    Cost((io_cost + cpu_cost - params.index_bonus).max(0.001))
}
```

最後那個 `- params.index_bonus` 值得注意：**人為給 index 一點折扣**。

為什麼？因為成本模型是估的，而估錯的**後果不對稱**：

- 該用 index 卻全表掃描 → 慢幾百倍。
- 不該用 index 卻用了 → 慢幾倍。

在不確定時偏向 index 是理性的風險管理。`.max(0.001)` 則確保成本不會變成負數或零（否則後續的比較與乘法會出問題）。

### 唯一點查找的特判

**`core/translate/optimizer/cost.rs:181-189`** — 完整貼出：

```rust
pub(crate) fn is_unique_point_lookup(
    index_info: IndexInfo,
    usable_constraint_refs: &[RangeConstraintRef],
) -> bool {
    let eq_count = usable_constraint_refs
        .iter()
        .take_while(|cref| cref.eq.is_some())
        .count();
    index_info.unique && eq_count >= index_info.column_count
}
```

如果 index 是唯一的，而且**所有欄位都有等值約束**，那結果最多一列。

`take_while`（而非 `filter`）是關鍵：index 的欄位是**有序的前綴**。`INDEX(a, b, c)` 上，`WHERE a=1 AND c=3` 只能用到 `a`——中間缺了 `b`，`c` 的約束無法用於 seek。`take_while` 正確地在第一個非等值處停止。

**寫成 `filter` 會高估 index 的能力**，選出一個實際上只能用一個欄位的計畫，卻以為它能精確定位。

### 統計資料的來源要標記

**`core/translate/optimizer/cost.rs:191-200`** — 完整貼出：

```rust
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum RowCountEstimate {
    HardcodedFallback(f64),
    AnalyzeStats(f64),
}
```

**用型別區分「猜的」和「量過的」。**

兩者都是 `f64`，但意義不同。有 `ANALYZE` 統計時是實測值，可信度高；沒有時是 `rows_per_table_fallback` 這個猜測。

某些決策（例如「要不要冒險選一個激進的計畫」）應該只在有真實統計時才做。**把資料來源編碼進型別**，讓這種區分無法被忽略——如果只用 `f64`，呼叫端根本不知道自己拿到的是什麼。

---

---

> ### ⏸ Session 1 到此
>
> 目前為止涵蓋了：WHERE 條件如何變成 Constraint，以及成本模型的三段公式。
>
> 休息之前，先確認你能說出這幾件事；說不出來就往回翻，不要硬推進——後半段會用到它們。
>
> **Session 2** 從下一節開始：AccessMethod 的選擇與 join order 的 DP 列舉。

---

## 第三步：AccessMethod

**`core/translate/optimizer/access_method.rs:55-68`** — 完整貼出：

```rust
pub struct AccessMethod {
    /// The estimated number of page fetches.
    /// CPU costs are folded into the same scalar cost model.
    pub cost: Cost,
    /// Estimated rows produced per outer row before applying remaining filters.
    pub estimated_rows_per_outer_row: f64,
    /// Whether join cardinality should still apply planner-side selectivity after
    /// using this access path's own row estimate.
    pub residual_constraints: ResidualConstraintMode,
    /// WHERE-term indices already accounted for by this access path's row estimate.
    pub consumed_where_terms: SmallVec<[usize; 4]>,
    /// Table-type specific access method details.
    pub params: AccessMethodParams,
}
```

一個 `AccessMethod` 代表「在某個 join 位置上，用某種方式存取某張表」，並附帶成本與列數估算。

**`consumed_where_terms` 是避免重複計算選擇率的機制。**

假設 `WHERE x = 1 AND y = 2`，而我們選了 `INDEX(x)`：

- index 已經處理了 `x = 1`，回傳的列數已經反映了它的選擇率。
- `y = 2` 還沒處理，之後要當過濾條件，它的選擇率要**額外**乘上去。

如果不記錄「哪些條件已經被吸收」，就會把 `x = 1` 的選擇率算兩次，嚴重低估結果列數，進而讓後續的 join 決策全錯。

**`core/translate/optimizer/access_method.rs:70-80`** — 完整貼出：

```rust
/// Describes whether join planning should still apply residual WHERE-term
/// selectivity after choosing an access path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResidualConstraintMode {
    /// Apply the selectivity of all relevant WHERE terms that this access path
    /// did not already consume.
    ApplyUnconsumed,
    /// The access path already provided its own final row estimate; do not
    /// multiply any planner-side residual selectivity on top.
    None,
}
```

`None` 這個變體是給**虛擬表**用的：虛擬表的 `xBestIndex` 會自己回報估計列數，那是模組作者提供的權威數字，planner 不該在上面再乘自己的猜測。

---

## 第四步：Join Order 的列舉

### 兩種演算法，依表數切換

**`core/translate/optimizer/join.rs:946-976`** — 完整貼出：

```rust
    // Skip work if we have no tables to consider.
    if joined_tables.is_empty() {
        return Ok(None);
    }

    let num_tables = joined_tables.len();

    // For large queries, use greedy join ordering instead of exhaustive DP.
    // The DP algorithm has O(2^n) complexity which becomes prohibitively slow
    // beyond ~12 tables. The greedy algorithm is O(n²) and produces good
    // (though not always optimal) plans.
    let where_term_table_ids = build_where_term_table_ids(where_clause, joined_tables);
    if num_tables > GREEDY_JOIN_THRESHOLD {
        return compute_greedy_join_order(
            joined_tables,
            initial_input_cardinality,
            planning_context,
            constraints,
            base_table_rows,
            access_methods_arena,
            where_clause,
            &where_term_table_ids,
            subqueries,
            index_method_candidates,
            params,
            analyze_stats,
            available_indexes,
            table_references,
            schema,
        );
    }
```

**這是一個明確的取捨，而且寫在註解裡**：

| 表數 | 演算法 | 複雜度 | 結果 |
|---|---|---|---|
| ≤ 12 | 動態規劃 | O(2^n) | 最佳 |
| > 12 | 貪婪 | O(n²) | 夠好但不保證最佳 |

12 張表的 DP 是 4096 個子集，還可以接受；13 張是 8192，20 張是一百萬——**編譯時間會超過查詢執行時間**，那就本末倒置了。

**這是所有查詢最佳化器都要面對的問題**：最佳化本身是有成本的。超過某個規模，「快速找到一個好計畫」比「慢慢找到最佳計畫」更有價值。

### 先算一個 baseline

**`core/translate/optimizer/join.rs:978-996`** — 完整貼出：

```rust
    // Compute naive left-to-right plan to use as pruning threshold
    let naive_plan = compute_naive_left_deep_plan(
        joined_tables,
        initial_input_cardinality,
        planning_context,
        base_table_rows,
        access_methods_arena,
        constraints,
        where_clause,
        &where_term_table_ids,
        subqueries,
        index_method_candidates,
        params,
        analyze_stats,
        available_indexes,
        table_references,
        schema,
    )?;
```

先照使用者寫的順序算一個計畫，當作**剪枝門檻**。

搜尋時任何部分計畫只要成本已經超過這個 baseline，就可以整個分支放棄——不必展開它的所有後續排列。這是 branch-and-bound 的標準做法。

**而且它保證了一個下限**：最終選出的計畫至少不會比「照使用者寫的順序」更差。

### 排序與成本的取捨

**`core/translate/optimizer/join.rs:997-1010`** — 完整貼出：

```rust
    // Keep track of both 1. the best plan overall (not considering sorting), and 2. the best ordered plan (which might not be the same).
    // We assign Some Cost (tm) to any required sort operation, so the best ordered plan may end up being
    // the one we choose, if the cost reduction from avoiding sorting brings it below the cost of the overall best one.
    let mut best_ordered_plan: Option<JoinN> = None;
    let mut best_plan_is_also_ordered =
        match (naive_plan.as_ref(), planning_context.maybe_order_target) {
            (Some(plan), Some(order_target)) => plan_satisfies_order_target(
                plan,
                access_methods_arena,
                joined_tables,
                order_target,
                schema,
            ),
            _ => false,
        };
```

**同時追蹤兩個最佳計畫**：整體最便宜的，以及「輸出剛好有序」的最便宜的。

為什麼？因為有 `ORDER BY` 時，如果計畫的輸出天然有序，就**完全不用排序**。一個看起來比較貴的計畫，加上省下的排序成本，可能反而總成本更低。

`03-source-code-learn-1-planner.md` 提過 `optimize_table_access` 的參數包含 `&mut plan.order_by`——就是為了這個。選中有序計畫時，`order_by` 會被清空，emitter 就不會產生 sorter。

註解裡那句 "Some Cost (tm)" 是開發者的自嘲：排序的成本也是估的。

### 記憶化：利用 join 的代數性質

**`core/translate/optimizer/join.rs:1035-1050`** — 完整貼出：

```rust
    // Keep track of the best plan for a given subset of tables.
    // Consider this example: we have tables a,b,c,d to join.
    // if we find that 'b JOIN a' is better than 'a JOIN b', then we don't need to even try
    // to do 'a JOIN b JOIN c', because we know 'b JOIN a JOIN c' is going to be better.
    // This is due to the commutativity and associativity of inner joins.
    // Memo table keyed by a subset mask, then by the last table in the join order.
    //
    // We keep multiple plans per subset instead of only the cheapest one. The cheapest
    // subset plan is not always the best foundation for the next join. Keeping variants
    // lets the planner choose a better join order later (e.g. for hash-join chaining).
    let mut best_plan_memo: HashMap<TableMask, HashMap<usize, JoinN>> =
        HashMap::with_capacity_and_hasher(2usize.pow(num_tables as u32 - 1), Default::default());
```

**這段註解把 DP 的原理講完了。**

核心洞見：inner join 滿足**交換律與結合律**。所以如果 `{a,b}` 這個子集的最佳順序是 `b JOIN a`，那麼任何包含 `{a,b}` 的更大計畫，都應該用 `b JOIN a` 當基礎，不必再試 `a JOIN b`。

於是搜尋空間從「所有排列」（n!）降到「所有子集」（2^n）。4 張表：24 種排列 vs 16 個子集；10 張表：360 萬 vs 1024。

**但這裡有一個精妙的修正**：

> We keep multiple plans per subset instead of only the cheapest one. The cheapest subset plan is not always the best foundation for the next join.

memo 的型別是 `HashMap<TableMask, HashMap<usize, JoinN>>` —— 每個子集不是只存一個計畫，而是**依「最後一張表」分別存**。

為什麼需要？因為下一個 join 的成本**取決於目前計畫的最後一張表**。`{a,b}` 用 `a JOIN b` 結尾在 b，用 `b JOIN a` 結尾在 a；如果接下來要 join 的 c 剛好和 a 有 index 可用，那即使 `b JOIN a` 本身比較貴，它也是更好的基礎。

hash join 更是如此——它需要特定的表當 build side，鏈接關係會影響後續。

**這是教科書 DP 的一個實務修正**：純粹的「每個子集只留最佳」在有 index 與 hash join 的世界裡會漏掉更好的計畫。

`HashMap::with_capacity_and_hasher(2^(n-1))` 則是預先配置——既然知道子集數量的上限，就不要讓 HashMap 反覆重新配置。

---

## 完整流程

```text
optimize_select_plan                    optimizer/mod.rs:737
  │
  ├─ 前置改寫（unnest、常數消除、共同子式提取）   ← 03-1 講過
  │
  ├─ constraints.rs：WHERE terms → Constraint
  │     每個約束記住：來源 term 位置、運算子、lhs_mask
  │
  └─ optimize_table_access
       └─ core/translate/optimizer/join.rs:892  compute_best_join_order
            │
            ├─ 表數 > 12 → compute_greedy_join_order   O(n²)
            │
            └─ 否則 DP：
                 ├─ compute_naive_left_deep_plan       產生剪枝門檻
                 ├─ 依子集大小遞增列舉
                 │    對每個 (子集, 最後一張表)：
                 │      對每個候選 index / scan：
                 │        ├─ 檢查 lhs_mask 是否已滿足   ← 約束可用性
                 │        ├─ core/translate/optimizer/cost.rs:114 estimate_index_cost
                 │        │    seek + leaf scan + 回表 - index_bonus
                 │        ├─ 記錄 consumed_where_terms  ← 避免重複算選擇率
                 │        └─ 存進 memo（依最後一張表分開存）
                 │
                 └─ 同時追蹤 best_plan 與 best_ordered_plan
                      最後比較「總成本」vs「總成本 + 排序成本」
```

---

## 動手驗證

看成本模型如何改變決策：

```bash
cd /Users/stanhsu/projects/turso
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE small(id INTEGER PRIMARY KEY, v TEXT);
CREATE TABLE big(id INTEGER PRIMARY KEY, sid INTEGER, v TEXT);
CREATE INDEX big_sid ON big(sid);

INSERT INTO small SELECT value, 'x' FROM generate_series(1, 10);
INSERT INTO big SELECT value, value % 10, 'y' FROM generate_series(1, 10000);

EXPLAIN QUERY PLAN SELECT * FROM small JOIN big ON big.sid = small.id;
```

optimizer 應該選擇「掃 small（10 列），對每列用 `big_sid` seek big」，而不是反過來。**因為外層應該是小表**——這就是成本模型的作用。

看 covering index 的效果：

```sql
EXPLAIN SELECT sid FROM big WHERE sid = 5;      -- covering，不用回表
EXPLAIN SELECT v FROM big WHERE sid = 5;        -- 非 covering，要回表
```

第二個會多出用 rowid 回主表的動作。對照 `estimate_index_cost` 裡的 `table_lookup_cost`。

看 optimizer 的決策過程：

```bash
RUST_LOG=turso_core::translate::optimizer=debug cargo run -q --bin tursodb -- -q
```

`03-source-code-learn-1-planner.md` 提過，`optimize_plan` 結尾會把最佳化後的計畫印回 SQL 文字。

追 source：

```bash
rg -n "pub struct Constraint\b|pub enum ConstraintOperator" core/translate/optimizer/constraints.rs
rg -n "pub struct CostModelParams" core/translate/optimizer/cost_params.rs
rg -n "fn estimate_scan_cost|pub fn estimate_index_cost|fn is_unique_point_lookup" core/translate/optimizer/cost.rs
rg -n "pub struct AccessMethod|pub enum ResidualConstraintMode" core/translate/optimizer/access_method.rs
rg -n "pub fn compute_best_join_order|GREEDY_JOIN_THRESHOLD" core/translate/optimizer/join.rs
```

---

## 自我檢查

1. `Constraint.where_clause_pos` 有兩個用途，第二個為什麼會影響查詢正確性？
2. `SELECT * FROM t1,t2,t3 WHERE t1.x = t2.x + t3.x` 裡，t1 能不能用 index？這個問題為什麼沒有固定答案？
3. `lhs_mask` 為什麼用 bitmask 而不是表名列表？
4. `ConstraintOperator::In` 為什麼要帶 `estimated_values`？
5. 成本模型的參數為什麼要集中在一個 struct 並支援 JSON 覆寫？
6. `sel_eq_indexed <= sel_eq_unindexed` 這個不變量背後的假設是什麼？
7. `cache_reuse_factor` 如果拿掉，optimizer 會系統性地偏向哪種 join？為什麼？
8. 範圍查找回傳 1000 列，需要幾次 B-tree seek？算成 1000 次會有什麼後果？
9. 點查找的 `leaf_scan_cost` 為什麼是 0？
10. covering index 為什麼能省掉 `table_lookup_cost`？這對應執行期的什麼機制？
11. `index_bonus` 為什麼要人為給 index 折扣？和估錯的後果對稱性有什麼關係？
12. `is_unique_point_lookup` 用 `take_while` 而非 `filter`，為什麼？寫成 `filter` 會高估什麼？
13. `RowCountEstimate` 為什麼要用 enum 區分兩種來源，而不是直接用 `f64`？
14. `consumed_where_terms` 不記錄會導致什麼估算錯誤？
15. 為什麼表數超過 12 就改用貪婪演算法？這反映了什麼取捨？
16. DP 的記憶化為什麼能把 n! 降到 2^n？依賴 inner join 的什麼性質？
17. memo 為什麼要「每個子集依最後一張表分開存多個計畫」，而不是只留最便宜的？
18. 為什麼要同時追蹤 `best_plan` 和 `best_ordered_plan`？

---

下一篇 `03-source-code-learn-3-emitter-dml-ddl.md`：計畫如何變成指令，以及 INSERT / UPDATE / DELETE / DDL 的編譯。
