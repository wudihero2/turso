# 04-2. 源碼精讀：Cursor 與 Storage 類 Opcode

`04-source-code-learn-1-insn-dispatch.md` 講了指令怎麼定義、怎麼分派、register 怎麼運作，並拆了三個**純計算**的 opcode（`op_init`、`op_add`、`op_result_row`）。

本篇拆**會碰儲存層**的那一類。它們是 VM 裡唯一可能 I/O 的指令，也是狀態機最集中的地方。

**閱讀方式**：程式碼直接貼在文中並標註 `檔案:行號`，不開編輯器也能讀完。行號可能漂移；symbol 名稱較穩定。

> **閱讀時間**：約 60–75 分鐘（約 17k 字，其中 45% 是原始碼）。
>
> 讀原始碼比讀散文慢得多，不要用讀文章的速度衡量進度——卡在某段程式碼上是正常的，那通常代表那裡有值得想的東西。

## 本篇涵蓋的 opcode

```text
定位類:   op_rewind      掃描起點
          op_seek_rowid  rowid 點查找
移動類:   op_next        （04-1 拆過，本篇補 cursor 分派細節）
讀取類:   op_column      （01-5 拆過，本篇補狀態機）
寫入類:   op_insert      六個子狀態的狀態機
          op_delete      含 IVM 擷取
```

**判斷一條指令會不會 I/O 的最快方法**（`04-source-code-learn-1-insn-dispatch.md` 提過）：看簽章的 `pager` 參數有沒有底線前綴。但要注意——**沒有 `pager` 也可能 I/O**，因為 cursor 自己持有 `Arc<Pager>`。真正的判準是**函式體裡有沒有 `return_if_io!`**。

---

## op_rewind：掃描的起點

**`core/vdbe/execute.rs:1675-1693`** — 完整貼出：

```rust
pub fn op_rewind(
    _program: &Program,
    state: &mut ProgramState,
    insn: &Insn,
    _pager: &Arc<Pager>,
) -> Result<InsnFunctionStepResult> {
    load_insn!(
        Rewind {
            cursor_id,
            pc_if_empty,
        },
        insn
    );
    assert!(pc_if_empty.is_offset());
    // Clear any bloom filter associated with this cursor so stale filter data
    // does not incorrectly reject valid matches in subsequent iterations.
    if let Some(filter) = state.get_bloom_filter_mut(*cursor_id) {
        filter.clear();
    }
```

**bloom filter 的清除是一個容易漏掉的正確性細節。**

bloom filter 用在 join 最佳化：先掃一張表建立「這些值存在」的機率式集合，掃另一張表時可以快速排除不可能匹配的列。

但 `Rewind` 表示「重新開始掃描」——如果這個 cursor 在 nested loop 的內層，它會被 rewind 很多次。**舊的 filter 資料留著會錯誤地排除有效的列**（filter 記的是上一輪的值域）。

註解說得很精確：「stale filter data does not **incorrectly reject valid matches**」。這是會產生**錯誤查詢結果**的 bug，不是效能問題。

**`core/vdbe/execute.rs:1694-1707`** — cursor 型別分派：

```rust
    let is_empty = {
        let cursor = state.get_cursor(*cursor_id);
        match cursor {
            Cursor::BTree(btree_cursor) => {
                return_if_io!(btree_cursor.rewind());
                btree_cursor.is_empty()
            }
            Cursor::MaterializedView(mv_cursor) => {
                return_if_io!(mv_cursor.rewind());
                !mv_cursor.is_valid()?
            }
            _ => panic!("Rewind on non-btree/materialized-view cursor"),
        }
    };
```

`return_if_io!(btree_cursor.rewind())` —— 這就接上了 `06b-source-code-learn-btree-cursor-pager.md` 完整拆過的那個 `rewind` 狀態機（`move_to_root` → `get_next_record`）。

**注意這裡沒有自己的狀態機。** 為什麼？因為 `op_rewind` 在 `return_if_io!` 之前**沒有任何副作用**——bloom filter 清除是冪等的，重跑一次沒差。這是 `07b-source-code-learn-ioresult-reentry.md` 講的「解法一：讓操作可安全重做」。

