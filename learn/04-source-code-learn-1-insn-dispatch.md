# 04. 源碼精讀：VDBE 指令集、Register、Cursor 操作

本篇對應 `04-vdbe-execution.md`，把 bytecode VM 的內部結構攤開來讀：指令怎麼定義、怎麼分派、register 怎麼運作、cursor 指令怎麼推進迴圈。

`01-source-code-learn-4-step-vm.md` 已經講過 VM 的**主迴圈**（`normal_step`）。本篇補的是**指令本身**：一條 `Insn` 從定義到執行的完整樣貌。兩篇互補，建議先讀那篇。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 75–90 分鐘（約 18k 字，其中 41% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇的檔案跳轉路線

```text
core/vdbe/insn.rs      Insn enum ── 指令的定義
  ├─ InsnVariants      指令的「標籤」（不含資料）
  ├─ to_function       標籤 → 實作函式
  └─ INSN_VTABLE       編譯期產生的跳轉表
        └─> core/vdbe/execute.rs   op_* ── 指令的實作
              ├─ load_insn!        解構指令參數
              ├─ op_add            最單純的例子
              ├─ op_init           跳轉指令
              └─ op_next           cursor 推進 + 迴圈
                    └─> core/vdbe/mod.rs   Register / ProgramState
```

---

## Insn：指令的定義

### 每條指令是一個 enum 變體

**`core/vdbe/insn.rs:281-306`** — 完整貼出開頭幾個：

```rust
pub enum Insn {
    /// Initialize the program state and jump to the given PC.
    Init {
        target_pc: BranchOffset,
    },
    /// Write a NULL into register dest. If dest_end is Some, then also write NULL into register dest_end and every register in between dest and dest_end. If dest_end is not set, then only register dest is set to NULL.
    Null {
        dest: usize,
        dest_end: Option<usize>,
    },
    /// Mark the beginning of a subroutine tha can be entered in-line. This opcode is identical to Null
    /// it has a different name only to make the byte code easier to read and verify
    BeginSubrtn {
        dest: usize,
        dest_end: Option<usize>,
    },
    /// Move the cursor P1 to a null row. Any Column operations that occur while the cursor is on the null row will always write a NULL.
    NullRow {
        cursor_id: CursorID,
    },
    /// Add two registers and store the result in a third register.
    Add {
        lhs: usize,
        rhs: usize,
        dest: usize,
    },
```

```rust
    // ── 省略（core/vdbe/insn.rs:307-1990 附近）：其餘約 200 個指令變體，
    //    涵蓋算術、比較、cursor 操作、聚合、排序、視窗函式、虛擬表、
    //    交易控制、子程式等 ──
```

三個設計特徵：

**一、具名欄位而非位置參數。** SQLite 的 VDBE 指令是 `(opcode, p1, p2, p3, p4, p5)` 這種通用格式，讀 C 原始碼時得一直查「這個 opcode 的 p2 是什麼意思」。Turso 用 Rust enum 讓每個參數有名字：`Add { lhs, rhs, dest }` 一看就懂。

**代價**是 `Insn` 這個 enum 的大小等於最大變體的大小。所以你會在別處看到針對指令大小的斟酌。

**二、`BeginSubrtn` 和 `Null` 的實作完全相同。** 註解說明了原因：

> This opcode is identical to Null it has a different name only to make the byte code easier to read and verify

**為了 EXPLAIN 的可讀性而增加一個指令**。這是務實的取捨——bytecode 是要給人除錯的，語義相同但意圖不同的操作值得分開命名。

**三、`NullRow` 的註解揭露了 OUTER JOIN 的實作。** 「把游標移到 null row，之後所有 Column 都回 NULL」——這就是 LEFT JOIN 沒配到對應列時的做法。`03-source-code-learn-1-planner.md` 講過 `WhereTerm` 為什麼要為 OUTER JOIN 特殊處理，`NullRow` 就是那套邏輯在執行期的對應物。

### BranchOffset：label 與實際位址的統一表示

`Init { target_pc: BranchOffset }` 的型別不是 `u32` 而是 `BranchOffset`。原因在 `01-source-code-learn-3-translate.md` 講過：編譯時常需要「跳到還沒產生的位置」，先配置 label 佔位，之後回填。

