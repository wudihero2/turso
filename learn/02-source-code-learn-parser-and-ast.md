# 02. 源碼精讀：Lexer、Parser、AST

本篇對應 `02-parser-and-ast.md`，把 SQL 文字變成語法樹的整條路徑攤開來讀。

**閱讀方式**：本篇的程式碼都直接貼在文中並標註 `檔案:行號`，設計成不開編輯器也能讀完。行號以撰寫當下的 checkout 為準，可能漂移；symbol 名稱較穩定，找不到時用 `rg -n "symbol_name" <file>`。

> **閱讀時間**：約 90–120 分鐘（約 21k 字，其中 49% 是原始碼）。建議分 **2 個 session**，文中有標示休息點。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
sqlite/parser/src/lexer.rs    Lexer / Token ── 把 bytes 切成 token
  └─> sqlite/parser/src/parser.rs   Parser ── 遞迴下降，token 變 AST
        ├─ next_cmd      主入口
        ├─ parse_stmt    語句分派
        ├─ parse_expr    表達式與運算子優先權
        └─ create_variable  SQL 參數編號
              └─> sqlite/parser/src/ast.rs   Cmd / Stmt / Expr ── 產物
```

**先界定 parser 的職責。** 它只回答「這段文字語法上合法嗎、結構是什麼」。它**不知道**表存不存在、欄位屬於誰、該用哪個 index、資料長什麼樣。那些是 `core/translate/` 的事（見 `03-source-code-learn-*.md`）。

這個邊界在程式碼上是硬的：`turso_parser` 是獨立 crate，**不依賴 `turso_core`**。它連 `Schema` 型別都看不到。

---

## 第一層：Lexer

### Lexer 只有兩個欄位

**`sqlite/parser/src/lexer.rs:212-215`** — 完整貼出：

```rust
pub struct Lexer<'a> {
    pub(crate) offset: usize,
    pub(crate) input: &'a [u8],
}
```

整個 lexer 的狀態就是「一段 bytes」和「掃到第幾個 byte」。沒有緩衝區、沒有 token 佇列——它是純粹的按需掃描器。

`input` 是 `&[u8]` 而非 `&str`。第 1 篇提過原因：SQL 的關鍵字與符號都是 ASCII，逐 byte 比對比處理 UTF-8 字元邊界快得多。只有在真正要取出識別字或字串內容時才轉 UTF-8。

`'a` 這個 lifetime 是關鍵設計：token 直接借用原始輸入的切片，**不複製字串**。

### Token 也只有兩個欄位

**`sqlite/parser/src/lexer.rs:184-188`** — 完整貼出：

```rust
#[derive(Clone, PartialEq, Eq, Debug)] // do not derive Copy for Token, just use .clone() when needed
pub struct Token<'a> {
    pub value: &'a [u8],
    pub token_type: TokenType, // None means Token is whitespaces or comments
}
```

`value` 是**指向原始輸入的切片**，不是新配置的字串。解析一條 SQL 全程幾乎不做字串配置——這在每秒要處理大量查詢的資料庫裡很重要。

**`sqlite/parser/src/lexer.rs:191-210`** — 完整貼出方法：

```rust
impl<'a> Token<'a> {
    #[inline]
    pub const fn new(value: &'a [u8], token_type: TokenType) -> Self {
        Token { value, token_type }
    }
    #[inline]
    pub fn to_utf8(&self) -> String {
        String::from_utf8_lossy(self.as_bytes()).to_string()
    }
    /// # Safety
    /// Same as `String::from_utf8_unchecked`,
    /// the caller must ensure that token bytes are valid UTF-8.
    #[inline]
    pub unsafe fn to_utf8_unchecked(&self) -> String {
        String::from_utf8_unchecked(self.as_bytes().to_vec())
    }
    #[inline]
    pub const fn as_bytes(&self) -> &[u8] {
        self.value
    }
}
```

兩個 UTF-8 轉換版本：安全版 `to_utf8`（用 lossy，遇到非法 bytes 換成替代字元）和 unsafe 版 `to_utf8_unchecked`。後者用在「已經由 lexer 保證是合法 UTF-8」的路徑上，省下驗證成本。unsafe 帶著 `# Safety` 註解說明契約——這是 Rust 的規矩，也提醒讀者這裡有前提條件。