狀態機在下一層（`BTreeCursor.rewind_state`）就夠了。

最後那個 `panic!` 是斷言不變量：`Rewind` 只能用在可迭代的 cursor 上。

**`core/vdbe/execute.rs:1708-1716`** — 分支：

```rust
    if is_empty {
        state.pc = pc_if_empty.as_offset_int();
    } else {
        // Rewind positions to the first row, which is effectively a read
        state.record_rows_read(1);
        state.pc += 1;
    }
    Ok(InsnFunctionStepResult::Step)
}
```

**這就是 `03-source-code-learn-1-planner.md` 那份 EXPLAIN 裡 `Rewind 0 6 0` 的 p2=6 的意義**：表是空的就跳到 addr 6（`Halt`），跳過整個迴圈。

`record_rows_read(1)` 值得注意：**`Rewind` 定位到第一列，這本身就算讀了一列**。如果不計，`SELECT * FROM t` 讀 100 列會只統計到 99 列——統計數字會系統性地少一。這種 off-by-one 在可觀測性上很惱人。

---

## op_seek_rowid：點查找

**`core/vdbe/execute.rs:5258-5277`** — 完整貼出開頭：

```rust
pub fn op_seek_rowid(
    _program: &Program,
    state: &mut ProgramState,
    insn: &Insn,
    _pager: &Arc<Pager>,
) -> Result<InsnFunctionStepResult> {
    load_insn!(
        SeekRowid {
            cursor_id,
            src_reg,
            target_pc,
        },
        insn
    );
    if !target_pc.is_offset() {
        crate::bail_corrupt_error!("Unresolved label: {target_pc:?}");
    }
    invalidate_deferred_seeks_for_cursor(state, *cursor_id);
```

`invalidate_deferred_seeks_for_cursor` 很重要。`01-source-code-learn-5-cursor-storage.md` 講過 deferred seek：用 index 找到項目後，「回主表取資料」這個動作可以延後。

現在 cursor 要主動 seek 到新位置了，**之前掛著的延後 seek 就失效了**——它記的是舊位置。不清掉的話，之後 `op_column` 會用過期的資訊回表，讀到錯誤的列。

**`core/vdbe/execute.rs:5279-5300`** — 完整貼出 MaterializedView 分支：

```rust
    let (pc, did_seek) = {
        let cursor = get_cursor!(state, *cursor_id);

        // Handle MaterializedView cursor
        let (pc, did_seek) = match cursor {
            Cursor::MaterializedView(mv_cursor) => {
                let rowid = match state.registers[*src_reg].get_value() {
                    Value::Numeric(Numeric::Integer(rowid)) => Some(*rowid),
                    Value::Null => None,
                    _ => None,
                };

                match rowid {
                    Some(rowid) => {
                        let seek_result = return_if_io!(mv_cursor
                            .seek(SeekKey::TableRowId(rowid), SeekOp::GE { eq_only: true }));
                        let pc = if !matches!(seek_result, SeekResult::Found) {
                            target_pc.as_offset_int()
                        } else {
                            state.pc + 1
                        };
                        (pc, true)
                    }
                    None => (target_pc.as_offset_int(), false),
                }
```

```rust
            // ── 省略（core/vdbe/execute.rs:5301-5340）：Cursor::BTree 分支，
            //    邏輯相同但走 BTreeCursor::seek；以及尾端的 panic! 斷言 ──
```

三個值得看的地方：

**一、型別檢查決定控制流。**

```rust
                let rowid = match state.registers[*src_reg].get_value() {
                    Value::Numeric(Numeric::Integer(rowid)) => Some(*rowid),
                    Value::Null => None,
                    _ => None,
                };
```

rowid 必須是整數。`NULL` 或其他型別一律當作「找不到」（`None`），直接跳到 `target_pc`。

**為什麼不報錯？** 因為 `WHERE id = 'abc'` 是合法的 SQL，它的答案就是「沒有符合的列」，不是錯誤。這是 SQLite 動態型別的體現（`05-source-code-learn-schema-values-records.md`）。

