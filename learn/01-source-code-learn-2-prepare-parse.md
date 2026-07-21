# 01-2. 源碼精讀：prepare_with_origin 與 SQL 文字變 AST

本篇對應 `01-sql-lifecycle.md` 的**第三層與第四層**：`prepare_with_origin` 的完整流程，以及 SQL 文字如何經過 dialect 抽象進到 parser，變成 AST。

前一篇（`01-source-code-learn-1-entry-api.md`）的結論是：`turso::Connection::prepare` 經過三層 wrapper 之後，收斂到 `core/connection.rs` 的 `prepare_with_origin`。本篇從那裡接著走。

> 行號以撰寫當下的 checkout 為準，可能漂移；symbol 名稱較穩定。找不到時用 `rg -n "symbol_name" <file>`。

> **閱讀時間**：約 60–75 分鐘（約 15k 字，其中 44% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/connection.rs            prepare_with_origin ── 本篇主角
  ├─> core/connection.rs      parse_sql（三行的轉發）
  │     └─> core/dialect/sqlite.rs   parse ── dialect 抽象層
  │           └─> sqlite/parser/src/parser.rs   Parser::new / next_cmd
  │                 └─> sqlite/parser/src/ast.rs   Cmd / Stmt
  └─> core/connection.rs      compile_cmd ── 留給第 3 篇
```

---

## prepare_with_origin：完整讀一遍

這是本篇最重要的一段程式碼。它只有 50 行，但把「資料庫如何安全地編譯一條 SQL」講完了。

**`core/connection.rs:970-1023`** — 完整貼出：

```rust
    #[turso_macros::trace_stack]
    pub(crate) fn prepare_with_origin(
        self: &Arc<Connection>,
        sql: impl AsRef<str>,
        origin: StatementOrigin,
    ) -> Result<Statement> {
        if self.is_closed() {
            return Err(LimboError::InternalError("Connection closed".to_string()));
        }
        if sql.as_ref().is_empty() {
            return Err(LimboError::InvalidArgument(
                "The supplied SQL string contains no statements".to_string(),
            ));
        }

        let needs_nested_guard = origin.needs_nested_guard();
        if needs_nested_guard {
            self.start_nested();
        }
        let result = (|| {
            let sql = sql.as_ref();
            tracing::debug!("Preparing: {}", sql);

            let (cmd, byte_offset_end) = {
                crate::stack::trace_stack!("parse");
                self.parse_sql(sql)?
            };
            let cmd = match cmd {
                Some(cmd) => cmd,
                None => {
                    return Err(LimboError::InvalidArgument(
                        "The supplied SQL string contains no statements".to_string(),
                    ));
                }
            };
            let input = str::from_utf8(&sql.as_bytes()[..byte_offset_end])
                .unwrap()
                .trim();
            let (program, pager, mode) = self.compile_cmd(cmd, input, origin)?;

            Ok(Statement::new_with_origin(
                program,
                pager,
                mode,
                byte_offset_end,
                origin,
                needs_nested_guard,
            ))
        })();
        if result.is_err() && needs_nested_guard {
            self.end_nested();
        }
        result
    }
```

現在逐段拆解。

### 第一段：前置檢查

```rust
        if self.is_closed() {
            return Err(LimboError::InternalError("Connection closed".to_string()));
        }
        if sql.as_ref().is_empty() {
            return Err(LimboError::InvalidArgument(
                "The supplied SQL string contains no statements".to_string(),
            ));
        }
```

兩個檢查，注意它們回傳**不同的錯誤類型**：

- connection 已關閉 → `InternalError`。這代表呼叫者用錯了 API（在關閉後還想用），是程式邏輯問題。
- SQL 是空字串 → `InvalidArgument`。這是使用者輸入問題。

錯誤分類不是美學問題。binding 層會把不同錯誤映射到不同的對外錯誤碼，使用者據此決定要重試、要報錯、還是要修程式。**分類錯了，上層就無法正確反應。**

### 第二段：nested guard 的成對記帳

```rust
        let needs_nested_guard = origin.needs_nested_guard();
        if needs_nested_guard {
            self.start_nested();
        }
```

回憶第 1 篇看過的定義，**`core/statement.rs:69-73`**：

```rust
impl StatementOrigin {
    pub(crate) const fn needs_nested_guard(self) -> bool {
        matches!(self, Self::InternalHelper)
    }
}
```

只有 `InternalHelper` 需要這個 guard。`start_nested` / `end_nested` 本身很簡單：

**`core/connection.rs:817-823`**

```rust
    pub fn start_nested(&self) {
        self.nestedness.fetch_add(1, Ordering::SeqCst);
    }
    /// ends nested program execution
    pub fn end_nested(&self) {
        self.nestedness.fetch_add(-1, Ordering::SeqCst);
    }
