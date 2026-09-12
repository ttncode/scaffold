#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : scripts/check-provenance.sh
# Description : Diff every verbatim row in docs/PROVENANCE.md against upstream.
# Author      : ttncode
#
# Usage:
#   ./scripts/check-provenance.sh
#
# Example:
#   SCAFFOLD_UPSTREAM_CLONE=~/src/immich ./scripts/check-provenance.sh
# ═══════════════════════════════════════════════════════════════════════════
#
# From a local clone, with no network fallback: a fetch that silently returns
# empty on a denied curl would read as "everything drifted" instead of "could
# not check" — worse than failing loudly up front.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="${ROOT}/docs/PROVENANCE.md"

# Unlike SCAFFOLD_ROOT this path is not self-locating — it names a clone on
# whichever machine runs this script, so it must be overridable. The default is
# a guess about layout, not about who is running it: a specific user's home
# directory does not belong in a shared repository.
LOCAL_CLONE="${SCAFFOLD_UPSTREAM_CLONE:-${HOME}/workspace/playground/immich}"

VERBATIM_ROW_PREFIX='^| `'
VERBATIM_STATUS="verbatim"

UPSTREAM=""
COMMIT=""
TMP_UPSTREAM=""

ok=0
drifted=0
missing=0
errors=0

# ─── what this run can check ───────────────────────────────────────────────

read_upstream_pin() {
  [ -f "${ROOT}/UPSTREAM" ] || { echo "error: ${ROOT}/UPSTREAM not found" >&2; exit 1; }
  [ -f "$TABLE" ] || { echo "error: ${TABLE} not found" >&2; exit 1; }

  UPSTREAM="$(cat "${ROOT}/UPSTREAM")"
  COMMIT="${UPSTREAM#*@}"
  [ -n "$COMMIT" ] && [ "$COMMIT" != "$UPSTREAM" ] || {
    echo "error: UPSTREAM (${UPSTREAM}) is not of the form owner/repo@commit" >&2
    exit 1
  }
}

require_local_clone() {
  if [ ! -d "${LOCAL_CLONE}/.git" ]; then
    echo "error: no local clone at ${LOCAL_CLONE}" >&2
    echo "check-provenance.sh has no other way to verify provenance in this environment; clone ${UPSTREAM%@*} there and try again" >&2
    exit 1
  fi

  git -C "$LOCAL_CLONE" cat-file -e "${COMMIT}^{commit}" 2>/dev/null || {
    echo "error: ${COMMIT} is not a commit in ${LOCAL_CLONE}" >&2
    exit 1
  }
}

# ─── one row at a time ─────────────────────────────────────────────────────

check_row() {
  local local_path="$1" upstream_path="$2"

  if [ ! -f "${ROOT}/${local_path}" ]; then
    printf '  MISSING   %s\n' "$local_path"
    missing=$((missing + 1))
    return 0
  fi

  if ! git -C "$LOCAL_CLONE" show "${COMMIT}:${upstream_path}" >"$TMP_UPSTREAM" 2>/dev/null; then
    echo "  ERROR     ${local_path}: could not read ${upstream_path} at ${COMMIT} from the local clone" >&2
    errors=$((errors + 1))
    return 0
  fi

  if diff -q "$TMP_UPSTREAM" "${ROOT}/${local_path}" >/dev/null 2>&1; then
    printf '  ok        %s\n' "$local_path"
    ok=$((ok + 1))
  else
    printf '  DRIFTED   %s\n' "$local_path"
    diff "$TMP_UPSTREAM" "${ROOT}/${local_path}" | sed 's/^/              /'
    drifted=$((drifted + 1))
  fi
}

check_verbatim_rows() {
  local _ local_col upstream_col status_col status local_path upstream_path

  while IFS='|' read -r _ local_col upstream_col status_col _; do
    status="$(echo "$status_col" | tr -d ' ')"
    [ "$status" = "$VERBATIM_STATUS" ] || continue

    local_path="$(echo "$local_col" | tr -d ' `')"
    upstream_path="$(echo "$upstream_col" | tr -d ' `')"

    if [ -z "$local_path" ] || [ -z "$upstream_path" ]; then
      echo "  ERROR     unparseable verbatim row: ${local_col}|${upstream_col}|${status_col}" >&2
      errors=$((errors + 1))
      continue
    fi

    check_row "$local_path" "$upstream_path"
  done < <(grep "$VERBATIM_ROW_PREFIX" "$TABLE")
}

# A table that suddenly parses to nothing is a broken checker, not a clean run.
print_summary() {
  echo
  echo "${ok} ok, ${drifted} drifted, ${missing} missing, ${errors} errors"

  if [ $((ok + drifted + missing + errors)) -eq 0 ]; then
    echo "error: no verbatim rows found in ${TABLE}; nothing was checked" >&2
    exit 1
  fi

  [ "$drifted" -eq 0 ] && [ "$missing" -eq 0 ] && [ "$errors" -eq 0 ]
}

main() {
  read_upstream_pin
  require_local_clone

  TMP_UPSTREAM="$(mktemp)"
  trap 'rm -f "$TMP_UPSTREAM"' EXIT

  echo "checking verbatim files against ${UPSTREAM}"
  echo
  check_verbatim_rows
  print_summary
}

main "$@"
