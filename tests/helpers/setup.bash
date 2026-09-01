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
