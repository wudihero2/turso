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
    | search_filter '^(core|sqlite|bindings|sdk-kit|extensions|sync|postgres|testing|tests|docs|scripts|perf|tools|learn|cli|macros|sdk-kit-macros|fuzz|examples|serverless|packages|assets|licenses|tlaplus)(/|$)|^[0-9][0-9A-Za-z.-]+\.md$|^(Cargo.toml|AGENTS.md|README.md|CONTRIBUTING.md|COMPAT.md|Makefile)$' \
    | sed -E 's#^([0-9][0-9A-Za-z.-]+\.md)$#learn/\1#' \
    | sort -u
)

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
CHECKS

if [[ "$status" -eq 0 ]]; then
  echo "learn docs lint passed"
else
  echo "learn docs lint failed"
fi

exit "$status"
