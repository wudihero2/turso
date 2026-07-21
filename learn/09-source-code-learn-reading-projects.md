# 09. 源碼精讀：綜合追蹤與除錯方法

本篇對應 `09-reading-projects.md`。前面各篇是**分層講解**，本篇是**綜合演練**：用兩份真實的 EXPLAIN 輸出，把前八篇的概念全部串起來，再整理一套遇到 bug 時的定位方法。

**閱讀方式**：程式碼與輸出都直接貼在文中並標註來源，不開編輯器也能讀完。

> **閱讀時間**：約 75–90 分鐘（約 18k 字，其中 26% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇要用到的前置知識

| 概念 | 出處 |
|---|---|
| prepare/step 兩段式 | `01-source-code-learn-1` ~ `01-source-code-learn-5` |
| `Init`/`Goto` 結構 | `03-source-code-learn-1-planner.md` |
| register 與指令分派 | `04-source-code-learn-1-insn-dispatch.md` |
| affinity 與 record | `05-source-code-learn-schema-values-records.md` |
| root page 與 sqlite_schema | `05-source-code-learn-schema-values-records.md` |
| WAL 與交易 | `07a-source-code-learn-wal-transactions.md` |

---

## 演練一：追一條 INSERT

指令：

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
CREATE INDEX t_name ON t(name);
EXPLAIN INSERT INTO t(name) VALUES ('carol');
```

實際輸出（本機 debug build 實測）：

```text
addr  opcode             p1    p2    p3    p4             p5  comment
----  -----------------  ----  ----  ----  -------------  --  -------
0     Init               0     18    0                    0   Start at 18
1     OpenWrite          1     2     0                    0   root=2; iDb=0
2     SoftNull           3     0     0                    0
3     String8            0     4     0     carol          0   r[4]='carol'
4     OpenWrite          0     3     0                    0   root=3; iDb=0
5     Affinity           3     2     0                    0   r[3..5] = D, B
6     NewRowid           1     2     0                    0   r[2]=rowid
7     Copy               4     6     0                    0   r[6]=r[4]
8     Copy               2     7     0                    0   r[7]=r[2]
9     MakeRecord         3     2     5                    0   r[5]=mkrec(r[3..4])
10    Copy               4     8     0                    0   r[8]=r[4]
11    Copy               2     9     0                    0   r[9]=r[2]
12    MakeRecord         8     2     10                   0   r[10]=mkrec(r[8..9]); for t_name
13    IdxInsert          0     10    8                    2   key=r[10]
14    Insert             1     5     2     t              0   intkey=r[2] data=r[5]
15    Goto               0     16    0                    0
16    Goto               0     17    0                    0
17    Halt               0     0     0                    0
18    Transaction        0     2     2                    0   iDb=0 tx_mode=Write
19    Goto               0     1     0                    0
```

**這 20 行包含了幾乎所有前面講過的機制。** 逐段拆解。

### 執行順序：先看 Init/Goto

執行順序**不是** 0→1→2→…，而是：

```text
0 (Init) → 18 (Transaction) → 19 (Goto) → 1 (OpenWrite) → 2 → … → 17 (Halt)
```

`03-source-code-learn-1-planner.md` 講過原因：`ProgramBuilder::prologue` 先發一個 `Init` 指向待回填的 label，`epilogue` 發完 `Halt` 後才把 label 綁到下一條指令，接著發 `Transaction`，最後發 `Goto` 跳回主體。

**為什麼 `Transaction` 要放最後才發？** 因為「這條語句需要讀交易還是寫交易」在編譯**開始時還不知道**。要等主體編譯完，才知道有沒有寫入操作。這裡 addr 18 的 `tx_mode=Write` 就是編譯過程中因為 `Insert`/`IdxInsert` 而累積出來的結論。

對照 `core/vdbe/builder.rs:1719` 的 `epilogue`：

```rust
            self.emit_halt(self.flags.rollback());              // → addr 17
            self.preassign_label_to_next_insn(self.init_label); // → label = 18
            if !matches!(self.txn_mode, TransactionMode::None) {
                // ...
                    self.emit_insn(Insn::Transaction { ... });  // → addr 18
            }
            // ...
            self.emit_insn(Insn::Goto {
                target_pc: self.start_offset,                   // → addr 19，跳回 1
            });
