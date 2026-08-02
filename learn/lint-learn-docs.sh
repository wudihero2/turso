#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# rg is preferred but not guaranteed to be installed; fall back to grep.
if command -v rg >/dev/null 2>&1; then
  search_extract() { rg -o -N --no-filename "$1" "${@:2}"; }
  search_filter() { rg "$1"; }
  search_quiet_fixed() { rg -qF "$1" "$2"; }
else
  search_extract() { grep -ohE "$1" "${@:2}"; }
  search_filter() { grep -E "$1"; }
  search_quiet_fixed() { grep -qF "$1" "$2"; }
fi

status=0

echo "checking referenced paths in learn/*.md"
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  [[ "$path" == http* ]] && continue
  [[ "$path" == *"*"* ]] && continue
  [[ "$path" == *"<"* ]] && continue
  [[ "$path" == *" "* ]] && continue

  if [[ ! -e "$path" ]]; then
    echo "missing path: $path"
    status=1
  fi
done < <(
  search_extract '`[^`]+`' learn/*.md \
    | sed -E 's/^`//; s/`$//' \
    | sed -E 's/:[0-9]+(-[0-9]+)?$//' \
    | search_filter '^(core|sqlite|bindings|sdk-kit|extensions|sync|postgres|testing|tests|docs|scripts|perf|tools|learn|cli|macros|sdk-kit-macros|fuzz|examples|serverless|packages|assets|licenses|tlaplus)(/|$)|^[0-9][0-9A-Za-z.-]+\.md$|^(Cargo.toml|AGENTS.md|README.md|CONTRIBUTING.md|COMPAT.md|Makefile)$' \
    | sed -E 's#^([0-9][0-9A-Za-z.-]+\.md)$#learn/\1#' \
    | sort -u
)

echo "checking file:line references (path completeness + line ranges)"
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PYCHECK' || status=1
import glob, os, re, sys

ROOTS = ('core/','sqlite/','bindings/','sdk-kit/','extensions/','sync/','postgres/',
         'testing/','tests/','docs/','scripts/','perf/','tools/','cli/','macros/','fuzz/')
# `path.rs:N` or `path.rs:N-M`, with or without leading directories
REF = re.compile(r'(?<![\w/.-])([\w./-]+\.(?:rs|md|sh|toml|sqltest)):(\d+)(?:-(\d+))?')

cache = {}
def nlines(p):
    if p not in cache:
        try: cache[p] = sum(1 for _ in open(p, 'rb'))
        except OSError: cache[p] = None
    return cache[p]

bad = []
for md in sorted(glob.glob('learn/*.md')):
    for i, line in enumerate(open(md, encoding='utf-8'), 1):
        for m in REF.finditer(line):
            path, a, b = m.group(1), int(m.group(2)), m.group(3)
            b = int(b) if b else a
            if '/' not in path:
                bad.append(f'{md}:{i}  abbreviated path (needs full path): {m.group(0)}')
                continue
            if not path.startswith(ROOTS):
                continue
            n = nlines(path)
            if n is None:
                bad.append(f'{md}:{i}  no such file: {path}')
            elif b > n:
                bad.append(f'{md}:{i}  line out of range: {m.group(0)} (file has {n} lines)')

for b in bad:
    print('  ' + b)
sys.exit(1 if bad else 0)
PYCHECK
else
  echo "  (python3 unavailable, skipped)"
fi

echo "checking selected source symbols"
while IFS='|' read -r file symbol; do
  [[ -z "$file" || "$file" == \#* ]] && continue

  if [[ ! -e "$file" ]]; then
    echo "missing symbol file: $file ($symbol)"
    status=1
    continue
  fi

  if ! search_quiet_fixed "$symbol" "$file"; then
    echo "missing symbol: $symbol in $file"
    status=1
  fi
done <<'CHECKS'
bindings/rust/src/lib.rs|Builder
sdk-kit/src/rsapi.rs|TursoConnection
core/connection.rs|prepare_with_origin
core/connection.rs|parse_schema_rows
sqlite/parser/src/parser.rs|next_cmd
sqlite/parser/src/ast.rs|pub enum Stmt
core/translate/mod.rs|translate_inner
core/translate/select.rs|translate_select
core/translate/expr/translator.rs|pub fn translate_expr
core/translate/planner.rs|ROWID_STRS
core/translate/plan.rs|SelectPlan
core/translate/emitter/mod.rs|Resolver
core/vdbe/mod.rs|normal_step
core/vdbe/insn.rs|ResultRow
core/vdbe/execute.rs|op_seek_rowid
core/vdbe/execute.rs|OpColumnState
core/schema.rs|BTreeTable
core/util.rs|parse_schema_rows
core/types.rs|IOResult
core/storage/sqlite3_ondisk.rs|DatabaseHeader
core/storage/btree.rs|CursorTrait
core/storage/pager.rs|begin_write_tx
core/storage/wal.rs|WalAutoActions
core/io/completions.rs|CompletionGroup
extensions/core/src/lib.rs|ExtensionApi
sync/engine/src/wal_session.rs|WalSession
bindings/rust/src/connection.rs|pub async fn prepare
sdk-kit/src/rsapi.rs|prepare_single
core/lib.rs|pub fn connect
core/statement.rs|enum StatementOrigin
core/statement.rs|fn _step
core/dialect/sqlite.rs|pub fn parse
core/dialect/sqlite.rs|resolve_builtin_function
sqlite/parser/src/lexer.rs|pub struct Lexer
sqlite/parser/src/lexer.rs|pub struct Token
sqlite/parser/src/parser.rs|MAX_EXPR_DEPTH
sqlite/parser/src/parser.rs|fn create_variable
sqlite/parser/src/ast.rs|pub enum Cmd
sqlite/parser/src/ast.rs|pub enum Expr
core/translate/select.rs|emit_select_plan
core/translate/optimizer/mod.rs|optimize_select_plan
core/translate/emitter/select.rs|emit_program_for_select
core/translate/plan.rs|pub enum Operation
core/translate/plan.rs|pub enum Search
core/translate/plan.rs|pub struct WhereTerm
core/vdbe/builder.rs|pub fn prologue
core/vdbe/builder.rs|pub fn epilogue
core/vdbe/insn.rs|INSN_VTABLE
core/vdbe/insn.rs|get_insn_virtual_table
core/vdbe/mod.rs|pub enum Register
core/vdbe/mod.rs|pub enum StepResult
core/vdbe/mod.rs|pub struct PreparedProgram
core/vdbe/execute.rs|macro_rules! load_insn
core/vdbe/execute.rs|pub enum InsnFunctionStepResult
core/vdbe/execute.rs|pub fn op_add
core/vdbe/execute.rs|pub fn op_result_row
core/vdbe/execute.rs|pub fn op_function
core/vdbe/execute.rs|pub fn op_agg_step
core/vdbe/affinity.rs|pub enum Affinity
core/schema.rs|pub struct Schema
core/schema.rs|SCHEMA_TABLE_NAME
core/function.rs|pub enum Func
core/types.rs|pub enum Value
core/types.rs|pub struct IOCompletions
core/util.rs|macro_rules! io_yield_one
core/util.rs|pub trait IOExt
core/storage/sqlite3_ondisk.rs|pub enum PageType
core/storage/sqlite3_ondisk.rs|pub enum BTreeCell
core/storage/sqlite3_ondisk.rs|pub struct WalHeader
core/storage/sqlite3_ondisk.rs|pub struct WalFrameHeader
core/storage/btree.rs|pub mod offset
core/storage/btree.rs|pub struct BTreeCursor
core/storage/btree.rs|struct PageStack
core/storage/pager.rs|pub struct Pager
core/storage/pager.rs|pub fn begin_read_tx
core/storage/pager.rs|pub fn commit_tx
core/storage/wal.rs|pub enum CheckpointMode
core/vtab.rs|pub struct VirtualTable
extensions/core/src/vtabs.rs|pub trait VTabModule
extensions/core/src/vfs_modules.rs|pub trait VfsExtension
core/translate/expr/translator.rs|pub fn translate_expr
core/translate/optimizer/constraints.rs|pub struct Constraint
core/translate/optimizer/constraints.rs|pub enum ConstraintOperator
core/translate/optimizer/cost_params.rs|pub struct CostModelParams
core/translate/optimizer/cost.rs|pub fn estimate_index_cost
core/translate/optimizer/cost.rs|fn estimate_scan_cost
core/translate/optimizer/cost.rs|fn is_unique_point_lookup
core/translate/optimizer/cost.rs|pub enum RowCountEstimate
core/translate/optimizer/access_method.rs|pub struct AccessMethod
core/translate/optimizer/access_method.rs|pub enum ResidualConstraintMode
core/translate/optimizer/join.rs|pub fn compute_best_join_order
core/translate/optimizer/join.rs|GREEDY_JOIN_THRESHOLD
core/translate/optimizer/join.rs|compute_naive_left_deep_plan
core/translate/main_loop/init.rs|pub struct InitLoop
core/translate/main_loop/open.rs|pub struct OpenLoop
core/translate/main_loop/close.rs|pub struct CloseLoop
core/translate/main_loop/body.rs|pub fn emit_loop
core/vdbe/execute.rs|pub fn op_rewind
core/vdbe/execute.rs|pub enum OpInsertSubState
core/vdbe/execute.rs|pub fn op_program
core/vdbe/execute.rs|pub fn op_sorter_open
core/vdbe/execute.rs|pub fn op_agg_final
core/types.rs|pub enum AggContext
core/storage/btree.rs|enum BalanceSubState
core/storage/btree.rs|struct BalanceState
core/storage/btree.rs|fn balance_root
core/storage/btree.rs|MAX_SIBLING_PAGES_TO_BALANCE
core/translate/plan.rs|pub struct HashJoinOp
core/translate/plan.rs|pub enum HashJoinType
core/translate/main_loop/hash.rs|struct HashBuildConfig
core/translate/main_loop/hash.rs|struct HashBuildPlanner
core/translate/main_loop/hash.rs|enum HashBuildPlan
core/translate/main_loop/hash.rs|struct GraceHashLoop
core/vdbe/insn.rs|HashProbe
core/vdbe/insn.rs|HashGraceInit
core/mvcc/mod.rs|Multiversion concurrency control
core/mvcc/database/mod.rs|pub struct RowVersion
core/mvcc/database/mod.rs|pub enum TxTimestampOrID
core/mvcc/database/mod.rs|enum TransactionState
core/mvcc/database/mod.rs|fn is_visible_to
core/mvcc/database/mod.rs|fn is_begin_visible
core/mvcc/database/mod.rs|commit_dep_counter
core/mvcc/database/mod.rs|WriteWriteConflict
core/mvcc/cursor.rs|pub struct MvccLazyCursor
core/incremental/dbsp.rs|pub struct Delta
core/incremental/dbsp.rs|pub struct Hash128
core/incremental/dbsp.rs|fn hash_values
core/incremental/operator.rs|pub trait IncrementalOperator
postgres/frontend/catalog.rs|impl Dialect for PostgresDialect
postgres/parser/translator.rs|pub struct TranslateResult
postgres/parser/translator.rs|pub struct PostgreSQLTranslator
postgres/parser/translator.rs|pub fn map_pg_type
postgres/parser/translator.rs|pub fn try_extract_set
sync/engine/src/client_proto.rs|pub enum LogicalOpType
sync/engine/src/client_proto.rs|pub enum LogicalSchemaAction
sync/engine/src/client_proto.rs|pub struct LogicalOp
sync/engine/src/database_tape.rs|pub struct DatabaseTape
sync/engine/src/database_tape.rs|DEFAULT_CDC_TABLE_NAME
sync/engine/src/database_sync_operations.rs|pub async fn db_bootstrap
sync/engine/src/database_sync_operations.rs|pub async fn push_logical_changes
testing/simulator/model/property.rs|pub enum Property
testing/simulator/model/property.rs|InsertValuesSelect
testing/simulator/model/property.rs|ReadYourUpdatesBack
testing/simulator/generation/property.rs|fn get_extensional_query_gen_function
testing/simulator/main.rs|SimulatorCommand::Loop
CHECKS

if [[ "$status" -eq 0 ]]; then
  echo "learn docs lint passed"
else
  echo "learn docs lint failed"
fi

exit "$status"
