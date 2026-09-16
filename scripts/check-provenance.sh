#!/usr/bin/env bash
# Diff every verbatim row in docs/PROVENANCE.md against the pinned upstream,
# from a local clone only: a network fetch failing quietly would read as
# "everything drifted" instead of "could not check".
#
# Usage:   ./scripts/check-provenance.sh
# Example: SCAFFOLD_UPSTREAM_CLONE=~/src/immich ./scripts/check-provenance.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="${ROOT}/docs/PROVENANCE.md"

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

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

read_upstream_pin() {
  [[ -f "${ROOT}/UPSTREAM" ]] || die "${ROOT}/UPSTREAM not found"
  [[ -f "$TABLE" ]] || die "${TABLE} not found"

  UPSTREAM="$(cat "${ROOT}/UPSTREAM")"
  COMMIT="${UPSTREAM#*@}"
  [[ -n "$COMMIT" ]] && [[ "$COMMIT" != "$UPSTREAM" ]] ||
    die "UPSTREAM (${UPSTREAM}) is not of the form owner/repo@commit"
}

require_local_clone() {
  if [[ ! -d "${LOCAL_CLONE}/.git" ]]; then
    die "$(printf '%s\n' \
      "no local clone at ${LOCAL_CLONE}" \
      "check-provenance.sh has no other way to verify provenance in this environment; clone ${UPSTREAM%@*} there and try again")"
  fi

  git -C "$LOCAL_CLONE" cat-file -e "${COMMIT}^{commit}" 2>/dev/null ||
    die "${COMMIT} is not a commit in ${LOCAL_CLONE}"
}

check_row() {
  local -r local_path="$1" upstream_path="$2"

  if [[ ! -f "${ROOT}/${local_path}" ]]; then
    printf '  MISSING   %s\n' "$local_path"
    missing=$((missing + 1))
    return 0
  fi

  if ! git -C "$LOCAL_CLONE" show "${COMMIT}:${upstream_path}" >"$TMP_UPSTREAM" 2>/dev/null; then
    printf '%s\n' "  ERROR     ${local_path}: could not read ${upstream_path} at ${COMMIT} from the local clone" >&2
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
    status="$(printf '%s\n' "$status_col" | tr -d ' ')"
    [[ "$status" == "$VERBATIM_STATUS" ]] || continue

    local_path="$(printf '%s\n' "$local_col" | tr -d ' `')"
    upstream_path="$(printf '%s\n' "$upstream_col" | tr -d ' `')"

    if [[ -z "$local_path" ]] || [[ -z "$upstream_path" ]]; then
      printf '%s\n' "  ERROR     unparseable verbatim row: ${local_col}|${upstream_col}|${status_col}" >&2
      errors=$((errors + 1))
      continue
    fi

    check_row "$local_path" "$upstream_path"
  done < <(grep "$VERBATIM_ROW_PREFIX" "$TABLE")
}

# A table that parses to nothing is a broken checker, not a clean run.
print_summary() {
  echo
  printf '%s\n' "${ok} ok, ${drifted} drifted, ${missing} missing, ${errors} errors"

  if ((ok + drifted + missing + errors == 0)); then
    die "no verbatim rows found in ${TABLE}; nothing was checked"
  fi

  ((drifted == 0)) && ((missing == 0)) && ((errors == 0))
}

main() {
  read_upstream_pin
  require_local_clone

  TMP_UPSTREAM="$(mktemp)"
  trap 'rm -f "$TMP_UPSTREAM"' EXIT

  printf '%s\n' "checking verbatim files against ${UPSTREAM}"
  echo
  check_verbatim_rows
  print_summary
}

main "$@"
