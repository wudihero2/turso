# 01-3. 源碼精讀：compile_cmd、translate 與 bytecode 的誕生

本篇對應 `01-sql-lifecycle.md` 的**第五層與第六層**：AST 如何變成 VDBE bytecode，`Program` 為什麼要拆成兩半，以及 `EXPLAIN` 裡那個奇怪的 `Init` → 跳到結尾 → `Goto` 跳回來的結構是誰造成的。

前一篇結束在 `prepare_with_origin` 呼叫 `compile_cmd`。本篇從那裡接著走。

> 行號以撰寫當下的 checkout 為準；symbol 名稱較穩定。找不到時用 `rg -n "symbol_name" <file>`。

> **閱讀時間**：約 90–120 分鐘（約 23k 字，其中 53% 是原始碼）。建議分 **2 個 session**，文中有標示休息點。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/connection.rs           compile_cmd ── 準備編譯所需的環境
  └─> core/translate/mod.rs  translate ── 編譯總入口
        ├─> core/vdbe/builder.rs         ProgramBuilder::new / prologue / epilogue / build
        ├─> core/translate/emitter/mod.rs  Resolver ── compiler 看 schema 的眼睛
        └─> core/translate/mod.rs        translate_inner ── 依語句類型分派
              └─> core/translate/select.rs 等各語句的編譯器（本篇只到門口）
```

本篇的核心結論先講：**編譯階段不執行任何 SQL、不碰任何資料**。它只產生一串指令。真正的執行是下一篇的事。

---

## compile_cmd：為編譯準備環境

**`core/connection.rs:892-916`** — 完整貼出主要路徑：

```rust
    #[turso_macros::trace_stack]
    fn compile_cmd(
        self: &Arc<Connection>,
        cmd: Cmd,
        input: &str,
        origin: StatementOrigin,
    ) -> Result<(Program, Arc<Pager>, QueryMode)> {
        self.maybe_update_schema();

        let syms = self.syms.read();
        let pager = self.pager.load().clone();
        let mode = QueryMode::new(&cmd);
        let (Cmd::Stmt(stmt) | Cmd::Explain(stmt) | Cmd::ExplainQueryPlan(stmt)) = cmd;
        let schema = self.schema.read().clone();
        match translate::translate(
            &schema,
            stmt,
            pager.clone(),
            self.clone(),
            &syms,
            mode,
            input,
            origin,
        ) {
            Ok(program) => Ok((program, pager, mode)),
            // ── 省略：schema 過期時的重試路徑，下面單獨講 ──
        }
    }
```

逐行看它蒐集了什麼：

**`self.maybe_update_schema()`** —— 編譯前先確認 schema 是最新的。這是整個編譯正確性的前提：如果別的 connection 剛建了一張表，而我們拿舊 schema 去編譯，會編出錯誤的 bytecode（例如把新表當成不存在）。

**`let syms = self.syms.read()`** —— symbol table，存放 extension 註冊的函式與虛擬表模組。

**`let pager = self.pager.load().clone()`** —— 抓一份 pager handle。注意用的是 `load()`，代表 `self.pager` 是 atomic 的、可能被抽換。第 2 篇提過：statement 必須抓住編譯當下的那一個。

**`let mode = QueryMode::new(&cmd)`** —— 從 `Cmd` 的變體決定模式。`Cmd::Stmt` → `Normal`、`Cmd::Explain` → `Explain`、`Cmd::ExplainQueryPlan` → `ExplainQueryPlan`。

**接下來這行是本函式最值得看的一行：**

```rust
        let (Cmd::Stmt(stmt) | Cmd::Explain(stmt) | Cmd::ExplainQueryPlan(stmt)) = cmd;
