#!/usr/bin/env bash
# check-provenance.sh — diff every verbatim row in docs/PROVENANCE.md
# against the pinned upstream commit, from a local clone. no network
# fallback: a fetch that silently returns empty on a denied curl would read
# as "everything drifted" instead of "could not check" — worse than failing
# loudly up front.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="${ROOT}/docs/PROVENANCE.md"
# unlike SCAFFOLD_ROOT, this path is not self-locating — it names a clone on
# whichever machine runs this script, so it must be overridable (CI, another
# contributor's checkout). a wrong value still fails loudly below rather than
# passing silently.
LOCAL_CLONE="${SCAFFOLD_UPSTREAM_CLONE:-/home/ttndev/workspace/playground/immich}"

[ -f "${ROOT}/UPSTREAM" ] || { echo "error: ${ROOT}/UPSTREAM not found" >&2; exit 1; }
[ -f "$TABLE" ] || { echo "error: ${TABLE} not found" >&2; exit 1; }

UPSTREAM="$(cat "${ROOT}/UPSTREAM")"
COMMIT="${UPSTREAM#*@}"
[ -n "$COMMIT" ] && [ "$COMMIT" != "$UPSTREAM" ] || {
  echo "error: UPSTREAM (${UPSTREAM}) is not of the form owner/repo@commit" >&2
  exit 1
}

if [ ! -d "${LOCAL_CLONE}/.git" ]; then
  echo "error: no local clone at ${LOCAL_CLONE}" >&2
  echo "check-provenance.sh has no other way to verify provenance in this environment; clone ${UPSTREAM%@*} there and try again" >&2
  exit 1
fi

if ! git -C "$LOCAL_CLONE" cat-file -e "${COMMIT}^{commit}" 2>/dev/null; then
  echo "error: ${COMMIT} is not a commit in ${LOCAL_CLONE}" >&2
  exit 1
fi

tmp_upstream="$(mktemp)"
trap 'rm -f "$tmp_upstream"' EXIT

ok=0
drifted=0
missing=0
errors=0

echo "checking verbatim files against ${UPSTREAM}"
echo

while IFS='|' read -r _ local_col upstream_col status_col _; do
  status="$(echo "$status_col" | tr -d ' ')"
  [ "$status" = "verbatim" ] || continue

  local_path="$(echo "$local_col" | tr -d ' `')"
  upstream_path="$(echo "$upstream_col" | tr -d ' `')"

  if [ -z "$local_path" ] || [ -z "$upstream_path" ]; then
    echo "  ERROR     unparseable verbatim row: ${local_col}|${upstream_col}|${status_col}" >&2
    errors=$((errors + 1))
    continue
  fi

  if [ ! -f "${ROOT}/${local_path}" ]; then
    printf '  MISSING   %s\n' "$local_path"
    missing=$((missing + 1))
    continue
  fi

  if ! git -C "$LOCAL_CLONE" show "${COMMIT}:${upstream_path}" >"$tmp_upstream" 2>/dev/null; then
    echo "  ERROR     ${local_path}: could not read ${upstream_path} at ${COMMIT} from the local clone" >&2
    errors=$((errors + 1))
    continue
  fi

  if diff -q "$tmp_upstream" "${ROOT}/${local_path}" >/dev/null 2>&1; then
    printf '  ok        %s\n' "$local_path"
    ok=$((ok + 1))
  else
    printf '  DRIFTED   %s\n' "$local_path"
    diff "$tmp_upstream" "${ROOT}/${local_path}" | sed 's/^/              /'
    drifted=$((drifted + 1))
  fi
done < <(grep '^| `' "$TABLE")

echo
echo "${ok} ok, ${drifted} drifted, ${missing} missing, ${errors} errors"

if [ $((ok + drifted + missing + errors)) -eq 0 ]; then
  echo "error: no verbatim rows found in ${TABLE}; nothing was checked" >&2
  exit 1
fi

[ "$drifted" -eq 0 ] && [ "$missing" -eq 0 ] && [ "$errors" -eq 0 ]
