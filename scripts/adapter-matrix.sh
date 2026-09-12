#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : scripts/adapter-matrix.sh
# Description : Print the tier-a and tier-b adapter matrices for CI (ADR-0012).
# Author      : ttncode
#
# Usage:
#   ./scripts/adapter-matrix.sh <event-name> <schedule-cron> [base-sha] [head-sha]
#
# Example:
#   ./scripts/adapter-matrix.sh pull_request "" "$BASE_SHA" "$HEAD_SHA"
# ═══════════════════════════════════════════════════════════════════════════
#
# Tier membership comes from each adapter's own adapter.env (via `scaffold list
# --adapters`), not a second list baked into the workflow, so the tier recorded
# on the adapter and the tier CI runs cannot drift apart silently.
#
# Tier a runs on every pull request, every schedule fire and every dispatch.
# Tier b runs on a pull request only when its own directory changed, and
# otherwise on the weekly schedule or a manual dispatch.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

EVENT_NAME="${1:?event name required}"
SCHEDULE_CRON="${2:-}"
BASE_SHA="${3:-}"
HEAD_SHA="${4:-}"

# Must match the weekly line in .github/workflows/adapters.yml: a schedule event
# carries the cron string that fired but nothing that names it.
WEEKLY_CRON="23 2 * * 1"

KNOWN_TIERS=(A B C)

to_json_array() {
  jq -R . | jq -sc 'map(select(length > 0))'
}

adapters_at_tier() {
  "${ROOT}/scaffold" list --adapters | awk -F'\t' -v tier="$1" '$3 == tier { print $1 }'
}

# A well-formed but unrecognised ADAPTER_TIER (a typo, a trailing space) would
# otherwise fail every `$3 == tier` match above and vanish from both matrices
# with exit 0 — the exact "stopped being checked and nobody noticed" failure
# this project keeps finding elsewhere.
assert_known_tiers() {
  local name tier
  while IFS=$'\t' read -r name _ tier; do
    case " ${KNOWN_TIERS[*]} " in
      *" ${tier} "*) ;;
      *)
        echo "error: adapter '${name}' has an unrecognised ADAPTER_TIER: '${tier}'" >&2
        exit 1
        ;;
    esac
  done < <("${ROOT}/scaffold" list --adapters)
}

changed_tier_b_adapters() {
  local changed name
  changed="$(git -C "$ROOT" diff --name-only "$1" "$2")"

  adapters_at_tier B | while IFS= read -r name; do
    case "$changed" in
      *"adapters/${name}/"*) echo "$name" ;;
    esac
  done | to_json_array
}

assert_known_tiers

tier_a_json="$(adapters_at_tier A | to_json_array)"

case "$EVENT_NAME" in
  pull_request)
    [ -n "$BASE_SHA" ] && [ -n "$HEAD_SHA" ] || {
      echo "error: pull_request needs a base and head sha" >&2
      exit 1
    }
    tier_b_json="$(changed_tier_b_adapters "$BASE_SHA" "$HEAD_SHA")"
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