```

用 or-pattern 一次解構三個變體，取出裡面的 `Stmt`。這是一個 irrefutable pattern（`Cmd` 只有這三個變體，必然匹配），所以不需要 `match`。

**它的意義**：編譯階段完全不在乎這是不是 EXPLAIN。`EXPLAIN SELECT ...` 和 `SELECT ...` 走**完全相同的編譯流程**，產生**完全相同的 bytecode**。差別只在 `mode`，那是執行階段才用到的。

這解釋了為什麼 `EXPLAIN` 的輸出可信：它不是另一套模擬器算出來的，它就是真的要執行的那份 bytecode。

**`let schema = self.schema.read().clone()`** —— 複製一份 schema 快照。為什麼要 clone 而不是持有讀鎖？因為編譯過程可能很長（複雜查詢），一直握著鎖會擋住其他 connection。拿快照則保證編譯期間 schema 視圖穩定，這也是 snapshot isolation 概念在編譯層的體現。

### schema 競態的重試路徑

**`core/connection.rs:917-949`** — 完整貼出被省略的那段：

```rust
            Err(err) if self.should_retry_cross_process_schema_lookup(&err)? => {
                // Cold path: re-parse the SQL from scratch after schema refresh rather
                // than cloning the original AST, which can overflow the stack
                // on deeply nested expression trees.
                drop(syms);
                let cmd = {
                    crate::stack::trace_stack!("schema_retry_parse");
                    let (cmd, _) = self.parse_sql(input)?;
                    let Some(cmd) = cmd else {
                        return Err(err);
                    };
                    cmd
                };
                self.maybe_update_schema();
                let syms = self.syms.read();
                let pager = self.pager.load().clone();
                let mode = QueryMode::new(&cmd);
                let (Cmd::Stmt(stmt) | Cmd::Explain(stmt) | Cmd::ExplainQueryPlan(stmt)) = cmd;
                let schema = self.schema.read().clone();
                translate::translate(
                    &schema,
                    stmt,
                    pager.clone(),
                    self.clone(),
                    &syms,
                    mode,
                    input,
                    origin,
                )
                .map(|program| (program, pager, mode))
            }
            Err(err) => Err(err),
```

這段處理一個真實的競態：**多程序情境下，另一個程序可能在我們 `maybe_update_schema()` 之後、`translate()` 之前改了 schema**。translate 因而失敗（例如找不到表）。這時要刷新 schema 再試一次。

那段註解值得細讀：

> re-parse the SQL from scratch after schema refresh rather than cloning the original AST, which can overflow the stack on deeply nested expression trees.

重試時**重新 parse，而不是複製原本的 AST**。因為 AST 是遞迴結構，深層巢狀表達式的 clone 是遞迴操作，可能爆 stack。重新 parse 反而更安全。

這是很典型的資料庫工程細節：正確的做法（clone AST）在極端輸入下不安全，所以選了看似浪費但穩健的做法（重 parse）。

---

## translate：編譯總入口

**`core/translate/mod.rs:74-144`** — 完整貼出：

```rust
pub fn translate(
    schema: &Schema,
    stmt: ast::Stmt,
    pager: Arc<Pager>,
    connection: Arc<Connection>,
    syms: &SymbolTable,
    query_mode: QueryMode,
    input: &str,
    origin: crate::statement::StatementOrigin,
) -> Result<Program> {
    tracing::trace!("querying {}", input);
    let change_cnt_on = matches!(
        stmt,
        ast::Stmt::CreateIndex { .. }
            | ast::Stmt::Delete { .. }
            | ast::Stmt::Insert { .. }
            | ast::Stmt::Update { .. }
    );

    let capture_data_changes_info = if connection.is_mvcc_bootstrap_connection() {
        None
    } else {
        connection.get_capture_data_changes_info().clone()
    };
    // Boxed so the ~800 B builder sits on the heap instead of the prepare frame.
    let mut program = Box::new(ProgramBuilder::new(
        query_mode,
        capture_data_changes_info,
        // These options will be extended whithin each translate program
        ProgramBuilderOpts::new(1, 32, 2),
    ));
    program.set_mvcc_enabled(connection.mvcc_enabled());

    program.prologue();
    let mut resolver = Resolver::new(
        schema,
        connection.database_schemas(),
        &connection.temp.database,
        connection.attached_databases(),
        syms,
        connection.experimental_custom_types_enabled(),
        connection.get_dqs_dml().into(),
        // Engine-generated helper statements are always SQLite text and
        // must resolve functions with SQLite semantics regardless of the
        // database's dialect — the same invariant as unmarked schema rows.
        if matches!(origin, crate::statement::StatementOrigin::InternalHelper) {
            Arc::new(crate::dialect::SqliteDialect) as Arc<dyn crate::dialect::Dialect>
        } else {
            connection.dialect()
        },
    );

    match stmt {
        // There can be no nesting with pragma, so lift it up here
        ast::Stmt::Pragma { name, body } => {
            pragma::translate_pragma(
                &resolver,
                &name,
                body,
                pager,
                connection.clone(),
                &mut program,
            )?;
        }
        stmt => translate_inner(stmt, &mut resolver, &mut program, &connection, input)?,
    };

    program.epilogue(schema);

    program.build(connection, change_cnt_on, input)
}
```

拆開來看五個階段。

### 一、判斷是否要計數變更列數

```rust
    let change_cnt_on = matches!(
        stmt,
        ast::Stmt::CreateIndex { .. }
            | ast::Stmt::Delete { .. }
            | ast::Stmt::Insert { .. }
            | ast::Stmt::Update { .. }
    );
