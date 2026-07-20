# 05b. Function 與 Expression: registers 如何算出值

本章目標：把 function system 從 schema/value 章節獨立出來，只看 expression compiler 和 runtime function call。

## 60 分鐘閱讀範圍

| 時間 | 檔案 | 只讀這些 symbol / 區塊 |
|---:|---|---|
| 10 分鐘 | `core/translate/expr/translator.rs` | `translate_expr` 入口與 literal/binary/function 分支 |
| 10 分鐘 | `core/function.rs` | `Func`、scalar/aggregate/window function 分類 |
| 10 分鐘 | `core/functions/mod.rs` | built-in function registration/resolution 入口 |
| 8 分鐘 | `core/functions/string.rs` | 挑一個簡單 scalar function 看參數/回傳 |
| 8 分鐘 | `core/vdbe/insn.rs` | `Function`、`AggStep`、`AggFinal` variants |
| 8 分鐘 | `core/vdbe/execute.rs` | 只 `rg` 對應 function opcode，不展開整個檔案 |
| 6 分鐘 | 練習與自我檢查 | 用 `EXPLAIN SELECT upper('a')` 對照 |

## 心智模型

Expression compiler 把 SQL expression 變成 register operations：

```text
1 + 2
  -> load 1 into register
  -> load 2 into register
  -> Add register/register -> dest register

upper(name)
  -> Column name -> argument register
  -> Function upper(arg) -> dest register
```

Function system 只是一種 expression evaluation。它不是 table scan，不是 storage，也不是 parser。

## Function 分類

Turso function 概念分幾類：

```text
scalar:
  one row in, one value out

aggregate:
  many rows update accumulator, final value out

window:
  aggregate-like, but over window frame

extension function:
  external module supplies callback
```

Built-in scalar functions如 string/math/date 在：

```text
core/functions/string.rs
core/functions/math.rs
core/functions/datetime.rs
core/functions/printf.rs
```

Compiler 遇到 `upper(name)` 會解析 function name/arg count，emit function-related opcode。VM 執行時從 registers 取 args，呼叫 function implementation，把結果寫回 register。

## Aggregate 為什麼比較難

`sum(x)` 和 `upper(x)` 不一樣。`upper(x)` 每 row 可直接算出結果；`sum(x)` 要跨 rows 保存 accumulator。

所以 aggregate/window 會牽涉：

```text
planner:
  找出 aggregate/window expression

emitter:
  emit AggStep / AggFinal 或 window-specific bytecode

runtime:
  register or side state 保存 accumulator
```

第一輪只要知道「aggregate 需要跨 row state」，不要追完整 window implementation。

## Custom types / arrays 的位置

Turso 有一些 SQLite 以外的 type/function feature，例如 custom types、domains、arrays、struct/union。第一輪只需知道：

```text
schema/translate:
  做型別解析、encode/decode expression planning

vdbe/register:
  執行 function/expression

storage:
  最終仍要落成 SQLite-compatible value/record bytes
```

相關入口：

```text
core/schema.rs
core/translate/schema.rs
core/translate/expr/custom_types.rs
core/translate/expr/arrays.rs
core/vdbe/array.rs
docs/sql-reference/data-types.mdx
docs/sql-reference/experimental-features.mdx
```

## 練習

跑：

```sql
EXPLAIN SELECT upper('alice'), 1 + 2;
```

預期你會看到 literal loading、function call、arithmetic、`ResultRow`。opcode 名稱可能隨版本調整，但你應該能找到「先把 argument 放進 register，再執行 function，再回傳 row」這條線。

追 source：

```bash
rg -n "translate_expr|FunctionCall|FunctionCallStar" core/translate/expr/translator.rs
rg -n "pub enum Func|ScalarFunc|AggFunc|Window" core/function.rs
rg -n "Function \\{|AggStep|AggFinal" core/vdbe/insn.rs
rg -n "op_function|AggStep|AggFinal" core/vdbe/execute.rs
```

## 自我檢查

1. scalar function 和 aggregate function 在 runtime 上最大的差別是什麼？
2. `upper(name)` 的 `name` 先在哪個 opcode 裡變成 register value？
3. function resolution 為什麼需要 arg count？
4. extension function 和 built-in function 對 compiler 來說有什麼共同點？

