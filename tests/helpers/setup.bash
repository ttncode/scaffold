# Shared bats setup: an owned environment, assert_ok, copy_toolbox.
# shellcheck shell=bash
SCAFFOLD_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export SCAFFOLD_ROOT
PATH="${SCAFFOLD_ROOT}:${PATH}"
export PATH

# A runner has no git github.user, so without this every suite that generates
# a project fails resolve_github_owner's guard.
export SCAFFOLD_GITHUB_OWNER="${SCAFFOLD_GITHUB_OWNER:-test-owner}"

# A runner has no git identity either, and `scaffold new` commits what it
# creates. Owned by this suite rather than written into the runner's HOME.
if [[ -z "${GIT_CONFIG_GLOBAL:-}" ]]; then
  GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR:-${BATS_SUITE_TMPDIR:-/tmp}}/gitconfig"
  export GIT_CONFIG_GLOBAL
  git config --global user.name "scaffold tests"
  git config --global user.email "tests@scaffold.invalid"
  # A commit can hand the repo to a detached `git gc` that outlives the
  # command and keeps writing into .git — the likely race remove_workdir waits out.
  git config --global gc.auto 0
fi

# mise records every config it trusts under its state directory; owned here
# like GIT_CONFIG_GLOBAL above, so a suite generating projects in tmpdirs
# doesn't write into the developer's real (and already pre-trusted) store.
if [[ -z "${MISE_STATE_DIR:-}" ]]; then
  MISE_STATE_DIR="${BATS_TEST_TMPDIR:-${BATS_SUITE_TMPDIR:-/tmp}}/mise-state"
  export MISE_STATE_DIR
fi

# bats' `run` captures the output, so a bare `[ "$status" -eq 0 ]` reports the
# line that failed and nothing about why.
assert_ok() {
  # shellcheck disable=SC2154 # status/output set by bats' run in the calling test
  ((status == 0)) || {
    printf 'exit status %s; command output follows:\n' "$status"
    printf '%s\n' "$output"
    false
  }
}

# A private copy of the toolbox, for a test that modifies it and would
# otherwise race the real tree under --jobs. The scripts resolve their own
# root from their location, so running them out of the copy is enough.
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

# teardown's `rm -rf`, retried: it reports "Directory not empty" when a
# background writer still touches a generated project, which has nothing to
# do with what the test asserted.
remove_workdir() {
  local -r dir="$1"

  for _ in 1 2 3 4 5; do
    rm -rf "$dir" 2>/dev/null && return 0
    sleep 1
  done

  rm -rf "$dir" && return 0
  printf 'could not remove %s, left behind:\n' "$dir" >&2
  find "$dir" >&2
  return 1
}
