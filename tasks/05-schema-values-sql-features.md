# 05. Schema, Values, And SQL Feature Tasks

這一組把 SQL metadata、runtime value、record format、functions、constraints、trigger 等 feature 接起來。這些 feature 讓 toy database 變成 SQLite-like database。

- [ ] T156. **sqlite_schema model**: read `core/schema.rs`, `core/translate/schema.rs`; output how schema rows become in-memory objects.
- [ ] T157. **Schema parse path**: read `parse_schema_rows` paths in `core/schema.rs`, `core/vdbe/execute.rs`; output when runtime reparses schema.
- [ ] T158. **Table metadata**: read `core/schema.rs`; output fields for ordinary tables, virtual tables, indexes, views, triggers, and sequences.
- [ ] T159. **BTreeTable and Index**: read `core/schema.rs`; output root page, columns, primary key, rowid, and index metadata.
- [ ] T160. **Column metadata**: read `core/schema.rs`, `sqlite/parser/src/ast.rs`; output how declared type, constraints, generated columns, and collation survive parsing.
- [ ] T161. **Value enum**: read `core/vdbe/value.rs`; output runtime representation of NULL, integer, float, text, blob, and extension values.
- [ ] T162. **ValueRef**: read `core/vdbe/value.rs`; output why borrowed values exist and where avoiding clones matters.
- [ ] T163. **Record encoding**: read `core/storage/sqlite3_ondisk.rs`, `core/vdbe/execute.rs`; output serial type, header, payload, and column extraction.
- [ ] T164. **Serial types**: read `core/storage/sqlite3_ondisk.rs`; output mapping between SQLite serial type codes and runtime values.
- [ ] T165. **Affinity basics**: read `core/vdbe/affinity.rs`; output the five affinities and examples where conversion changes results.
- [ ] T166. **Declared type to affinity**: read `core/schema.rs`, `core/vdbe/affinity.rs`; output SQLite's substring-based affinity rules.
- [ ] T167. **STRICT tables**: read `core/translate/schema.rs`, `core/vdbe/execute.rs`; output how STRICT changes type checking.
- [ ] T168. **Collation system**: read `core/translate/collate.rs`, `core/vdbe/execute.rs`; output where collation is selected and applied.
- [ ] T169. **Scalar functions registry**: read `core/function.rs`, `core/functions/mod.rs`; output how built-in scalar functions are registered and resolved.
- [ ] T170. **String functions**: read `core/functions/string.rs`; output how one function validates args, handles NULL, and returns `Value`.
- [ ] T171. **Math functions**: read `core/functions/math.rs`; output numeric conversion and error behavior for one math function.
- [ ] T172. **Datetime functions**: read `core/functions/datetime.rs`, `core/time/mod.rs`; output how SQL datetime behavior is layered.
- [ ] T173. **Printf and format**: read `core/functions/printf.rs`; output why SQLite-compatible formatting is its own subsystem.
- [ ] T174. **Aggregate function runtime**: read `core/function.rs`, `core/vdbe/execute.rs`; output step/final state ownership.
- [ ] T175. **Percentile aggregate**: read `core/percentile.rs`, `sqlite/conformance/sqlite-sqltests/agg-functions/`; output ordered-set aggregate requirements.
- [ ] T176. **JSON functions**: read `core/json/mod.rs`, `core/json/ops.rs`, `core/json/path.rs`; output JSON text, path, and JSONB boundaries.
- [ ] T177. **JSON virtual table**: read `core/json/vtab.rs`; output how `json_each`-style tables enter cursor model.
- [ ] T178. **Generated columns**: read `core/translate/emitter/gencol.rs`, `sqlite/conformance/sqlite-sqltests/gencol.sqltest`; output when generated values are computed.
- [ ] T179. **CHECK and NOT NULL**: read `core/translate/schema.rs`, `core/vdbe/execute.rs`; output where constraints become bytecode.
- [ ] T180. **UNIQUE and conflict resolution**: read `core/translate/insert.rs`, `core/translate/upsert.rs`; output how conflict policy changes bytecode flow.
- [ ] T181. **Foreign keys**: read `core/translate/fkeys.rs`, `sqlite/conformance/sqlite-sqltests/foreign_keys.sqltest`; output immediate vs deferred checks.
- [ ] T182. **Triggers**: read `core/translate/trigger.rs`, `core/translate/trigger_exec.rs`; output trigger compile-time and runtime boundaries.
- [ ] T183. **RETURNING**: read DML compiler paths and `sqlite/conformance/sqlite-sqltests/returning.sqltest`; output how mutation statements produce rows.
- [ ] T184. **ALTER TABLE**: read `core/translate/alter.rs`, alter opcodes in `core/vdbe/execute.rs`; output schema rewrite versus metadata update cases.
- [ ] T185. **VACUUM**: read `core/translate/vacuum.rs`, `core/vdbe/vacuum.rs`; output why VACUUM is not just a normal table scan.
- [ ] T186. **PRAGMA runtime**: read `core/pragma.rs`, `core/translate/pragma.rs`; output read-only, setting, and table-valued PRAGMA categories.
- [ ] T187. **Sequences and custom types**: read `core/translate/sequence.rs`, `core/translate/expr/custom_types.rs`; output how non-SQLite extensions plug into the compiler.
- [ ] T188. **Vector values**: read `core/vector/mod.rs`, `core/vector/operations/mod.rs`; output how vector operations fit the value/function model.
- [ ] T189. **Integrity check**: read `core/translate/integrity_check.rs`, `core/vdbe/execute.rs`; output how SQL-level integrity checking reaches storage validation.
- [ ] T190. **Schema/value milestone**: run SQL that exercises type affinity, a function, an index, and a constraint; output a source trace from AST to VDBE to storage.