### 掃描主迴圈：一個大 match

**`sqlite/parser/src/lexer.rs:217-247`** — 完整貼出前半：

```rust
impl<'a> Iterator for Lexer<'a> {
    type Item = Result<Token<'a>>;

    #[inline]
    fn next(&mut self) -> Option<Self::Item> {
        match self.peek() {
            None => None, // End of file
            Some(b) if b.is_ascii_whitespace() => Some(Ok(self.eat_white_space())),
            // matching logic
            Some(b) => match b {
                b'-' => Some(Ok(self.eat_minus_or_comment_or_ptr())),
                b'(' => Some(Ok(self.eat_one_token(TokenType::TK_LP))),
                b')' => Some(Ok(self.eat_one_token(TokenType::TK_RP))),
                b';' => Some(Ok(self.eat_one_token(TokenType::TK_SEMI))),
                b'+' => Some(Ok(self.eat_one_token(TokenType::TK_PLUS))),
                b'*' => Some(Ok(self.eat_one_token(TokenType::TK_STAR))),
                b'/' => Some(self.mark(|l| l.eat_slash_or_comment())),
                b'%' => Some(Ok(self.eat_one_token(TokenType::TK_REM))),
                b'=' => Some(Ok(self.eat_eq())),
                b'<' => Some(Ok(self.eat_le_or_ne_or_lshift_or_lt())),
                b'>' => Some(Ok(self.eat_ge_or_gt_or_rshift())),
                b'!' => Some(self.mark(|l| l.eat_ne())),
                b'|' => Some(Ok(self.eat_concat_or_bitor())),
                b',' => Some(Ok(self.eat_one_token(TokenType::TK_COMMA))),
                b'&' => Some(Ok(self.eat_overlap_or_bitand())),
                b'~' => Some(Ok(self.eat_one_token(TokenType::TK_BITNOT))),
                b'\'' | b'"' | b'`' => Some(self.mark(|l| l.eat_lit_or_id())),
                b'.' => Some(self.mark(|l| l.eat_dot_or_frac(false))),
                b'0'..=b'9' => Some(self.mark(|l| l.eat_number())),
                b'[' => Some(Ok(self.eat_one_token(TokenType::TK_LBRACKET))),
                b']' => Some(Ok(self.eat_one_token(TokenType::TK_RBRACKET))),
```

`Lexer` 實作 `Iterator`，每次 `next()` 吐一個 token。整體就是「看第一個 byte，決定走哪條分支」。

函式名稱本身就說明了歧義在哪：

- `eat_minus_or_comment_or_ptr` —— `-` 可能是減號、`--` 註解開頭、或指標運算子。
- `eat_le_or_ne_or_lshift_or_lt` —— `<` 可能是 `<`、`<=`、`<>`、`<<`。
- `eat_lit_or_id` —— 引號可能包字串常值，也可能包識別字（SQLite 允許 `"column name"`）。

**這就是 lexer 的本質工作：處理最大匹配的歧義。** 看到 `<` 不能立刻決定，要看下一個 byte。

### 前瞻的兩個實例

**`sqlite/parser/src/lexer.rs:248-256`** — 完整貼出：

```rust
                b'@' => {
                    // @> is array contains operator; bare @ starts a variable
                    if self.input.get(self.offset + 1) == Some(&b'>') {
                        Some(Ok(self.eat_array_contains()))
                    } else {
                        Some(self.mark(|l| l.eat_var()))
                    }
                }
                b'?' | b'$' => Some(self.mark(|l| l.eat_var())),
```

**`sqlite/parser/src/lexer.rs:266-274`** — 完整貼出：

```rust
                b':' => {
                    // `:name` is a named parameter, but `:` followed by a digit
                    // or non-identifier char is a standalone colon (used in slice syntax).
                    match self.input.get(self.offset + 1) {
                        Some(&b) if is_identifier_start(b) => Some(self.mark(|l| l.eat_var())),
                        _ => Some(Ok(self.eat_one_token(TokenType::TK_COLON))),
                    }
                }
                b if is_identifier_start(b) => Some(self.mark(|l| l.eat_blob_or_id())),
                _ => Some(self.eat_unrecognized()),
            },
        }
    }
}
```

兩處都用 `self.input.get(self.offset + 1)` 直接看下一個 byte。用 `get` 而不是索引，因為可能已到字串尾端——回 `None` 就走另一條分支，不會 panic。

`:` 的處理特別有意思：`:name` 是具名參數，但單獨的 `:` 是切片語法的一部分（Turso 的陣列擴充）。**同一個字元在不同上下文是不同 token**，這種脈絡相依是 SQL 方言擴充時最容易出問題的地方。

`#` 的處理值得一提：

