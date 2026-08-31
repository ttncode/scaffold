# shellcheck shell=bash
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
fi

# bats' `run` captures the output, so a bare `[ "$status" -eq 0 ]` reports the
# line that failed and nothing about why.
assert_ok() {
  [ "$status" -eq 0 ] || {
    echo "exit status ${status}; command output follows:"
    echo "$output"
    false
  }
}
