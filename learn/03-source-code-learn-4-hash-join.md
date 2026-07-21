# 03-4. 源碼精讀：Hash Join 與 Grace Hash Join

`03-source-code-learn-2-optimizer.md` 講 optimizer 時提過 `Operation::HashJoin`，但沒展開。本篇補上：**hash join 為什麼存在、如何編譯、以及記憶體不夠時怎麼辦**。

`core/translate/main_loop/hash.rs` 有 1461 行，是 `main_loop/` 目錄裡最大的檔案——比整個 `open.rs`（705 行）加 `close.rs`（560 行）還大。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 60–75 分鐘（約 15k 字，其中 37% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/translate/plan.rs              HashJoinOp / HashJoinType ── 計畫層的描述
core/translate/main_loop/hash.rs    編譯：build 階段、probe 階段、grace 階段
core/vdbe/insn.rs                   Hash* 指令家族（16 條）
```

---

## 為什麼需要 hash join

`03-source-code-learn-2-optimizer.md` 講的成本模型裡，nested loop join 的成本是：

```text
外層列數 × 內層每次掃描的成本
```

如果內層有 index，每次是一次 seek（便宜）。**但如果沒有可用的 index 呢？**

```sql
SELECT * FROM a JOIN b ON a.x = b.y   -- b.y 沒有 index
```

nested loop 要對 a 的每一列全表掃描 b。a 有 1 萬列、b 有 1 萬列，就是 1 億次比較。

**hash join 把它變成兩次掃描**：

1. **Build**：掃一次 b，把每列依 `b.y` 的雜湊值放進 hash table。
2. **Probe**：掃一次 a，用 `a.x` 的雜湊值直接查表。

成本從 O(n×m) 降到 O(n+m)。代價是**要有記憶體放 hash table**——這就是後面 grace hash join 要解決的問題。

---

## 計畫層：HashJoinOp

**`core/translate/plan.rs:2088-2106`** — 完整貼出：

```rust
/// Hash join operation metadata
#[derive(Debug, Clone)]
pub struct HashJoinOp {
    /// Index of the build table in the join order
    pub build_table_idx: usize,
    /// Index of the probe table in the join order
    pub probe_table_idx: usize,
    /// Join key references, each entry points to an equality condition in the [WhereTerm]
    /// and indicates which side of the equality belongs to the build table.
    pub join_keys: Vec<HashJoinKey>,
    /// Memory budget for hash table
    pub mem_budget: usize,
    /// Whether the build input should be materialized as a rowid list before hash build.
    pub materialize_build_input: bool,
    /// Whether to use a bloom filter on the probe side.
    pub use_bloom_filter: bool,
    /// Join semantics (inner, left outer, or full outer).
    pub join_type: HashJoinType,
}
```

幾個欄位值得展開。

**`build_table_idx` / `probe_table_idx`** —— 哪一邊建表、哪一邊探測。**這是 optimizer 的決定**，而且很關鍵：hash table 要放在記憶體裡，所以**應該用小的那一邊 build**。選錯邊會讓記憶體爆掉或觸發 grace 溢出。

**`join_keys: Vec<HashJoinKey>`** —— 注意是 `Vec`，支援複合鍵（`ON a.x = b.y AND a.z = b.w`）。註解說每個項目「指向 `WhereTerm` 裡的一個等值條件，並標示哪一側屬於 build table」。

**這回頭連上 `03-source-code-learn-2-optimizer.md` 講的 `Constraint.where_clause_pos`**：同樣是「記住這個條件來自哪個 WHERE term」，因為條件被 hash join 吸收後就不必再當過濾條件求值。

**`mem_budget`** —— 記憶體預算。超過就要溢出到磁碟。

**`materialize_build_input`** —— 是否先把 build 側**物化成 rowid 列表**再建 hash table。為什麼需要這一步？因為 build 側可能是一個複雜的子查詢或有過濾條件的掃描；先物化可以避免重複計算，也讓後續的 grace 分割更容易。

**`use_bloom_filter`** —— 這是重要的最佳化，下面詳談。

### 三種 join 語義

**`core/translate/plan.rs:2079-2086`** — 完整貼出：

```rust
pub enum HashJoinType {
    /// Only matching rows emitted.
    Inner,
    /// All build rows appear; unmatched build rows get NULLs for the probe side.
    LeftOuter,
    /// Like LeftOuter, plus unmatched probe rows get NULLs for the build side.
    FullOuter,
}
```

**注意 `LeftOuter` 的定義方向**：「**所有 build 列都會出現**，沒配到的 build 列在 probe 側補 NULL」。

這和直覺可能相反。SQL 的 `a LEFT JOIN b` 是「a 的每列都出現」，但在 hash join 裡，a 可能是 build 側也可能是 probe 側——**optimizer 可以把 build/probe 反過來**（因為小表當 build 比較好）。所以 `HashJoinType` 描述的是「相對於 build/probe 角色」的語義，不是「相對於 SQL 左右」的語義。

**這是編譯器內部表示與 SQL 語法脫鉤的例子**，和 `03-source-code-learn-1-planner.md` 講的 `join_order` 與使用者寫的順序脫鉤是同一種思路。

實作上，「所有 build 列都要出現」需要額外機制：**記錄哪些 build 列被配對過**，probe 結束後把沒配到的掃出來。這對應下面會看到的 `HashMarkMatched` / `HashScanUnmatched` 指令。

---

## 指令家族：16 條 Hash* 指令

**`core/vdbe/insn.rs:1827-1954`** — 指令名稱一覽：

```rust
    HashBuild {              // :1827  把一列加進 hash table
    HashDistinct {           // :1832  去重用的變體
    HashBuildFinalize {      // :1838  build 完成，準備 probe
    HashProbe {              // :1849  用 key 查表
    HashNext {               // :1871  同一個 key 的下一個匹配
    HashClose {              // :1883
    HashClear {              // :1888
    HashMarkMatched {        // :1893  標記這個 build 列配對過（OUTER JOIN）
    HashResetMatched {       // :1900
    HashScanUnmatched {      // :1907  掃出沒配對的 build 列
    HashNextUnmatched {      // :1918
    HashGraceInit {          // :1929  以下五條是 grace hash join
    HashGraceLoadPartition { // :1936
    HashGraceNextProbe {     // :1944
    HashGraceAdvancePartition { // :1954
```

**16 條指令分成四組**：

| 組別 | 指令 | 用途 |
|---|---|---|
| 建表 | `HashBuild`、`HashDistinct`、`HashBuildFinalize` | build 階段 |
| 探測 | `HashProbe`、`HashNext` | probe 階段 |
| OUTER | `HashMarkMatched`、`HashResetMatched`、`HashScanUnmatched`、`HashNextUnmatched` | 未配對列的處理 |
| Grace | `HashGrace*` 五條 | 記憶體不足時的磁碟分割 |

**`HashNext` 的存在說明 hash join 要處理「一對多」**：同一個 key 可能有多個 build 列（join key 不唯一），所以 probe 到之後要能迭代所有匹配。這和 `Next` 之於 B-tree cursor 是同樣的角色。

---

## Build 階段的配置

**`core/translate/main_loop/hash.rs:37-49`** — 完整貼出：

```rust
/// Static configuration for a fresh hash-table build.
struct HashBuildConfig {
    payload_columns: Vec<MaterializedColumnRef>,
    payload_signature_columns: ColumnUsedMask,
    key_affinities: String,
    collations: Vec<CollationSeq>,
    use_bloom_filter: bool,
    bloom_filter_cursor_id: CursorID,
    materialized_cursor_id: Option<CursorID>,
    use_materialized_keys: bool,
    allow_seek: bool,
    signature: HashBuildSignature,
}
```

三組欄位。

**`payload_columns` / `payload_signature_columns`** —— hash table 裡要存哪些欄位。**只存查詢真的會用到的欄位**，不是整列——`ColumnUsedMask` 就是這個過濾。

為什麼重要？hash table 在記憶體裡，每列少存幾個欄位，就能多裝幾列，也就更不容易觸發 grace 溢出。

**`key_affinities: String` / `collations`** —— 這兩個是**正確性關鍵**。

`05-source-code-learn-schema-values-records.md` 講過 affinity：比較之前要先做型別轉換。hash join 的比較是「雜湊值相等」加「實際值相等」，**兩者都必須套用和 nested loop 相同的 affinity 與 collation 規則**，否則同一個查詢用 hash join 和用 nested loop 會得到不同結果。

`key_affinities` 是 `String` 而非 `Vec<Affinity>`——因為它直接對應 `04-source-code-learn-1-insn-dispatch.md` 看過的那個字元編碼（`'A'`~`'E'`），要塞進指令的 p4 參數。

**`use_bloom_filter` / `bloom_filter_cursor_id`** —— 下一節。

**`signature: HashBuildSignature`** —— 這個欄位配合下面的重用機制。

---

## Bloom filter：便宜的預先排除

`04-source-code-learn-2-cursor-opcodes.md` 講 `op_rewind` 時提過 bloom filter 要清除，當時說「用在 join 最佳化」。這裡是它的來源。

**運作方式**：build 階段除了建 hash table，還建一個 bloom filter（一個位元陣列，記錄「這些 key 的雜湊出現過」）。

probe 階段先查 bloom filter：

- **filter 說「沒有」** → 一定沒有，直接跳過，**不用查 hash table**。
- **filter 說「可能有」** → 再查 hash table 確認。

bloom filter 有偽陽性但**沒有偽陰性**——說沒有就一定沒有。

**為什麼值得多一層？** 因為 bloom filter 極小（幾 KB），能整個放進 CPU cache；hash table 可能有幾百 MB，每次查詢都是一次 cache miss 甚至 page fault。

當多數 probe 列**配不到**任何 build 列時（選擇性高的 join），bloom filter 能擋掉絕大多數的 hash table 查詢。

這也解釋了 `04-source-code-learn-2-cursor-opcodes.md` 那段程式碼為什麼是正確性問題：

```rust
    // Clear any bloom filter associated with this cursor so stale filter data
    // does not incorrectly reject valid matches in subsequent iterations.
    if let Some(filter) = state.get_bloom_filter_mut(*cursor_id) {
        filter.clear();
    }
```

**bloom filter 的「說沒有就一定沒有」保證，只在它對應當前的 build 集合時成立。** 如果 cursor 被 rewind（進入新一輪的外層迴圈），build 側可能已經換了內容，舊 filter 就會**錯誤地排除有效的匹配**——查詢少回傳資料。

---

## Hash build 的重用

**`core/translate/main_loop/hash.rs:51-80`** — 完整貼出：

```rust
/// Typestate entry point for hash-build planning.
///
/// Planning decides whether an existing hash build can be reused and, if not,
/// captures all configuration needed to emit a fresh build deterministically.
pub(crate) struct HashBuildPlanner<'a, 'plan> {
    program: &'a mut ProgramBuilder,
    t_ctx: &'a mut TranslateCtx<'plan>,
    table_references: &'a TableReferences,
    non_from_clause_subqueries: &'a [NonFromClauseSubquery],
    predicates: &'a [WhereTerm],
    hash_join_op: &'a HashJoinOp,
    hash_build_cursor_id: CursorID,
    hash_table_id: usize,
}

/// A planned hash build whose signature check has already completed.
pub(super) struct PreparedHashBuild<'a, 'plan> {
    planner: HashBuildPlanner<'a, 'plan>,
    config: HashBuildConfig,
}

/// Result of hash-build planning.
///
/// Reuse means the caller can immediately probe an existing compatible hash
/// table. Build means the caller must execute the prepared build before probing.
pub(super) enum HashBuildPlan<'a, 'plan> {
    Reuse(HashBuildPayloadInfo),
    Build(Box<PreparedHashBuild<'a, 'plan>>),
}
```

**「Typestate」這個詞是關鍵。**

Typestate pattern 是用**型別**來表達「物件處於哪個階段」。這裡：

- `HashBuildPlanner` —— 尚未決定要不要重用。
- `PreparedHashBuild` —— 已經檢查完 signature，確定要建新的。
- `HashBuildPlan::Reuse` / `Build` —— 決定的結果。

**好處是「未檢查就建表」在型別上不可能發生**——你手上只有 `HashBuildPlanner` 時，根本沒有 emit 的方法可以呼叫。編譯器強制了正確的順序。

**為什麼需要重用機制？** 考慮三表 join：

```sql
SELECT * FROM a JOIN b ON a.x = b.x JOIN c ON c.x = b.x
```

如果 b 是 build 側，而 a 和 c 都用同一個 key 探測 b，**那個 hash table 可以共用**——不必建兩次。

`HashBuildSignature` 就是判斷「兩次 build 是否等價」的依據：同一張表、同樣的 join key、同樣的過濾條件、同樣的 payload 欄位。

**`Box<PreparedHashBuild>`** —— 又是 `Box`。和 `03-source-code-learn-1-planner.md` 講的 `ProgramBuilder`、`TranslateCtx` 一樣，避免大 struct 佔用遞迴編譯的 stack frame。

---

## Grace Hash Join：記憶體不夠時

如果 build 側裝不進 `mem_budget` 呢？不能直接失敗——資料庫必須能處理超過記憶體的資料。

**解法是 Grace Hash Join**（名字來自 1980 年代日本的 GRACE 資料庫機）：

```text
1. build 時發現記憶體不足
2. 依 join key 的雜湊值把 build 資料分成 N 個 partition，寫到磁碟
3. probe 時，probe 列也依同樣的雜湊分到 N 個 partition，寫到磁碟
4. 逐一處理每個 partition：
     載入 partition i 的 build 資料到記憶體（現在夠小了）
     用 partition i 的 probe 資料探測
```

**關鍵洞見**：如果 `hash(key)` 相同的列都在同一個 partition，那麼**跨 partition 的列絕不可能配對**。所以可以一個 partition 一個 partition 處理，每次只需要 1/N 的記憶體。

### 編譯後的控制流

**`core/translate/main_loop/hash.rs:1192-1215`** — 完整貼出：

```rust
/// Grace Hash Join processing loop after the probe cursor is exhausted.
pub(crate) struct GraceHashLoop;

impl GraceHashLoop {
    /// Emit VDBE-driven grace hash join processing loop.
    /// Uses the shared inner body via `Goto match_found_label` and `grace_flag_reg`
    /// dispatch so that aggregates, LIMIT, ORDER BY, etc. all work naturally.
    /// At runtime, HashGraceInit is a no-op if the build side didn't spill.
    pub fn emit<'a>(
        program: &mut ProgramBuilder,
        t_ctx: &mut TranslateCtx<'a>,
        hash_join_op: &HashJoinOp,
        hash_ctx: &HashCtx,
        select_plan: Option<&'a SelectPlan>,
        table_index: usize,
        probe_cursor_id: CursorID,
    ) -> Result<()> {
        // Need grace_flag_reg + probe_rowid_reg for grace processing
        let Some(probe_rowid_reg) = hash_ctx.probe_rowid_reg else {
            return Ok(());
        };
        let Some(grace_flag_reg) = hash_ctx.grace_flag_reg else {
            return Ok(());
        };
```

那段註解揭露了兩個重要的設計決定。

**一、共用迴圈體。**

> Uses the shared inner body via `Goto match_found_label` and `grace_flag_reg` dispatch so that aggregates, LIMIT, ORDER BY, etc. all work naturally.

grace 階段產生的配對列，和一般 probe 階段產生的配對列，**走同一段迴圈體程式碼**（`03-source-code-learn-3-emitter-dml-ddl.md` 講的 `emit_loop`）。

用 `Goto` 跳進去、用 `grace_flag_reg` 記錄「我是從 grace 路徑來的」以便正確返回。

**如果不共用會怎樣？** 那些聚合、`LIMIT`、`ORDER BY`、`DISTINCT` 的邏輯就要**再實作一次**。兩份實作必然會漂移——某天有人修了一般路徑的 bug 卻忘了 grace 路徑，就出現「資料量小時對、大時錯」的經典症狀（`09-source-code-learn-reading-projects.md` 講過這個症狀通常指向重入 bug，這裡是另一個成因）。

**二、執行期才知道要不要 grace。**

> At runtime, `HashGraceInit` is a **no-op if the build side didn't spill**.

編譯期**無法知道** build 側會不會超過記憶體預算——那取決於實際資料量。

所以編譯器**總是**產生 grace 處理的 bytecode，執行期由 `HashGraceInit` 判斷：沒溢出就什麼都不做，整段被跳過。

**這是「編譯期不確定性」的標準處理方式**：產生兩條路徑的程式碼，執行期選一條。代價是 bytecode 變長（多了五條指令與相關跳轉），好處是不需要在執行到一半時重新編譯。

那兩個 `let Some(...) else { return Ok(()) }` 則是防禦：如果 planner 沒有配置 grace 需要的 register，就不產生這段程式碼——代表這個 join 從一開始就不可能 grace（例如 build 側是常數大小）。

---

## 完整的執行流程

```text
【Build 階段】
  Rewind build cursor
  loop:
    讀取 payload 欄位
    HashBuild        → 加進 hash table（同時更新 bloom filter）
                       記憶體超過 mem_budget → 溢出成磁碟 partition
    Next
  HashBuildFinalize  → build 完成

【Probe 階段】
  Rewind probe cursor
  loop:
    算 join key
    bloom filter 檢查 → 沒有就跳過（省下 hash table 查詢）
    HashProbe        → 查表
    loop:
      HashMarkMatched  → 標記這個 build 列配對過（OUTER JOIN 才需要）
      <共用的迴圈體：過濾、算結果、輸出>
      HashNext         → 同一個 key 的下一個匹配
    Next

【Grace 階段】（只在溢出時執行）
  HashGraceInit          → 沒溢出就是 no-op
  loop over partitions:
    HashGraceLoadPartition   → 載入這個 partition 的 build 資料
    loop:
      HashGraceNextProbe     → 這個 partition 的下一個 probe 列
      HashProbe / HashNext
      Goto match_found_label → 跳回共用的迴圈體
    HashGraceAdvancePartition

【OUTER JOIN 收尾】（只在 LeftOuter / FullOuter）
  HashScanUnmatched    → 掃出沒被 HashMarkMatched 標記的 build 列
  loop:
    輸出（probe 側補 NULL）
    HashNextUnmatched
```

---

## 何時該用 hash join

回到 `03-source-code-learn-2-optimizer.md` 的成本模型。optimizer 選 hash join 的條件大致是：

| 情況 | 傾向 |
|---|---|
| join 條件是等值（`a.x = b.y`） | hash join 可用（**不等值完全不能用**） |
| 內層沒有可用的 index | 傾向 hash join |
| build 側小（放得進記憶體） | 傾向 hash join |
| 外層列數少 | 傾向 nested loop（build 的固定成本划不來） |
| 需要保持順序 | 傾向 nested loop + index（hash join 破壞順序） |

**最後一項容易被忽略**：hash join 的輸出順序是任意的。如果查詢有 `ORDER BY` 而某個 index 能提供天然順序，nested loop + index 可能總成本更低——因為省掉了排序（`03-source-code-learn-2-optimizer.md` 講的 `best_ordered_plan`）。

而 `cache_reuse_factor` 那個參數（同一篇）就是在平衡這件事：如果沒有快取折扣，optimizer 會系統性地高估 nested loop 的成本，過度偏向 hash join。

---

## 動手驗證

看 hash join 被選中：

```bash
cd /Users/stanhsu/projects/turso
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE a(id INTEGER PRIMARY KEY, x INTEGER);
CREATE TABLE b(id INTEGER PRIMARY KEY, y INTEGER);
INSERT INTO a SELECT value, value % 100 FROM generate_series(1, 5000);
INSERT INTO b SELECT value, value % 100 FROM generate_series(1, 5000);

EXPLAIN QUERY PLAN SELECT count(*) FROM a JOIN b ON a.x = b.y;
EXPLAIN SELECT count(*) FROM a JOIN b ON a.x = b.y;
```

兩張表都沒有 `x`/`y` 的 index，所以 nested loop 要 2500 萬次比較——optimizer 應該選 hash join。EXPLAIN 裡找 `HashBuild`、`HashProbe`、`HashNext`。

看 index 讓 optimizer 改變決定：

```sql
CREATE INDEX b_y ON b(y);
EXPLAIN SELECT count(*) FROM a JOIN b ON a.x = b.y;
```

有了 index，nested loop + index seek 可能更便宜（尤其 build 的固定成本省下來）。

看不等值 join 不能用 hash：

```sql
EXPLAIN SELECT count(*) FROM a JOIN b ON a.x > b.y;
```

一定是 nested loop——雜湊只能加速等值比較。

追 source：

```bash
rg -n "pub struct HashJoinOp|pub enum HashJoinType" core/translate/plan.rs
rg -n "struct HashBuildConfig|struct HashBuildPlanner|enum HashBuildPlan|struct GraceHashLoop" core/translate/main_loop/hash.rs
rg -n "Hash[A-Za-z]+ \{" core/vdbe/insn.rs
```

---

## 自我檢查

1. hash join 把 nested loop 的 O(n×m) 降到什麼？代價是什麼？
2. optimizer 應該選哪一邊當 build 側？選錯會怎樣？
3. `HashJoinType::LeftOuter` 的「所有 build 列都出現」為什麼和 SQL 的 `a LEFT JOIN b` 語義不是直接對應？
4. `payload_columns` 為什麼只存查詢用到的欄位？這影響什麼？
5. `key_affinities` 和 `collations` 為什麼是正確性關鍵而非效能考量？
6. bloom filter 有偽陽性但沒有偽陰性。這個性質為什麼讓它可以當「預先排除」用？
7. bloom filter 極小卻能大幅加速，關鍵原因是什麼（提示：CPU cache）？
8. `op_rewind` 沒清 bloom filter 會產生什麼錯誤？是效能問題還是正確性問題？
9. 什麼是 Typestate pattern？`HashBuildPlanner` → `PreparedHashBuild` 這個轉換防止了什麼錯誤？
10. 三表 join 時 hash table 什麼情況可以重用？`HashBuildSignature` 要比對什麼？
11. Grace hash join 的核心洞見是什麼？為什麼「跨 partition 的列絕不可能配對」？
12. grace 階段為什麼要用 `Goto` 跳回共用的迴圈體，而不是自己實作一份？不共用會出現什麼經典症狀？
13. 為什麼編譯器總是產生 grace 的 bytecode，即使多數情況用不到？
14. `HashMarkMatched` 和 `HashScanUnmatched` 是為了支援什麼？
15. `ORDER BY` 存在時，為什麼 optimizer 可能寧願選 nested loop + index？
16. 不等值 join（`a.x > b.y`）為什麼不能用 hash join？

---

本篇是 03 章的**進階補充**——hash join 不在「一條 SQL 的最短路徑」上，第一輪可以跳過。

按 README 的順序，接下來是 `04-source-code-learn-1-insn-dispatch.md`：VDBE 的指令集結構與分派機制。

如果你是為了 join 才讀到這裡，相關的延伸是 `03-source-code-learn-2-optimizer.md`（optimizer 何時選擇 hash join，以及 `cache_reuse_factor` 如何影響它與 nested loop 的取捨）。
