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
