# 03-3. 源碼精讀：Emitter 的迴圈骨架與 DML/DDL 編譯

`03-source-code-learn-1-planner.md` 講了 AST → Plan，`03-source-code-learn-2-optimizer.md` 講了 optimizer 如何選 index 與 join order。本篇是編譯的最後一段：**Plan 如何變成一連串 `Insn`**，以及 SELECT 以外的語句怎麼編譯。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 60–75 分鐘（約 15k 字，其中 39% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/translate/main_loop/       迴圈骨架的四個階段
  ├─ init.rs   InitLoop    開 cursor、迴圈前的準備
  ├─ open.rs   OpenLoop    每張表的定位（Rewind 或 Seek）
  ├─ body.rs   emit_loop   迴圈內部：過濾、算結果
  └─ close.rs  CloseLoop   Next 與跳回
core/translate/emitter/
  ├─ mod.rs     OperationMode ── 同一套骨架服務四種語句
  ├─ update.rs  UPDATE（2636 行，最複雜）
  └─ delete.rs  DELETE
```

**本篇的核心觀念**：SELECT、INSERT、UPDATE、DELETE **共用同一套迴圈骨架**。差別只在迴圈內部做什麼。

---

## 迴圈骨架的四個階段

`01-source-code-learn-4-step-vm.md` 看過的那份 EXPLAIN：

```text
1     OpenRead           0     2     0        ← InitLoop
2     Rewind             0     6     0        ← OpenLoop
3       Column           0     1     1        ← body
4       ResultRow        1     1     0        ← body
5     Next               0     3     0        ← CloseLoop
6     Halt               0     0     0
```

**bytecode 的形狀直接對應 emitter 的四個函式。** 現在逐個看。

### InitLoop：迴圈前的準備

**`core/translate/main_loop/init.rs:32-48`** — 完整貼出（註解說明職責）：

```rust
/// First step of Loop emission, opens cursors for all tables and initializes distinct aggregate
/// hash tables. Also emits condition checks for any WHERE clause terms that need to be evaluated
/// before the loop (e.g. those that reference only tables that are on the outermost level of the
/// join order).
pub struct InitLoop;
impl InitLoop {
    #[allow(clippy::too_many_arguments)]
    pub fn emit<'a>(
        program: &mut ProgramBuilder,
        t_ctx: &mut TranslateCtx<'a>,
        tables: &TableReferences,
        aggregates: &mut [Aggregate],
        mode: &OperationMode,
        where_clause: &[WhereTerm],
        join_order: &[JoinOrderMember],
        subqueries: &mut [NonFromClauseSubquery],
    ) -> Result<()> {
```

註解裡最後那句是 `03-source-code-learn-2-optimizer.md` 講的 predicate pushdown 的**最終落點**：

> Also emits condition checks for any WHERE clause terms that need to be evaluated **before the loop**

如果一個條件只依賴最外層的表（甚至完全不依賴任何表，例如 `WHERE 1=0`），就在迴圈**開始前**求值一次。不成立就直接跳過整個迴圈——連一列都不用掃。

**`core/translate/main_loop/init.rs:49-54`** — 一個斷言：

```rust
        turso_assert_eq!(
            t_ctx.meta_left_joins.len(),
            tables.joined_tables().len(),
            "meta_left_joins length must match tables length"
        );
```

用斷言檢查兩個平行陣列長度一致。這符合專案原則：**斷言不變量，不要靜默容錯**。如果長度不符，後面用索引存取就會拿到錯誤的 metadata——與其產生難以追查的錯誤 bytecode，不如立刻爆。

**`core/translate/main_loop/init.rs:55-70`** — 完整貼出：

```rust
        if matches!(
            &mode,
            OperationMode::INSERT | OperationMode::UPDATE { .. } | OperationMode::DELETE
        ) {
            turso_assert_eq!(tables.joined_tables().len(), 1);
            let changed_table = &tables.joined_tables()[0].table;
            let prepared = prepare_cdc_if_necessary(
                program,
                t_ctx.resolver.schema(),
                Some(changed_table.get_name()),
            )?;
            if let Some((cdc_cursor_id, _)) = prepared {
                t_ctx.cdc_cursor_id = Some(cdc_cursor_id);
            }
        }
```

**這段揭露了兩件事。**

第一，`turso_assert_eq!(tables.joined_tables().len(), 1)` —— **DML 語句只能有一張目標表**。SQL 的 `UPDATE t SET ... FROM other` 語法裡，`other` 是資料來源不是目標；真正被修改的永遠只有一張。

第二，**CDC（Change Data Capture）在這裡掛勾**。如果啟用了變更擷取，DML 會額外開一個 cursor 寫入變更記錄。這是 sync engine 的基礎之一（`08-source-code-learn-extensions-sync-testing.md`）。

**`core/translate/main_loop/init.rs:72-80`** — 另一個值得看的細節：

```rust
        // Evaluate + range-check percentile direct arguments once, pre-loop.
        // Doing this before the row loop opens means an out-of-range fraction
        // halts the program regardless of how many rows reach the aggregate
        // body (including empty / all-NULL / all-filtered input), matching PG.
        for agg in aggregates
            .iter_mut()
            .filter(|a| matches!(a.func, AggFunc::PercentileCont | AggFunc::PercentileDisc))
        {
            emit_percentile_fraction_check(program, tables, &t_ctx.resolver, agg)?;
        }
```

`percentile(x, 1.5)` 的 `1.5` 超出 [0,1] 範圍，應該報錯。但**如果表是空的呢**？

如果檢查放在迴圈裡，空表就不會執行到，錯誤不會被報出來。放在迴圈前，**無論有幾列都會報錯**——註解說這是為了對齊 PostgreSQL 的行為。

**這是「什麼時候檢查」影響語義的例子**，不只是效能問題。

### OpenLoop：每張表的定位

**`core/translate/main_loop/open.rs:44-60`** — 完整貼出：

```rust
/// Opens the main loop for each table in the join order, emitting instructions to initialize
/// cursors and perform index seeks as necessary.
pub struct OpenLoop;

impl OpenLoop {
    #[allow(clippy::too_many_arguments)]
    pub fn emit(
        program: &mut ProgramBuilder,
        t_ctx: &mut TranslateCtx,
        table_references: &TableReferences,
        join_order: &[JoinOrderMember],
        predicates: &[WhereTerm],
        temp_cursor_id: Option<CursorID>,
        mode: OperationMode,
        subqueries: &mut [NonFromClauseSubquery],
    ) -> Result<()> {
        let live_table_ids: HashSet<_> = join_order.iter().map(|member| member.table_id).collect();
        for (join_index, join) in join_order.iter().enumerate() {
```

**依 `join_order` 逐張表產生巢狀迴圈。** 注意它走的是 optimizer 決定的順序，不是使用者寫的順序（`03-source-code-learn-2-optimizer.md`）。

每張表依它的 `Operation` 產生不同指令：

| Plan 裡的 Operation | 產生的指令 |
|---|---|
| `Scan` | `Rewind` |
| `Search(RowidEq)` | `SeekRowid`（無迴圈） |
| `Search(Seek)` | `SeekGE`/`SeekGT` + 邊界檢查 |
| `Search(InSeek)` | 臨時 B-tree 迴圈 + 內層 seek |
| `HashJoin` | 探測 hash table |

**`core/translate/main_loop/open.rs:61-67`** — 每張表的三個 label：

```rust
            let LoopLabels {
                loop_start,
                loop_end,
                next,
            } = *t_ctx
                .labels_main_loop
                .get(joined_table_index)
                .expect("table has no loop labels");
```

三個 label 對應迴圈的三個位置。`03-source-code-learn-1-planner.md` 講過 label／回填機制——這裡 `OpenLoop` 用到它們，但真正的位址要等 `CloseLoop` 才確定。

**`core/translate/main_loop/open.rs:69-85`** — 一個真實的複雜度：

```rust
            // For chained anti-joins (e.g. NOT EXISTS t2 AND NOT EXISTS t3),
            // when anti-join N exhausts without a match, execution should continue
            // to anti-join N+1's open_loop (not jump to the body). Resolve the
            // previous anti-join's label_body to the current program offset.
            if join_index > 0 {
                let prev_table_idx = join_order[join_index - 1].original_idx;
                let prev_is_anti = table_references.joined_tables()[prev_table_idx]
                    .join_info
                    .as_ref()
                    .is_some_and(|ji| ji.is_anti());
                if prev_is_anti {
                    if let Some(prev_sa_meta) = t_ctx.meta_semi_anti_joins[prev_table_idx].as_ref()
                    {
                        program.preassign_label_to_next_insn(prev_sa_meta.label_body);
                    }
                }
            }
```

**anti-join 的控制流是反的。** 一般 join 是「找到匹配就進入 body」；anti-join（`NOT EXISTS`）是「**沒找到**匹配才進入 body」。

所以連續兩個 anti-join 時，第一個掃完沒找到匹配，不該直接跳到 body，而該繼續檢查第二個 anti-join。這段程式碼就是把前一個 anti-join 的 `label_body` 回填到「當前位置」，也就是下一個 anti-join 的起點。

**這種 label 回填的時機錯誤，會產生控制流錯誤的 bytecode**——查詢不會 crash，只會回傳錯誤結果。這類 bug 極難查，所以註解寫得特別詳細。

### body：迴圈內部

**`core/translate/main_loop/body.rs:26-33`** — 完整貼出：

```rust
/// Emits the bytecode for the inner loop of a query.
/// At this point the cursors for all tables have been opened and rewound.
pub fn emit_loop<'a>(
    program: &mut ProgramBuilder,
    t_ctx: &mut TranslateCtx<'a>,
    plan: &'a SelectPlan,
) -> Result<()> {
    LoopBodyEmitter::emit(program, t_ctx, plan)
}
```

**`core/translate/main_loop/body.rs:36-44`** — 一個關於順序的警告：

```rust
/// Emits the select-loop body.
pub struct LoopBodyEmitter;

/// Internal state for loop-body emission.
///
/// The body has one non-obvious ordering rule: anti-join body entry must be
/// resolved before any body instructions are emitted, otherwise relocated
/// constants can make the backward jump land incorrectly.
struct LoopBody<'prog, 'ctx, 'plan> {
```

> anti-join body entry must be resolved before any body instructions are emitted, otherwise **relocated constants** can make the backward jump land incorrectly.

**"relocated constants" 指的是 `03-source-code-learn-1-planner.md` 講的常數摺疊機制**：常數指令會被搬到程式尾端的初始化區（`emit_constant_insns`）。

搬動指令會改變位址。如果 label 在搬動**之後**才解析，它記錄的位址可能已經失效——向後跳轉就會落在錯誤的地方。

**這是「最佳化與程式碼產生互相干擾」的實例**。註解特別標為 "non-obvious"，因為讀程式碼時完全看不出這個順序有什麼特別。

body 內部做的事，依 `03-source-code-learn-1-planner.md` 看過的 `LoopBodyEmitter` 目標分類：

```rust
    OrderBySorter,
    AggStep,
    Window,
    QueryResult,
```

四種去向：寫進排序器、餵給聚合、餵給視窗函式、或直接輸出成結果列。這對應 `SelectPlan.query_destination`。

### CloseLoop：反序關閉

**`core/translate/main_loop/close.rs:6-31`** — 完整貼出：

```rust
/// Represents final step of Loop emission
pub struct CloseLoop;

impl CloseLoop {
    pub fn emit<'a>(
        program: &mut ProgramBuilder,
        t_ctx: &mut TranslateCtx<'a>,
        tables: &TableReferences,
        join_order: &[JoinOrderMember],
        mode: OperationMode,
        select_plan: Option<&'a SelectPlan>,
    ) -> Result<()> {
        // We close the loops for all tables in reverse order, i.e. innermost first.
        // OPEN t1
        //   OPEN t2
        //     OPEN t3
        //       <do stuff>
        //     CLOSE t3
        //   CLOSE t2
        // CLOSE t1
        for join in join_order.iter().rev() {
```

註解裡那張圖說明了一切：**巢狀迴圈必須反序關閉**。`join_order.iter().rev()` 就是這個。

每次 close 產生一條 `Next`（跳回該層的 `loop_start`）並解析 `loop_end` label。

**`core/translate/main_loop/close.rs:33-40`** — semi/anti-join 的特殊處理：

```rust
            // SEMI/ANTI-JOIN: emit Goto -> outer_next right after the body.
            // For semi-join: after body runs (one match found), skip inner's Next.
            // For anti-join: after body runs (inner exhausted), move to next outer row.
            let is_semi_or_anti = table
                .join_info
                .as_ref()
                .is_some_and(|ji| ji.is_semi_or_anti());
```

**semi-join（`EXISTS`）找到一個匹配就該停止內層迴圈**——它只問「有沒有」，不需要找出全部。所以 body 執行完要直接跳到外層的 `Next`，跳過內層的 `Next`。

這是一個實質的最佳化：`WHERE EXISTS (SELECT ... FROM big)` 只要找到第一筆就結束，不用掃完 big。

---

## OperationMode：一套骨架，四種語句

**`core/translate/emitter/mod.rs:1040-1045`** — 完整貼出：

```rust
pub enum OperationMode {
    SELECT,
    INSERT,
    UPDATE(UpdateRowSource),
    DELETE,
}
```

**這五行是本篇最重要的設計。**

`InitLoop`、`OpenLoop`、`CloseLoop` 都接收 `mode` 參數。四種語句共用同一套迴圈產生邏輯，只在需要時分支。

為什麼可以共用？因為它們的骨架完全一樣：

```text
SELECT: 開 cursor → 定位 → [讀取、過濾、輸出] → 前進
DELETE: 開 cursor → 定位 → [讀取、過濾、刪除] → 前進
UPDATE: 開 cursor → 定位 → [讀取、過濾、寫入] → 前進
INSERT INTO ... SELECT: 開來源 cursor → 定位 → [讀取、寫入目標] → 前進
```

**只有中括號裡的部分不同。**

`UPDATE(UpdateRowSource)` 帶了額外資料，因為 UPDATE 有兩種資料來源：直接掃描目標表，或是先把要改的 rowid 收集到臨時儲存再處理（避免修改正在掃描的 B-tree——見下面）。

---

## DML 的額外複雜度

`core/translate/emitter/update.rs` 有 **2636 行**，是 emitter 目錄裡最大的檔案，比 `select.rs`（999 行）大兩倍多。為什麼 UPDATE 比 SELECT 複雜這麼多？

### 一、Halloween Problem

修改正在掃描的 B-tree 是危險的。考慮：

```sql
UPDATE t SET x = x + 1 WHERE x < 100;
```

如果邊掃邊改：改完的列 `x` 變大，可能被移到 B-tree 的後面，然後**又被掃到一次**，再加一次……無限迴圈。

這是資料庫的經典問題（Halloween Problem，因為 1976 年萬聖節被發現而得名）。

解法是先把要改的 rowid 收集起來，掃描結束後再逐一修改——這就是 `UpdateRowSource` 存在的原因。什麼時候需要這樣做，取決於是否會改到掃描用的 index key。

### 二、索引維護

`09-source-code-learn-reading-projects.md` 的 INSERT 演練看過：一次 INSERT 產生兩次 B-tree 寫入（表 + 索引）。

UPDATE 更麻煩：改一個被索引的欄位，要**先刪除舊索引項，再插入新索引項**。順序不能反——如果先插後刪，中間狀態會有兩個索引項指向同一列，唯一性檢查會誤報衝突。

而且只有**真的改變的**索引才需要維護。改 `name` 不影響 `INDEX(age)`，重建它是浪費。

### 三、約束、trigger、外鍵

UPDATE 要檢查 NOT NULL、CHECK、UNIQUE、外鍵；要觸發 BEFORE/AFTER UPDATE trigger；trigger 裡的 `OLD.x` 和 `NEW.x` 都要能存取，所以舊值和新值必須同時在 register 裡。

外鍵的 `ON UPDATE CASCADE` 還會遞迴修改其他表——那是 `Insn::Program` 子程式（`04-source-code-learn-1-insn-dispatch.md` 提過）。

### 四、RETURNING

`UPDATE ... RETURNING *` 要回傳修改後的列。但修改和輸出不能同時做（又是 Halloween Problem 的變體），所以要用臨時儲存緩衝。

`01-source-code-learn-1-entry-api.md` 看過的 `Statement.has_returned_row` 欄位註解就提到這個機制：

```rust
    /// True once step() has returned Row for a write statement (INSERT/UPDATE/DELETE
    /// with RETURNING). With ephemeral-buffered RETURNING, the first Row proves all
    /// DML completed — only the scan-back remains.
```

**「第一個 Row 證明所有 DML 已完成，剩下的只是掃回緩衝」** —— 這個性質讓 statement 在被中途放棄時能正確決定要 commit 還是 rollback。

---

## DDL：編譯成 sqlite_schema 的寫入

DDL 的編譯在 `core/translate/schema.rs`。`09-source-code-learn-reading-projects.md` 已經用真實 EXPLAIN 完整拆解過 `CREATE TABLE`，這裡只回顧結構：

```text
CreateBtree    → 配置 root page
OpenWrite(1)   → 開啟 sqlite_schema
NewRowid       → 產生 schema 列的 rowid
String8 × 5    → type, name, tbl_name, rootpage, sql
MakeRecord     → 組成 record
Insert         → 寫入 sqlite_schema
SetCookie      → 更新 schema 版本
ParseSchema    → 更新記憶體 schema
```

**DDL 沒有迴圈骨架**——它不掃描任何表，只是往 `sqlite_schema` 寫一列並更新 metadata。所以它不走 `main_loop/`。

值得注意的是存進去的 SQL 是**正規化過的**（`02-source-code-learn-parser-and-ast.md` 講的 `ast/fmt.rs`），確保下次開啟資料庫時能重新解析。

---

## 各語句的編譯器位置速查

| 語句 | 計畫階段 | 產生指令階段 |
|---|---|---|
| SELECT | `translate/select.rs` | `emitter/select.rs` + `main_loop/` |
| INSERT | `translate/insert.rs` | 同檔（含 upsert 在 `upsert.rs`） |
| UPDATE | `translate/update.rs` | `emitter/update.rs`（2636 行） |
| DELETE | `translate/delete.rs` | `emitter/delete.rs` |
| CREATE/DROP | `translate/schema.rs` | 同檔 |
| ALTER TABLE | `translate/alter.rs` | 同檔 |
| trigger | `translate/trigger.rs`、`trigger_exec.rs` | 產生 `Insn::Program` 子程式 |
| 外鍵 | `translate/fkeys.rs` | 同上 |
| GROUP BY | `translate/group_by.rs` | 與 `main_loop/body.rs` 協作 |
| 視窗函式 | `translate/window.rs` | 同上 |
| ORDER BY | `translate/order_by.rs` | sorter 相關指令 |
| hash join | `main_loop/hash.rs`（1461 行） | 建表與探測 |

---

## 動手驗證

看四種語句共用同一套骨架：

```bash
cd /Users/stanhsu/projects/turso
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT);
CREATE INDEX t_a ON t(a);

EXPLAIN SELECT b FROM t WHERE a > 5;
EXPLAIN DELETE FROM t WHERE a > 5;
EXPLAIN UPDATE t SET b = 'x' WHERE a > 5;
```

三份輸出都應該有相同的骨架（開 cursor → seek → 迴圈 → Next），差別只在迴圈內部：第一個是 `ResultRow`，第二個是 `Delete`，第三個是讀舊值 + 索引維護 + `Insert`。

看 UPDATE 的索引維護：

```sql
EXPLAIN UPDATE t SET a = a + 1 WHERE id = 1;
```

因為改的是被索引的 `a`，你應該看到 `IdxDelete` 和 `IdxInsert` 成對出現。再試改不被索引的欄位：

```sql
EXPLAIN UPDATE t SET b = 'y' WHERE id = 1;
```

應該**沒有**索引維護指令——只有真的改到的索引才需要更新。

看 semi-join 的提早結束：

```sql
CREATE TABLE big(x INTEGER);
EXPLAIN SELECT * FROM t WHERE EXISTS (SELECT 1 FROM big WHERE big.x = t.a);
```

追 source：

```bash
rg -n "pub struct InitLoop|pub struct OpenLoop|pub struct CloseLoop" core/translate/main_loop/
rg -n "pub fn emit_loop" core/translate/main_loop/body.rs
rg -n "pub enum OperationMode" core/translate/emitter/mod.rs
wc -l core/translate/emitter/*.rs core/translate/main_loop/*.rs
```

---

## 自我檢查

1. bytecode 的四段形狀（開 cursor / 定位 / 迴圈體 / 前進）分別由哪四個 emitter 函式產生？
2. `InitLoop` 為什麼要在迴圈**前**求值某些 WHERE 條件？這對應 optimizer 的什麼機制？
3. DML 的 `turso_assert_eq!(tables.joined_tables().len(), 1)` 在斷言什麼？`UPDATE t SET ... FROM other` 的 `other` 算不算目標表？
4. percentile 的參數範圍檢查為什麼要放在迴圈前？表是空的時候差別是什麼？
5. `OpenLoop` 依照什麼順序產生巢狀迴圈？是使用者寫的順序嗎？
6. 連續兩個 anti-join 時，第一個掃完沒找到匹配該跳去哪？為什麼不是 body？
7. body 的「anti-join body entry 必須在任何 body 指令前解析」和常數摺疊有什麼關係？
8. `CloseLoop` 為什麼要用 `.rev()` 反序關閉？
9. semi-join 找到第一個匹配就跳出內層迴圈，這是什麼查詢的最佳化？
10. `OperationMode` 這個 enum 讓四種語句共用什麼？它們的差別集中在哪裡？
11. 什麼是 Halloween Problem？`UPDATE t SET x = x + 1 WHERE x < 100` 邊掃邊改會發生什麼？
12. UPDATE 維護索引時為什麼必須「先刪後插」而不能反過來？
13. 為什麼 `emitter/update.rs` 有 2636 行而 `select.rs` 只有 999 行？列出三個原因。
14. `RETURNING` 為什麼需要臨時緩衝？「第一個 Row 證明 DML 已完成」這個性質有什麼用？
15. DDL 為什麼不走 `main_loop/`？

---

下一篇 `04-source-code-learn-2-cursor-opcodes.md`：cursor 與 storage 類 opcode 的實作。