`BranchOffset` 就同時表示這兩種狀態：尚未解析的 label，或已解析的實際位址。執行期會檢查：

**`core/vdbe/execute.rs:404-416`** — 完整貼出 `op_init`：

```rust
pub fn op_init(
    _program: &Program,
    state: &mut ProgramState,
    insn: &Insn,
    _pager: &Arc<Pager>,
) -> Result<InsnFunctionStepResult> {
    load_insn!(Init { target_pc }, insn);
    if unlikely(!target_pc.is_offset()) {
        crate::bail_corrupt_error!("Unresolved label: {target_pc:?}");
    }
    state.pc = target_pc.as_offset_int();
    Ok(InsnFunctionStepResult::Step)
}
```

`if unlikely(!target_pc.is_offset())` —— 如果執行到這裡 label 還沒回填，代表**編譯器有 bug**。這時報 corrupt error 而不是靜默跳到奇怪的位置。

`unlikely(...)` 是給分支預測器的提示：這個檢查幾乎永遠不成立，讓 CPU 優先預測另一條路。**這種「必然為真的檢查」是防禦性程式設計的典型**——正常情況零成本（分支預測命中），出錯時立刻爆而不是產生難以追查的行為。

注意 `op_init` **直接設定 `state.pc`** 而不是 `+= 1`。這就是跳轉指令的實作方式：跳轉與否，差別只在如何寫 `state.pc`。

---

## 指令分派：編譯期產生的跳轉表

VM 主迴圈每執行一條指令都要「從 `Insn` 找到對應的實作函式」。這件事發生數十億次，所以做法很講究。

### to_function：一對一的對應表

**`core/vdbe/insn.rs:2017-2029`** — 節錄：

```rust
    // This function is used for generating `INSN_VTABLE`.
    // We need to keep this function to make sure we implement all opcodes
    pub(crate) const fn to_function(self) -> InsnFunction {
        match self {
            InsnVariants::Init => execute::op_init,
            InsnVariants::Null => execute::op_null,
            InsnVariants::BeginSubrtn => execute::op_null,
            InsnVariants::NullRow => execute::op_null_row,
            InsnVariants::Add => execute::op_add,
            InsnVariants::Subtract => execute::op_subtract,
            InsnVariants::Multiply => execute::op_multiply,
            InsnVariants::Divide => execute::op_divide,
            InsnVariants::DropIndex => execute::op_drop_index,
            InsnVariants::Compare => execute::op_compare,
```

```rust
            // ── 省略（core/vdbe/insn.rs:2030-2230 附近）：其餘約 200 個
            //    InsnVariants → op_* 的對應 ──
```

注意 `InsnVariants` 和 `Insn` 是**兩個不同型別**：

- `Insn` —— 帶資料的完整指令（`Add { lhs: 2, rhs: 3, dest: 1 }`）。
- `InsnVariants` —— 只有標籤、不帶資料，可以轉成 `usize` 索引。

分開的理由下一節就會看到。

註解那句話值得注意：

> We need to keep this function to make sure we implement all opcodes

這個 `match` 沒有 `_ =>` 萬用分支，所以**新增指令卻忘記實作就編譯不過**。用編譯器強制完整性，而不是靠人記得。

### const fn 建表：零執行期成本

**`core/vdbe/insn.rs:1993-2007`** — 完整貼出：

```rust
const fn get_insn_virtual_table() -> [InsnFunction; InsnVariants::COUNT] {
    let mut result: [InsnFunction; InsnVariants::COUNT] = [execute::op_init; InsnVariants::COUNT];

    let mut insn = 0;
    while insn < InsnVariants::COUNT {
        result[insn] = InsnVariants::from_repr(insn as u8)
            .expect("insn index should be valid within COUNT")
            .to_function();
        insn += 1;
    }

    result
}

const INSN_VTABLE: [InsnFunction; InsnVariants::COUNT] = get_insn_virtual_table();
```

**這整個迴圈在編譯期執行。** `const fn` + `const INSN_VTABLE` 代表產生的是一個**靜態陣列常數**，直接放進二進位檔的唯讀區段。程式啟動時不做任何初始化工作。

於是執行期的分派變成：

**`core/vdbe/insn.rs:2013-2015`**

```rust
    pub(crate) const fn to_function_fast(self) -> InsnFunction {
        INSN_VTABLE[self as usize]
    }
```