```

只有這四種語句會影響 `changes()` 計數（SQLite 的 `sqlite3_changes()`）。`CreateIndex` 也在列表裡，因為建索引會寫入資料列。

### 二、建立 ProgramBuilder

```rust
    // Boxed so the ~800 B builder sits on the heap instead of the prepare frame.
    let mut program = Box::new(ProgramBuilder::new(...));
```

那行註解說明了為什麼要 `Box`：builder 約 800 bytes，直接放在 stack frame 上會讓 prepare 的呼叫鏈變胖。而編譯是**遞迴**的（子查詢、trigger 會層層嵌套 translate），每層都多 800 bytes 就容易爆 stack。放 heap 上，stack frame 只留一個指標。

這種考量在 parser 那邊也看過（`expr_nesting_depth` 限制）。**遞迴深度是 SQL 編譯器的長期敵人。**

### 三、prologue：先埋一個 Init

**`core/vdbe/builder.rs:1641-1661`** — 完整貼出：

```rust
    pub fn prologue(&mut self) {
        if self.flags.is_subprogram() {
            // Subprograms (triggers, FK actions) don't need Transaction - they run within parent's tx
            self.init_label = self.allocate_label();
            self.emit_insn(Insn::Init {
                target_pc: self.init_label,
            });
            self.preassign_label_to_next_insn(self.init_label);
            self.start_offset = self.offset();
            return;
        }
        if self.nested_level == 0 {
            self.init_label = self.allocate_label();

            self.emit_insn(Insn::Init {
                target_pc: self.init_label,
            });

            self.start_offset = self.offset();
        }
    }
```

程式的第一條指令永遠是 `Insn::Init`，它的跳轉目標是一個**還不知道位址的 label**。

這就是「label / 回填」機制：編譯時常常需要「跳到之後才會產生的位置」。做法是先配置一個 label 佔位，等目標位置確定後再回填實際位址。

`self.start_offset = self.offset()` 記下「主體從第幾條指令開始」，`epilogue` 會用到。

注意 subprogram 的分支：trigger 和 FK action **不發 `Transaction` 指令**，因為它們跑在父語句的交易裡。這是 `StatementOrigin::Subprogram` 在編譯期的具體影響。

### 四、Resolver：compiler 看 schema 的眼睛

**`core/translate/emitter/mod.rs:136-142`** — 節錄前幾個欄位：

```rust
pub struct Resolver<'a> {
    schema: &'a Schema,
    database_schemas: &'a RwLock<HashMap<usize, Arc<Schema>>>,
    temp_database: &'a RwLock<Option<crate::connection::TempDatabase>>,
    attached_databases: &'a RwLock<DatabaseCatalog>,
    non_main_schema_cache: RefCell<HashMap<usize, Arc<Schema>>>,
    pub symbol_table: &'a SymbolTable,
    // ── 省略：expr_to_reg_cache、register_affinities、register_collations 等
    //         編譯期最佳化與 affinity 追蹤用的欄位 ──