**`sqlite/parser/src/lexer.rs:257-265`**

```rust
                b'#' => {
                    let start = self.offset;
                    self.eat(); // consume '#'
                    self.eat_while(is_identifier_continue);
                    Some(Ok(Token::new(
                        &self.input[start..self.offset],
                        TokenType::TK_ILLEGAL,
                    )))
                }
```

`#` 開頭的東西被明確標成 `TK_ILLEGAL`，**但仍然產生一個 token**，而不是直接報錯。為什麼？因為這樣錯誤訊息可以顯示完整的無效識別字（`#foo` 而不是只有 `#`），對使用者更有幫助。**lexer 不負責報錯，它負責提供足夠資訊讓 parser 報好錯。**

---

## 第二層：Parser

### Parser 的狀態

**`sqlite/parser/src/parser.rs:187-198`** — 完整貼出建構子（欄位一目瞭然）：

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

**`sqlite/parser/src/parser.rs:155-164`** — 欄位的原始註解：

```rust
    last_variable_id: u32,
    named_variables: HashMap<&'a [u8], NonZeroU32>,
    /// Tracks STRUCT/UNION nesting depth to prevent stack overflow from deeply nested types
    type_nesting_depth: u32,
    /// Current expression recursion depth of the parser, bounded by [`MAX_EXPR_DEPTH`]
    expr_nesting_depth: u32,
    /// Height of the most recently parsed expression (`1 + max(child heights)`,
    /// like SQLite's `Expr.nHeight`), bounded by [`MAX_EXPR_DEPTH`]
    last_expr_height: usize,
}
```

三組狀態：

- **`lexer` + `current_token` + `peekable`** —— token 供應與前瞻。
- **`last_variable_id` + `named_variables`** —— SQL 參數編號（下面詳談）。
- **三個深度／高度欄位** —— 遞迴防護（下面詳談）。

### next_cmd：主入口

**`sqlite/parser/src/parser.rs:254-284`** — 完整貼出（第 1 篇的第 2 篇看過，這裡重點放在 parser 視角）：

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

開頭重置參數狀態，因為**參數編號是每條語句獨立的**。`"SELECT ?; SELECT ?;"` 的兩個 `?` 都是該語句的第 1 號參數，不是第 1 號和第 2 號。

`eat_assert!` vs `eat_expect!` 的差別是本節的重點：

- **`eat_assert!`** —— 用在「已經 peek 確認過」的地方。消耗失敗代表 parser 自己有 bug，應該 panic。
- **`eat_expect!`** —— 用在「期待但不保證」的地方。消耗失敗是使用者的語法錯誤，應該產生錯誤訊息。

看 `EXPLAIN QUERY PLAN` 的處理：`TK_QUERY` 是 peek 過才吃的，用 `eat_assert!`；但 `TK_PLAN` 沒 peek 過（`EXPLAIN QUERY` 後面不一定是 `PLAN`），所以用 `eat_expect!`。使用者打 `EXPLAIN QUERY FOO` 會得到語法錯誤而不是 panic。

**這個區分是「用型別／巨集表達不變量」的實例**：哪些情況是程式錯誤、哪些是使用者錯誤，在程式碼上就分清楚了。

### parse_stmt：語句分派

**`sqlite/parser/src/parser.rs:659-694`** — 完整貼出：

