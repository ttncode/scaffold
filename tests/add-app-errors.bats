# covers the failure paths task 8 asked for beyond the brief's five given
# tests: locating the project (outside git, inside a non-scaffold git repo),
# a pre-existing target surviving a refused add with its contents intact,
# resolving the target relative to the project root from a subdirectory, and
# the cleanup trap actually firing on a partial failure — all without a real
# adapter's network-hitting generator, so this file stays fast.

setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "add refuses to run outside a git repository" {
  cd "$WORKDIR"
  run scaffold add apps/api --adapter nestjs
  [ "$status" -eq 1 ]
  [[ "$output" == *"not inside a git repository"* ]]
}

@test "add refuses a git repo with no scaffold mise.toml" {
  mkdir -p "$WORKDIR/plain"
  git -C "$WORKDIR/plain" init --initial-branch=main --quiet
  cd "$WORKDIR/plain"
  run scaffold add apps/api --adapter nestjs
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a scaffold project"* ]]
}

@test "add refuses a git repo whose mise.toml is not a scaffold root" {
  mkdir -p "$WORKDIR/plain"
  git -C "$WORKDIR/plain" init --initial-branch=main --quiet
  printf 'monorepo_root = false\n' > "$WORKDIR/plain/mise.toml"
  cd "$WORKDIR/plain"
  run scaffold add apps/api --adapter nestjs
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a scaffold project"* ]]
}

@test "add refuses a path that already exists, and the existing app survives untouched" {
  scaffold new "$PROJECT"
  mkdir -p "${PROJECT}/apps/api"
  echo "keep me" > "${PROJECT}/apps/api/marker"

  cd "$PROJECT"
  run scaffold add apps/api --adapter nestjs
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]

  [ -d "${PROJECT}/apps/api" ]
  [ -f "${PROJECT}/apps/api/marker" ]
  [ "$(cat "${PROJECT}/apps/api/marker")" = "keep me" ]
}

@test "add resolves the target against the project root, not the caller's cwd" {
  scaffold new "$PROJECT"
  cd "${PROJECT}/docs"
  run "${SCAFFOLD_ROOT}/tests/fixtures/add-fixtures/scaffold" add apps/worker --adapter ok
  assert_ok
  [ -f "${PROJECT}/apps/worker/marker" ]
  [ ! -e "${PROJECT}/docs/apps" ]
}

# apply_adapter's own overlay copy and ADAPTER_POST_GENERATE both run after
# the generator has already written real files; the "broken" fixture adapter
# creates a marker file and then fails in ADAPTER_POST_GENERATE, so this
# proves the trap removes actual content, not just an empty directory.
@test "a failure inside cmd_add removes what it created" {
  scaffold new "$PROJECT"
  cd "$PROJECT"
  run "${SCAFFOLD_ROOT}/tests/fixtures/add-fixtures/scaffold" add apps/worker --adapter broken
  [ "$status" -eq 1 ]
  [[ "$output" == *"removed incomplete app: ${PROJECT}/apps/worker"* ]]
  [ ! -e "${PROJECT}/apps/worker" ]
}

# Dockerfile.workspace filters pnpm by the app's own directory name (`pnpm
# --filter worker`), which only holds because create-next-app/@nestjs/cli
# happen to name the package after the directory today. The "mismatched-name"
# fixture adapter ships a Dockerfile.workspace and a generator that names its
# package.json something else, standing in for a future generator version
# that would too.
@test "add refuses an app whose package.json does not match its directory" {
  scaffold new "$PROJECT"
  cd "$PROJECT"
  run "${SCAFFOLD_ROOT}/tests/fixtures/add-fixtures/scaffold" add apps/worker --adapter mismatched-name
  [ "$status" -eq 1 ]
  [[ "$output" == *"wrong-name"* ]]
  [[ "$output" == *"worker"* ]]
  [ ! -e "${PROJECT}/apps/worker" ]
}

# the "broken" fixture adapter is marked typescript, so cmd_add's
# confirmModulesPurge relaxation is exercised here too: this manufactures an
# already-established workspace (a pnpm-workspace.yaml, no real adapter
# install needed for that) without touching the network, then proves the
# relaxation is removed on the *failure* path specifically, not only on
# success.
@test "a failure inside cmd_add removes both temporary workspace relaxations" {
  scaffold new "$PROJECT"
  printf 'packages:\n  - apps/*\n  - packages/*\n  - docs\n' > "${PROJECT}/pnpm-workspace.yaml"
  cd "$PROJECT"
  run "${SCAFFOLD_ROOT}/tests/fixtures/add-fixtures/scaffold" add apps/worker --adapter broken
  [ "$status" -eq 1 ]
  [ ! -e "${PROJECT}/apps/worker" ]
  # both, not just the first: each is written for the generator's benefit and
  # neither may ship in the caller's project.
  run grep -cE 'confirmModulesPurge|frozenLockfile|minimumReleaseAge: 0' "${PROJECT}/pnpm-workspace.yaml"
  [ "$output" = "0" ]
}

@test "scaffold new rejects an unknown database" {
  run scaffold new "${BATS_TEST_TMPDIR}/p" --api laravel-api --db orable
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown service: orable"* ]]
}

@test "scaffold new rejects a cache in the database slot" {
  run scaffold new "${BATS_TEST_TMPDIR}/p" --api laravel-api --db redis
  [ "$status" -eq 1 ]
  [[ "$output" == *"redis is a cache, not a database"* ]]
}

@test "scaffold new refuses a database for a project with no backend" {
  run scaffold new "${BATS_TEST_TMPDIR}/p" --web nextjs --db mysql
  [ "$status" -eq 1 ]
  [[ "$output" == *"no application to connect it"* ]]
}

@test "scaffold new rejects a repeated --db" {
  run scaffold new "${BATS_TEST_TMPDIR}/p" --db mysql --db postgres
  [ "$status" -eq 1 ]
  [[ "$output" == *"--db given more than once"* ]]
}

