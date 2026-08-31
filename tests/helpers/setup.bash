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