```rust
    fn parse_stmt(&mut self) -> Result<Stmt> {
        let tok = peek_expect!(
            self,
            TK_BEGIN,
            TK_COMMIT,
            TK_END,
            TK_ROLLBACK,
            TK_SAVEPOINT,
            TK_RELEASE,
            TK_CREATE,
            TK_SELECT,
            TK_VALUES,
            TK_WITH,
            TK_ANALYZE,
            TK_ATTACH,
            TK_DETACH,
            TK_PRAGMA,
            TK_VACUUM,
            TK_ALTER,
            TK_DELETE,
            TK_DROP,
            TK_INSERT,
            TK_REPLACE,
            TK_UPDATE,
            TK_REINDEX,
            TK_OPTIMIZE
        );

        match tok.token_type {
            TK_BEGIN => self.parse_begin(),
            TK_COMMIT | TK_END => self.parse_commit(),
            TK_ROLLBACK => self.parse_rollback(),
            TK_SAVEPOINT => self.parse_savepoint(),
            TK_RELEASE => self.parse_release(),
            TK_CREATE => self.parse_create_stmt(),
            TK_SELECT | TK_VALUES => Ok(Stmt::Select(self.parse_select()?)),
```

```rust
            // ── 省略（sqlite/parser/src/parser.rs:695-720 附近）：TK_WITH、TK_INSERT、
            //    TK_UPDATE、TK_DELETE、TK_DROP、TK_ALTER、TK_PRAGMA 等其餘分支，
            //    形式與上面相同：token 型別 → 對應的 parse_* 函式 ──
```

`peek_expect!` 把「合法的起始 token」列成清單。這個清單有雙重作用：決定分派，以及**產生錯誤訊息**。使用者打 `FOO BAR;` 時，錯誤訊息可以列出「期待 BEGIN、COMMIT、CREATE、SELECT……」，遠比「語法錯誤」有用。

注意 `TK_SELECT | TK_VALUES` 走同一條路：`VALUES (1,2)` 在 SQL 裡是一種特殊的 SELECT（產生常值列的查詢），所以共用 `parse_select`。

### 遞迴下降是什麼

`parse_stmt` → `parse_select` → `parse_from` / `parse_where` → `parse_expr` → `parse_expr_operand` → 可能再回到 `parse_select`（子查詢）。

**函式呼叫結構直接對應語法結構**，這就是遞迴下降。優點是好讀好改（相對於 Lemon/yacc 這類產生器）；代價是**語法的巢狀深度會直接變成 Rust 的 stack 深度**——這帶出下一節。

---

---

> ### ⏸ Session 1 到此
>
> 目前為止涵蓋了：Lexer 如何切 token、Parser 的狀態與 next_cmd/parse_stmt 分派。
>
> 休息之前，先確認你能說出這幾件事；說不出來就往回翻，不要硬推進——後半段會用到它們。
>
> **Session 2** 從下一節開始：遞迴深度防護、SQL 參數編號、AST 的結構。

---

## 遞迴深度防護：一個真實的攻擊面

### 上限與理由

**`sqlite/parser/src/parser.rs:166-170`** — 完整貼出：

```rust
/// Maximum query expression depth, our equivalent of SQLite's
/// `SQLITE_MAX_EXPR_DEPTH` (default 1000). Kept lower because our recursive
/// translator/optimizer uses larger stack frames per nesting level, so a
/// 1000-deep tree still overflows a default 8 MiB thread stack in debug builds.
pub const MAX_EXPR_DEPTH: usize = 100;
```

這段註解資訊量很大：

- Turso 的上限是 **100**，SQLite 是 **1000**。
- 為什麼更低？因為**後續的 translator/optimizer 每層用的 stack frame 更大**。parser 撐得住 1000 層，但編譯階段撐不住。
- 「in debug builds」點出 debug build 的 frame 比 release 大，所以上限要以最壞情況設定。

**這是一個跨階段的限制**：parser 的上限不是為了保護 parser 自己，而是為了保護下游。這種「在最早的關卡擋住下游擋不住的東西」是分層設計的常見手法。

### 兩層防護

**`sqlite/parser/src/parser.rs:2035-2049`** — 完整貼出：

```rust
    /// Parse an expression, bounding both the parser's recursion depth and the
    /// height of the resulting tree by [`MAX_EXPR_DEPTH`]. On return,
    /// `last_expr_height` holds the height of the returned expression.
    fn parse_expr(&mut self, precedence: u8) -> Result<Box<Expr>> {
        self.expr_nesting_depth += 1;
        if self.expr_nesting_depth as usize > MAX_EXPR_DEPTH {
            self.expr_nesting_depth -= 1;
            return Err(Error::ParseError(format!(
                "Expression tree is too large (maximum depth {MAX_EXPR_DEPTH})"
            )));
        }
        let result = self.parse_expr_inner(precedence);
        self.expr_nesting_depth -= 1;
        result
    }
```

