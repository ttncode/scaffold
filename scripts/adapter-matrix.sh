#!/usr/bin/env bash
# adapter-matrix.sh <event-name> <schedule-cron> [base-sha] [head-sha] —
# print the tier-a and tier-b matrices as GITHUB_OUTPUT lines (see
# docs/decisions/0012). tier membership comes from each adapter's own
# adapter.env (via `scaffold list`), not a second list baked into the
# workflow, so the tier recorded on the adapter and the tier CI runs can't
# drift apart silently.
#
# tier a runs on every pull request and every schedule fire (nightly and
# weekly) and workflow_dispatch. tier b only runs on a pull request when its
# own directory changed, or on the weekly schedule (WEEKLY_CRON below, which
# must match the weekly line in .github/workflows/adapters.yml — schedule
# events carry the cron string that fired but nothing that names it) or a
# manual dispatch.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVENT_NAME="${1:?event name required}"
SCHEDULE_CRON="${2:-}"
BASE_SHA="${3:-}"
HEAD_SHA="${4:-}"

WEEKLY_CRON="23 2 * * 1"

to_json_array() {
  jq -R . | jq -sc 'map(select(length > 0))'
}

adapters_at_tier() {
  "${ROOT}/scaffold" list | awk -F'\t' -v tier="$1" '$3 == tier { print $1 }'
}

# a well-formed but unrecognised ADAPTER_TIER (a typo, a trailing space)
# would otherwise just fail every `$3 == tier` match above and vanish from
# both matrices with exit 0 — the exact "stopped being checked and nobody
# noticed" failure mode this project keeps finding elsewhere.
validate_tiers() {
  local name tier
  while IFS=$'\t' read -r name _ tier; do
    case "$tier" in
      A | B | C) ;;
      *)
        echo "error: adapter '${name}' has an unrecognised ADAPTER_TIER: '${tier}'" >&2
        exit 1
        ;;
    esac
  done < <("${ROOT}/scaffold" list)
}

validate_tiers

tier_a_json="$(adapters_at_tier A | to_json_array)"

case "$EVENT_NAME" in
  pull_request)
    [ -n "$BASE_SHA" ] && [ -n "$HEAD_SHA" ] || {
      echo "error: pull_request needs a base and head sha" >&2
      exit 1
    }
    changed="$(git -C "$ROOT" diff --name-only "$BASE_SHA" "$HEAD_SHA")"
    tier_b_json="$(
      adapters_at_tier B | while IFS= read -r name; do
        case "$changed" in
          *"adapters/${name}/"*) echo "$name" ;;
        esac
      done | to_json_array
    )"
    ;;
  workflow_dispatch)
    tier_b_json="$(adapters_at_tier B | to_json_array)"
    ;;
  schedule)
    if [ "$SCHEDULE_CRON" = "$WEEKLY_CRON" ]; then
      tier_b_json="$(adapters_at_tier B | to_json_array)"
    else
      tier_b_json="[]"
    fi
    ;;
  *)
    tier_b_json="[]"
    ;;
esac

echo "tier-a=${tier_a_json}"
echo "tier-b=${tier_b_json}"
