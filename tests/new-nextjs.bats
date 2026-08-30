setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "nextjs generates an app at apps/web" {
  run scaffold new "$PROJECT" --web nextjs
  [ "$status" -eq 0 ]
  [ -f "${PROJECT}/apps/web/package.json" ]
  [ -f "${PROJECT}/apps/web/mise.toml" ]
  [ -f "${PROJECT}/apps/web/Dockerfile" ]
  [ -f "${PROJECT}/apps/web/.env.example" ]
}

@test "nextjs registers itself as a config root" {
  scaffold new "$PROJECT" --web nextjs
  run grep -c '"apps/web",' "${PROJECT}/mise.toml"
  [ "$output" = "1" ]
}

@test "the ci workflow lists apps/web" {
  scaffold new "$PROJECT" --web nextjs
  run grep 'roots:' "${PROJECT}/.github/workflows/ci.yml"
  [[ "$output" == *'apps/web'* ]]
}

@test "the generated web app passes its own ci-unit" {
  scaffold new "$PROJECT" --web nextjs
  cd "$PROJECT"
  run mise run //apps/web:ci-unit
  [ "$status" -eq 0 ]
}

@test "a role mismatch is rejected" {
  run scaffold new "$PROJECT" --api nextjs
  [ "$status" -eq 1 ]
  [[ "$output" == *"adapter nextjs has role web"* ]]
}

@test "the web app builds the standalone tree its Dockerfile copies" {
  scaffold new "$PROJECT" --web nextjs
  run grep "output: 'standalone'" "${PROJECT}/apps/web/next.config.ts"
  [ "$status" -eq 0 ]
}
