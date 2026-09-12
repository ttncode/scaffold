# ═══════════════════════════════════════════════════════════════════════════
# Script      : lib/log.sh
# Description : Terminal output: messages, step markers and quiet command runs.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck shell=bash

log()  { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Marks a step that takes minutes, so a captured command does not read as a
# hang. Unnumbered: the number of steps depends on the adapters requested.
step() { printf '→ %s\n' "$*" >&2; }

# run_quietly <what-for> <command>...
# Captures output and prints it only on failure; SCAFFOLD_VERBOSE=1 passes it
# straight through, for a run that hangs rather than fails.
run_quietly() {
  local what="$1"; shift
  local log status=0

  if [ "${SCAFFOLD_VERBOSE:-0}" = 1 ]; then
    "$@" || die "failed while ${what}"
    return 0
  fi

  log="$(mktemp)"
  "$@" >"$log" 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    cat "$log" >&2
    rm -f "$log"
    die "failed while ${what}"
  fi
  rm -f "$log"
}