```

就是一個計數器。**為什麼需要它？** 因為 engine 內部執行 helper SQL 時（例如 schema reparse 要跑 `SELECT * FROM sqlite_schema`），系統必須知道「我現在正在別的 statement 內部」。有些行為在巢狀狀態下必須改變——例如不能在 helper statement 裡自動 commit 外層的 transaction，否則會把使用者的交易莫名其妙提交掉。

### 第三段：closure 包住主體，確保記帳不漏

這是本函式最值得學的寫法：

```rust
        let result = (|| {
            // ...主要工作...
        })();
        if result.is_err() && needs_nested_guard {
            self.end_nested();
        }
        result
```

主體被包進一個立刻執行的 closure。為什麼要這麼寫？

因為主體裡有**四個 `?` 早退點**（parse 失敗、cmd 是 None、compile 失敗等）。如果直接用 `?` 從 `prepare_with_origin` 回傳，每個早退點都會跳過後面的 `end_nested()`，計數器就永遠回不去了。用 closure 把主體隔離，所有早退都只會退出 closure，回到外層統一處理清理。

這是 Rust 沒有 `try/finally` 時的標準替代寫法。你在 core 裡會反覆看到這個模式。

注意清理條件是 `result.is_err()` —— **成功時不呼叫 `end_nested()`**。因為成功建立的 `Statement` 會接手這個責任（第 1 篇看過的 `nested_guard_active` 欄位，最後一個參數 `needs_nested_guard` 就是傳給它的），由 `Statement` 的 drop 負責歸還。這叫「所有權轉移」：失敗時我自己清，成功時交給接手的物件清。

### 第四段：呼叫 parser

```rust
            let (cmd, byte_offset_end) = {
                crate::stack::trace_stack!("parse");
                self.parse_sql(sql)?
            };
            let cmd = match cmd {
                Some(cmd) => cmd,
                None => {
                    return Err(LimboError::InvalidArgument(
                        "The supplied SQL string contains no statements".to_string(),
                    ));
                }
            };
```

`parse_sql` 回傳 `(Option<Cmd>, usize)`。兩個回傳值都重要：

- `Option<Cmd>`：解析出的第一條語句。為什麼是 `Option`？因為 SQL 可能只有分號或空白（例如 `";"` 或 `"  "`），語法上合法但沒有任何語句。這種情況回 `None`，這裡轉成 `InvalidArgument` 錯誤。
- `usize`：已消耗的 byte 數。

`trace_stack!("parse")` 是 stack 深度追蹤，用來偵測深層遞迴（惡意或病態的巢狀 SQL 可能撐爆 stack）。屬於防禦機制，第一輪可略過。

### 第五段：byte offset 的用途

```rust
            let input = str::from_utf8(&sql.as_bytes()[..byte_offset_end])
                .unwrap()
                .trim();
```

用 parser 回報的 offset，把**這一條語句的原始文字**切出來。

假設使用者傳入 `"SELECT 1; SELECT 2;"`，parser 只解析第一條，回報 `byte_offset_end = 9`。這裡就切出 `"SELECT 1;"`，`trim()` 後成為 `input`。

`input` 會傳給 `compile_cmd`，最終存進 `PreparedProgram.sql`。用途有三個：`EXPLAIN` 輸出要顯示原始 SQL、錯誤訊息要指出是哪條語句、需要重編譯（reprepare）時要有原文可用。

而 `byte_offset_end` 本身傳給 `Statement::new_with_origin` 成為 `tail_offset`，讓呼叫者知道「剩下的 SQL 從第 9 個 byte 開始」——這正是第 1 篇提過的 `sqlite3_prepare_v2` 的 `pzTail` 契約。

至於那個 `.unwrap()`：切片邊界來自 parser 回報的 token 邊界，必然落在合法的 UTF-8 字元邊界上，所以不會 panic。這是「用 unwrap 表達不變量」的例子——如果它 panic 了，代表 parser 的 offset 算錯，那是必須修的 bug，不該用錯誤處理掩蓋。

### 第六段：交棒

```rust
            let (program, pager, mode) = self.compile_cmd(cmd, input, origin)?;

            Ok(Statement::new_with_origin(
                program,
                pager,
                mode,
                byte_offset_end,
                origin,
                needs_nested_guard,
            ))
