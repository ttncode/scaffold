# shellcheck shell=bash
log()  { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# step <description>
# A line before a step that takes minutes, so a captured command does not look
# like a hang. Numbered nothing and totalled nothing: the number of steps
# depends on the adapters requested, and a "3 of 7" that is wrong is worse
# than no count.
step() { printf '→ %s\n' "$*" >&2; }

# run_quietly <what-for> <command>...
# Runs a command with its output captured, and prints that output only if it
# fails. `scaffold new` used to hand the terminal several minutes of a package
# manager's progress bars, through which the one line that mattered — which
# application is being generated — never appeared at all.
#
# SCAFFOLD_VERBOSE=1 passes the output straight through. The failure path
# already prints everything, so this is for a run that hangs rather than
# fails, where there is otherwise nothing to look at.
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
