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
  # suffixed with the app it came from, so two apps of the same language keep
  # a hook each rather than one overwriting the other
  run yq '.pre-commit.commands | has("pint-apps-api")' "${PROJECT}/lefthook.yml"
  [ "$output" = "true" ]
  run yq '.pre-commit.commands | has("gitleaks")' "${PROJECT}/lefthook.yml"
  [ "$output" = "true" ]
}

@test "the fragment resolves the app root" {
  scaffold new "$PROJECT" --api laravel-api
  run yq '.pre-commit.commands.pint-apps-api.root' "${PROJECT}/lefthook.yml"
  [ "$output" = "apps/api/" ]
}

@test "a mixed-language project has no packages/types" {
  scaffold new "$PROJECT" --api laravel-api --web nextjs
  [ ! -e "${PROJECT}/packages/types" ]
  [ ! -e "${PROJECT}/packages-types" ]
}

@test "a mixed-language project keeps the supply-chain policy" {
  scaffold new "$PROJECT" --api laravel-api --web nextjs
  # allowBuilds is ADR-0017's policy and applies to any typescript app, but it
  # lived in the root pnpm-workspace.yaml, which this branch used to delete
  # outright — so one PHP app in the project removed the policy protecting the
  # TypeScript one. The packages: list does go, since there is no shared
  # workspace without a fully TypeScript project; the settings stay.
  [ -f "${PROJECT}/pnpm-workspace.yaml" ]
  run yq -r '.allowBuilds | keys | .[]' "${PROJECT}/pnpm-workspace.yaml"
  assert_ok
  [[ "$output" == *"unrs-resolver"* ]]
  run yq -r '.packages // "absent"' "${PROJECT}/pnpm-workspace.yaml"
  [ "$output" = "absent" ]
}

@test "the generated api passes its own ci-unit" {
  scaffold new "$PROJECT" --api laravel-api
  cd "$PROJECT"
  run mise run //apps/api:ci-unit
  assert_ok
}

@test "the adapter's docker directory reaches the generated app" {
  scaffold new "$PROJECT" --api laravel-api
  # apply_adapter copies a docker/ subtree separately from the flat files, and
  # nothing asserted it: deleting that line left every test green while the
  # Dockerfile went on COPYing a file that was no longer there.
  [ -f "${PROJECT}/apps/api/docker/opcache.ini" ]
  run grep -c 'docker/opcache.ini' "${PROJECT}/apps/api/Dockerfile"
  [ "$output" != "0" ]
}

@test "a typescript app added to a mixed-language project can install" {
  scaffold new "$PROJECT" --api laravel-api
  cd "$PROJECT"
  run scaffold add apps/worker --adapter nestjs
  assert_ok

  # ADR-0018's central scenario, and the one nothing covered: a project with no
  # root workspace still has to produce an app whose own contract tasks run.
  # resolve_minimum_release_age returned early whenever the project root had no
  # pnpm-workspace.yaml, so pnpm's default minimum-release-age policy rejected
  # the lockfile the generator had just written.
  run mise run //apps/worker:install
  assert_ok
}

@test "a mixed-language project's root lockfile can install after generation" {
  scaffold new "$PROJECT" --api laravel-api --web nextjs
  cd "$PROJECT"

  # commitlint backs the commit-msg hook and installs from the project root,
  # not from an app dir — the one place resolve_minimum_release_age used to
  # skip in this branch, so a violation among commitlint's own dependencies
  # (too fresh at generation time) surfaced only here, minutes later, on the
  # first commit.
  run mise exec -- pnpm exec commitlint --version
  assert_ok
}

@test "two php apps each keep their own pint hook" {
  scaffold new "$PROJECT" --api laravel-api --app laravel-inertia
  # Both fragments define pre-commit.commands.pint, and yq's merge is key-wise,
  # so the second overwrote the first — one hook survived, scoped to one app,
  # and the other app's php was never formatted on commit. Silently.
  run yq -r '.pre-commit.commands | keys | .[]' "${PROJECT}/lefthook.yml"
  assert_ok
  local hooks
  hooks="$(printf '%s\n' "$output" | grep -c pint)"
  [ "$hooks" -eq 2 ] || { echo "expected 2 pint hooks, found ${hooks}:"; echo "$output"; false; }
}

@test "a php-only project still ships the build policy" {
  scaffold new "$PROJECT" --api laravel-api
  # The root package.json is node tooling — commitlint backs the commit-msg
  # hook — so ADR-0017's allowBuilds applies even with no TypeScript app. This
  # branch used to delete the file that carries it outright.
  [ -f "${PROJECT}/pnpm-workspace.yaml" ]
  run yq -r '.allowBuilds | keys | .[]' "${PROJECT}/pnpm-workspace.yaml"
  assert_ok
  [[ "$output" == *"unrs-resolver"* ]]
}

@test "the api is configured for the project's database" {
  scaffold new "$PROJECT" --api laravel-api
  run grep -qx 'DB_CONNECTION=mysql' "${PROJECT}/apps/api/.env.example"
  assert_ok
  run grep -q 'pdo_mysql' "${PROJECT}/apps/api/Dockerfile"
  assert_ok
  run grep -q '@SERVICE_SETUP@' "${PROJECT}/apps/api/Dockerfile"
  [ "$status" -ne 0 ]
}
