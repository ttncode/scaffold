# Terminal output: messages, step markers and quiet command runs.
# shellcheck shell=bash

log() { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

step() { printf '→ %s\n' "$*" >&2; }

# Output is shown only on failure; SCAFFOLD_VERBOSE=1 streams it, for a hang.
run_quietly() {
  local -r what="$1"
  shift
  local log status=0

  if [[ "${SCAFFOLD_VERBOSE:-0}" == "1" ]]; then
    "$@" || die "failed while ${what}"
    return 0
  fi

  log="$(mktemp)"
  "$@" >"$log" 2>&1 || status=$?
  ((status == 0)) || die_with_log "$log" "failed while ${what}"
  rm -f "$log"
}

die_with_log() {
  local -r log="$1" message="$2"

  cat "$log" >&2
  rm -f "$log"
  die "$message"
}