**一次陣列索引。** 沒有 match、沒有分支鏈、沒有虛擬函式呼叫。

這也解釋了為什麼要把 `InsnVariants` 從 `Insn` 分出來：只有不帶資料的標籤才能轉成 `usize` 當索引。

`01-source-code-learn-4-step-vm.md` 看過的主迴圈那一行：

```rust
            let insn_function = insn.to_function();
```

底下就是這個查表。**在一個每秒執行數億條指令的迴圈裡，分派成本從「match 分支鏈」降到「一次記憶體讀取」是有意義的最佳化。**

---

## load_insn!：安全與速度兼顧的解構

每個 `op_*` 函式收到的是 `&Insn`（完整 enum），但它只關心自己那個變體。解構的巨集是：

**`core/vdbe/execute.rs:167-179`** — 完整貼出：

```rust
macro_rules! load_insn {
    ($variant:ident { $($field:tt $(: $binding:pat)?),* $(,)? }, $insn:expr) => {
        #[cfg(debug_assertions)]
        let Insn::$variant { $($field $(: $binding)?),* } = $insn else {
            panic!("Expected Insn::{}, got {:?}", stringify!($variant), $insn);
        };
        #[cfg(not(debug_assertions))]
        let Insn::$variant { $($field $(: $binding)?),*} = $insn else {
             // this will optimize away the branch
            unsafe { std::hint::unreachable_unchecked() };
        };
    };
}
```

同一個解構，兩種編譯模式：

- **debug build** —— 型別不符就 `panic!`，訊息包含期待與實際的指令。
- **release build** —— `unreachable_unchecked()`，告訴編譯器「這個分支不可能發生」，於是**檢查被完全最佳化掉**。

為什麼 release 可以省略檢查？因為對應關係由 `INSN_VTABLE` 保證：`op_add` 只會透過 `InsnVariants::Add` 這個索引被取出，傳進來的必然是 `Insn::Add`。這是型別系統加建表方式共同保證的不變量。

**這是「不變量在別處被保證，此處用 unsafe 換取速度」的典型用法**，而且保留了 debug build 的檢查——如果哪天不變量被破壞，debug 測試會立刻抓到。

---

## Register：VM 的暫存格

**`core/vdbe/mod.rs:258-262`** — 完整貼出：

```rust
pub enum Register {
    Value(Value),
    Aggregate(AggContext),
    Record(ImmutableRecord),
}
```

只有三種內容：

- **`Value`** —— 一般的 SQL 值（整數、浮點、文字、blob、NULL）。
- **`Aggregate`** —— 聚合函式的累加器。`sum(x)` 需要跨多列保存狀態，那個狀態就放在 register 裡（見 `05b`）。
- **`Record`** —— 編碼後的 record。`MakeRecord` 產生它、`Insert` 消費它，中間存在 register。

**register 不只放「值」，也放「累加器」和「編碼後的位元組」**。這比一般虛擬機的暫存器概念更寬。

### set_int：避免重複配置

**`core/vdbe/mod.rs:270-278`** — 節錄：

```rust
    #[inline(always)]
    /// Sets the value of the register to an integer,
    /// reusing the existing Register::Value(Value::Numeric(Numeric::Integer(_))) if possible,
    /// which is faster than always creating a new one.
    pub fn set_int(&mut self, val: i64) {
        match self {
            Register::Value(Value::Numeric(Numeric::Integer(existing))) => {
                *existing = val;
            }
```

```rust
            // ── 省略：其他情況下建立新的 Register::Value ──
```

如果 register 裡本來就是整數，**直接覆寫那個 i64**，不重建整個 enum。

看起來是微不足道的最佳化，但放進脈絡就有意義：一個掃描百萬列的迴圈裡，rowid register 每列都被寫一次。省下一次 enum 建構 × 百萬次是可觀的。而且對 `Value::Text` 這類持有堆積配置的變體，重建還可能觸發配置與釋放。

`ProgramState` 裡 registers 的型別是 `Box<[Register]>`（`01-source-code-learn-4-step-vm.md` 提過），大小在編譯期由 `PreparedProgram.max_registers` 決定，不需要 `Vec` 的動態成長能力。

---

## 三個指令的完整實作

### op_add：最單純的形狀

**`core/vdbe/execute.rs:418-432`** — 完整貼出：

