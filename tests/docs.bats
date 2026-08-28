setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
  scaffold new "$PROJECT" --api nestjs
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "docs is a config root with the full contract" {
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/contract.sh"
  source "${SCAFFOLD_ROOT}/lib/lint.sh"
  for task in "${CONTRACT_TASKS[@]}"; do
    run grep -Eq "^\[tasks\.\"?${task}\"?\]" "${PROJECT}/docs/mise.toml"
    [ "$status" -eq 0 ]
  done
}

@test "the adr template and the seed adr ship" {
  [ -f "${PROJECT}/docs/decisions/0000-record-architecture-decisions.md" ]
  [ -f "${PROJECT}/docs/decisions/_template.md" ]
}

@test "the path check fails on a path that does not exist" {
  echo 'See `docs/nope-does-not-exist.md`.' >> "${PROJECT}/docs/index.md"
  cd "${PROJECT}/docs"
  run node scripts/check-paths.mjs
  [ "$status" -eq 1 ]
  [[ "$output" == *"nope-does-not-exist.md"* ]]
}

@test "the adr check rejects an adr missing a required section" {
  cat > "${PROJECT}/docs/decisions/0001-broken.md" <<'EOF'
# 0001 — Broken

Status: Accepted

## Context

Nothing else follows.
EOF
  cd "${PROJECT}/docs"
  run node scripts/check-adrs.mjs
  [ "$status" -eq 1 ]
  [[ "$output" == *"0001-broken.md"* ]]
}

@test "the docs site builds" {
  cd "$PROJECT"
  run mise run //docs:build
  [ "$status" -eq 0 ]
}