`parse_expr` 是一層薄包裝，只做三件事：進入時 +1、超過就報錯、離開時 -1。真正的解析在 `parse_expr_inner`。

**注意錯誤路徑也做了 `-= 1`。** 這是成對記帳的紀律：任何一條退出路徑都要還原計數。漏一條，後續的解析就會誤判深度。

但只有這一層還不夠：

**`sqlite/parser/src/parser.rs:2051-2062`** — 完整貼出：

```rust
    fn parse_expr_inner(&mut self, precedence: u8) -> Result<Box<Expr>> {
        let mut result = self.parse_expr_operand()?;
        // Running height of `result`, maintained bottom-up so that a left-deep
        // chain (`a OR b OR c ...`), which this loop consumes iteratively, is
        // bounded too. Check the operand up front: it can already be over the
        // limit on its own without being followed by an operator.
        let mut result_height = self.last_expr_height;
        if result_height > MAX_EXPR_DEPTH {
            return Err(Error::ParseError(format!(
                "Expression tree is too large (maximum depth {MAX_EXPR_DEPTH})"
            )));
        }
```

**第二層防護在防什麼？** 註解說得很清楚：`a OR b OR c OR d ...`。

這種左深鏈（left-deep chain）是**用迴圈**消耗的，不是遞迴——所以 `expr_nesting_depth` 完全不會增加。parser 可以輕鬆吃下一萬個 `OR`。但產生的 AST 是一棵**一萬層深的左傾樹**：

```text
        OR
       /  \
      OR   d
     /  \
    OR   c
   /  \
  a    b
```

parser 沒事，但下游的 translator 是**遞迴走訪**這棵樹的——它會爆 stack。

所以需要第二個獨立的量：`last_expr_height`，追蹤**產生的樹有多高**（而非解析時遞迴多深）。這兩者在左深鏈的情況下完全脫鉤。

**這是本篇最值得記住的一課**：防護要對準真正的風險量。「遞迴深度」和「樹高」聽起來像同一件事，實際上不是；只防一個就會留下漏洞。

### 特例：高度會重置的情況

**`sqlite/parser/src/parser.rs:2070-2075`** — 節錄：

```rust
            let mut tok = self.peek_no_eof()?;
            let mut not = false;
            // Set by arms that replace `result` with a fresh leaf (e.g. `x IN ()`)
            // instead of wrapping it, so its height resets to 1.
            let mut leaf = false;
```

有些語法不是「包住」原本的表達式，而是「換掉」它。例如 `x IN ()`（空集合）可以直接化簡成常數 false。這時樹高要**重置為 1**，而不是繼續累加。

漏掉這個處理不會造成安全問題（只會過度保守地拒絕合法查詢），但會造成使用者困惑。**這種細節就是「相容性」的真實內容。**

---

## SQL 參數：三種語法，一套編號

**`sqlite/parser/src/parser.rs:200-239`** — 完整貼出：

```rust
    fn create_variable(&mut self, token: &'a [u8]) -> Result<Expr> {
        debug_assert!(!token.is_empty());
        if token == b"?" {
            // Rewrite anonymous variables in encounter order
            self.last_variable_id += 1;
            let index = NonZeroU32::new(self.last_variable_id).unwrap();
            Ok(Expr::Variable(Variable::indexed(index)))
        } else if token[0] == b'?' {
            let variable_str = std::str::from_utf8(&token[1..])
                .map_err(|e| Error::Custom(format!("non-utf8 positional variable id: {e}")))?;
            let variable_id = variable_str
                .parse::<u32>()
                .map_err(|e| Error::Custom(format!("non-integer positional variable id: {e}")))?;
            if variable_id == 0 {
                return Err(Error::Custom(
                    "variable number must be between ?1 and ?250000".to_string(),
                ));
            }
            if variable_id > 250000 {
                return Err(Error::Custom(
                    "variable number must be between ?1 and ?250000".to_string(),
                ));
            }
            self.last_variable_id = self.last_variable_id.max(variable_id);
            let index = NonZeroU32::new(variable_id).unwrap();
            Ok(Expr::Variable(Variable::indexed(index)))
        } else {
            debug_assert!(matches!(token[0], b':' | b'@' | b'$'));
            let index = if let Some(index) = self.named_variables.get(token).copied() {
                index
            } else {
                self.last_variable_id += 1;
                let index = NonZeroU32::new(self.last_variable_id).unwrap();
                self.named_variables.insert(token, index);
                index
            };
            Ok(Expr::Variable(Variable::named(
                from_bytes_as_str(token),
                index,
            )))
        }
    }
```

