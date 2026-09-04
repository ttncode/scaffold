setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "nestjs generates an app at apps/api" {
  run scaffold new "$PROJECT" --api nestjs
  assert_ok
  [ -f "${PROJECT}/apps/api/nest-cli.json" ]
  [ -f "${PROJECT}/apps/api/mise.toml" ]
}

@test "an all-typescript project gets packages/types" {
  scaffold new "$PROJECT" --api nestjs --web nextjs
  [ -f "${PROJECT}/packages/types/src/index.ts" ]
  [ -f "${PROJECT}/pnpm-workspace.yaml" ]
  run grep -c '"packages/types",' "${PROJECT}/mise.toml"
  [ "$output" = "1" ]
}

# register_config_root inserts newest-first, and packages/types is registered
# after both apps, so the resulting order is the reverse of the --api/--web
# calls, with packages/types first; assert it exactly, not just that it's
# somewhere in the file — a silent reversal here would change the ci matrix
# without failing anything else.
@test "config roots land in the order the calls actually produce" {
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/project.sh"
  scaffold new "$PROJECT" --api nestjs --web nextjs

  run collect_config_roots "$PROJECT"
  [ "${lines[0]}" = "packages/types" ]
  [ "${lines[1]}" = "apps/web" ]
  [ "${lines[2]}" = "apps/api" ]
  [ "${lines[3]}" = "docs" ]
}

@test "packages-types never survives as a directory name" {
  scaffold new "$PROJECT" --api nestjs
  [ ! -e "${PROJECT}/packages-types" ]
}

@test "the generated api passes its own ci-unit" {
  scaffold new "$PROJECT" --api nestjs
  cd "$PROJECT"
  run mise run //apps/api:ci-unit
  assert_ok
}

# Reproduces the bug directly: apply_service_drivers exports SCAFFOLD_PROJECT_ROOT
# for a driver's child process, whose cwd is the app directory, not the
# caller's — a relative target left nest.sh's `stat` resolving against the
# wrong place. `scaffold new` is the only path that can hand the driver a
# relative root at all; cmd_add's is always absolute via `git rev-parse
# --show-toplevel`.
@test "a relative target still reaches a nest-family db driver" {
  cd "$WORKDIR"
  run scaffold new relative-demo --api nestjs --db mysql
  assert_ok
  [ -f "relative-demo/pnpm-workspace.yaml" ]
}

@test "the generated app's README does not trip the secret scanner" {
  scaffold new "$PROJECT" --api nestjs
  # `nest new` writes badge URLs containing a placeholder `?token=`, which
  # gitleaks reports as a leaked credential — blocking the first commit of
  # every project and training people to ignore the scanner.
  # gitleaks is pinned by the generated project, not by this toolbox, so it is
  # invoked through the project's own mise — the same way its hook does.
  cd "$PROJECT"
  run mise exec -- gitleaks detect --no-git --source apps/api --redact --no-banner
  assert_ok
}