**二、`SeekOp::GE { eq_only: true }`。**

用「大於等於」但限定「只要相等」。為什麼要這樣表達，而不是直接有個 `SeekOp::EQ`？

因為 B-tree 的搜尋本質上是「找到第一個 >= key 的位置」。`eq_only` 是在那之上加一個檢查：找到的位置如果不是恰好相等，就報告找不到。**共用同一套 seek 實作，只在最後判定時分歧。**

**三、找到與否決定 PC。**

```rust
                        let pc = if !matches!(seek_result, SeekResult::Found) {
                            target_pc.as_offset_int()
                        } else {
                            state.pc + 1
                        };
```

這就是 `03-source-code-learn-1-planner.md` 那份 EXPLAIN 的 `SeekRowid 0 2 5` —— p3=5 表示「找不到就跳到 addr 5」。

**注意這裡沒有迴圈。** `03-source-code-learn-1-planner.md` 引過 `Search::RowidEq` 的註解：「does not loop」。rowid 唯一，最多一列，所以沒有 `Next` 跳回。

---

## op_insert：六個子狀態

寫入是 VM 裡最複雜的操作。先看狀態機的定義——**這個 enum 的註解本身就是完整的說明文件**。

**`core/vdbe/execute.rs:10152-10175`** — 完整貼出：

```rust
pub enum OpInsertSubState {
    /// If this insert overwrites a record, capture the old record for incremental view maintenance.
    /// If cursor is already positioned (no REQUIRE_SEEK), capture directly.
    /// If REQUIRE_SEEK is set, transition to Seek first.
    MaybeCaptureRecord,
    /// Seek to the correct position if needed.
    /// In a table insert, if the caller does not pass InsertFlags::REQUIRE_SEEK, they must ensure that a seek has already happened to the correct location.
    /// This typically happens by invoking either Insn::NewRowid or Insn::NotExists, because:
    /// 1. op_new_rowid() seeks to the end of the table, which is the correct insertion position.
    /// 2. op_not_exists() seeks to the position in the table where the target rowid would be inserted.
    Seek,
    /// Capture the old record at the current cursor position for IVM.
    /// The cursor must already be positioned (by a prior seek or by NotExists/NewRowid).
    CaptureRecord,
    /// Check whether the update is a no-op (existing record matches new record).
    /// Must complete before Insert so that cursor.rowid()/record() are never
    /// interleaved with a partially-completed cursor.insert().
    NoopCheck,
    /// Insert the row into the table.
    Insert,
    /// Updating last_insert_rowid may return IO, so we need a separate state for it so that we don't
    /// start inserting the same row multiple times.
    UpdateLastRowid,
```

**六個狀態，每一個都是因為「這一步可能 I/O」而必須存在。**

逐個看註解揭露的資訊：

### Seek：呼叫者的契約

> if the caller does not pass `InsertFlags::REQUIRE_SEEK`, they must ensure that a seek has already happened to the correct location. This typically happens by invoking either `Insn::NewRowid` or `Insn::NotExists`

**這是一個跨指令的契約。** `Insert` 指令假設 cursor 已經在正確位置，而「把 cursor 放到正確位置」是前面某條指令的責任：

- `NewRowid` —— seek 到表尾（新列該插入的地方）。
- `NotExists` —— seek 到目標 rowid 應該在的位置。

回頭看 `09-source-code-learn-reading-projects.md` 那份 INSERT 的 EXPLAIN：

```text
6     NewRowid           1     2     0        r[2]=rowid
...
14    Insert             1     5     2     t
```

`NewRowid` 在 addr 6 就已經把 cursor 1 定位好了，所以 addr 14 的 `Insert` 不需要 `REQUIRE_SEEK`。

**編譯器和執行期共同維護這個契約**——emitter 必須保證發出 `Insert` 之前有定位指令。契約破壞的話，資料會被寫到錯誤的位置。

### NoopCheck：註解裡的順序警告

> Must complete before Insert so that `cursor.rowid()/record()` are **never interleaved with a partially-completed `cursor.insert()`**.