```rust
pub fn op_add(
    _program: &Program,
    state: &mut ProgramState,
    insn: &Insn,
    _pager: &Arc<Pager>,
) -> Result<InsnFunctionStepResult> {
    load_insn!(Add { lhs, rhs, dest }, insn);
    state.registers[*dest].set_value(
        state.registers[*lhs]
            .get_value()
            .exec_add(state.registers[*rhs].get_value()),
    );
    state.pc += 1;
    Ok(InsnFunctionStepResult::Step)
}
```

15 行，示範了所有 `op_*` 函式的共同結構：

1. **統一簽章** `(&Program, &mut ProgramState, &Insn, &Arc<Pager>)` —— 所以它們能放進同一個函式指標陣列。用不到的參數加底線（`_program`、`_pager`），一看就知道這條指令不碰程式 metadata 也不碰儲存層。
2. **`load_insn!` 解構參數。**
3. **對 registers 做事。**
4. **`state.pc += 1`** —— 前進到下一條。
5. **回 `Step`** —— 告訴主迴圈「做完了，繼續」。

實際的加法在 `exec_add`，那裡處理 SQL 的型別規則：整數溢位要不要轉浮點、文字要不要嘗試轉數字、NULL 加任何東西都是 NULL。**這些規則屬於 `Value` 層而非 VM 層**，所以 `05-source-code-learn-schema-values-records.md` 才是它們的主場。

**`op_add` 完全不碰 pager，所以它永遠不會 I/O。** 這類純計算指令是 VM 裡的多數。

### op_result_row：為什麼 step 會停下來

`01-source-code-learn-5-cursor-storage.md` 貼過完整程式碼，這裡只回顧關鍵兩行：

**`core/vdbe/execute.rs:2989-2991`**

```rust
    state.result_row = Some(row);
    state.pc += 1;
    Ok(InsnFunctionStepResult::Row)
```

回傳 `Row` 讓主迴圈 return，把控制權交還呼叫者。而 **PC 已經先前進了**，所以下次 step 從下一條指令繼續，不會重複輸出同一列。

這就是 streaming 的實作：VM 不把所有列算完，算一列停一次。

### op_next：迴圈是怎麼跑起來的

`Next` 是理解 bytecode 迴圈的關鍵。看它的尾段：

**`core/vdbe/execute.rs:3037-3054`** — 完整貼出：

```rust
    if !is_empty {
        // Increment metrics for row read
        state.record_rows_read(1);
        state.metrics.btree_next = state.metrics.btree_next.saturating_add(1);
        state.metrics.search_count = state.metrics.search_count.saturating_add(1);
        // Track if this is a full table scan or index scan
        if let Some((_, cursor_type)) = program.cursor_ref.get(*cursor_id) {
            if cursor_type.is_index() {
                state.metrics.index_steps = state.metrics.index_steps.saturating_add(1);
            } else if matches!(cursor_type, CursorType::BTreeTable(_)) {
                state.metrics.fullscan_steps = state.metrics.fullscan_steps.saturating_add(1);
            }
        }
        state.pc = pc_if_next.as_offset_int();
    } else {
        state.pc += 1;
    }
    Ok(InsnFunctionStepResult::Step)
}
```

**整個迴圈機制就在最後那五行**：

- **還有下一列** → `state.pc = pc_if_next`，**跳回迴圈開頭**。
- **沒有了** → `state.pc += 1`，**繼續往下**（離開迴圈）。

對照 `01-source-code-learn-4-step-vm.md` 那份 EXPLAIN：

```text
2     Rewind             0     6     0    → 表為空就跳到 6 (Halt)
3       Column           0     1     1
4       ResultRow        1     1     0
5     Next               0     3     0    → 還有列就跳回 3
6     Halt               0     0     0
```

`Next` 的 p2 = 3，正是 `Column` 的位址。**bytecode 沒有「迴圈」這種結構，只有條件跳轉**——迴圈是 `Rewind`（進入前檢查）與 `Next`（每輪結尾跳回）合作出來的。

中段的 metrics 也值得一提：`fullscan_steps` 和 `index_steps` 分開統計。這讓使用者能診斷「這條查詢到底有沒有用到 index」——如果 `fullscan_steps` 很高，代表在做全表掃描。**可觀測性是設計進去的，不是事後加的。**

