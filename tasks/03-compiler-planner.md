# 03. Compiler And Planner Tasks

這一組看 AST 如何變成 logical plan，再變成可發 bytecode 的資料結構。先走 dispatcher，再走 resolver、planner、optimizer。

- [ ] T076. **Translate entrypoint**: read `core/translate/mod.rs`; output inputs to `translate` and outputs to VDBE.
- [ ] T077. **Translate prologue**: read `core/translate/mod.rs`, `core/vdbe/builder.rs`; output why bytecode starts with initialization control flow.
- [ ] T078. **Translate dispatch**: read `core/translate/mod.rs`; output the mapping from AST statement kinds to compiler modules.
- [ ] T079. **Resolver role**: read `core/translate/mod.rs`, `core/translate/expr/metadata.rs`; output how names, tables, functions, and scopes become resolved references.
- [ ] T080. **Table references**: read `core/translate/plan.rs`; output how compiler tracks tables visible to SELECT expressions.
- [ ] T081. **Result columns**: read `core/translate/plan.rs`, `core/translate/result_row.rs`; output how `SELECT *`, aliases, and expression columns become result metadata.
- [ ] T082. **SELECT entrypoint**: read `core/translate/select.rs`; output the high-level phases from AST SELECT to emitted program.
- [ ] T083. **SelectPlan structure**: read `core/translate/plan.rs`; output each field of `SelectPlan` and which SQL clause created it.
- [ ] T084. **FROM planning**: read `core/translate/planner.rs`, `core/translate/plan.rs`; output how table sources and joins enter the plan.
- [ ] T085. **WHERE terms**: read `core/translate/plan.rs`, `core/translate/planner.rs`; output how predicates become searchable terms plus residual filters.
- [ ] T086. **Search operations**: read `core/translate/plan.rs`; output the difference between table scan, rowid seek, index seek, and index scan.
- [ ] T087. **Index metadata use**: read `core/translate/index.rs`, `core/schema.rs`; output how planner learns available indexes.
- [ ] T088. **Expression indexes**: read `core/translate/expression_index.rs`; output how expression equivalence and index usability are proven.
- [ ] T089. **Partial indexes**: read `core/translate/optimizer/constraints.rs`, `sqlite/conformance/sqlite-sqltests/partial_idx.sqltest`; output why a predicate must be proven before using a partial index.
- [ ] T090. **ORDER BY planning**: read `core/translate/order_by.rs`, `core/translate/optimizer/order.rs`; output when ordering can be satisfied by scan order.
- [ ] T091. **GROUP BY planning**: read `core/translate/group_by.rs`, `core/translate/aggregation.rs`; output how aggregate grouping changes plan shape.
- [ ] T092. **DISTINCT planning**: read `core/translate/plan.rs`, `core/translate/select.rs`; output how DISTINCT can use ephemeral structures or existing order.
- [ ] T093. **LIMIT and OFFSET planning**: read `core/translate/select.rs`, `core/translate/plan.rs`; output where count and offset registers enter the plan.
- [ ] T094. **Compound SELECT planning**: read `core/translate/compound_select.rs`; output how UNION-style queries combine arms.
- [ ] T095. **CTE planning**: read `core/translate/select.rs`, `core/translate/subquery.rs`; output when CTEs are materialized or inlined.
- [ ] T096. **Subquery representation**: read `core/translate/subquery.rs`, `core/translate/plan.rs`; output scalar, EXISTS, IN, and correlated subquery differences.
- [ ] T097. **Outer references**: read `core/translate/plan.rs`, `core/translate/subquery.rs`; output how correlated subqueries refer to outer scopes.
- [ ] T098. **Join info**: read `core/translate/plan.rs`, `core/translate/planner.rs`; output how join type, ON/USING, and null-extension semantics are stored.
- [ ] T099. **Logical plan layer**: read `core/translate/logical.rs`; output why an additional logical representation exists alongside `SelectPlan`.
- [ ] T100. **Optimizer entrypoint**: read `core/translate/optimizer/mod.rs`, `core/translate/optimizer/OPTIMIZER.md`; output optimizer phase order.
- [ ] T101. **Access method optimizer**: read `core/translate/optimizer/access_method.rs`; output how candidate scans and seeks are compared.
- [ ] T102. **Cost model**: read `core/translate/optimizer/cost.rs`, `core/translate/optimizer/cost_params.rs`; output which factors affect plan choice.
- [ ] T103. **Join ordering**: read `core/translate/optimizer/join.rs`; output how join order is chosen and constrained.
- [ ] T104. **Multi-index OR**: read `core/translate/optimizer/multi_index.rs`, `core/translate/main_loop/multi_index.rs`; output the plan shape for OR predicates using multiple indexes.
- [ ] T105. **IN seek optimization**: read `core/translate/main_loop/in_seek.rs`, `sqlite/conformance/sqlite-sqltests/in-index-seek.sqltest`; output how IN-lists or IN-subqueries become seek loops.
- [ ] T106. **Unnesting**: read `core/translate/optimizer/unnest.rs`; output which subqueries can be transformed and what correctness conditions apply.
- [ ] T107. **Common subexpression lifting**: read `core/translate/optimizer/lift_common_subexpressions.rs`; output what is lifted, why, and where values are reused.
- [ ] T108. **DML safety planning**: read `core/translate/plan.rs`, `core/translate/delete.rs`, `core/translate/update.rs`; output why UPDATE/DELETE sometimes need delayed rowid collection.
- [ ] T109. **INSERT planning**: read `core/translate/insert.rs`; output the source forms of INSERT and how they affect later emission.
- [ ] T110. **UPSERT planning**: read `core/translate/upsert.rs`; output how conflict targets and DO UPDATE become executable state.
- [ ] T111. **Foreign key planning**: read `core/translate/fkeys.rs`; output where FK checks and cascades are inserted into compiled programs.
- [ ] T112. **Trigger planning**: read `core/translate/trigger.rs`, `core/translate/trigger_exec.rs`; output how trigger programs differ from top-level programs.
- [ ] T113. **Schema DDL planning**: read `core/translate/schema.rs`, `core/translate/alter.rs`; output how DDL turns into writes against schema tables.
- [ ] T114. **PRAGMA planning**: read `core/translate/pragma.rs`; output why PRAGMA compilation mixes metadata reads, settings writes, and result rows.
- [ ] T115. **Compiler milestone**: run `EXPLAIN` for one SELECT, one INSERT, one CREATE TABLE; output which planner/compiler files explain the resulting bytecode.

