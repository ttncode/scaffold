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

@test "the path check fails on an adr citation that does not ship" {
  echo '# see docs/decisions/0014-deployment-deferred-with-seams.md' >> "${PROJECT}/compose.yaml"
  cd "${PROJECT}/docs"
  run node scripts/check-paths.mjs
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/decisions/0014-deployment-deferred-with-seams.md"* ]]
}

@test "the path check accepts an adr citation that does ship" {
  echo '# see docs/decisions/0000 for the rule' >> "${PROJECT}/compose.yaml"
  cd "${PROJECT}/docs"
  run node scripts/check-paths.mjs
  [ "$status" -eq 0 ]
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

@test "the path check ignores a generated app's own generator-owned markdown" {
  mkdir -p "${PROJECT}/apps/web"
  cat > "${PROJECT}/apps/web/AGENTS.md" <<'EOF'
See `node_modules/next/dist/server/lib/generate-agent-files.js`.
This block is written and re-added by `next dev`.
EOF
  cat > "${PROJECT}/apps/web/README.md" <<'EOF'
Edit `app/page.tsx`. Fonts are loaded with `next/font`.
EOF
  cd "${PROJECT}/docs"
  run node scripts/check-paths.mjs
  [ "$status" -eq 0 ]
}

@test "the docs site builds" {
  cd "$PROJECT"
  run mise run //docs:build
  [ "$status" -eq 0 ]
}

@test "the docs build fails on a dead link" {
  echo '[nowhere](/nowhere)' >> "${PROJECT}/docs/index.md"
  cd "$PROJECT"
  run mise run //docs:build
  [ "$status" -ne 0 ]
  [[ "$output" == *"dead link"* ]]
}

@test "a broken path surfaces as a failing docs:check" {
  echo 'See `docs/nope-does-not-exist.md`.' >> "${PROJECT}/docs/index.md"
  cd "$PROJECT"
  run mise run //docs:check
  [ "$status" -ne 0 ]
}

@test "a broken adr surfaces as a failing docs:check" {
  cat > "${PROJECT}/docs/decisions/0001-broken.md" <<'EOF'
# 0001 — Broken

Status: Accepted

## Context

Nothing else follows.
EOF
  cd "$PROJECT"
  run mise run //docs:check
  [ "$status" -ne 0 ]
}
