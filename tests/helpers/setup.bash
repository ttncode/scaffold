# shellcheck shell=bash
SCAFFOLD_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export SCAFFOLD_ROOT
PATH="${SCAFFOLD_ROOT}:${PATH}"
export PATH

# scaffold new substitutes the "you/" placeholder in generated workflows with
# this account; tests run wherever CI happens to run, with no git github.user
# configured, so give init_project a fixed one rather than have every suite
# that calls `scaffold new` fail resolve_github_owner's guard.
export SCAFFOLD_GITHUB_OWNER="${SCAFFOLD_GITHUB_OWNER:-test-owner}"

# `scaffold new` commits the project it creates, and git refuses to commit with
# no identity configured — which is the state a CI runner starts in, so every
# suite that generates a project failed there while passing locally. Point git
# at a config this suite owns rather than writing into the runner's HOME.
if [ -z "${GIT_CONFIG_GLOBAL:-}" ]; then
  GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR:-${BATS_SUITE_TMPDIR:-/tmp}}/gitconfig"
  export GIT_CONFIG_GLOBAL
  git config --global user.name "scaffold tests"
  git config --global user.email "tests@scaffold.invalid"
fi

# assert_ok — bats' `run` captures the command's output, so a bare
# `[ "$status" -eq 0 ]` reports which line failed and nothing about why. Every
# CI diagnosis in this repository has started by adding this by hand first.
assert_ok() {
  [ "$status" -eq 0 ] || {
    echo "exit status ${status}; command output follows:"
    echo "$output"
    false
  }
}