```

`compile_cmd` 是第 3 篇的主題。這裡先記住它回傳三樣東西：

- `program`：編譯好的 bytecode。
- `pager`：這條 statement 要用的 pager handle。為什麼 statement 要自己抓一份？因為 `Connection` 的 pager 可能在執行期間被換掉（例如 sync engine 重建資料庫），statement 必須抓住自己開始時的那一個，避免中途換底。
- `mode`：`Normal` / `Explain` / `ExplainQueryPlan`。決定 step 時走哪條路徑。

至此 prepare 完成，回傳 `Statement`。**注意：到這裡完全沒有碰過資料。** 沒有讀 page、沒有開 transaction、沒有 I/O（schema 已在記憶體中）。prepare 是純粹的編譯階段。

---

## parse_sql：一層 dialect 間接

**`core/connection.rs:1731-1733`** — 完整貼出：

```rust
    pub(crate) fn parse_sql(&self, sql: &str) -> Result<(Option<Cmd>, usize)> {
        self.db.dialect().parse(sql)
    }
```

三行，但透露了一個架構決策：**parser 不是寫死的，而是透過 `Dialect` trait 抽換**。

為什麼？因為 Turso 除了 SQLite 方言，還支援 PostgreSQL frontend（`postgres/` 目錄）。PG 的語法和 SQLite 不同，但底層的 translate/VDBE/storage 可以共用。`Dialect` 就是這個切換點。

`Dialect` trait 除了 `parse`，還負責 function 解析與 catalog 註冊。你在 `core/dialect/sqlite.rs` 可以看到 SQLite 實作的其他方法：

**`core/dialect/sqlite.rs:66-76`**

```rust
    fn register_catalog(
        &self,
        schema: &mut Schema,
        enable_custom_types: bool,
    ) -> crate::Result<()> {
        register_builtin_catalog(schema, enable_custom_types)
    }

    fn resolve_function(&self, name: &str, arg_count: usize) -> crate::Result<Option<Func>> {
        resolve_builtin_function(name, arg_count)
    }
```

`resolve_function` 帶 `arg_count` 參數——因為 SQL 允許同名不同參數個數的函式（例如 `substr(x,y)` 和 `substr(x,y,z)`），解析函式必須看參數個數。這是 `05b-functions-expressions.md` 的主題。

### SQLite dialect 的 parse

**`core/dialect/sqlite.rs:79-84`** — 完整貼出：

```rust
/// Parse the first SQLite statement in `sql` and return its consumed byte count.
pub fn parse(sql: &str) -> crate::Result<(Option<turso_parser::ast::Cmd>, usize)> {
    let mut parser = turso_parser::parser::Parser::new(sql.as_bytes());
    let cmd = parser.next_cmd()?;
    Ok((cmd, parser.offset()))
}
```

三個動作：建立 parser、取第一條語句、回報消耗的 byte 數。

注意 `sql.as_bytes()` —— parser 吃的是 **bytes 而非 `&str`**。這是效能考量：SQL 的關鍵字和符號都是 ASCII，逐 byte 掃描比處理 UTF-8 字元邊界快得多。只有在遇到識別字或字串常值、需要真正取出文字時，才會做 UTF-8 轉換。

每次呼叫 `parse` 都會**新建一個 `Parser`**，所以它只回傳第一條語句。要處理多條語句的 SQL，呼叫者要根據 offset 自己切、反覆呼叫。

---

## 進入 parser crate

現在跳到 `sqlite/parser/`，這是獨立的 crate（`turso_parser`），不依賴 core。這個邊界很重要：**parser 不知道 table 是否存在、不知道有哪些 index**。它只回答「這段文字語法上合法嗎、它的結構是什麼」。

### Parser struct

**`sqlite/parser/src/parser.rs:187-198`**

```rust
    pub fn new(input: &'a [u8]) -> Self {
        Self {
            lexer: Lexer::new(input),
            peekable: false,
            current_token: Token::new(&input[..0], TokenType::TK_NONE),
            last_variable_id: 0,
            named_variables: HashMap::new(),
            type_nesting_depth: 0,
            expr_nesting_depth: 0,
            last_expr_height: 0,
        }
    }