這是 `07b-source-code-learn-ioresult-reentry.md` 講的重入問題的一個具體實例。

`cursor.insert()` 是可中斷的（可能要分裂 page、配置新 page）。如果在它執行到一半時去呼叫 `cursor.rowid()` 或 `cursor.record()`，會讀到**結構不一致的 B-tree**——cursor 的 `stack` 可能正在重建、page 可能正在分裂。

所以「檢查是不是 no-op」必須**完全做完**才能開始 insert。用一個獨立的狀態確保這個順序。

**「no-op 檢查」本身是個最佳化**：`UPDATE t SET x = 5 WHERE x = 5` 實際上沒改變任何東西，跳過寫入可以省下 page 變 dirty、WAL frame、索引維護的成本。

### UpdateLastRowid：為什麼連這個都要獨立狀態

> Updating last_insert_rowid may return IO, so we need a separate state for it so that we don't **start inserting the same row multiple times**.

更新 `last_insert_rowid()` 這種看似瑣碎的操作也可能 I/O（在某些設定下要寫入序列表）。

如果它和 `Insert` 共用一個狀態，那麼「insert 完成、更新 rowid 時 yield」之後重入，就會**從 Insert 開始重跑**——同一列被插入兩次。

**這正是 `07b` 那個錯誤示範的真實版本。** 註解直接點名了後果：「start inserting the same row multiple times」。

### MaybeCaptureRecord / CaptureRecord：IVM

**`core/vdbe/execute.rs:10196-10220`** — 完整貼出狀態機開頭：

```rust
    loop {
        match state.active_op_state.insert().sub_state {
            OpInsertSubState::MaybeCaptureRecord => {
                let has_dependent_views = {
                    let schema = program.connection.schema.read();
                    !schema
                        .get_dependent_materialized_views(table_name)
                        .is_empty()
                };
                // If there are no dependent views, we don't need to capture the old record.
                // We also don't need to do it if the rowid of the UPDATEd row was changed, because
                // op_delete already captured the deletion for IVM, and this insert only needs to
                // record the new row (which ApplyViewChange handles without old_record).
                let needs_capture =
                    has_dependent_views && !flag.has(InsertFlags::UPDATE_ROWID_CHANGE);

                if flag.has(InsertFlags::REQUIRE_SEEK) {
                    state.active_op_state.insert().sub_state = OpInsertSubState::Seek;
                } else if needs_capture {
                    state.active_op_state.insert().sub_state = OpInsertSubState::CaptureRecord;
                } else {
                    state.active_op_state.insert().sub_state = OpInsertSubState::NoopCheck;
                }
                continue;
            }
```

**IVM（Incremental View Maintenance，增量視圖維護）** 需要知道「舊值是什麼」才能算出 materialized view 的差量。

但擷取舊值要讀取現有 record（可能 I/O），所以只在**真的有依賴視圖時**才做——`has_dependent_views` 這個檢查避免了絕大多數情況下的無謂成本。

註解裡那個 UPDATE 換 rowid 的特例也值得注意：改 rowid 的 UPDATE 會被拆成「delete 舊列 + insert 新列」，`op_delete` 已經擷取過舊值了，這裡不必重複。**避免同一個變更被記錄兩次**。

`continue` 讓狀態機在同一次呼叫內連續推進——只有真的遇到 I/O 才 return。所以理想情況（資料都在 cache）下，這六個狀態一次呼叫就全部走完，沒有額外開銷。

---

## op_delete：對稱的結構

**`core/vdbe/execute.rs:10554-10584`** — 完整貼出開頭：

