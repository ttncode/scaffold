#!/usr/bin/env bats

setup() {
  load 'helpers/setup'
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/contract.sh"
  source "${SCAFFOLD_ROOT}/lib/adapter.sh"
  source "${SCAFFOLD_ROOT}/lib/service.sh"
  source "${SCAFFOLD_ROOT}/lib/project.sh"
  source "${SCAFFOLD_ROOT}/lib/pnpm.sh"
  source "${SCAFFOLD_ROOT}/lib/manifest.sh"
  source "${SCAFFOLD_ROOT}/lib/update.sh"
  WORKDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORKDIR"
}

_commit() {
  git -C "$1" add -A
  git -C "$1" -c user.email=t@scaffold.invalid -c user.name=t commit -q -m "$2"
}

# _toolbox_with_history — a private copy of the toolbox carrying two commits,
# so a test has a real "before" to diff from. Generating a project and waiting
# for a toolbox commit to happen would make every one of these tests an
# integration test for no extra coverage.
_toolbox_with_history() {
  local box; box="$(copy_toolbox)"
  git -C "$box" init -q -b main
  _commit "$box" "before"
  printf '\n# a later change to the shipped hooks\n' >> "${box}/common/lefthook.yml"
  _commit "$box" "after"
  printf '%s' "$box"
}

# _fixture_project <dir> <version> — the least a project can be and still be
# one this command will act on: the marker, the registry path, a config root,
# and the two workflows whose computed regions get re-derived.
_fixture_project() {
  local project="$1" version="$2"

  mkdir -p "${project}/.github/workflows"
  cp "${SCAFFOLD_ROOT}/common/lefthook.yml" "${project}/lefthook.yml"
  cat > "${project}/mise.toml" <<EOF
monorepo_root = true

[vars]
image = "ghcr.io/acme/demo"

[monorepo]
config_roots = [
  "docs",
]

[tasks.checklist]
run = [{ task = "//docs:checklist" }]
EOF
  printf 'jobs:\n  ci:\n    with:\n      roots: %s\n' "'[\"docs\"]'" \
    > "${project}/.github/workflows/ci.yml"
  printf 'jobs:\n  build:\n    with:\n      images: "[]"\n' \
    > "${project}/.github/workflows/build.yml"
  printf 'jobs:\n  release:\n    with:\n      images: "[]"\n' \
    > "${project}/.github/workflows/release.yml"
  printf 'version = "%s"\n\n[apps]\n' "$version" > "${project}/.scaffold.toml"

  git -C "$project" init -q -b main
  _commit "$project" "scaffold project"
}

@test "a generated project records the toolbox that produced it" {
  local project="${WORKDIR}/demo"
  scaffold new "$project"
  [ -f "${project}/.scaffold.toml" ]

  run yq -p toml -oy -r '.version' "${project}/.scaffold.toml"
  assert_ok
  [ "$output" = "$(git -C "$SCAFFOLD_ROOT" describe --tags --always --dirty)" ] \
    || { echo "recorded ${output}"; false; }
}

@test "rewrite_patch_paths moves headers and leaves content alone" {
  # A path-shaped string in a context line is file content. Rewriting it would
  # corrupt the hunk it appears in, and the corruption would only show up as a
  # rejected patch much later.
  local patch
  patch="$(printf '%s\n' \
    'diff --git a/common/lefthook.yml b/common/lefthook.yml' \
    '--- a/common/lefthook.yml' \
    '+++ b/common/lefthook.yml' \
    '@@ -1,2 +1,2 @@' \
    '-# see common/lefthook.yml for the hooks' \
    '+# see lefthook.yml for the hooks')"

  # Not through bats' `run`, which starts a subshell the function was never
  # exported to.
  local rewritten
  rewritten="$(printf '%s\n' "$patch" | rewrite_patch_paths 'common/' '')"
  [[ "$rewritten" == *'diff --git a/lefthook.yml b/lefthook.yml'* ]]
  [[ "$rewritten" == *'--- a/lefthook.yml'* ]]
  [[ "$rewritten" == *'+++ b/lefthook.yml'* ]]
  # untouched, because it is content
  [[ "$rewritten" == *'-# see common/lefthook.yml for the hooks'* ]]
}

