# 05b. 源碼精讀：Expression 編譯與 Function 系統

本篇對應 `05b-functions-expressions.md`，看表達式如何變成 register 操作，以及純量／聚合／視窗函式在編譯與執行上的差別。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 60–75 分鐘（約 14k 字，其中 39% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/translate/expr/translator.rs   translate_expr ── 表達式 → bytecode
core/function.rs                     Func ── 函式的分類
  └─> core/dialect/sqlite.rs         resolve_builtin_function ── 名稱+arity → Func
        └─> core/vdbe/execute.rs     op_function  ── 純量函式的執行
                                     op_agg_step  ── 聚合的累加
```

**先建立本篇的核心對比**：

| | 純量函式 `upper(x)` | 聚合函式 `sum(x)` |
|---|---|---|
| 輸入 | 一列 | 多列 |
| 狀態 | 無 | 跨列的累加器 |
| bytecode | 一條 `Function` | `AggStep` × N 次 + `AggFinal` × 1 次 |
| register 內容 | `Register::Value` | `Register::Aggregate` |

---

## translate_expr：表達式編譯的入口

**`core/translate/expr/translator.rs:94-110`** — 完整貼出開頭：

```rust
pub fn translate_expr(
    program: &mut ProgramBuilder,
    referenced_tables: Option<&TableReferences>,
    expr: &ast::Expr,
    target_register: usize,
    resolver: &Resolver,
) -> Result<usize> {
    let constant_span = if expr.is_constant(resolver) {
        if !program.constant_span_is_open() {
            Some(program.constant_span_start())
        } else {
            None
        }
    } else {
        program.constant_span_end_all();
        None
    };
```

先看簽章：**`target_register` 是參數，不是回傳值**。呼叫者決定「算完放哪個 register」，`translate_expr` 負責產生把結果放進去的指令。

這是遞迴式程式碼產生的標準做法：外層先配置好目的地，內層各自把子結果算到暫時的 register，最後合併寫入目的地。

### 常數摺疊：constant span

開頭那段在做的事是**辨識常數表達式**。

`expr.is_constant(resolver)` 判斷這個表達式是否與資料無關（例如 `1 + 2`、`'a' || 'b'`）。是的話就開一個「常數區段」。

為什麼要這樣做？回想 `04-source-code-learn-1-insn-dispatch.md` 那份 EXPLAIN：

```text
0     Init               0     3     0   Start at 3
1     ResultRow          1     1     0
2     Halt               0     0     0
3     Integer            1     2     0   r[2]=1
4     Integer            2     3     0   r[3]=2
5     Add                2     3     1   r[1]=r[2]+r[3]
6     Goto               0     1     0
```

`Integer`、`Integer`、`Add` 這三條被放在**程式尾端的初始化區**，而不是主體裡。`03-source-code-learn-1-planner.md` 講過 `epilogue` 裡有一行 `emit_constant_insns()`，發的就是這些。

**效果**：如果這個表達式在一個掃描百萬列的迴圈裡，常數部分只會算一次，不是一百萬次。

`constant_span_end_all()` 則是遇到非常數表達式時「關閉所有開著的常數區段」——因為一旦依賴資料，後面的計算就不能再提到初始化區了。

### 表達式快取

**`core/translate/expr/translator.rs:112-118`** — 完整貼出：

```rust
    if let Some((reg, needs_decode, collation_ctx)) = resolver.resolve_cached_expr_reg(expr) {
        program.emit_insn(Insn::Copy {
            src_reg: reg,
            dst_reg: target_register,
            extra_amount: 0,
        });
```

如果同一個表達式**已經算過**並且結果還在某個 register 裡，就直接 `Copy`，不重算。

什麼時候會重複？`SELECT a+b, (a+b)*2 FROM t` 裡的 `a+b`，或是 `GROUP BY x` 與 `SELECT x` 的 `x`。這就是 `03-source-code-learn-1-planner.md` 提過 `Resolver` 有 `expr_to_reg_cache` 欄位的用途。

**`core/translate/expr/translator.rs:119-131`** — 續：

```rust
        // Hash join payloads store raw encoded values; apply DECODE for custom
        // type columns so the result set contains human-readable text.
        if needs_decode && !program.flags.suppress_custom_type_decode() {
            if let ast::Expr::Column {
                table: table_ref_id,
                column,
                ..
            } = expr
            {
```

```rust
                // ── 省略（core/translate/expr/translator.rs:132-180 附近）：
                //    查出自訂型別並 emit DECODE 指令的細節 ──
```

這個 `needs_decode` 標記說明了快取不只是「存 register 編號」——還要記住那個 register 裡的值是**什麼形式**。hash join 的 payload 存的是原始編碼值，直接輸出給使用者會是亂碼，所以要記得補一條 DECODE。

**快取存錯了會產生錯誤結果，不只是慢**——這是為什麼快取項要帶這些 metadata。

### 主體：依 Expr 變體分派

```rust
    // ── 省略（core/translate/expr/translator.rs:180-2400 附近）：
    //    對 ast::Expr 各變體的巨大 match。主要分支：
    //      Literal    → emit Integer / Real / String8 / Blob / Null
    //      Column     → emit Column（從 cursor 讀）或 RowId
    //      Binary     → 遞迴算 lhs、rhs 到暫存 register，再 emit Add/Eq/...
    //      Unary      → 遞迴算運算元，再 emit Not/Negative/BitNot
    //      FunctionCall → 算完所有引數到連續 register，再 emit Function
    //      Case       → 一串條件跳轉 + label
    //      InList     → 展開成一連串比較，或用臨時 B-tree
    //      Subquery   → 呼叫 SELECT 編譯器
    //      Variable   → emit Variable（綁定參數）
    //      Cast/Collate/Between/Like/IsNull/... ──
```

這個 match 有兩千多行，但形狀高度重複，第一輪只需要掌握**遞迴模式**：

```text
translate_expr(Binary(lhs, Add, rhs), target=1)
  ├─ 配置暫存 register 2, 3
  ├─ translate_expr(lhs, target=2)   ← 遞迴
  ├─ translate_expr(rhs, target=3)   ← 遞迴
  └─ emit Insn::Add { lhs: 2, rhs: 3, dest: 1 }
```

**AST 的樹狀結構，變成 register 編號的資料流。** 樹的葉節點先算進暫存 register，內部節點再把子結果合併。這就是 `1 + 2` 為什麼會產生 `Integer r[2]`、`Integer r[3]`、`Add 2 3 1` 三條指令。

也因為是遞迴，深度巢狀的表達式會消耗 stack——這正是 `02-source-code-learn-parser-and-ast.md` 講的 `MAX_EXPR_DEPTH = 100` 要保護的下游。註解在那裡寫得很清楚：「our recursive translator/optimizer uses larger stack frames per nesting level」。

---

## Func：函式的分類

**`core/function.rs:1542-1558`** — 完整貼出：

```rust
pub enum Func {
    Agg(AggFunc),
    Window(WindowFunc),
    Scalar(ScalarFunc),
    Math(MathFunc),
    Vector(VectorFunc),
    #[cfg(all(feature = "fts", not(target_family = "wasm")))]
    Fts(FtsFunc),
    #[cfg(feature = "json")]
    Json(JsonFunc),
    AlterTable(AlterTableFunc),
    External(Arc<ExternalFunc>),
    /// Scalar function provided by the database's schema dialect (e.g. a
    /// PostgreSQL catalog function). Resolved and executed through
    /// [`crate::dialect::Dialect`]; the engine only carries the name.
    Dialect(String),
}
```

分類的維度混合了兩種：

**按執行模型分**：`Agg`（聚合）、`Window`（視窗）vs 其餘（純量）。這個區分**影響 bytecode 結構**。

**按來源／領域分**：`Scalar`、`Math`、`Vector`、`Fts`、`Json` 都是純量函式，只是實作分在不同模組。這個區分**只影響程式碼組織**，不影響 bytecode。

兩個特殊變體：

**`External(Arc<ExternalFunc>)`** —— extension 提供的函式。用 `Arc` 因為它持有外部模組的 callback 指標，需要共享且要控制生命週期（extension 卸載時不能還有人在用）。

**`Dialect(String)`** —— 註解說明得很清楚：「the engine only carries the name」。PostgreSQL 方言的目錄函式（例如 `pg_catalog` 相關）由 dialect 自行解析執行，engine 只負責傳遞名稱。這是 `01-source-code-learn-2-prepare-parse.md` 講的 `Dialect` trait 抽象的延伸。

`#[cfg(...)]` 條件編譯也值得注意：FTS 和 JSON 是 feature-gated 的。**不需要的功能不編進二進位檔**——對嵌入式資料庫來說，二進位大小是實際的考量。

---

## 函式解析：名稱 + arity

**`core/function.rs:1669-1671`** — 完整貼出：

```rust
    pub fn resolve_function(name: &str, arg_count: usize) -> Result<Option<Self>, LimboError> {
        crate::dialect::sqlite::resolve_builtin_function(name, arg_count)
    }
```

**參數必須包含 `arg_count`**。這在 `01-source-code-learn-2-prepare-parse.md` 提過，現在看到原因：

**`core/dialect/sqlite.rs:190-212`** — 完整貼出：

```rust
pub fn resolve_builtin_function(name: &str, arg_count: usize) -> crate::Result<Option<Func>> {
    let normalized_name = crate::util::normalize_ident(name);
    match normalized_name.as_str() {
        "avg" => {
            if arg_count != 1 {
                crate::bail_parse_error!("wrong number of arguments to function {}()", name)
            }
            Ok(Some(Func::Agg(AggFunc::Avg)))
        }
        "count" => {
            // Handle both COUNT() and COUNT(expr) cases
            if arg_count == 0 {
                Ok(Some(Func::Agg(AggFunc::Count0))) // COUNT() case
            } else if arg_count == 1 {
                Ok(Some(Func::Agg(AggFunc::Count))) // COUNT(expr) case
            } else {
                crate::bail_parse_error!("wrong number of arguments to function {}()", name)
            }
        }
        "group_concat" => {
            if arg_count != 1 && arg_count != 2 {
                println!("{arg_count}");
                crate::bail_parse_error!("wrong number of arguments to function {}()", name)
```

```rust
    // ── 省略（core/dialect/sqlite.rs:213-500 附近）：其餘上百個內建函式的
    //    名稱比對與 arity 檢查，形式相同 ──
```

`count` 這個例子完整說明了為什麼需要 arity：

- `count()` → `AggFunc::Count0`
- `count(x)` → `AggFunc::Count`

**同一個名稱，不同參數個數，對應到不同的實作**。`count()` 數的是列數，`count(x)` 數的是 `x` 非 NULL 的列數——語義不同，所以是兩個不同的 `AggFunc`。

`normalize_ident(name)` 處理大小寫（SQL 函式名不分大小寫）與引號。

`group_concat` 那個分支裡有一行 `println!("{arg_count}")` —— 這是**遺留的除錯輸出**，會在使用者用錯參數個數時印到 stdout。這種東西在真實程式碼裡確實會出現；讀源碼時看到不合理的地方，有時候它就是單純的疏漏，不必假設一定有深意。

---

## 純量函式的執行

**`core/vdbe/execute.rs:7557-7574`** — 完整貼出開頭：

```rust
pub fn op_function(
    program: &Program,
    state: &mut ProgramState,
    insn: &Insn,
    pager: &Arc<Pager>,
) -> Result<InsnFunctionStepResult> {
    load_insn!(
        Function {
            constant_mask: _,
            func,
            start_reg,
            dest,
        },
        insn
    );
    let arg_count = func.arg_count;

    match &func.func {
```

```rust
        // ── 省略（core/vdbe/execute.rs:7575-8900 附近）：對 Func 各變體
        //    與各具體函式的巨大 match，每個分支從 registers[start_reg..]
        //    取引數、計算、寫回 registers[dest] ──
```

三個結構重點：

**`start_reg` 而非引數列表。** 引數放在**連續的 register**，從 `start_reg` 開始，共 `arg_count` 個。這是 SQLite VDBE 的慣例：指令只帶起點和數量，不帶每個引數的位置。編譯器負責把引數算到連續的位置。

**`constant_mask: _` 被忽略。** 這個位元遮罩標記哪些引數是常數，可用於最佳化（例如 `LIKE` 的 pattern 是常數時可以預編譯）。此處的通用路徑不使用它。

**`pager` 沒有底線前綴**（對比 `04-source-code-learn-1-insn-dispatch.md` 的 `op_add` 是 `_pager`）。表示某些函式**會碰儲存層**——例如 `last_insert_rowid()`、或某些需要讀取資料庫狀態的函式。所以 `op_function` 是**可能 I/O** 的指令。

看一個具體分支：

**`core/vdbe/execute.rs:7575-7584`** — 節錄：

```rust
        #[cfg(feature = "json")]
        crate::function::Func::Json(json_func) => match json_func {
            JsonFunc::Json => {
                let json_value = &state.registers[*start_reg];
                let json_str = get_json(json_value.get_value(), None);
                match json_str {
                    Ok(json) => state.registers[*dest].set_value(json),
                    Err(e) => return Err(e),
                }
            }
```

模式很清楚：**從 `registers[start_reg]` 取引數 → 計算 → 寫回 `registers[dest]`**。純量函式的整個生命週期就在這一列之內，不留任何狀態。

---

## 聚合函式：為什麼比較難

聚合需要**跨列保存狀態**，這打破了「一條指令做完就結束」的模型。

### bytecode 結構

```text
        AggStep  acc_reg=5, func=Sum, col=r[2]     ← 每列執行一次
        ...迴圈...
        AggFinal acc_reg=5, func=Sum                ← 迴圈結束後執行一次
```

`AggStep` 在迴圈**內**，`AggFinal` 在迴圈**外**。累加器活在 `acc_reg` 這個 register 裡，橫跨整個迴圈。

### 累加器住在 register 裡

**`core/vdbe/execute.rs:6865-6896`** — 完整貼出開頭：

```rust
pub fn op_agg_step(
    program: &Program,
    state: &mut ProgramState,
    insn: &Insn,
    _pager: &Arc<Pager>,
) -> Result<InsnFunctionStepResult> {
    load_insn!(
        AggStep {
            acc_reg,
            col,
            delimiter,
            func,
            comparator,
        },
        insn
    );

    if let AccumulatorFunc::Window(win_func) = func {
        return op_window_step(state, *acc_reg, win_func);
    }
    let func = func.expect_agg();

    // Initialize aggregate state if not already done
    if let Register::Value(Value::Null) = state.registers[*acc_reg] {
        state.registers[*acc_reg] = match func {
            AggFunc::External(ext_func) => match ext_func.as_ref() {
                ExtFunc::Aggregate {
                    context,
                    init,
                    step,
                    finalize,
```

```rust
                    // ── 省略（core/vdbe/execute.rs:6897-7100 附近）：各 AggFunc
                    //    的累加器初始化，以及初始化後對本列值的累加邏輯 ──
```

三個重點：

**一、惰性初始化。**

```rust
    if let Register::Value(Value::Null) = state.registers[*acc_reg] {
```

register 初始是 `Value::Null`；第一次 `AggStep` 執行時才建立真正的累加器。

為什麼不在迴圈前先初始化？因為那要多一條指令，而且 `GROUP BY` 時每個群組都要重新初始化——用「NULL 代表尚未初始化」可以讓同一段 bytecode 自然處理多個群組。

**二、`Register::Aggregate` 的用途在此。** `04-source-code-learn-1-insn-dispatch.md` 看過 `Register` 有三個變體，`Aggregate(AggContext)` 就是給這裡用的。累加器不是普通的值——`avg` 要同時記總和與計數、`group_concat` 要記已拼接的字串，這些都放在 `AggContext` 裡。

**三、視窗函式共用這條指令。**

```rust
    if let AccumulatorFunc::Window(win_func) = func {
        return op_window_step(state, *acc_reg, win_func);
    }
```

視窗函式和聚合共用 `AggStep` 指令，但在執行期分流。因為兩者的累加模型類似（都是逐列餵資料），差別在**何時輸出結果**：聚合是整個群組結束才輸出一次，視窗是每列都輸出。

**四、extension 提供的聚合有四個部分**：`context`、`init`、`step`、`finalize`。這是 SQLite 的 `sqlite3_create_function` 聚合介面的形狀——extension 要提供初始化、每列累加、最終計算三個 callback，加上一塊自有的狀態空間。

---

## 三種函式的完整對照

| | 純量 | 聚合 | 視窗 |
|---|---|---|---|
| 指令 | `Function` | `AggStep` + `AggFinal` | `AggStep`（分流到 `op_window_step`） |
| register 型別 | `Value` | `Aggregate` | `Aggregate` |
| 狀態範圍 | 無 | 一個群組 | 一個 frame |
| 輸出時機 | 每列 | 群組結束 | 每列 |
| 編譯位置 | `translate/expr/` | `translate/aggregation.rs`、`group_by.rs` | `translate/window.rs` |

編譯期的辨識在 planner：`03-source-code-learn-1-planner.md` 提過 `SelectPlan` 有 `aggregates: Vec<Aggregate>` 和 `window: Option<Window>` 欄位，就是在 `prepare_select_plan` 階段掃描表達式樹收集出來的。

`SelectPlan.window` 是 `Option`（最多一個）這件事，欄位註解有解釋：

> There is at most one window per SELECT. If the original query contains more, they are pushed down into subqueries.

多個視窗定義會被改寫成巢狀子查詢，每層處理一個。**用「改寫成已知能處理的形狀」來簡化實作**——這是編譯器常見的策略。

---

## 動手驗證

看純量函式的 bytecode：

```bash
cargo run -q --bin tursodb -- -q
```

```sql
EXPLAIN SELECT upper('alice'), 1 + 2;
```

你會看到常數載入、`Function`、`Add`、`ResultRow`。注意常數部分被放在程式尾端的初始化區（`Init` 跳過去的那一段）。

看聚合的 bytecode 結構：

```sql
CREATE TABLE t(a INTEGER, b TEXT);
INSERT INTO t VALUES (1,'x'),(2,'y'),(3,'z');
EXPLAIN SELECT sum(a) FROM t;
```

找出 `AggStep` 和 `AggFinal` 的位址，確認 `AggStep` 在 `Rewind`/`Next` 迴圈**之內**，`AggFinal` 在迴圈**之外**。

驗證 arity 決定函式：

```sql
SELECT count(), count(a), count(*) FROM t;
```

三者都合法但走不同的 `AggFunc`。再試錯誤的參數個數：

```sql
SELECT count(a, b) FROM t;
```

應該得到「wrong number of arguments」——這個錯誤就來自 `resolve_builtin_function`。

驗證常數摺疊：

```sql
EXPLAIN SELECT a + (1 + 2) FROM t;
```

`1 + 2` 應該只在初始化區算一次，迴圈裡只有 `a` 加上那個已算好的 register。

追 source：

```bash
rg -n "pub fn translate_expr" core/translate/expr/translator.rs
rg -n "pub enum Func\b|pub fn resolve_function" core/function.rs
rg -n "pub fn resolve_builtin_function" core/dialect/sqlite.rs
rg -n "pub fn op_function|pub fn op_agg_step" core/vdbe/execute.rs
```

---

## 自我檢查

1. `translate_expr` 的 `target_register` 為什麼是參數而不是回傳值？
2. 常數表達式為什麼要放進程式尾端的初始化區？在什麼查詢裡效益最大？
3. 表達式快取除了 register 編號，為什麼還要記 `needs_decode`？記錯會怎樣？
4. `1 + 2` 為什麼會產生三條指令而不是一條？這反映了什麼編譯模式？
5. `Func` 的分類混合了兩種維度，分別是什麼？哪一種會影響 bytecode 結構？
6. 函式解析為什麼一定要帶 `arg_count`？用 `count` 舉例說明。
7. `op_function` 的 `pager` 參數沒有底線前綴，這代表什麼？
8. 純量函式的引數為什麼用 `start_reg` + `arg_count` 表示，而不是一個位置列表？
9. 聚合的累加器為什麼要惰性初始化？和 `GROUP BY` 有什麼關係？
10. `Register::Aggregate` 存的是什麼？為什麼 `avg` 不能只用一個數字表示狀態？
11. 視窗函式和聚合函式共用 `AggStep` 指令，它們的差別在哪裡？
12. 為什麼 `SelectPlan.window` 是 `Option` 而不是 `Vec`？多個視窗怎麼處理？

---

下一篇 `06a-source-code-learn-file-format-pages.md`：SQLite 的檔案格式、page 佈局、cell 結構、overflow chain。