```rust
pub fn op_delete(
    program: &Program,
    state: &mut ProgramState,
    insn: &Insn,
    _pager: &Arc<Pager>,
) -> Result<InsnFunctionStepResult> {
    load_insn!(
        Delete {
            cursor_id,
            table_name,
            is_part_of_update,
        },
        insn
    );

    loop {
        match state.active_op_state.delete().sub_state {
            OpDeleteSubState::MaybeCaptureRecord => {
                let schema = program.connection.schema.read();
                let dependent_views = schema.get_dependent_materialized_views(table_name);
                if dependent_views.is_empty() {
                    state.active_op_state.delete().sub_state = OpDeleteSubState::Delete;
                    continue;
                }

                let deleted_record = {
                    let cursor = state.get_cursor(*cursor_id);
                    let cursor = cursor.as_btree_mut();
                    // Get the current key
                    let maybe_key = return_if_io!(cursor.rowid());
                    let key = maybe_key.ok_or_else(|| {
```

結構和 `op_insert` 對稱：先判斷要不要為 IVM 擷取舊值，不用就直接進 `Delete` 狀態。

**`is_part_of_update` 這個參數揭露了 UPDATE 的實作**：改 rowid 的 UPDATE 會產生一對 delete + insert，而 delete 需要知道自己是不是 UPDATE 的一部分——因為：

- 獨立的 DELETE 要觸發 DELETE trigger。
- UPDATE 的一部分不該觸發 DELETE trigger，該觸發 UPDATE trigger。

**同一條指令，因為上下文不同而行為不同。** 這種標記參數在 DML 的實作裡很常見。

---

## op_next：cursor 分派的細節

`04-source-code-learn-1-insn-dispatch.md` 拆過 `op_next` 的**尾段**（迴圈跳轉的機制）。這裡補中段的 cursor 分派：

**`core/vdbe/execute.rs:3008-3036`** — 完整貼出：

```rust
    let is_empty = {
        let cursor = state.get_cursor(*cursor_id);
        match cursor {
            Cursor::BTree(btree_cursor) => {
                // If cursor is in NullRow state, don't advance - just return empty.
                // This matches SQLite's OP_Next behavior: btreeNext() returns
                // SQLITE_DONE when eState==CURSOR_INVALID (NullRow calls
                // sqlite3BtreeClearCursor which sets CURSOR_INVALID).
                let is_null_row = btree_cursor.get_null_flag();
                btree_cursor.set_null_flag(false);
                if is_null_row {
                    true // is_empty = true
                } else {
                    return_if_io!(btree_cursor.next());
                    btree_cursor.is_empty()
                }
            }
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

**null row 的處理是 OUTER JOIN 的關鍵。**

`04-source-code-learn-1-insn-dispatch.md` 提過 `Insn::NullRow` 的註解：「Move the cursor P1 to a null row. Any Column operations that occur while the cursor is on the null row will always write a NULL.」

LEFT JOIN 沒配到對應列時，內層 cursor 被設成 null row 狀態，body 照常執行但所有欄位讀出 NULL。然後 `Next` 執行時：

```rust
                let is_null_row = btree_cursor.get_null_flag();
                btree_cursor.set_null_flag(false);
                if is_null_row {
                    true // is_empty = true
                }
```

**不前進，直接回報「空了」**，讓迴圈結束。因為 null row 是虛構的一列，不存在「下一列」。

同時 `set_null_flag(false)` 把旗標清掉——下次外層迴圈進來時 cursor 要恢復正常狀態。

註解還標明了這對應 SQLite 的哪個行為（`btreeNext()` 在 `CURSOR_INVALID` 時回 `SQLITE_DONE`）。**這種交叉引用讓相容性有據可查**。

---

## 這些 opcode 的共同模式

把本篇拆過的五個 opcode 放在一起，可以看出一致的結構：

```text
1. load_insn!            解構參數
2. 前置檢查/清理          label 已解析？deferred seek 失效？bloom filter 清除？
3. match cursor 型別      BTree / MaterializedView / IndexMethod / ...
4. return_if_io!(...)     呼叫 cursor 方法，可能 yield
5. 依結果決定 PC          找到/沒找到、空/非空 → 跳轉或 +1
6. 回 Step
```

而**是否需要自己的狀態機**，取決於 `07b-source-code-learn-ioresult-reentry.md` 講的那個判準：

| opcode | 有狀態機？ | 原因 |
|---|---|---|
| `op_rewind` | 無 | yield 前無副作用，可安全重跑 |
| `op_seek_rowid` | 無 | 同上（invalidate 是冪等的） |
| `op_next` | 無 | 同上 |
| `op_column` | 有（條件性） | 有 deferred seek 時，seek 完成是副作用 |
| `op_insert` | 有（六狀態） | 每一步都有副作用 |
| `op_delete` | 有 | 同上 |

**規律很清楚：讀取類多半可以重跑，寫入類一定需要狀態機。**

---

## 動手驗證

看 null row 與 OUTER JOIN：

```bash
cd /Users/stanhsu/projects/turso
cargo run -q --bin tursodb -- -q
```

```sql
CREATE TABLE a(id INTEGER PRIMARY KEY, v TEXT);
CREATE TABLE b(id INTEGER PRIMARY KEY, aid INTEGER, w TEXT);
INSERT INTO a VALUES (1,'x'),(2,'y');
INSERT INTO b VALUES (1,1,'p');

