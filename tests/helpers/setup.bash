# shellcheck shell=bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : tests/helpers/setup.bash
# Description : Shared bats setup: an owned environment, assert_ok, copy_toolbox.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
SCAFFOLD_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export SCAFFOLD_ROOT
PATH="${SCAFFOLD_ROOT}:${PATH}"
export PATH

# A runner has no git github.user, so without this every suite that generates
# a project fails resolve_github_owner's guard.
export SCAFFOLD_GITHUB_OWNER="${SCAFFOLD_GITHUB_OWNER:-test-owner}"

# Same shape: a runner has no git identity either, and `scaffold new` commits
# what it creates. Owned by this suite rather than written into the runner's
# HOME.
if [ -z "${GIT_CONFIG_GLOBAL:-}" ]; then
  GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR:-${BATS_SUITE_TMPDIR:-/tmp}}/gitconfig"
  export GIT_CONFIG_GLOBAL
  git config --global user.name "scaffold tests"
  git config --global user.email "tests@scaffold.invalid"
  # `scaffold new` commits, and a commit can hand the repository to a detached
  # `git gc`. That process outlives the command and keeps writing into .git,
  # which is the likeliest thing remove_workdir below is racing. A throwaway
  # repository has nothing worth maintaining.
  git config --global gc.auto 0
fi

# mise records every config it trusts under its state directory, so a suite
# that generates projects in throwaway tmpdirs writes an entry per run into
# the developer's real store and never removes it — it had grown past 7600
# stale `tmp.*-demo` entries. Owned by the test, like GIT_CONFIG_GLOBAL above,
# which also makes the trust behaviour itself observable: the real store is
# pre-trusted on a runner, so a test asserting an untrusted parent could only
# ever skip there.
if [ -z "${MISE_STATE_DIR:-}" ]; then
  MISE_STATE_DIR="${BATS_TEST_TMPDIR:-${BATS_SUITE_TMPDIR:-/tmp}}/mise-state"
  export MISE_STATE_DIR
fi

# bats' `run` captures the output, so a bare `[ "$status" -eq 0 ]` reports the
# line that failed and nothing about why.
assert_ok() {
  # shellcheck disable=SC2154 # status/output set by bats' run in the calling test
  [ "$status" -eq 0 ] || {
    echo "exit status ${status}; command output follows:"
    echo "$output"
    false
  }
}

# copy_toolbox — a private copy of the toolbox for a test that has to modify
# it. Two tests need to see how the scripts behave against a broken adapter or
# a drifted file; editing the real tree made them race each other once the
# suites started running with --jobs, and one left ADAPTER_TIER="Z" behind in
# a tracked file. The scripts resolve their own root from their location, so
# running them out of the copy is enough.
copy_toolbox() {
  local dest="${BATS_TEST_TMPDIR}/toolbox"
  mkdir -p "$dest"
  cp -R "${SCAFFOLD_ROOT}/adapters" "${SCAFFOLD_ROOT}/lib" \
    "${SCAFFOLD_ROOT}/scripts" "${SCAFFOLD_ROOT}/common" \
    "${SCAFFOLD_ROOT}/scaffold" "$dest/"
  cp "${SCAFFOLD_ROOT}/UPSTREAM" "$dest/" 2>/dev/null || true
  mkdir -p "$dest/docs"
  cp "${SCAFFOLD_ROOT}/docs/PROVENANCE.md" "$dest/docs/" 2>/dev/null || true
  printf '%s' "$dest"
}

# remove_workdir — teardown's `rm -rf`, retried.
#
# `rm -rf` reports "Directory not empty" when an entry appears after it walked
# the directory, so a background process still writing into a generated project
# fails a teardown that has nothing to do with what the test asserted. Seen on
# CI against `tests/compose.bats`, which generates a project per test under
# --jobs, and on a different test each run; never reproduced locally, and the
# writer was never caught in the act, so this waits the race out rather than
# naming a cause. A tree that is genuinely stuck still fails, and says what is
# left in it.
remove_workdir() {
  local -r dir="$1"

  for _ in 1 2 3 4 5; do
    rm -rf "$dir" 2>/dev/null && return 0
    sleep 1
  done

  rm -rf "$dir" && return 0
  echo "could not remove ${dir}, left behind:" >&2
  find "$dir" >&2
  return 1
}
