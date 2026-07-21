# 14. 源碼精讀：確定性模擬器

`testing/simulator/` 有 13,639 行，是找出併發與 I/O bug 的主力工具。

前面的章節反覆提到它：`07b-source-code-learn-ioresult-reentry.md` 說重入 bug「一般測試抓不到」、`06c-source-code-learn-btree-balancing.md` 說 balancing 的 bug「不會立刻顯現」。本篇看模擬器如何解決這些問題。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 45–60 分鐘（約 12k 字，其中 30% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
testing/simulator/
  ├─ main.rs                    入口、種子管理、bugbase
  ├─ model/property.rs          Property ── 要驗證的不變量
  ├─ generation/property.rs     property → 具體 SQL（2,475 行）
  ├─ generation/plan.rs         互動計畫的生成
  ├─ runner/env.rs              模擬環境（1,720 行）
  ├─ runner/execution.rs        執行引擎
  ├─ runner/differential.rs     與 SQLite 對照
  ├─ runner/doublecheck.rs      重跑驗證
  └─ shrink/plan.rs             失敗案例最小化
```

---

## 問題：一般測試抓不到什麼

回顧前面章節指出的三類 bug：

**一、重入 bug**（`07b`）—— 只在 I/O 真的 yield 時出現。本機測試資料小、全在 cache，`read_page` 立刻回 `Done`，重入路徑根本沒被走到。

**二、併發 bug** —— 只在特定的交錯順序出現。手寫測試無法控制執行緒排程。

**三、崩潰恢復 bug** —— 只在特定時機斷電時出現。

這三者的共同點是：**bug 的觸發條件是「時機」而非「輸入」**。傳統測試控制輸入，但控制不了時機。

**模擬器的解法：把時機也變成可控的輸入。**

---

## 核心機制：確定性

`08-source-code-learn-extensions-sync-testing.md` 提過一個當時看似奇怪的設計——`VfsExtension` trait 裡有這兩個方法：

```rust
    fn generate_random_number(&self) -> i64 {
    fn get_current_time(&self) -> String {
```

**為什麼隨機數和時鐘要放在 I/O 抽象層？** 答案就在這裡。

模擬器提供自己的 `IO` 實作，控制**所有**不確定性來源：

| 不確定來源 | 模擬器如何控制 |
|---|---|
| I/O 完成時機 | 自己決定何時完成哪個 completion |
| 隨機數 | 從種子產生 |
| 時鐘 | 虛擬時間 |
| 執行緒排程 | 單執行緒 + 明確的協程切換 |
| I/O 失敗 | 依種子注入 |

**於是「同一個種子 → 同一次執行」完全成立。** 這是模擬器一切價值的基礎：

- 找到 bug 後可以**精確重現**。
- 修好之後可以**驗證真的修好了**（同一個種子不再失敗）。
- 可以**最小化**失敗案例（下面談）。

`06b-source-code-learn-btree-cursor-pager.md` 提過 core 裡有一個 `Date.now()` 之類的限制——這裡是那個限制的原因。

---

## Property：要驗證什麼

模擬器不是隨機亂打 SQL 然後看有沒有 crash。它驗證**具名的不變量**。

**`testing/simulator/model/property.rs:11-38`** — 完整貼出第一個：

```rust
pub enum Property {
    /// Insert-Select is a property in which the inserted row
    /// must be in the resulting rows of a select query that has a
    /// where clause that matches the inserted row.
    /// The execution of the property is as follows
    ///     INSERT INTO <t> VALUES (...)
    ///     I_0
    ///     I_1
    ///     ...
    ///     I_n
    ///     SELECT * FROM <t> WHERE <predicate>
    /// The interactions in the middle has the following constraints;
    /// - There will be no errors in the middle interactions.
    /// - The inserted row will not be deleted.
    /// - The inserted row will not be updated.
    /// - The table `t` will not be renamed, dropped, or altered.
    InsertValuesSelect {
        /// The insert query
        insert: Insert,
        /// Selected row index
        row_index: usize,
        /// Additional interactions in the middle of the property
        queries: Vec<Query>,
        /// The select query
        select: Select,
        /// Interactive query information if any
        interactive: Option<InteractiveQueryInfo>,
    },
```

**這個 property 的形狀值得細看。**

不變量是：「插入一列之後，只要沒有東西刪掉或改掉它，就一定能查回來」。

**關鍵是 `queries: Vec<Query>` 這個欄位** —— 中間可以插入**任意多條其他查詢**（註解裡的 `I_0` 到 `I_n`）。

這才是威力所在：不只測「插入後立刻查詢」，而是測「插入 → 做一堆別的事 → 查詢」。中間那些操作可能觸發 page 分裂、checkpoint、cache 逐出、WAL restart——**任何一個環節出錯都會讓那一列消失**。

註解列的四個約束是生成時的限制：中間的查詢不能刪掉/改掉那一列、不能動那張表。生成器必須確保產生的隨機查詢滿足這些條件，否則不變量本身就不成立。

第一個約束特別誠實：

> - There will be no errors in the middle interactions. (this constraint is impossible to check, so this is just best effort)

**「這個約束無法檢查，所以只是盡力而為」** —— 生成器沒辦法預知一條隨機查詢會不會出錯。這種誠實標註在測試工具裡很重要，它告訴你這個 property 的可信度邊界。

### 第二個 property：驗證回滾

**`testing/simulator/model/property.rs:39-53`** — 完整貼出：

```rust
    /// ReadYourUpdatesBack verifies UPDATE behavior for both success and failure cases.
    ///
    /// Execution:
    ///     SELECT <cols> FROM <t> WHERE <predicate>  -- snapshot before
    ///     UPDATE <t> SET <cols> WHERE <predicate>
    ///     SELECT <cols> FROM <t> WHERE <predicate>  -- snapshot after
    ///
    /// Assertion:
    /// - If UPDATE succeeded: after rows have updated values
    /// - If UPDATE failed (e.g., constraint error): before == after (rollback verified)
    ReadYourUpdatesBack {
        update: Update,
        select_before: Select,
        select_after: Select,
    },
```

**這個 property 同時驗證成功與失敗兩條路徑。**

- UPDATE 成功 → 值必須改變。
- UPDATE 失敗（例如違反約束）→ **值必須完全沒變**。

第二個斷言測的是**原子性**：失敗的語句不能留下半套修改。

`03-source-code-learn-3-emitter-dml-ddl.md` 講過 UPDATE 要維護索引、觸發 trigger、檢查約束。如果約束檢查在改了一半之後才失敗，回滾必須把所有已做的修改都撤銷——**包括索引**。這個 property 就是在測那件事。

`01-source-code-learn-1-entry-api.md` 看過的 `Statement` 欄位在這裡有了意義：

```rust
    /// Whether the statement needs to be wrapped in a statement subtransaction
    /// when run as part of an interactive (non-autocommit) transaction.
    pub needs_stmt_subtransactions: Arc<AtomicBool>,
```

**statement subtransaction 就是保證這件事的機制**，而這個 property 驗證它真的有效。

---

## 生成：從 property 到 SQL

**`testing/simulator/generation/property.rs:43-60`** — 完整貼出：

```rust
type PropertyQueryGenFunc<'a, R, G> =
    fn(&mut R, &G, &QueryDistribution, &Property) -> Option<Query>;

impl Property {
    pub(super) fn get_extensional_query_gen_function<R, G>(&self) -> PropertyQueryGenFunc<R, G>
    where
        R: rand::Rng + ?Sized,
        G: GenerationContext,
    {
        match self {
            Property::InsertValuesSelect { .. } => {
                // - [x] There will be no errors in the middle interactions. (this constraint is impossible to check, so this is just best effort)
                // - [x] The inserted row will not be deleted.
                // - [x] The inserted row will not be updated.
                // - [x] The table `t` will not be renamed, dropped, or altered.
                |rng: &mut R, ctx: &G, query_distr: &QueryDistribution, property: &Property| {
```

**那四行 `- [x]` 是核取清單**：對應 property 定義裡列的四個約束，這裡逐一勾選表示生成函式有處理。

**這是一種輕量的追蹤機制**——把「宣告的約束」和「實作的檢查」放在一起，讓兩者容易對照。缺一個就看得出來。

回傳 `Option<Query>` 表示生成可能失敗（例如沒有合適的表可用），呼叫者要處理。

### 生成器需要知道 schema

```rust
        G: GenerationContext,
```

檔案開頭的 FIXME 說明了為什麼：

**`testing/simulator/generation/property.rs:1-6`** — 完整貼出：

```rust
//! FIXME: With the current API and generation logic in plan.rs,
//! for Properties that have intermediary queries we need to CLONE the current Context tables
//! to properly generate queries, as we need to shadow after each query generated to make sure we are generating
//! queries that are valid. This is specially valid with DROP and ALTER TABLE in the mix, because with outdated context
//! we can generate queries that reference tables that do not exist. This is not a correctness issue, but more of
//! an optimization issue that is good to point out for the future
```

**「shadow」是關鍵概念**：生成器維護一份**影子 schema**，每產生一條查詢就更新它。

為什麼？因為產生第 5 條查詢時，前 4 條可能已經 `DROP TABLE` 了。如果用過期的 schema，就會產生引用不存在的表的查詢——那不是有效的測試，只是浪費。

FIXME 說目前的做法是 clone 整個 context（效能不佳但正確）。**誠實標註為「optimization issue, not correctness issue」**——這種區分讓後人知道優先級。

---

## 三種驗證模式

`main.rs` 引入了三個 runner：

```rust
use runner::differential;
use crate::runner::doublecheck;
```

**一、Differential（`runner/differential.rs`）** —— 同一組操作同時對 Turso 和真正的 SQLite 執行，比對結果。

這是最強的驗證：不需要自己判斷「正確答案是什麼」，直接問 SQLite。`08-source-code-learn-extensions-sync-testing.md` 講的 `.sqltest` 用的是同樣的思路，只是這裡的輸入是隨機生成的。

**二、Doublecheck（`runner/doublecheck.rs`）** —— 同一個種子跑兩次，比對結果。

**這在測什麼？** 測**確定性本身**。如果兩次執行結果不同，代表有不受控的不確定性洩漏進來（真正的隨機數、真實時鐘、執行緒排程）。

**這是模擬器的自我檢查**。如果確定性壞了，模擬器找到的所有 bug 都無法重現，整個工具就失效了。

**三、Property 斷言** —— 上面講的那些不變量。

---

## Shrink：把失敗案例變小

`testing/simulator/shrink/plan.rs`（340 行）。

**問題**：模擬器跑了 10,000 條隨機操作後失敗。這 10,000 條裡，可能只有 3 條與 bug 相關。

**Shrink 的做法**：反覆嘗試刪掉一些操作，看是否仍然失敗。仍然失敗就保留這個更短的版本，繼續縮減。

```text
10000 條操作 → 失敗
 5000 條      → 仍然失敗，採用
 2500 條      → 不失敗，退回
 3750 條      → 仍然失敗，採用
 ...
    3 條      → 最小失敗案例
```

**為什麼這需要確定性？** 因為每次縮減後都要重跑驗證。如果執行不確定，「不失敗」可能只是這次剛好沒觸發，縮減就會走錯方向。

最小化後的案例可以直接變成一個 `.sqltest` 或 Rust 回歸測試（`08-source-code-learn-extensions-sync-testing.md` 講的 `tests/fuzz/` 就是放這些的）。

**這是模糊測試工具的標準配備**，但只有在確定性成立時才可行。

---

## BugBase：失敗案例的資料庫

**`testing/simulator/main.rs:5` 與 `testing/simulator/main.rs:45-49`**：

```rust
use runner::bugbase::BugBase;
...
            SimulatorCommand::List => {
                let mut bugbase = BugBase::load()?;
                bugbase.list_bugs()
            }
```

**已知的失敗種子被存起來。** 這樣可以：

- 修好 bug 後驗證那個種子不再失敗。
- 回歸測試時重跑所有已知種子。
- 團隊之間交換「種子 12345 會失敗」而不用交換一整份重現腳本。

**`testing/simulator/main.rs:50-57`** — 完整貼出：

```rust
            SimulatorCommand::Loop { n, short_circuit } => {
                banner();
                for i in 0..n {
                    println!("iteration {i}");
                    let result = testing_main(&mut cli_opts, &profile);
                    if result.is_err() && short_circuit {
```

**`Loop` 子命令跑 N 次不同的種子。** 這是實際使用模擬器的方式：不是跑一次，而是持續跑，直到找到失敗。

`short_circuit` 讓你選擇「找到就停」（除錯時）或「跑完全部」（收集統計時）。

---

## 專門的記憶體測試

**`testing/simulator/runner/memory/`** 目錄：

```text
mvcc_recovery.rs        629 行
statement_abandon.rs    383 行
```

**`statement_abandon.rs`** —— 測「statement 執行到一半被放棄」。

`01-source-code-learn-1-entry-api.md` 看過 `Statement.has_returned_row` 的註解：

```rust
    /// True once step() has returned Row for a write statement (INSERT/UPDATE/DELETE
    /// with RETURNING). With ephemeral-buffered RETURNING, the first Row proves all
    /// DML completed — only the scan-back remains. Used by reset_internal to decide
    /// commit vs rollback when a statement is abandoned.
```

**「when a statement is abandoned」** —— 使用者可能 prepare 之後 step 幾次就把 statement 丟掉（例如 `LIMIT` 已滿足、或程式提早返回）。這時 engine 要決定：已做的修改要 commit 還是 rollback？

這種情況在正常測試裡很難構造，所以有專門的模擬器測試。

**`mvcc_recovery.rs`** —— 測 MVCC 的崩潰恢復（`10-source-code-learn-mvcc.md`）。logical log 寫到一半斷電，恢復後版本鏈必須一致。

---

## 與其他測試層的關係

`08-source-code-learn-extensions-sync-testing.md` 列過測試層級的分工。現在可以補上模擬器的定位：

| 層級 | 控制什麼 | 抓什麼 bug |
|---|---|---|
| `.sqltest` | 輸入 SQL | SQL 語義、相容性 |
| `tests/integration/` | 輸入 + API 呼叫序列 | API 層行為、多連線 |
| `core/io/memory_yield.rs` | 強制每次都 yield | 重入 bug（粗暴但有效） |
| **`testing/simulator/`** | **輸入 + I/O 時機 + 失敗注入 + 隨機數 + 時鐘** | **併發、重入、恢復** |
| `testing/differential-oracle/` | 輸入，對照 SQLite | 語義差異 |

**模擬器的獨特之處是它控制「時機」。** 其他工具都只控制輸入。

`memory_yield` 和模擬器的差別值得說明：`memory_yield` 是「每次都 yield」——粗暴、覆蓋所有 yield 點，但無法測試特定的交錯。模擬器可以精確控制「這次 yield、下次不 yield」，於是能探索交錯的空間。

---

## 動手驗證

跑模擬器：

```bash
cd /Users/stanhsu/projects/turso
cargo run --bin simulator -- --help
```

看可用的子命令與參數（種子、迭代次數、profile）：

```bash
cargo run --bin simulator -- loop -n 5
```

看已知的 bug 種子：

```bash
cargo run --bin simulator -- list
```

看 property 清單：

```bash
rg -n "^    [A-Z][A-Za-z]+ \{" testing/simulator/model/property.rs | head -20
```

看 profile 設定（控制生成的權重與規模）：

```bash
ls testing/simulator/profiles/
```

另有一個包裝腳本：

```bash
cat scripts/run-sim 2>/dev/null | head -20
```

追 source：

```bash
rg -n "pub enum Property" testing/simulator/model/property.rs
rg -n "fn get_extensional_query_gen_function" testing/simulator/generation/property.rs
rg -n "SimulatorCommand::Loop|SimulatorCommand::List" testing/simulator/main.rs
wc -l testing/simulator/**/*.rs | tail -5
```

---

## 自我檢查

1. 重入 bug、併發 bug、恢復 bug 的共同點是什麼？為什麼傳統測試抓不到？
2. 模擬器控制哪五類不確定性來源？
3. `VfsExtension` 為什麼要包含 `generate_random_number` 和 `get_current_time`？和模擬器有什麼關係？
4. 「同一個種子 → 同一次執行」為什麼是模擬器一切價值的基礎？列出它讓哪三件事成為可能。
5. `InsertValuesSelect` 這個 property 裡的 `queries: Vec<Query>` 為什麼是威力所在？
6. 「There will be no errors in the middle interactions」這個約束為什麼標註「impossible to check」？這種誠實標註有什麼價值？
7. `ReadYourUpdatesBack` 的第二個斷言（UPDATE 失敗時 before == after）在測什麼性質？和 statement subtransaction 有什麼關係？
8. 生成函式裡那些 `- [x]` 核取清單是做什麼用的？
9. 什麼是「shadow schema」？沒有它會產生什麼問題？
10. Differential 模式為什麼不需要自己判斷「正確答案」？
11. Doublecheck 模式在測什麼？如果它失敗，代表什麼？為什麼這是模擬器的自我檢查？
12. Shrink 為什麼需要確定性才能運作？
13. BugBase 讓團隊能交換什麼，而不用交換什麼？
14. `statement_abandon.rs` 測的情境是什麼？為什麼正常測試難以構造？
15. `memory_yield` 和模擬器都能測重入 bug，兩者的差別是什麼？
16. 在所有測試層級裡，模擬器獨特的能力是什麼？

---

## 系列全部完成

`learn/` 的源碼精讀版現在涵蓋 Turso 的所有主要子系統：

```text
核心路徑
  01（5篇）  一條 SQL 的完整生命週期
  02         Lexer / Parser / AST
  03（4篇）  Planner / Optimizer / Emitter+DML+DDL / Hash Join
  04（3篇）  指令分派 / Cursor opcodes / 聚合+排序+子程式
  05, 05b    Schema / Value / Record / Affinity / Function
  06（3篇）  File format / BTree+Pager / Balancing
  07（2篇）  WAL+交易 / IOResult+重入

周邊系統
  08         Extension / VFS / Sync 接點 / 測試分層
  10         MVCC
  11         Materialized View 與 DBSP 增量計算
  12         PostgreSQL Frontend
  13         Sync Engine 與同步協定
  14         確定性模擬器

方法論
  09         綜合追蹤與除錯方法
```

**貫穿全系列的三個主題**，值得在讀完後回顧：

**一、明確的 I/O 模型。** `IOResult` + 狀態機 + 重入正確性（`07b`）。它出現在 B-tree（`06b`、`06c`）、VM（`04`）、schema 解析（`05`）、增量視圖（`11`）——幾乎每一層。

**二、插進既有的抽象點。** extension 接 function resolver、虛擬表接 `CursorTrait`、VFS 接 `IO` trait、PG 接 `Dialect`、sync 的 lazy storage 接 `DatabaseStorage`、模擬器接 `IO`。**沒有一個是繞過核心的旁路**——這也是為什麼同一組抽象同時服務了擴充性與可測試性。

**三、SQLite 相容性的真實代價。** 不只複製正確的部分，也要複製怪異的部分（`POINT` 得到 INTEGER affinity）、以及那些「看似顯然卻會出錯」的細節（OUTER JOIN 的條件下推、checkpoint 失敗不等於交易失敗）。
