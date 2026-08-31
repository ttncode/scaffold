setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/bakery"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "laravel-inertia generates a single app at apps/app" {
  run scaffold new "$PROJECT" --app laravel-inertia
  assert_ok
  [ -f "${PROJECT}/apps/app/artisan" ]
  # laravel/vue-starter-kit ships a typescript vite config, not vite.config.js
  [ -f "${PROJECT}/apps/app/vite.config.ts" ]
  [ ! -e "${PROJECT}/apps/web" ]
  [ ! -e "${PROJECT}/apps/api" ]
}

@test "the fullstack project has exactly two config roots" {
  scaffold new "$PROJECT" --app laravel-inertia
  run bash -c "source '${SCAFFOLD_ROOT}/lib/log.sh'; source '${SCAFFOLD_ROOT}/lib/project.sh'; collect_config_roots '${PROJECT}' | sort | tr '\n' ' '"
  [ "$output" = "apps/app docs " ]
}

@test "php stays scoped to the app" {
  scaffold new "$PROJECT" --app laravel-inertia
  run grep -q 'php' "${PROJECT}/mise.toml"
  [ "$status" -ne 0 ]
}

@test "the app declares node because vite builds the assets" {
  scaffold new "$PROJECT" --app laravel-inertia
  run grep -q 'node = ' "${PROJECT}/apps/app/mise.toml"
  assert_ok
}

@test "the generated app passes its own ci-unit" {
  scaffold new "$PROJECT" --app laravel-inertia
  cd "$PROJECT"
  run mise run //apps/app:ci-unit
  assert_ok
}
