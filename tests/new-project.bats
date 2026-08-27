setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "new creates a git repository on main" {
  run scaffold new "$PROJECT"
  [ "$status" -eq 0 ]
  run git -C "$PROJECT" rev-parse --abbrev-ref HEAD
  [ "$output" = "main" ]
}

@test "new copies the common layer" {
  scaffold new "$PROJECT"
  [ -f "${PROJECT}/lefthook.yml" ]
  [ -f "${PROJECT}/commitlint.config.js" ]
  [ -f "${PROJECT}/renovate.json" ]
  [ -f "${PROJECT}/CONTRIBUTING.md" ]
  [ -f "${PROJECT}/.editorconfig" ]
}

@test "new leaves no toolbox files in the project" {
  scaffold new "$PROJECT"
  [ ! -e "${PROJECT}/adapters" ]
  [ ! -e "${PROJECT}/common" ]
  [ ! -e "${PROJECT}/mise.root.toml" ]
  [ ! -e "${PROJECT}/UPSTREAM" ]
}

@test "new writes a root mise.toml with docs as the only config root" {
  scaffold new "$PROJECT"
  run collect_roots "$PROJECT"
  [ "$output" = "docs" ]
}

@test "register_config_root is idempotent" {
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/project.sh"
  scaffold new "$PROJECT"
  register_config_root "$PROJECT" "apps/api"
  register_config_root "$PROJECT" "apps/api"
  run bash -c "grep -c '\"apps/api\",' '${PROJECT}/mise.toml'"
  [ "$output" = "1" ]
}

@test "sync_ci_roots writes the roots as a JSON array" {
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/project.sh"
  scaffold new "$PROJECT"
  register_config_root "$PROJECT" "apps/api"
  sync_ci_roots "$PROJECT"
  run grep 'roots:' "${PROJECT}/.github/workflows/ci.yml"
  [[ "$output" == *'["apps/api","docs"]'* ]]
}

@test "new refuses to overwrite an existing path" {
  mkdir -p "$PROJECT"
  run scaffold new "$PROJECT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to overwrite"* ]]
}

# register_config_root, collect_config_roots and sync_ci_roots must agree on
# formatting (two-space indent, quoted value, trailing comma) or the ci matrix
# silently drops entries. round-trip two roots and check every stage.
@test "register, collect and sync agree on two roots" {
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/project.sh"
  scaffold new "$PROJECT"
  register_config_root "$PROJECT" "apps/api"
  register_config_root "$PROJECT" "apps/web"

  run collect_config_roots "$PROJECT"
  [ "${lines[0]}" = "apps/web" ]
  [ "${lines[1]}" = "apps/api" ]
  [ "${lines[2]}" = "docs" ]

  sync_ci_roots "$PROJECT"
  run grep 'roots:' "${PROJECT}/.github/workflows/ci.yml"
  [[ "$output" == *'["apps/web","apps/api","docs"]'* ]]
}

# init_project must trust only the config it just wrote, never a parent
# directory's config it did not create (mise trust -a walks parents too).
@test "new does not trust a parent config it did not create" {
  printf 'monorepo_root = true\n\n[monorepo]\nconfig_roots = [\n  "x",\n]\n' \
    > "${WORKDIR}/mise.toml"
  run mise trust --show -C "$WORKDIR"
  [[ "$output" == *"${WORKDIR}: untrusted"* ]]

  scaffold new "$PROJECT"

  run mise trust --show -C "$PROJECT"
  [[ "$output" == *"${WORKDIR}: untrusted"* ]]
  [[ "$output" == *"${PROJECT}: trusted"* ]]
}

# init_project arms its cleanup trap immediately after mkdir succeeds, so a
# later step failing (git init, the common-layer copy, mise trust) is covered
# too, not just a failure in cmd_new after init_project already returned.
# tests/fixtures/no-common symlinks the real scaffold/lib but ships no
# common/ directory, so the cp -R in init_project fails deterministically,
# without depending on mise or the network.
@test "a failure inside init_project after mkdir removes what it created" {
  run "${SCAFFOLD_ROOT}/tests/fixtures/no-common/scaffold" new "$PROJECT"
  [ "$status" -eq 1 ]
  [ ! -e "$PROJECT" ]
}

# this is the assertion that would catch an unsafe placement of the trap
# (armed before the overwrite guard runs): a pre-existing target must survive
# a rejected `new` untouched, contents included.
@test "a pre-existing target survives a rejected new" {
  mkdir -p "$PROJECT"
  echo "keep me" > "${PROJECT}/marker"

  run "${SCAFFOLD_ROOT}/tests/fixtures/no-common/scaffold" new "$PROJECT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to overwrite"* ]]
  [ -d "$PROJECT" ]
  [ -f "${PROJECT}/marker" ]
  [ "$(cat "${PROJECT}/marker")" = "keep me" ]
}

collect_roots() {
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/project.sh"
  collect_config_roots "$1"
}
