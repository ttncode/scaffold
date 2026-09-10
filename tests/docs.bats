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
    assert_ok
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
  assert_ok
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
  assert_ok
}

@test "the shipped docs are already prettier-clean" {
  # The toolbox's own `lint` only shellchecks, so nothing else runs prettier
  # over common/docs. A shipped markdown file with the wrong emphasis marker
  # reaches every generated project and fails its first //docs:ci-unit.
  cd "$PROJECT"
  run mise run //docs:format
  assert_ok
}

@test "the docs site builds" {
  cd "$PROJECT"
  run mise run //docs:build
  assert_ok
}

@test "the vendored theme ships whole: css, licence, notice and logo" {
  local vendor="${PROJECT}/docs/.vitepress/theme/vendor/escrcpy" file
  for file in LICENSE NOTICE rainbow.css vars.css; do
    [ -f "${vendor}/${file}" ] || { echo "missing: vendor/escrcpy/${file}"; false; }
  done
  [ -f "${PROJECT}/docs/public/logo.png" ]
  # reformatting the copy would make it a modified file under section 4(b);
  # the exemption is the only thing standing between prettier and that.
  run grep -qx '.vitepress/theme/vendor' "${PROJECT}/docs/.prettierignore"
  assert_ok
}

@test "the built site carries the vendored brand colour and the hero logo" {
  cd "$PROJECT"
  run mise run //docs:build
  assert_ok
  # the vendored css reaches a reader only through theme/index.js. Drop that
  # import and the site still builds, still passes every other check, and
  # quietly serves stock vitepress green.
  run grep -rq -- '#00a98e' docs/.vitepress/dist/assets
  assert_ok
  run grep -q 'logo.png' docs/.vitepress/dist/index.html
  assert_ok
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
