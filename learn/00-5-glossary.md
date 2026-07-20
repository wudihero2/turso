# 00.5 名詞表: 先補資料庫新手的地基

本章目標：先把後面會一直出現的核心名詞講白話。這章不是源碼深讀，而是進入源碼前的 45-60 分鐘預備課。

## 60 分鐘安排

| 時間 | 讀什麼 | 目標 |
|---:|---|---|
| 10 分鐘 | SQLite architecture page | 先看官方分層圖，不追細節 |
| 20 分鐘 | 本章名詞表前半 | 搞懂 SQL -> VM -> storage 的詞 |
| 20 分鐘 | 本章名詞表後半 | 搞懂 transaction/WAL/I/O 的詞 |
| 10 分鐘 | 自我檢查 | 確認能用自己的話說出差異 |

建議先讀 SQLite 官方 architecture 頁面，至少看懂這幾個層：interface、SQL compiler、virtual machine、B-tree、pager、OS interface。

## 預備知識

Rust 方面，你不需要先精通整個 Rust，但至少要能辨認：

- `Arc<T>`: shared ownership。資料庫裡常用來讓多個 connection/cursor/program 共用同一份狀態。
- `Mutex` / `RwLock`: 保護共享狀態。讀 source 時先問「這個鎖保護的是 shared database state 還是 connection-local state」。
- `trait`: 介面。`IO`、`File`、`DatabaseStorage`、`CursorTrait` 都是 trait。
- `enum`: 狀態與資料變體。Turso 很多 correctness 都靠 enum state machine。
- `Result<T, E>`: 可能成功或失敗。
- macro: `return_if_io!` 這類 macro 是控制 I/O yield 的語法工具。

## 名詞表

SQL statement
: 一句 SQL，例如 `SELECT ...`、`INSERT ...`、`CREATE TABLE ...`。在 parser 後會變成 AST 裡的 `Stmt`。

AST
: Abstract Syntax Tree，語法樹。它只表示 SQL 文字的結構，不表示 table 一定存在，也不表示已經選好 index。

Compiler / translator
: 把 AST 變成 bytecode 的階段。Turso 的主要位置是 `core/translate/`。

VDBE
: Virtual Database Engine。SQLite-style register-based bytecode VM。Turso 的位置是 `core/vdbe/`。

Opcode / Insn
: VM 的一條指令。例如 `OpenRead`、`Column`、`ResultRow`、`Insert`。Turso 用 `Insn` 這個 enum 表示 opcode。

Register
: VM 執行時的暫存格。`Column` 會把 record 的某欄放進 register，`ResultRow` 會把一段 registers 回傳給使用者。

Cursor
: VM 看 table/index 的把手。它不是滑鼠游標，而是「目前指到 B-tree 的哪一筆」的執行狀態。

Rowid
: SQLite rowid table 的整數主鍵。一般 rowid table 的 table B-tree key 就是 rowid，所以 `WHERE rowid = 1` 可以直接 seek table B-tree。

Affinity
: SQLite 的型別傾向，不是硬性靜態型別。`INTEGER` 欄位偏向把值轉成 integer，`TEXT` 欄位偏向 text，但 runtime value 仍可以有不同型別。

Record
: SQLite on-disk row payload 格式。它不是 Rust struct，而是一段 bytes，包含 header、serial types、column data。

Page
: database file 的固定大小區塊，常見 4096 bytes。B-tree、freelist、overflow 都是 page 層概念。

B-tree
: table/index 的磁碟資料結構。table B-tree 用 rowid 當 key；index B-tree 用 indexed columns 加 rowid tie-breaker。

Pager
: 管 page cache、dirty page、transaction、commit、rollback、checkpoint 的層。B-tree 不直接寫檔案，而是透過 Pager。

WAL
: Write-Ahead Log。寫 transaction 先 append frames 到 `.db-wal`，commit frame durable 後，transaction 才算提交。

Checkpoint
: 把 WAL 裡已提交的 page frame 回寫到 main `.db` file。checkpoint 失敗不一定代表 commit 失敗，這是很重要的 correctness 區分。

Snapshot
: reader 看到的一致版本。WAL reader 會拿到 read mark，只看某個 commit frame 以前的內容。

fsync
: 要求 OS/磁碟把資料刷到穩定儲存。資料庫 durability 不能只靠 write system call。

VFS / IO backend
: 把 read/write/sync/open file 抽象成 trait。Turso 可以用 memory、Unix file、Windows file、io_uring、extension VFS 等 backend。

I/O yield
: 某個操作需要等 I/O 完成，所以先把控制權還給 caller。Turso core 用 `IOResult<T>` 明確表示這件事。

Re-entry
: yield 後 caller 再次呼叫同一個操作，操作要從上次停下的狀態繼續，而不是重做已完成的 mutation。

## 自我檢查

1. `AST` 和 `Plan` 有什麼差別？
2. `Register` 和 `Record` 有什麼差別？
3. `Cursor` 和 `Pager` 各負責什麼？
4. WAL commit 已成功但 checkpoint 失敗，transaction 應該算成功還是失敗？
5. 為什麼 explicit I/O yield 需要 state machine？