### 中段：cursor 型別的分派

**`core/vdbe/execute.rs:3024-3036`** — 節錄：

```rust
            Cursor::MaterializedView(mv_cursor) => {
                let has_more = return_if_io!(mv_cursor.next());
                !has_more
            }
            Cursor::IndexMethod(_) => {
                let cursor = cursor.as_index_method_mut();
                let has_more = return_if_io!(cursor.query_next());
                !has_more
            }
            _ => panic!("Next on non-btree/materialized-view cursor"),
        }
    };
```

每種 cursor 有自己的 `next`，但都可能 `return_if_io!`——推進游標可能需要讀下一個 page。

最後那個 `panic!` 是**斷言不變量**：`Next` 只該用在可迭代的 cursor 上，用在別種 cursor 是編譯器的 bug。這符合專案的「Assert invariants，不要用 if 靜默容錯」原則。

`return_if_io!` 在 `execute.rs` 有自己的版本：

**`core/vdbe/execute.rs:181-188`** — 節錄：

```rust
macro_rules! return_if_io {
    ($expr:expr) => {
        match $expr {
            Ok(IOResult::Done(v)) => v,
            Ok(IOResult::IO(io)) => return Ok(InsnFunctionStepResult::IO(io)),
            Err(err) => {
                mark_unlikely();
```

和 `core/types.rs` 那個版本的差別在**回傳型別**：這裡包成 `InsnFunctionStepResult::IO`（VM 層的型別），`types.rs` 那個包成 `IOResult::IO`（storage 層的型別）。同名巨集、不同層各一份，讓 I/O 能在跨層時自動轉換。

---

## EXPLAIN：同一份 bytecode 的另一種消費方式

`01-source-code-learn-4-step-vm.md` 提過 `Program::step` 依 `QueryMode` 分派到 `explain_step`。

**`core/vdbe/mod.rs:1629-1634`** — 節錄：

```rust
        let pc = state.pc as usize;

        // Explain the current instruction from the active program.
        // We collect subprograms separately to avoid borrow conflicts with explain_state.
        let (row, subprogram) = if let Some(ref current) = explain_state.current {
            let (insn, _) = &current.insns[pc];
```

`explain_step` 同樣用 `state.pc` 走訪 `insns`，但把每條指令**格式化成一列文字**而不是執行它。

**`core/vdbe/mod.rs:1610-1627`** — 節錄子程式展開：

```rust
        // Advance to the next subprogram if the current one is finished
        loop {
            if let Some(ref current) = explain_state.current {
                if (state.pc as usize) < current.insns.len() {
                    break;
                }
            } else if (state.pc as usize) < self.insns.len() {
                break;
            }
            // Current program is done, pop next subprogram from queue
            if let Some(next) = explain_state.pending.pop_front() {
                explain_state.current = Some(next);
                state.pc = 0;
            } else {
                explain_state.current = None;
                return Ok(StepResult::Done);
            }
        }
```

主程式列完後，從 `pending` 佇列取出子程式繼續列。**所以 `EXPLAIN` 看得到 trigger 和 FK action 內部的 bytecode**——那些是編譯期就嵌進去的子程式（`Insn::Program`）。

格式化的實作在 `core/vdbe/explain.rs` 的 `insn_to_str`。它也被 `get_vdbe_trace()` 除錯模式共用（`01-source-code-learn-4-step-vm.md` 省略的那段），所以 EXPLAIN 輸出和 trace 輸出格式一致。

---

## 指令分類速查

不需要背，但要能歸類：

**純計算（不碰 storage，永不 I/O）**
```text
Integer, Real, String8, Blob, Null       載入常值
Copy, Move, SCopy                        register 搬移
Add, Subtract, Multiply, Divide, Remainder
Eq, Ne, Lt, Le, Gt, Ge, Compare          比較
And, Or, Not, BitAnd, BitOr, BitNot
Cast, Affinity                           型別轉換
Function                                 純量函式呼叫
```

**控制流（只改 PC）**
```text
Init, Goto, Gosub, Return
If, IfNot, IfPos, IfNullRow, Jump
Once                                     只執行一次的區塊
Halt                                     結束
```

