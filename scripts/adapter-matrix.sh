#!/usr/bin/env bash
# Print the tier-a and tier-b adapter matrices for CI (ADR-0012). Tier a runs on
# every event; tier b on a pull request only when its own directory changed,
# otherwise on the weekly schedule or a manual dispatch.
#
# Usage:   ./scripts/adapter-matrix.sh <event-name> <schedule-cron> [base-sha] [head-sha]
# Example: ./scripts/adapter-matrix.sh pull_request "" "$BASE_SHA" "$HEAD_SHA"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

EVENT_NAME="${1:?event name required}"
SCHEDULE_CRON="${2:-}"
BASE_SHA="${3:-}"
HEAD_SHA="${4:-}"

# Must match the weekly line in .github/workflows/adapters.yml: a schedule event
# carries the cron string that fired, not a name.
WEEKLY_CRON="23 2 * * 1"

KNOWN_TIERS=(A B C)

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

to_json_array() {
  jq -R . | jq -sc 'map(select(length > 0))'
}

adapters_at_tier() {
  local -r tier="$1"

  "${ROOT}/scaffold" list --adapters | awk -F'\t' -v tier="$tier" '$3 == tier { print $1 }'
}

# An unrecognised tier would match neither matrix and vanish with exit 0.
assert_known_tiers() {
  local name tier
  while IFS=$'\t' read -r name _ tier; do
    case " ${KNOWN_TIERS[*]} " in
      *" ${tier} "*) ;;
      *) die "adapter '${name}' has an unrecognised ADAPTER_TIER: '${tier}'" ;;
    esac
  done < <("${ROOT}/scaffold" list --adapters)
}

changed_tier_b_adapters() {
  local -r base="$1" head="$2"
  local changed name
  changed="$(git -C "$ROOT" diff --name-only "$base" "$head")"

  adapters_at_tier B | while IFS= read -r name; do
    case "$changed" in
      *"adapters/${name}/"*) printf '%s\n' "$name" ;;
    esac
  done | to_json_array
}

assert_known_tiers

tier_a_json="$(adapters_at_tier A | to_json_array)"

case "$EVENT_NAME" in
  pull_request)
    [[ -n "$BASE_SHA" ]] && [[ -n "$HEAD_SHA" ]] ||
      die "pull_request needs a base and head sha"
    tier_b_json="$(changed_tier_b_adapters "$BASE_SHA" "$HEAD_SHA")"
    ;;
  workflow_dispatch)
    tier_b_json="$(adapters_at_tier B | to_json_array)"
    ;;
  schedule)
    if [[ "$SCHEDULE_CRON" == "$WEEKLY_CRON" ]]; then
      tier_b_json="$(adapters_at_tier B | to_json_array)"
    else
      tier_b_json="[]"
    fi
    ;;
  *)
    tier_b_json="[]"
    ;;
esac

printf '%s\n' "tier-a=${tier_a_json}"
printf '%s\n' "tier-b=${tier_b_json}"