```

**輸出的每一行都能對應到具體的 emit 呼叫。**

### 兩個 cursor，兩棵 B-tree

```text
1     OpenWrite          1     2     0        root=2; iDb=0
4     OpenWrite          0     3     0        root=3; iDb=0
```

**cursor 1 → root page 2（表 `t`），cursor 0 → root page 3（索引 `t_name`）。**

注意：
- **指令裡沒有表名，只有 root page 編號。** `01-source-code-learn-5-cursor-storage.md` 講過，storage 層不知道 SQL 名稱。編譯器從 `BTreeTable.root_page` 取得這個數字（`05-source-code-learn-schema-values-records.md`）。
- 表和索引是**兩棵獨立的 B-tree**，各自要開 cursor（`06a-source-code-learn-file-format-pages.md`）。
- cursor id 是編譯期配置的（`ProgramBuilder::alloc_cursor_id`），和 root page 沒有對應關係。

### affinity 在寫入前套用

```text
3     String8            0     4     0     carol      r[4]='carol'
5     Affinity           3     2     0                r[3..5] = D, B
```

`Affinity` 指令對 r[3] 到 r[4] 套用 affinity，字串 `"D, B"` 就是 `05-source-code-learn-schema-values-records.md` 講的字元編碼：

**`core/vdbe/affinity.rs:85-89`**

```rust
pub const SQLITE_AFF_NONE: char = 'A'; // Historically called NONE, but it's the same as BLOB
pub const SQLITE_AFF_TEXT: char = 'B';
pub const SQLITE_AFF_NUMERIC: char = 'C';
pub const SQLITE_AFF_INTEGER: char = 'D';
pub const SQLITE_AFF_REAL: char = 'E';
```

`D` = INTEGER（欄位 `id`），`B` = TEXT（欄位 `name`）。

**affinity 在寫進 record 之前套用**——這就是為什麼 `INSERT INTO int_col VALUES('123')` 存進去會變成整數。`08-source-code-learn-extensions-sync-testing.md` 引的那個 `.sqltest` 測試（插入 `1, 2.0, '3', '4.0'` 全變整數）驗證的正是這條指令。

### rowid 的產生

```text
6     NewRowid           1     2     0        r[2]=rowid
```

我們只寫了 `name`，沒給 `id`。`id INTEGER PRIMARY KEY` 是 rowid 的別名，所以 engine 要自動產生一個。

`05-source-code-learn-schema-values-records.md` 提過 `BTreeTable` 有個特別的欄位：

```rust
    /// ON CONFLICT clause for the INTEGER PRIMARY KEY constraint.
    /// Stored here because rowid-alias PKs have their UniqueSet removed.
    pub rowid_alias_conflict_clause: Option<ResolveType>,
