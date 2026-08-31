setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "laravel-api generates an app at apps/api" {
  run scaffold new "$PROJECT" --api laravel-api
  assert_ok
  [ -f "${PROJECT}/apps/api/artisan" ]
  [ -f "${PROJECT}/apps/api/mise.toml" ]
}

# php is not pinned through mise (see docs/decisions/0016): mise's only php
# backends compile from source and fail on this machine. the guard the
# install task opens with still names php, so this checks presence rather
# than a specific `php = "..."` tools entry.
@test "php is declared in the app and never at the project root" {
  scaffold new "$PROJECT" --api laravel-api
  run grep -q 'php' "${PROJECT}/mise.toml"
  [ "$status" -ne 0 ]
  run grep -q 'php' "${PROJECT}/apps/api/mise.toml"
  assert_ok
}

@test "the laravel lefthook fragment is merged with the common hooks" {
  scaffold new "$PROJECT" --api laravel-api
  run yq '.pre-commit.commands | has("pint")' "${PROJECT}/lefthook.yml"
  [ "$output" = "true" ]
  run yq '.pre-commit.commands | has("gitleaks")' "${PROJECT}/lefthook.yml"
  [ "$output" = "true" ]
}

@test "the fragment resolves the app root" {
  scaffold new "$PROJECT" --api laravel-api
  run yq '.pre-commit.commands.pint.root' "${PROJECT}/lefthook.yml"
  [ "$output" = "apps/api/" ]
}

@test "a mixed-language project has no packages/types" {
  scaffold new "$PROJECT" --api laravel-api --web nextjs
  [ ! -e "${PROJECT}/packages/types" ]
  [ ! -e "${PROJECT}/packages-types" ]
}

@test "the generated api passes its own ci-unit" {
  scaffold new "$PROJECT" --api laravel-api
  cd "$PROJECT"
  run mise run //apps/api:ci-unit
  assert_ok
}