EXPLAIN SELECT a.v, b.w FROM a LEFT JOIN b ON b.aid = a.id;
SELECT a.v, b.w FROM a LEFT JOIN b ON b.aid = a.id;
```

EXPLAIN 裡應該有 `NullRow`。查詢結果第二列的 `b.w` 是 NULL——那就是 null row 機制的產物。

看 no-op 更新被跳過：

```sql
CREATE TABLE t(id INTEGER PRIMARY KEY, x INTEGER);
INSERT INTO t VALUES (1, 5);
UPDATE t SET x = 5 WHERE id = 1;   -- no-op
SELECT changes();
```

看 `NewRowid` 與 `Insert` 的配對：

```sql
EXPLAIN INSERT INTO t(x) VALUES (99);
```

確認 `NewRowid` 出現在 `Insert` **之前**——這就是上面講的跨指令契約。

追 source：

```bash
rg -n "pub fn op_rewind|pub fn op_seek_rowid|pub fn op_next|pub fn op_insert\b|pub fn op_delete\b" core/vdbe/execute.rs
rg -n "pub enum OpInsertSubState|pub enum OpDeleteSubState|pub enum OpColumnState" core/vdbe/execute.rs
rg -n "get_null_flag|set_null_flag" core/vdbe/execute.rs | head
```

---

## 自我檢查

1. 判斷一條 opcode 會不會 I/O，最可靠的方法是什麼？為什麼看 `_pager` 前綴不夠？
2. `op_rewind` 為什麼要清除 bloom filter？不清會產生效能問題還是正確性問題？
3. `op_rewind` 為什麼不需要自己的狀態機，但 `op_insert` 需要？
4. `Rewind` 指令的 `pc_if_empty` 對應 EXPLAIN 裡的哪個欄位？它讓程式跳到哪裡？
5. `Rewind` 為什麼要 `record_rows_read(1)`？不記會怎樣？
6. `op_seek_rowid` 為什麼要 `invalidate_deferred_seeks_for_cursor`？
7. `WHERE id = 'abc'` 為什麼不報錯而是回傳空結果？
8. `SeekOp::GE { eq_only: true }` 為什麼不直接做一個 `SeekOp::EQ`？
9. `Insert` 指令假設 cursor 已定位。是誰負責定位？破壞這個契約會怎樣？
10. `NoopCheck` 為什麼必須在 `Insert` **之前**完全做完？和 B-tree 的什麼狀態有關？
11. `UpdateLastRowid` 為什麼要獨立成一個狀態？和它共用狀態會產生什麼 bug？
12. IVM 的舊值擷取為什麼要先檢查 `has_dependent_views`？
13. 改 rowid 的 UPDATE 為什麼 `op_insert` 不需要再擷取舊值？
14. `op_delete` 的 `is_part_of_update` 參數影響什麼行為？
15. LEFT JOIN 沒配到對應列時，`op_next` 為什麼「不前進、直接回報空」？
16. 讀取類與寫入類 opcode 在「是否需要狀態機」上的規律是什麼？

---

下一篇 `04-source-code-learn-3-aggregate-sorter-subprogram.md`：聚合、排序器、協程、子程式類 opcode。