```

rowid 別名的唯一性由 B-tree 結構本身保證，不需要額外的唯一性檢查——所以這裡**沒有**看到任何檢查重複的指令。

### 兩次 MakeRecord：表與索引的 key 結構不同

```text
7     Copy               4     6     0        r[6]=r[4]
8     Copy               2     7     0        r[7]=r[2]
9     MakeRecord         3     2     5        r[5]=mkrec(r[3..4])
10    Copy               4     8     0        r[8]=r[4]
11    Copy               2     9     0        r[9]=r[2]
12    MakeRecord         8     2     10       r[10]=mkrec(r[8..9]); for t_name
```

**兩次 `MakeRecord` 產生兩個不同的 record**：

- addr 9：`mkrec(r[3..4])` → 表的資料列（id, name）。
- addr 12：`mkrec(r[8..9])` → 索引項（name, rowid）。

這正是 `06a-source-code-learn-file-format-pages.md` 講的差異：

| | key | payload |
|---|---|---|
| Table B-tree | rowid（整數） | 完整資料列 |
| Index B-tree | 索引欄位 + rowid | key 本身 |

索引項是 `(name, rowid)` —— rowid 當作 tie-breaker，讓相同 name 的多筆資料仍有唯一的 key，同時提供回主表查找的依據。

### 寫入的順序：先索引後表

```text
13    IdxInsert          0     10    8    p5=2   key=r[10]
14    Insert             1     5     2    t      intkey=r[2] data=r[5]
```

**先寫索引（cursor 0），再寫表（cursor 1）。**

順序有意義：如果索引有唯一性約束而插入失敗，此時表還沒被修改，回滾的工作較少。

`Insert` 指令的參數清楚顯示了 table B-tree 的結構：`intkey=r[2]`（rowid 當 key）、`data=r[5]`（record 當 payload）。

**一句 `INSERT` 產生兩次 B-tree 寫入。** 這回答了 `09-reading-projects.md` 原本的問題「INSERT 除了寫表還做什麼」——每多一個索引就多一次 `IdxInsert`。這也是為什麼索引會拖慢寫入。

### 這條路徑會碰到的 I/O

`IdxInsert` 和 `Insert` 都可能觸發：

- 讀取目標 leaf page（可能不在 cache → I/O）
- page 滿了要分裂 → `balance_state` 狀態機（`06b-source-code-learn-btree-cursor-pager.md`）
- 配置新 page → `allocate_page_state` 狀態機
- payload 太大 → overflow page chain

**每一個都可能 yield**，所以 `op_insert` 有 `OpInsertSubState`。這是 `07b-source-code-learn-ioresult-reentry.md` 的主題在寫入路徑上的體現。

---

## 演練二：追一條 CREATE TABLE

```sql
EXPLAIN CREATE TABLE x(a INTEGER, b TEXT);
```

實際輸出：

```text
addr  opcode             p1    p2    p3    p4             p5  comment
----  -----------------  ----  ----  ----  -------------  --  -------
0     Init               0     18    0                    0   Start at 18
1     ReadCookie         0     1     2                    0
2     If                 1     5     0                    0   if r[1] goto 5
3     SetCookie          0     2     4                    0
4     SetCookie          0     5     1                    0
5     CreateBtree        0     2     1                    0   r[2]=root iDb=0 flags=1
6     OpenWrite          0     1     0                    0   root=1; iDb=0
7     NewRowid           0     3     0                    0   r[3]=rowid
8     String8            0     4     0     table          0   r[4]='table'
9     String8            0     5     0     x              0   r[5]='x'
10    String8            0     6     0     x              0   r[6]='x'
11    Copy               2     7     0                    0   r[7]=r[2]
12    String8            0     8     0     CREATE TABLE x (a INTEGER, b TEXT)  0
13    MakeRecord         4     5     9                    0   r[9]=mkrec(r[4..8])
14    Insert             0     9     3     x              0   intkey=r[3] data=r[9]
15    SetCookie          0     1     1                    0
16    ParseSchema        0     0     0     tbl_name = 'x' AND type != 'trigger'
17    Halt               0     0     0                    0
18    Transaction        0     2     0                    0   iDb=0 tx_mode=Write
19    Goto               0     1     0                    0
```

**這份輸出是 `05-source-code-learn-schema-values-records.md` 講的「DDL 四者一致」的完整證明。**

### DDL 就是往 sqlite_schema 寫一列

```text
6     OpenWrite          0     1     0        root=1; iDb=0
```

**root page 1** —— 這就是 `sqlite_schema` 本身（`06a-source-code-learn-file-format-pages.md` 講過 page 1 同時是 database header 和 schema 的 B-tree root）。

```text
8     String8   ... 'table'                          → type
9     String8   ... 'x'                              → name
10    String8   ... 'x'                              → tbl_name
11    Copy      2  7   (r[7]=r[2]，即 CreateBtree 的結果)  → rootpage
12    String8   ... 'CREATE TABLE x (a INTEGER, b TEXT)'  → sql
13    MakeRecord 4 5 9  (r[4..8] 共 5 欄)
14    Insert    0 9 3
```

**五個欄位剛好對應 `sqlite_schema` 的固定結構**：type、name、tbl_name、rootpage、sql。

`05-source-code-learn-schema-values-records.md` 看過的讀取端：

**`core/util.rs:228-232`**

```rust
            let ty = row.get::<&str>(0)?;
            let name = row.get::<&str>(1)?;
            let table_name = row.get::<&str>(2)?;
            let root_page = row.get::<i64>(3)?;
            let sql = row.get::<&str>(4).ok();