三種參數語法，都要映射到同一個編號空間：

**一、匿名 `?`**

```rust
            self.last_variable_id += 1;
```

依出現順序自動編號。`SELECT ?, ?, ?` 得到 1, 2, 3。

**二、指定位置 `?N`**

```rust
            self.last_variable_id = self.last_variable_id.max(variable_id);
```

這行是關鍵。使用者寫 `?5` 之後，`last_variable_id` 跳到 5。所以接著寫的 `?` 會拿到 6，不會和已用的 5 衝突。

用 `max` 而非直接賦值，是因為使用者可能倒著寫：`SELECT ?5, ?2` 之後的 `?` 應該是 6，不是 3。

上下限檢查 `?1` 到 `?250000` 對齊 SQLite 的限制。`?0` 被拒絕，所以型別可以用 `NonZeroU32`——**用型別把不可能的狀態排除掉**。

**三、具名 `:name` / `@name` / `$name`**

```rust
            let index = if let Some(index) = self.named_variables.get(token).copied() {
                index
            } else {
                self.last_variable_id += 1;
                // ...插入 map...
            };
```

同名參數共用同一個編號。`SELECT * FROM t WHERE a = :x OR b = :x` 裡兩個 `:x` 是同一個 slot，使用者只需綁定一次。

`named_variables: HashMap<&'a [u8], NonZeroU32>` 的 key 是 **borrow 自原始輸入的 bytes**，不是 `String`。又一次避免配置。

**這個函式的價值**：它把三種表面語法統一成「一個整數 slot 編號」。後續的編譯與執行只認編號，不必再管使用者當初寫的是哪種語法。

---

## 第三層：AST

### Cmd：最外層

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

三個變體包同一個 `Stmt`。`EXPLAIN` 只是標記——`03-source-code-learn-*.md` 會看到編譯器如何用 or-pattern 一次解構三者，走完全相同的編譯路徑。

### Expr：表達式樹

**`sqlite/parser/src/ast.rs:426-456`** — 節錄開頭幾個變體：

```rust
pub enum Expr {
    /// `BETWEEN`
    Between {
        /// expression
        lhs: Box<Expr>,
        /// `NOT`
        not: bool,
        /// start
        start: Box<Expr>,
        /// end
        end: Box<Expr>,
    },
    /// binary expression
    Binary(Box<Expr>, Operator, Box<Expr>),
    /// Register reference for DBSP expression compilation
    /// This is not part of SQL syntax but used internally for incremental computation
    Register(usize),
    /// `CASE` expression
    Case {
        /// operand
        base: Option<Box<Expr>>,
        /// `WHEN` condition `THEN` result
        when_then_pairs: Vec<(Box<Expr>, Box<Expr>)>,
        /// `ELSE` result
        else_expr: Option<Box<Expr>>,
    },
    /// CAST expression
    Cast {
        /// expression
        expr: Box<Expr>,
        /// `AS` type name
```

```rust
    // ── 省略（sqlite/parser/src/ast.rs:457-700 附近）：Collate、Exists、
    //    FunctionCall、FunctionCallStar、Id、InList、InSelect、IsNull、Like、
    //    Literal、Name、NotNull、Parenthesized、Qualified、Raise、Subquery、
    //    Unary、Variable 等其餘數十個變體 ──
```

三個觀察：

**一、到處都是 `Box<Expr>`。** 遞迴型別在 Rust 必須裝箱（否則大小無法在編譯期決定）。這也意味著**每個節點都是一次 heap 配置**——深樹的成本不只在 stack，也在配置次數。

**二、`Expr::Register(usize)` 不是 SQL 語法。** 註解寫明「not part of SQL syntax but used internally」。它是編譯器為了增量計算（materialized view）而**回填進 AST** 的節點。

