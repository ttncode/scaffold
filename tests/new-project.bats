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

collect_roots() {
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/project.sh"
  collect_config_roots "$1"
}