```

**寫入端和讀取端在這裡對上了。** addr 8-12 寫的五個值，就是 `parse_schema_rows` 讀的五個欄位。

注意 addr 12 存的 SQL 是 `CREATE TABLE x (a INTEGER, b TEXT)` ——被**正規化**過（原本沒有空格的地方加了空格）。這是 `02-source-code-learn-parser-and-ast.md` 提過的 `ast/fmt.rs` 的工作：把 AST 格式化回 SQL 文字，確保存進去的是可重新解析的形式。

### CreateBtree：配置 root page

```text
5     CreateBtree        0     2     1        r[2]=root iDb=0 flags=1
```

先配置一棵新的 B-tree，得到 root page 編號放進 r[2]，稍後（addr 11）複製到 r[7] 寫進 `sqlite_schema` 的 `rootpage` 欄位。

**這就是 `BTreeTable.root_page` 的來源。** 下次開啟資料庫時，`parse_schema_rows` 讀回這個數字，之後 `OpenRead`/`OpenWrite` 就用它。

配置 page 可能需要從 freelist 拿（`06a`）或擴充檔案，過程中會 I/O——這是 `Pager.allocate_page_state` 存在的原因。

### Schema cookie 的三次操作

```text
1     ReadCookie         0     1     2
2     If                 1     5     0        if r[1] goto 5
3     SetCookie          0     2     4
4     SetCookie          0     5     1
...
15    SetCookie          0     1     1
```

addr 1-4 是**初始化**：讀取 cookie 2（file format），如果已經設定就跳過；否則設定 schema format 與 text encoding。這只在資料庫第一次建立物件時執行。

addr 15 是**關鍵的那一次**：`SetCookie 0 1 1` 更新 schema cookie（cookie 編號 1）。

**這個 cookie 是跨 connection 的 schema 版本通知機制。** 回顧 `01-source-code-learn-4-step-vm.md` 的 `_step`：

```rust
            if !self
                .program
                .prepare_context
                .matches_connection(&self.program.connection)
            {
                if let Err(err) = self.reprepare() {
```

其他 connection 的 prepared statement 就是靠比對 cookie 發現「schema 變了，我的 bytecode 過期了」，然後觸發 reprepare。

**如果這條 `SetCookie` 沒發，其他 connection 會繼續用過期的 bytecode**——可能開到已經不存在的 root page，讀出垃圾資料。

### ParseSchema：更新自己的記憶體 schema

```text
16    ParseSchema        0     0     0     tbl_name = 'x' AND type != 'trigger'
```

寫完磁碟後，**當前 connection 也要更新自己記憶體裡的 `Schema`**。

`ParseSchema` 的 p4 是一個 WHERE 條件——只重新解析和表 `x` 相關的列，不重掃整個 `sqlite_schema`。這是效能考量：schema 可能有上千個物件，為了新增一張表全部重掃太浪費。

這條指令最終會走到 `05-source-code-learn-schema-values-records.md` 講的 `parse_schema_rows`（`core/util.rs:201`），而那是個可能 yield I/O 的操作——所以 `ParseSchema` 也是可中斷指令。

### 四者一致，在同一段 bytecode 裡

`05-source-code-learn-schema-values-records.md` 說 DDL 的正確性核心是四樣東西必須一致。現在可以在輸出裡逐一指認：

| 要素 | 對應指令 |
|---|---|
| 配置的 root page | addr 5 `CreateBtree` |
| 磁碟上的 `sqlite_schema` 列 | addr 14 `Insert`（到 root page 1） |
| schema cookie | addr 15 `SetCookie` |
| 記憶體 `Schema` | addr 16 `ParseSchema` |

**四條指令，缺一不可。** 而且它們都在同一個寫交易裡（addr 18 `tx_mode=Write`），所以要嘛全部生效，要嘛全部回滾——`07a-source-code-learn-wal-transactions.md` 講的 commit frame 保證了這個原子性。

---

## 一套定位方法

遇到問題時，用**輸出的性質**決定從哪一層開始查。

### 步驟一：確認是哪一層

| 症狀 | 最可能的層 | 起點檔案 |
|---|---|---|
| 語法不被接受 | parser | `sqlite/parser/src/parser.rs` |
| 語法接受但報「no such table/column」 | resolver | `core/translate/emitter/mod.rs` 的 `Resolver` |
| 編譯失敗或報 unsupported | 各語句的 translate | `core/translate/<statement>.rs` |
| 有結果但結果錯 | optimizer 或 executor | 先 EXPLAIN 比對 |
| 用了 index 就錯，不用就對 | optimizer | `core/translate/optimizer/` |
| 資料量小時對、大時錯 | storage 或重入 | `core/storage/btree.rs`、狀態機 |
| 只在併發時錯 | 交易或鎖 | `core/storage/wal.rs`、`pager.rs` |
| crash 後資料不一致 | WAL 或 checkpoint | `core/storage/wal.rs` |
| binding 卡住不回 | I/O 驅動 | `sdk-kit/src/rsapi.rs`、`Completion` |

### 步驟二：用 EXPLAIN 切開編譯與執行

這是最有效的一刀。

```bash
cargo run -q --bin tursodb -- -q
```

```sql
EXPLAIN <你的查詢>;
```

- **bytecode 就不對**（少了指令、開錯 cursor、用錯 access path）→ 問題在編譯期，看 `core/translate/`。
- **bytecode 看起來對，但結果錯** → 問題在執行期，看 `core/vdbe/execute.rs` 對應的 `op_*`。

`03-source-code-learn-1-planner.md` 講過，EXPLAIN 用的就是真正要執行的那份 bytecode，所以這個判斷可信。

### 步驟三：和 SQLite 比對

```bash
scripts/diff.sh "SELECT ..." 
```

同時跑 sqlite3 和 tursodb，直接顯示差異。**相容性問題用這個最快**，不必自己推測 SQLite 的行為。

也可以比對 bytecode：

```bash
sqlite3 :memory: "CREATE TABLE t(a); EXPLAIN SELECT * FROM t;"
```

Turso 的指令名稱刻意對齊 SQLite（`04-source-code-learn-1-insn-dispatch.md`），所以兩邊的 EXPLAIN 可以直接對照。差異往往就指向 bug。

### 步驟四：用 trace 看執行過程

```sql
.vdbe_trace on
SELECT ...;
```

逐條印出執行的指令與 register 變化。`01-source-code-learn-4-step-vm.md` 省略的那段 trace 程式碼就是做這件事：

**`core/vdbe/mod.rs:1798-1810`** — 節錄：

```rust
                if let Some(ref old) = state.pre_op_registers {
                    for (i, (old_reg, new_reg)) in
                        old.iter().zip(state.registers.iter()).enumerate()
                    {
                        if old_reg != new_reg {
                            match new_reg {
                                Register::Value(v) => eprintln!("R[{i}] = {v}"),
```

它會 diff 前一條指令執行前後的 registers，只印出**改變的**那些。追「值在哪一步變錯」時非常有用。

更細的層級用環境變數：

```bash
RUST_LOG=turso_core::storage=trace cargo run -q --bin tursodb -- -q
RUST_LOG=turso_core::translate::optimizer=debug cargo run -q --bin tursodb -- -q
```

optimizer 的 debug log 會把最佳化後的計畫**印回 SQL 文字**（`03-source-code-learn-1-planner.md` 提過的 `plan.to_string()`），可以直接看出 optimizer 做了什麼改寫。

### 步驟五：寫一個會失敗的測試

專案的原則是「每個改動都要有測試，改動前失敗、改動後通過」。

依 `08-source-code-learn-extensions-sync-testing.md` 的分工選層級：

- SQL 語義問題 → `sqlite/conformance/sqlite-sqltests/` 的 `.sqltest`（**首選**）
- 需要多 connection、注入失敗、逾時 → `tests/integration/`
- 併發交錯、I/O 時機 → `testing/simulator/`

跑法：

```bash
make -C sqlite/conformance run-rust ARGS='--snapshot-filter __never__'
cargo test
```

---

## 三個容易誤判的情況

**一、「資料小時對、大時錯」通常不是資料量問題，是 I/O 時機問題。**

小資料全在 page cache，`read_page` 立刻回 `Done`，重入路徑根本沒被走到。大資料才會真的 yield，暴露 `07b-source-code-learn-ioresult-reentry.md` 講的重入 bug。

要驗證這個假設，用 `core/io/memory_yield.rs` 那個「每次都 yield」的測試後端，小資料也能重現。

**二、「用了 index 就錯」不一定是 index 的 bug。**

也可能是 optimizer 錯誤地認為某個條件已被 index 涵蓋，於是把它從 `where_clause` 移除了（`03-source-code-learn-1-planner.md` 講過條件會被「吸收」進 `Search`）。這時 bytecode 裡會少一個比較指令。

用 EXPLAIN 對照有無 index 的兩份輸出，看少了什麼。

**三、checkpoint 失敗不代表交易失敗。**

如果你看到「commit 回報成功但 checkpoint 有錯誤 log」，那是**正確行為**。`07a-source-code-learn-wal-transactions.md` 詳細講過：commit frame 一旦 durable，交易就已提交，checkpoint 只是搬運工作。

反過來，如果你在修改這條路徑時把 checkpoint 錯誤變成交易錯誤，那才是引入了資料遺失等級的 bug。

---

## 完整的閱讀路線圖

讀一個新功能時的順序：

```text
1. 語法           sqlite/parser/src/parser.rs, ast.rs        （02）
2. 語句編譯       core/translate/<feature>.rs                 （03）
3. 計畫與最佳化   core/translate/plan.rs, optimizer/          （03）
4. 指令產生       core/translate/emitter/, vdbe/builder.rs    （03）
5. 指令執行       core/vdbe/insn.rs, execute.rs               （04）
6. 值與 schema    core/types.rs, schema.rs, affinity.rs       （05, 05b）
7. 儲存           core/storage/btree.rs, pager.rs             （06a, 06b）
8. 交易與 I/O     core/storage/wal.rs, core/io/               （07a, 07b）
9. 測試           sqlite/conformance/, tests/, testing/       （08）
```

**不要反過來從 `btree.rs` 硬讀。** B-tree 是核心，但如果你不知道上層的 opcode 為什麼呼叫它、帶著什麼參數、期待什麼結果，一萬四千行程式碼是讀不進去的。

---

## 自己動手：五個練習

**練習一：追一條 UPDATE**

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
CREATE INDEX t_name ON t(name);
EXPLAIN UPDATE t SET name = 'bob' WHERE id = 1;
```

你應該能指認出：定位那一列的 seek、讀取舊值、刪除舊索引項、寫入新索引項、寫入新資料列。**為什麼索引要先刪後插？**

**練習二：比較三種 access path**

```sql
EXPLAIN SELECT * FROM t WHERE id = 1;        -- rowid
EXPLAIN SELECT * FROM t WHERE name = 'a';    -- secondary index
EXPLAIN SELECT * FROM t WHERE name LIKE 'a%'; -- 可能全掃
```

對照 `03-source-code-learn-1-planner.md` 的 `Search` enum 三個變體，指認每份輸出用的是哪一種。

**練習三：找出交易邊界**

```sql
EXPLAIN BEGIN;
EXPLAIN COMMIT;
```

然後思考：為什麼一般 `INSERT` 的 bytecode 裡也有 `Transaction` 指令？autocommit 和顯式交易的差別在哪一層？

**練習四：驗證 affinity**

```sql
CREATE TABLE aff(a POINT, b VARCHAR(10));
EXPLAIN INSERT INTO aff VALUES('123', 456);
```

找出 `Affinity` 指令的 p4 字串，對照 `05-source-code-learn-schema-values-records.md` 的五條規則，確認 `POINT` 為什麼得到 `D`（INTEGER）。

**練習五：找一個 .sqltest 反推**

```bash
ls sqlite/conformance/sqlite-sqltests/ | head -20
cat sqlite/conformance/sqlite-sqltests/affinity.sqltest
```

挑一個 test 區塊，用 `EXPLAIN` 看它產生的 bytecode，再從 opcode 反推「如果這個測試失敗，我會先看哪三個檔案」。

---

## 自我檢查

1. INSERT 的 EXPLAIN 裡為什麼有兩個 `OpenWrite`？兩個 root page 分別是什麼？
2. 為什麼有兩次 `MakeRecord`？兩個 record 的內容有什麼不同？
3. 為什麼先 `IdxInsert` 再 `Insert`，而不是相反？
4. `Affinity` 指令的 p4 是 `"D, B"`，這兩個字元代表什麼？為什麼要在寫入前套用？
5. INSERT 沒有指定 `id`，`NewRowid` 產生的值為什麼不需要額外的唯一性檢查？
6. CREATE TABLE 的 `OpenWrite` 開的是 root page 1，那是什麼？
7. addr 8-12 寫的五個值對應 `sqlite_schema` 的哪五個欄位？讀取端在哪個函式？
8. 存進 `sqlite_schema` 的 SQL 為什麼是正規化過的？哪個模組負責？
9. addr 15 的 `SetCookie` 如果沒發，其他 connection 會發生什麼？
10. `ParseSchema` 的 p4 帶了一個 WHERE 條件，為什麼不重掃整個 schema？
11. DDL 的「四者一致」分別對應輸出裡的哪四條指令？什麼機制保證它們原子生效？
12. 「資料小時對、大時錯」為什麼通常指向重入 bug 而不是資料量問題？怎麼在小資料下重現？
13. 遇到「用了 index 結果就錯」，除了 index 本身，還該檢查什麼？
14. 為什麼不該從 `btree.rs` 開始讀源碼？

---

## 核心 SQL 路徑到此結束

`01-source-code-learn-1` 到本篇，涵蓋了一條 SQL 從文字到磁碟的完整路徑，以及外圍的 extension、sync 接點、測試分層。**這是主線。**

後面還有五篇進階主題，各自獨立、可依興趣挑選，不必照順序讀：

| 篇 | 主題 |
|---|---|
| `10-source-code-learn-mvcc.md` | MVCC 多版本並行控制（實驗性） |
| `11-source-code-learn-incremental-views.md` | Materialized view 與 DBSP 增量計算 |
| `12-source-code-learn-postgres-frontend.md` | PostgreSQL frontend |
| `13-source-code-learn-sync-engine.md` | 完整同步協定 |
| `14-source-code-learn-simulator.md` | 確定性模擬器 |

除此之外的方向：

- **深入單一子系統** —— 挑一個你有興趣的（optimizer、B-tree balancing、MVCC），從本系列給的入口往下讀。
- **修一個真實的 bug** —— GitHub issue 上找標記 good-first-issue 的，用本篇的定位方法追。
- **讀 `docs/agent-guides/`** —— 專案自己的主題導讀，尤其是 `transaction-correctness.md` 和 `async-io-model.md`，會比本系列更深入。
- **跑 simulator** —— `testing/simulator/` 能製造出你手寫測試想不到的情境。