**Cursor / storage（可能 I/O）**
```text
OpenRead, OpenWrite, OpenEphemeral, Close
Rewind, Last, Next, Prev
SeekRowid, SeekGE, SeekGT, SeekLE, SeekLT
IdxGT, IdxGE, IdxLT, IdxLE               index 邊界檢查
Column, RowId, NullRow
Insert, Delete, IdxInsert, IdxDelete
MakeRecord                               registers → record
```

**交易 / schema（可能 I/O）**
```text
Transaction, AutoCommit, Savepoint
CreateBtree, DestroyBtree, ClearBtree
SetCookie, ReadCookie, ParseSchema
```

**進階**
```text
SorterOpen, SorterInsert, SorterSort, SorterNext, SorterData
AggStep, AggFinal                        聚合
Program                                  子程式（trigger / FK）
VOpen, VFilter, VColumn, VNext, VUpdate  虛擬表
InitCoroutine, Yield, EndCoroutine       協程（子查詢串流）
```

判斷一條指令會不會 I/O，最快的方法是看它的實作**有沒有用 `_pager`**：參數寫成 `_pager` 的必定不會碰儲存層。

---

## 動手驗證

看純計算指令：

```bash
cargo run -q --bin tursodb -- -q
```

```sql
EXPLAIN SELECT 1 + 2;
```

實際輸出：

```text
addr  opcode             p1    p2    p3    p4             p5  comment
----  -----------------  ----  ----  ----  -------------  --  -------
0     Init               0     3     0                    0   Start at 3
1     ResultRow          1     1     0                    0   output=r[1]
2     Halt               0     0     0                    0
3     Integer            1     2     0                    0   r[2]=1
4     Integer            2     3     0                    0   r[3]=2
5     Add                2     3     1                    0   r[1]=r[2]+r[3]
6     Goto               0     1     0                    0
```

`Add 2 3 1` 對應 `Add { lhs: 2, rhs: 3, dest: 1 }`，也就是 `r[1] = r[2] + r[3]`。執行順序是 0 → 3 → 4 → 5 → 6 → 1 → 2（`Init`/`Goto` 結構的原因見 `03-source-code-learn-1-planner.md`）。

看迴圈：

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO t VALUES (1,'a'),(2,'b');
EXPLAIN SELECT name FROM t;
```

找到 `Next` 那一行，它的 p2 應該指回 `Column` 的位址。這就是迴圈。

用 VDBE trace 看實際執行：

```sql
.vdbe_trace on
SELECT name FROM t;
```

會逐條印出執行的指令與 register 變化，讓你看到 `Next` 如何反覆跳回。

追 source：

```bash
rg -n "^pub enum Insn" core/vdbe/insn.rs
rg -n "const fn get_insn_virtual_table|INSN_VTABLE|fn to_function" core/vdbe/insn.rs
rg -n "macro_rules! load_insn|pub fn op_add|pub fn op_init|pub fn op_next" core/vdbe/execute.rs
rg -n "pub enum Register" core/vdbe/mod.rs
```

---

## 自我檢查

1. `Insn` 用具名欄位而不是 SQLite 那種 `p1..p5`，好處與代價各是什麼？
2. `BeginSubrtn` 和 `Null` 的實作完全一樣，為什麼還要分成兩個指令？
3. `InsnVariants` 和 `Insn` 為什麼要分成兩個型別？
4. `INSN_VTABLE` 是 `const`，這代表它在什麼時候被建立？執行期的分派成本是多少？
5. `to_function` 的 `match` 為什麼不加 `_ =>` 萬用分支？
6. `load_insn!` 在 debug 和 release 下行為不同。release 用 `unreachable_unchecked` 的安全依據是什麼？
7. `Register` 除了 `Value` 還有 `Aggregate` 和 `Record`，各在什麼情況使用？
8. `set_int` 為什麼要嘗試重用既有的整數而不是直接建新的？
9. 光看 `op_*` 的函式簽章，怎麼判斷這條指令會不會做 I/O？
10. bytecode 裡沒有「迴圈」這種結構，`Rewind` 和 `Next` 是怎麼合作出一個迴圈的？
11. `op_next` 為什麼要分別統計 `fullscan_steps` 和 `index_steps`？
12. `EXPLAIN` 為什麼看得到 trigger 內部的 bytecode？

---

下一篇 `05-source-code-learn-schema-values-records.md`：schema 如何從 `sqlite_schema` 重建、`Value` 與 record 格式、affinity 規則。