@test "update refuses a project that records nothing" {
  local project="${WORKDIR}/bare"
  mkdir -p "$project"
  printf 'monorepo_root = true\n' > "${project}/mise.toml"
  git -C "$project" init -q -b main 2>/dev/null || true

  run scaffold update "$project"
  [ "$status" -ne 0 ]
  [[ "$output" == *".scaffold.toml"* ]]
  # and says what to write, rather than only what is missing
  [[ "$output" == *"[apps]"* ]]
}

@test "update refuses a commit this toolbox does not have" {
  local project="${WORKDIR}/stranger"
  _fixture_project "$project" "0000000"

  run scaffold update "$project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no commit 0000000"* ]]
}

@test "update refuses a project generated from uncommitted edits" {
  # There is no commit to diff against, and saying that is more use than a
  # git error about an unknown revision ending in -dirty.
  local project="${WORKDIR}/dirty"
  _fixture_project "$project" "abc1234-dirty"

  run scaffold update "$project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted edits"* ]]
}

@test "update brings a later change to a project that predates it" {
  local box; box="$(_toolbox_with_history)"
  local from; from="$(git -C "$box" rev-parse HEAD~1)"
  local project="${WORKDIR}/old"
  _fixture_project "$project" "$from"
  # _fixture_project already copied common/lefthook.yml, and the toolbox
  # copy's first commit is a copy of this same tree — so the project is
  # carrying exactly what it would have been generated with at `from`.

  run "${box}/scaffold" update "$project"
  assert_ok
  run grep -c 'a later change to the shipped hooks' "${project}/lefthook.yml"
  [ "$output" = 1 ]
}

@test "update records the version it moved to" {
  local box; box="$(_toolbox_with_history)"
  local from; from="$(git -C "$box" rev-parse HEAD~1)"
  local project="${WORKDIR}/recorded"
  _fixture_project "$project" "$from"

  "${box}/scaffold" update "$project"

  run yq -p toml -oy -r '.version' "${project}/.scaffold.toml"
  [ "$output" = "$(git -C "$box" describe --tags --always --dirty)" ] \
    || { echo "still recorded ${output}"; false; }
}

@test "a dry run changes nothing" {
  local box; box="$(_toolbox_with_history)"
  local from; from="$(git -C "$box" rev-parse HEAD~1)"
  local project="${WORKDIR}/preview"
  _fixture_project "$project" "$from"

  run "${box}/scaffold" update "$project" --dry-run
  assert_ok
  [[ "$output" == *"a later change to the shipped hooks"* ]]
  [ -z "$(git -C "$project" status --porcelain)" ] \
    || { echo "a dry run wrote:"; git -C "$project" status --porcelain; false; }
}

@test "update refuses a project with uncommitted changes" {
  # `git diff` afterwards is the only review this gets, and it has to show
  # this run's changes alone.
  local box; box="$(_toolbox_with_history)"
  local from; from="$(git -C "$box" rev-parse HEAD~1)"
  local project="${WORKDIR}/messy"
  _fixture_project "$project" "$from"
  printf 'work in progress\n' >> "${project}/lefthook.yml"

  run "${box}/scaffold" update "$project"
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted changes"* ]]
}

@test "a patch that empties the computed build targets is re-derived, not left empty" {
  # The templates carry `images: "[]"`, because the array is written per
  # application at generation time. Applied verbatim to a project, that reads
  # as a comment change in `git diff` and leaves the project building nothing.
  local project="${WORKDIR}/derived"
  _fixture_project "$project" "0000000"
  printf '"apps/api" = "nestjs"\n' >> "${project}/.scaffold.toml"
  mkdir -p "${project}/apps/api"
  : > "${project}/apps/api/Dockerfile"
  _commit "$project" "an application"

  resync_derived "$project"

  run yq -r '[.jobs[] | select(has("with")) | .with.images] | .[0]' \
    "${project}/.github/workflows/build.yml"
  [[ "$output" == *'ghcr.io/acme/demo-api'* ]] || { echo "images are: ${output}"; false; }
  [[ "$output" == *'apps/api/Dockerfile'* ]]
}