```

`Resolver` 回答編譯器的所有「這個名字是什麼」的問題：

- `users` 是 main schema、temp schema 還是某個 attached database 的表？
- 它是普通表、view、虛擬表、還是 materialized view？
- `name` 是第幾個欄位？affinity 和 collation 是什麼？
- `abs()` 是內建函式、extension 函式、聚合函式還是視窗函式？

**parser 不做這些，Resolver 才做。** 這是語法與語義的分界線。

translate 裡建立 Resolver 時有一段值得注意的邏輯：

```rust
        // Engine-generated helper statements are always SQLite text and
        // must resolve functions with SQLite semantics regardless of the
        // database's dialect — the same invariant as unmarked schema rows.
        if matches!(origin, crate::statement::StatementOrigin::InternalHelper) {
            Arc::new(crate::dialect::SqliteDialect) as Arc<dyn crate::dialect::Dialect>
        } else {
            connection.dialect()
        },
```

**engine 自己產生的 helper SQL，一律用 SQLite 方言解析函式**，即使這個 connection 是 PostgreSQL 方言。

為什麼？因為 helper SQL（例如 schema reparse 用的查詢）是 engine 自己寫死的 SQLite 文字。如果讓它跟著 connection 的方言走，在 PG 模式下可能解析出不同的函式語義，導致 engine 內部行為錯亂。這就是 `StatementOrigin` 在編譯期的第二個具體影響。

### 五、分派與收尾

```rust
    match stmt {
        // There can be no nesting with pragma, so lift it up here
        ast::Stmt::Pragma { name, body } => {
            pragma::translate_pragma(...)?;
        }
        stmt => translate_inner(stmt, &mut resolver, &mut program, &connection, input)?,
    };

    program.epilogue(schema);

    program.build(connection, change_cnt_on, input)
```

PRAGMA 被特別提前處理（註解說明：PRAGMA 不會巢狀），其餘全部交給 `translate_inner`。

---

## translate_inner：依語句類型分派

**`core/translate/mod.rs:157-181`** — 節錄 write 判斷：

```rust
    let is_write = matches!(
        stmt,
        ast::Stmt::AlterTable { .. }
            | ast::Stmt::Analyze { .. }
            | ast::Stmt::CreateIndex { .. }
            | ast::Stmt::CreateTable { .. }
            | ast::Stmt::CreateTrigger { .. }
            | ast::Stmt::CreateView { .. }
            // ── 省略：其餘十多種寫入語句 ──
    );
```

**`core/translate/mod.rs:187-190`**

```rust
    if is_write && connection.get_query_only() {
        bail_parse_error!("Cannot execute write statement in query_only mode")
    }