這揭露了一個實務現象：**AST 不是唯讀的中間表示**。編譯器有時會改寫它。`05b` 提到的 UPDATE 表達式索引也用了類似手法（把欄位參照改寫成 `Expr::Register`）。這是設計上的取捨——比起另建一套 IR，直接改寫 AST 更省事，但也讓「AST 純粹代表語法」的直覺不再完全成立。

**三、`Between` 沒有被展開成兩個比較。** parser 忠實保留使用者寫的形式，不做任何化簡。化簡是 optimizer 的工作（見 `03`）。**parser 的產物應該盡量貼近原文**，這樣錯誤訊息、`EXPLAIN` 顯示、schema 存回 SQL 文字都能保真。

---

## ast/fmt.rs：反方向的路

`sqlite/parser/src/ast/fmt.rs` 做的是相反的事：把 AST 變回 SQL 文字。

為什麼需要？因為 `CREATE TABLE` 的原始 SQL 要**存進 `sqlite_schema`**，開啟資料庫時再讀出來重新 parse 成 schema。過程中 engine 有時需要產生正規化或可重放的 SQL，例如：

- `ALTER TABLE` 之後要更新 `sqlite_schema` 裡的定義。
- trigger 的 body 需要重建成文字儲存。
- schema 的 replay / 除錯輸出。

`05-source-code-learn-*.md` 會看到 `sqlite_schema` 這條路徑的完整樣貌。

---

## 動手驗證

驗證「parser 不查 schema」：

```bash
cargo run -q --bin tursodb -- -q
```

```sql
SELECT * FROM 完全不存在的表;
```

得到的是「no such table」而不是語法錯誤——證明它通過了 parser，在編譯階段才失敗。

驗證表達式深度上限（`MAX_EXPR_DEPTH = 100`）：

```sql
SELECT ((((((((((((((((((((((((((((((((((((((((((((((((((
((((((((((((((((((((((((((((((((((((((((((((((((((1
))))))))))))))))))))))))))))))))))))))))))))))))))
))))))))))))))))))))))))))))))))))))))))))))))))));
```

100 層括號應該會觸發 `Expression tree is too large`。

驗證參數編號規則：

```sql
CREATE TABLE t(a,b,c);
SELECT ?5, ?, ?2;
```

第一個是 5，第二個因為 `max` 規則會是 6，第三個是 2。

追 source：

```bash
rg -n "pub struct Lexer|pub struct Token" sqlite/parser/src/lexer.rs
rg -n "pub fn next_cmd|fn parse_stmt|fn parse_expr\b|fn create_variable" sqlite/parser/src/parser.rs
rg -n "MAX_EXPR_DEPTH" sqlite/parser/src/parser.rs
rg -n "pub enum Cmd|pub enum Stmt|pub enum Expr" sqlite/parser/src/ast.rs
```

---

## 自我檢查

1. `Token` 的 `value` 是 `&'a [u8]` 而不是 `String`。這個決定帶來什麼好處？對 `Parser` 的 lifetime 有什麼影響？
2. `eat_assert!` 和 `eat_expect!` 分別用在什麼情況？用錯會發生什麼？
3. `#` 開頭的無效輸入為什麼要產生一個 `TK_ILLEGAL` token，而不是直接回傳錯誤？
4. `MAX_EXPR_DEPTH` 為什麼設 100 而不是 SQLite 的 1000？理由和 parser 本身有關嗎？
5. `expr_nesting_depth` 和 `last_expr_height` 為什麼是兩個獨立的量？舉一個只有其中一個會成長的輸入。
6. `?5` 之後的 `?` 為什麼是 6？`last_variable_id.max(...)` 解決什麼問題？
7. `?0` 為什麼被拒絕？這和 `NonZeroU32` 有什麼關係？
8. `Expr::Register(usize)` 不是 SQL 語法，它為什麼會出現在 AST 裡？這對「AST 代表語法」的直覺造成什麼影響？
9. parser 為什麼不把 `BETWEEN` 展開成兩個比較？

---

下一篇 `03-source-code-learn-1-planner.md`：AST 如何變成 query plan，optimizer 如何選 index，emitter 如何吐出 bytecode。