```

欄位分三組：

**`lexer` + `current_token` + `peekable`** —— token 供應與前瞻。遞迴下降 parser 常需要「看下一個 token 但先不消耗」來決定走哪條規則，`peekable` 就是標記目前 `current_token` 是否已被消耗。

**`last_variable_id` + `named_variables`** —— SQL 參數編號。`?` 依出現順序自動編號、`?1` 指定位置、`:name` / `@name` / `$name` 是具名參數需要 map 到 slot。這個狀態在每次 `next_cmd` 開頭會重置（下面會看到），因為參數編號是**每條語句各自獨立**的。

**`type_nesting_depth` + `expr_nesting_depth` + `last_expr_height`** —— 遞迴深度防護。`SELECT ((((...))))` 這種深層巢狀會讓遞迴下降 parser 撐爆 stack。這是真實的攻擊面（CVE 等級），所以 parser 必須主動設限。

### next_cmd：parser 的主入口

**`sqlite/parser/src/parser.rs:254-284`** — 完整貼出前半：

```rust
    // entrypoint of parsing
    pub fn next_cmd(&mut self) -> Result<Option<Cmd>> {
        self.last_variable_id = 0;
        self.named_variables.clear();

        // consumes prefix SEMI
        while let Some(token) = self.peek()? {
            if token.token_type == TK_SEMI {
                eat_assert!(self, TK_SEMI);
            } else {
                break;
            }
        }

        let result = match self.peek()? {
            None => None, // EOF
            Some(token) => match token.token_type {
                TK_EXPLAIN => {
                    eat_assert!(self, TK_EXPLAIN);

                    if self.peek_no_eof()?.token_type == TK_QUERY {
                        eat_assert!(self, TK_QUERY);
                        eat_expect!(self, TK_PLAN);
                        Some(Cmd::ExplainQueryPlan(self.parse_stmt()?))
                    } else {
                        Some(Cmd::Explain(self.parse_stmt()?))
                    }
                }
                _ => Some(Cmd::Stmt(self.parse_stmt()?)),
            },
        };
```

四個步驟：

**一、重置參數狀態。** 前面提過，參數編號是每條語句獨立的。

**二、吃掉前置分號。** `";;; SELECT 1"` 應該要能解析。

**三、判斷 EXPLAIN 前綴。** 這裡可以看到 `EXPLAIN` 和 `EXPLAIN QUERY PLAN` 是在 parser 層就分開的，產生不同的 `Cmd` 變體。**這件事很關鍵**：`EXPLAIN SELECT ...` 不是另一種語句，而是「同一條 SELECT，外面包一層 EXPLAIN 標記」。所以 EXPLAIN 走的是**完全相同的編譯流程**，只是最後不執行 bytecode，而是把 bytecode 印出來。第 4 篇會看到 `QueryMode` 如何實現這件事。

**四、其餘一律交給 `parse_stmt`。**

`eat_assert!` 和 `eat_expect!` 的差別值得注意：前者用在「已經 peek 確認過」的情況（消耗失敗代表 parser 自己有 bug），後者用在「期待但不保證」的情況（消耗失敗是使用者的語法錯誤）。`EXPLAIN QUERY` 之後必須是 `PLAN`，所以用 `eat_expect!`，錯了會產生語法錯誤而非 panic。

### 語句結尾的處理

**`sqlite/parser/src/parser.rs:285-300`** — 節錄：

```rust
        let mut found_semi = false;
        loop {
            match self.peek()? {
                None => break,
                Some(token) if token.token_type == TK_SEMI => {
                    found_semi = true;
                    eat_assert!(self, TK_SEMI);
                }
                Some(token) => {
                    if !found_semi {
                        let tt = token.token_type;
                        let token_text = token.to_utf8();
                        let offset = self.offset();
                        return Err(Error::ParseUnexpectedToken {
                            parsed_offset: (offset, 1).into(),
                            // ── 省略：錯誤結構的其餘欄位 ──
```

語句解析完後，後面只允許分號或 EOF。如果**沒遇到分號就出現別的 token**，就是語法錯誤——例如 `"SELECT 1 SELECT 2"`（少了分號）會在這裡被抓到。

錯誤帶了 `parsed_offset`、token 類型、token 文字。**parser 的錯誤品質很重要**，因為 SQL 是使用者直接輸入的語言，錯誤訊息是他們唯一的線索。

### offset：告訴呼叫者吃到哪

**`sqlite/parser/src/parser.rs:244-252`** — 完整貼出：

```rust
    pub fn offset(&self) -> usize {
        if !self.peekable {
            // not peekable means current token already consumed
            // so just take lexer offset
            self.lexer.offset
        } else {
            self.lexer.offset - self.current_token.value.len()
        }
    }
```

這個函式看似瑣碎，但它是「多語句 SQL 能正確切割」的基礎，值得看懂。

lexer 的 offset 永遠指向**已掃描到的位置**。問題是：parser 可能已經 peek 了下一個 token（為了判斷語句是否結束），那個 token 已被 lexer 掃過，但邏輯上**還沒被這條語句消耗**。

所以：
- `peekable == false`：current_token 已消耗，lexer offset 就是答案。
- `peekable == true`：current_token 被 peek 但未消耗，要**扣掉它的長度**。

如果沒有這個修正，`"SELECT 1; SELECT 2;"` 切出來的第一條會多吃掉第二條的開頭 token，`input` 就錯了。

---

## AST：parser 的產物

**`sqlite/parser/src/ast.rs:21-28`** — 完整貼出：

```rust
pub enum Cmd {
    /// `EXPLAIN` statement
    Explain(Stmt),
    /// `EXPLAIN QUERY PLAN` statement
    ExplainQueryPlan(Stmt),
    /// statement
    Stmt(Stmt),
}
```

三個變體都包著同一個 `Stmt`。再次印證：EXPLAIN 只是標記，語句本身完全一樣。

你會在第 3 篇看到 `compile_cmd` 如何處理這個 enum：

```rust
let (Cmd::Stmt(stmt) | Cmd::Explain(stmt) | Cmd::ExplainQueryPlan(stmt)) = cmd;
```

用 or-pattern 一次解構三個變體，因為**編譯階段不在乎是不是 EXPLAIN**——三者都要走完整編譯。差別只在 `QueryMode`，那是執行階段的事。

`Stmt` 則是真正的大 enum，涵蓋所有語句類型（`Select`、`Insert`、`Update`、`Delete`、`CreateTable`、`Pragma`……）。第 3 篇會看到 `translate_inner` 如何對它做分派。

---

## 到這裡的完整鏈路

```text
core/connection.rs:971    prepare_with_origin
  ├─ 檢查 closed / 空字串
  ├─ start_nested()（僅 InternalHelper）
  ├─ core/connection.rs:1731   parse_sql
  │    └─ core/dialect/sqlite.rs:80   parse
  │         ├─ sqlite/parser/src/parser.rs:187   Parser::new
  │         ├─ sqlite/parser/src/parser.rs:255   next_cmd  →  ast::Cmd
  │         └─ sqlite/parser/src/parser.rs:244   offset     →  byte_offset_end
  ├─ 用 offset 切出 input 原文
  ├─ core/connection.rs:893    compile_cmd    ← 第 3 篇
  └─ core/statement.rs:344     Statement::new_with_origin
```

**這一段完全沒有 I/O、沒有 schema 查詢、沒有 index 選擇。** parser 只做語法。語義（表存不存在、欄位屬於誰、用哪個 index）從下一篇的 `compile_cmd` 才開始。

---

## 動手驗證

parser 不查 schema，這件事可以直接驗證。開啟 CLI：

```bash
cargo run -q --bin tursodb -- -q
```

輸入一條語法正確但表不存在的 SQL：

```sql
SELECT * FROM 這張表不存在;
```

你會得到「no such table」之類的錯誤，而**不是**語法錯誤。這證明它通過了 parser，是在後面的 compile 階段才失敗。

再試一條語法就錯的：

```sql
SELECT FROM WHERE;
```

這次會是 parse error，並且會告訴你出錯的位置與 token。

追 source：

```bash
rg -n "pub fn next_cmd|pub fn offset|fn create_variable" sqlite/parser/src/parser.rs
rg -n "pub enum Cmd|pub enum Stmt" sqlite/parser/src/ast.rs
rg -n "fn parse_sql|fn prepare_with_origin" core/connection.rs
```

---

## 自我檢查

1. `prepare_with_origin` 為什麼要把主體包進一個立刻執行的 closure？不包會出什麼問題？
2. 清理條件是 `result.is_err() && needs_nested_guard`。成功時為什麼**不**呼叫 `end_nested()`？誰接手了這個責任？
3. `parse_sql` 回傳的 `Option<Cmd>` 什麼時候會是 `None`？
4. `byte_offset_end` 有兩個用途，分別是什麼？
5. `Parser::offset()` 為什麼要區分 `peekable` 的兩種情況？如果不區分，`"SELECT 1; SELECT 2;"` 會發生什麼？
6. `EXPLAIN SELECT 1` 和 `SELECT 1` 在 AST 上差在哪？這對編譯流程有什麼影響？
7. parser 為什麼要限制 `expr_nesting_depth`？
8. 為什麼 parser 吃的是 `&[u8]` 而不是 `&str`？

---

下一篇 `01-source-code-learn-3-translate.md`：進入 `compile_cmd` 與 `translate`，看 AST 如何變成 VDBE bytecode，以及 `Program` / `PreparedProgram` 為什麼要拆開。