```

這是**編譯期的語義檢查**。如果 connection 設定為唯讀，寫入語句在這裡就被拒絕，根本不會產生 bytecode。

值得對照的是：這不是 storage 層的檢查。storage 層當然也有保護，但在編譯期就攔下來，錯誤訊息更清楚、也不浪費後續工作。**好的分層會在最早能判斷的地方判斷。**

接著是分派：

**`core/translate/mod.rs:193-220`** — 節錄開頭幾個分支：

```rust
    match stmt {
        ast::Stmt::AlterTable(alter) => {
            translate_alter_table(alter, resolver, program, connection, input)?;
        }
        ast::Stmt::Analyze { name } => translate_analyze(name, resolver, program)?,
        ast::Stmt::Attach { expr, db_name, key } => {
            attach::translate_attach(&expr, resolver, &db_name, &key, program, connection.clone())?;
        }
        ast::Stmt::Begin { typ, name } => translate_tx_begin(typ, name, resolver, program)?,
        ast::Stmt::Commit { name } => {
            translate_tx_commit(name, resolver.schema(), resolver, program)?
        }
        ast::Stmt::CreateIndex { .. } => {
            translate_create_index(program, connection, resolver, stmt)?;
        }
        ast::Stmt::CreateTable { temporary, if_not_exists, tbl_name, body } => {
            translate_create_table(tbl_name, resolver, temporary, if_not_exists,
                                   body, program, connection, input)?
        }
        // ── 省略：CreateTrigger、CreateView、Delete、Insert、Select、Update
        //         等其餘數十個分支，各自呼叫對應的 translate_* 函式 ──
```

這就是編譯器的分派表。每種語句有自己的編譯器檔案：

| 語句 | 編譯器位置 |
|---|---|
| SELECT | `core/translate/select.rs` |
| INSERT | `core/translate/insert.rs` |
| UPDATE | `core/translate/update.rs` |
| DELETE | `core/translate/delete.rs` |
| CREATE TABLE / DROP 等 | `core/translate/schema.rs` |
| BEGIN / COMMIT / ROLLBACK | `core/translate/transaction.rs` |
| PRAGMA | `core/translate/pragma.rs` |

各語句的內部編譯流程是 `03-compiler-planner.md` 的主題，本篇不深入。你只要建立這個對應關係：**遇到某種語句編譯有問題，直接去對應的檔案。**

---

---

> ### ⏸ Session 1 到此
>
> 目前為止涵蓋了：compile_cmd 如何備妥編譯環境、translate 的五個階段、translate_inner 的分派。
>
> 休息之前，先確認你能說出這幾件事；說不出來就往回翻，不要硬推進——後半段會用到它們。
>
> **Session 2** 從下一節開始：bytecode 的收尾結構（Init/Goto 之謎）與 Program 的型別設計。

---

## epilogue：Init/Goto 之謎的答案

如果你跑過 `EXPLAIN SELECT name FROM t`，會看到這樣的輸出（來自 `04-vdbe-execution.md` 的實測）：

```text
addr  opcode             p1    p2    p3    p4             p5  comment
0     Init               0     7     0                    0   Start at 7
1     OpenRead           0     2     0     k(2,B,B)       0   table=t, root=2, iDb=0
2     Rewind             0     6     0                    0   Rewind table t
3       Column           0     1     1                    0   r[1]=t.name
4       ResultRow        1     1     0                    0   output=r[1]
5     Next               0     3     0                    0
6     Halt               0     0     0                    0
7     Transaction        0     1     1                    0   iDb=0 tx_mode=Read
8     Goto               0     1     0                    0
```

為什麼 `Transaction` 在最後面？為什麼要 `Init` 跳過去、再 `Goto` 跳回來？答案就在 `epilogue`。

**`core/vdbe/builder.rs:1719-1782`** — 節錄主要路徑：

```rust
    pub fn epilogue(&mut self, schema: &Schema) {
        if self.flags.is_subprogram() {
            // Subprograms (triggers, FK actions) just emit Halt without Transaction
            // ── 省略：subprogram 只發 Halt 就 return ──
            return;
        }
        if self.nested_level == 0 {
            // "rollback" flag is used to determine if halt should rollback the transaction.
            self.emit_halt(self.flags.rollback());
            self.preassign_label_to_next_insn(self.init_label);

            if !matches!(self.txn_mode, TransactionMode::None) {
                let write_dbs = self.write_databases.clone();
                for db_id in &write_dbs {
                    let schema_cookie = if db_id == crate::MAIN_DB_ID {
                        schema.schema_version
                    } else {
                        self.write_database_cookies.get(&db_id).copied().unwrap_or(0)
                    };
                    self.emit_insn(Insn::Transaction {
                        db: db_id,
                        tx_mode: self.txn_mode,
                        schema_cookie,
                    });
                }
                // ── 省略：對只需讀取的 attached database 發 Read 模式的 Transaction ──
            }

            if !self.constant_spans.is_empty() {
                self.emit_constant_insns();
            }
            self.emit_insn(Insn::Goto {
                target_pc: self.start_offset,
            });
        }
    }
```

現在按順序對照上面的 EXPLAIN 輸出：

1. **`emit_halt(...)`** → 發出 addr 6 的 `Halt`。主體結束了。
2. **`preassign_label_to_next_insn(self.init_label)`** → 把 prologue 配置的那個 label 綁定到**下一條指令**（addr 7）。這就是回填：`Init` 的目標終於確定了，是 7。
3. **發 `Insn::Transaction`** → addr 7。
4. **`emit_constant_insns()`** → 如果有常數需要預先載入，放在這裡（`SELECT 1+2` 的兩個 `Integer` 就是這樣來的，見 `04-vdbe-execution.md`）。
5. **發 `Insn::Goto { target_pc: self.start_offset }`** → addr 8，跳回 prologue 記下的主體起點 addr 1。

所以實際執行順序是：

```text
0 (Init) → 7 (Transaction) → 8 (Goto) → 1 (OpenRead) → 2 (Rewind) → ... → 6 (Halt)
```

**為什麼要這樣設計？** 因為「要開哪種交易」在編譯**開始時還不知道**。是唯讀還是要寫？要碰哪幾個 attached database？這些只有在編譯完主體之後才確定（`txn_mode`、`write_databases`、`read_databases` 是編譯過程中逐步累積的）。

於是採用這個結構：程式頭放一個 `Init` 跳到尾端，尾端放已經確定的初始化指令，再跳回主體。這樣就不必回頭修改已產生的指令。

SQLite 的 VDBE 也是同樣做法。**如果你之前覺得 EXPLAIN 輸出「順序很怪」，現在你知道那不是怪，是必要的。**

---

## Program 與 PreparedProgram：為什麼要拆成兩半

`epilogue` 之後是 `program.build(...)`，產出最終的 `Program`。

**`core/vdbe/mod.rs:1428-1457`** — 完整貼出 `PreparedProgram`：

```rust
pub struct PreparedProgram {
    pub max_registers: usize,
    // we store original indices because we don't want to create new vec from
    // ProgramBuilder
    pub insns: Vec<(Insn, usize)>,
    pub cursor_ref: Vec<(Option<CursorKey>, CursorType)>,
    pub comments: Vec<(InsnReference, &'static str)>,
    pub parameters: crate::parameters::Parameters,
    pub change_cnt_on: bool,
    /// Flag that detect if the sqlite statement will directly manipulate the database file.\
    /// mirrors: https://sqlite.org/c3ref/stmt_readonly.html.
    pub readonly: bool,
    pub result_columns: Vec<ResultSetColumn>,
    pub table_references: TableReferences,
    pub sql: String,
    /// Whether the statement needs to be wrapped in a statement subtransaction
    /// when run as part of an interactive (non-autocommit) transaction.
    pub needs_stmt_subtransactions: Arc<AtomicBool>,
    /// If this Program is a trigger subprogram, a ref to the trigger is stored here.
    pub trigger: Option<Arc<Trigger>>,
    /// Whether this program is a subprogram (trigger or FK action) that runs within a parent statement.
    pub is_subprogram: bool,
    pub resolve_type: ResolveType,
    pub prepare_context: PrepareContext,
    /// Set of attached database indices that need write transactions.
    pub write_databases: BitSet,
    /// Set of attached database indices that need read transactions.
    pub read_databases: BitSet,
}
```

**`core/vdbe/mod.rs:1459-1463`** — 完整貼出 `Program`：

```rust
#[derive(Clone)]
pub struct Program {
    pub(crate) prepared: Arc<PreparedProgram>,
    pub connection: Arc<Connection>,
}
```

`Program` 只有兩個欄位：一個指向編譯產物的 `Arc`，一個 connection。

**為什麼要這樣拆？** 回想第 1 篇看過的 `prepare_cached`：

```rust
let program = turso_core::Program::from_prepared(
    cached.program.clone(),      // Arc<PreparedProgram> —— 廉價 clone
    self.connection.clone(),
);
```

`PreparedProgram` 是**不可變且與 connection 無關**的，所以可以放在 `Arc` 裡被多個 `Program` 共享。快取一條 SQL 的編譯結果、重複執行，只需要 clone 一個 `Arc`（複製一個指標 + 加引用計數），不必重新編譯。

`Program` 則把編譯產物與**當前 connection** 綁在一起。

三層結構完整了：

| 層 | 內容 | 生命週期 |
|---|---|---|
| `PreparedProgram` | bytecode、result columns、參數表 | 不可變，可跨執行共享 |
| `Program` | `Arc<PreparedProgram>` + connection | 一次綁定 |
| `ProgramState` | PC、registers、cursors、pending I/O | 每次執行都是新的 |

### prepare_context：快取失效的關鍵

`PreparedProgram` 裡有個欄位叫 `prepare_context`。它的文件寫得很清楚：

**`core/vdbe/mod.rs:1465-1476`**

```rust
/// Captures connection settings at statement preparation time for cache invalidation.
///
/// This struct is used to detect when a cached prepared statement needs to be recompiled
/// because relevant connection settings have changed. When `matches_connection()` returns
/// false, the statement will be automatically reprepared before execution.
///
/// # Adding New Fields
///
/// If you add a new setting to `Connection` that affects statement compilation or execution,
/// When adding a new connection setting that affects query compilation, you MUST call
/// `bump_prepare_context_generation()` in its setter so that prepared statements know
/// they need to be reprepared.
```

這段註解是給未來維護者的警告，也是給你的一課：

**快取的難點不是存，是失效。** bytecode 是根據「編譯當下的 schema + connection 設定」產生的。任何會影響編譯結果的設定改變（PRAGMA、attach 新資料庫、載入 extension、schema 變更），都必須讓舊 bytecode 失效，否則就會用過期的指令去操作已經改變的資料庫——這是嚴重的正確性 bug。

註解裡那句大寫的 `MUST` 說明了這個機制是**手動維護**的：新增設定時，開發者必須記得呼叫 `bump_prepare_context_generation()`。這是設計上的取捨（自動偵測會很昂貴），但也意味著這裡是容易出 bug 的地方。

第 4 篇會看到 `_step` 如何呼叫 `matches_connection()` 並在不符時觸發 `reprepare()`。

---

## Insn：VM 的指令集

編譯的最終產物是 `Vec<(Insn, usize)>`。`Insn` 是一個巨大的 enum，定義在 `core/vdbe/insn.rs`（約 2300 行）。

第一輪不需要背，只要認得幾類：

```text
資料流 / register:
  Null, Integer, Real, String8, Blob
  Copy, Move, SCopy
  Add, Subtract, Multiply, Divide
  Eq, Ne, Lt, Le, Gt, Ge
  Cast, Affinity, MakeRecord

Cursor / table / index:
  OpenRead, OpenWrite
  Rewind, Next, Prev
  SeekRowid, SeekGE, SeekGT, SeekLE, SeekLT
  Column, RowId
  Insert, Delete, IdxInsert, IdxDelete

控制流 / 結果:
  Init, Goto, If, IfNot, Jump
  ResultRow, Halt
  Transaction, Savepoint

進階:
  SorterOpen, SorterInsert, SorterNext
  AggStep, AggFinal
  Program（子程式：trigger / FK action）
  VOpen, VFilter, VColumn, VNext, VUpdate（虛擬表）
```

指令名稱刻意對齊 SQLite 的 VDBE opcode，這樣可以直接拿 SQLite 的 `EXPLAIN` 輸出來對照除錯——這是 `docs/agent-guides/debugging.md` 裡「bytecode comparison」手法的基礎。

每個 `Insn` 對應一個實作函式，透過 `to_function()` 取得：

**`core/vdbe/insn.rs:2019`**

```rust
    pub(crate) const fn to_function(self) -> InsnFunction {
```

這是 `const fn`，代表對應關係在編譯期就決定了，執行時只是查表。第 4 篇會看到 VM 主迴圈如何使用它。

---

## 回顧：本篇走完的路

```text
core/connection.rs:893      compile_cmd
  ├─ maybe_update_schema()          確保 schema 最新
  ├─ QueryMode::new(&cmd)           Normal / Explain / ExplainQueryPlan
  ├─ or-pattern 解構 Cmd             EXPLAIN 與否走同一條編譯路徑
  └─ core/translate/mod.rs:74   translate
       ├─ ProgramBuilder::new       Box 起來避免 stack 壓力
       ├─ core/vdbe/builder.rs:1641   prologue  發 Init（目標是待回填的 label）
       ├─ Resolver::new             編譯器查 schema 的窗口
       ├─ core/translate/mod.rs:150   translate_inner  依語句分派到各 translate_* 檔案
       ├─ core/vdbe/builder.rs:1719   epilogue  發 Halt → 回填 label → 發 Transaction → 發 Goto
       └─ core/vdbe/builder.rs:2013   build     產出 Program { Arc<PreparedProgram>, connection }
```

**全程沒有任何 I/O、沒有讀任何 page、沒有開任何 transaction。** 產物是一串指令加上 metadata。

---

## 動手驗證

驗證「EXPLAIN 與否編譯結果相同」：

```bash
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
EXPLAIN SELECT name FROM t;
```

然後把 `EXPLAIN` 拿掉再跑一次 `SELECT name FROM t;`。第二次你看到的是結果（空的），但**執行的是同一份 bytecode**。

驗證 `Init`/`Goto` 結構：對照上面 epilogue 的原始碼，確認 addr 0 的 `Init` 目標、最後一條 `Goto` 的目標，和 `start_offset` 的關係。

追 source：

```bash
rg -n "fn compile_cmd" core/connection.rs
rg -n "^pub fn translate\b|^pub fn translate_inner" core/translate/mod.rs
rg -n "pub fn prologue|pub fn epilogue|pub fn build\(" core/vdbe/builder.rs
rg -n "pub struct PreparedProgram|pub struct Program\b" core/vdbe/mod.rs
```

---

## 自我檢查

1. `compile_cmd` 裡那行 or-pattern 解構 `Cmd` 說明了什麼設計決策？為什麼 `EXPLAIN` 的輸出值得信任？
2. schema 重試路徑為什麼選擇「重新 parse」而不是「clone 原本的 AST」？
3. `ProgramBuilder` 為什麼要 `Box` 起來？跟編譯的什麼特性有關？
4. `Transaction` 指令為什麼被放在程式尾端，而不是開頭？
5. `prologue` 配置的 label 是在哪裡被回填的？回填成什麼位址？
6. `PreparedProgram` 和 `Program` 拆開的好處是什麼？哪個可以被快取共享？
7. `prepare_context` 解決什麼問題？為什麼新增 connection 設定時「MUST」呼叫 `bump_prepare_context_generation()`？
8. `query_only` 檢查為什麼放在編譯期而不是執行期？
9. 為什麼 `InternalHelper` 產生的語句要強制用 SQLite 方言解析函式？

---

下一篇 `01-source-code-learn-4-step-vm.md`：進入執行階段，看 `Statement::step` → `Program::step` → `normal_step` 的 VM 主迴圈，以及 `StepResult` 的五種狀態如何把 I/O 交還給呼叫者。
