setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
  scaffold new "$PROJECT" --api nestjs
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "add installs an adapter at an arbitrary path" {
  cd "$PROJECT"
  run scaffold add apps/worker --adapter nestjs
  assert_ok
  [ -f "${PROJECT}/apps/worker/mise.toml" ]
}

@test "add registers the new config root" {
  cd "$PROJECT"
  scaffold add apps/worker --adapter nestjs
  run grep -c '"apps/worker",' "${PROJECT}/mise.toml"
  [ "$output" = "1" ]
}

@test "add updates the ci roots input" {
  cd "$PROJECT"
  scaffold add apps/worker --adapter nestjs
  run grep 'roots:' "${PROJECT}/.github/workflows/ci.yml"
  [[ "$output" == *'apps/worker'* ]]
}

@test "add touches exactly one line of the ci workflow" {
  cd "$PROJECT"
  scaffold add apps/worker --adapter nestjs
  run bash -c "git -C '${PROJECT}' diff --numstat -- .github/workflows/ci.yml"
  # exact match, not a prefix: a trailing wildcard here would also match
  # 1\t10, 1\t19, 1\t100 ... and this is the one assertion that says the
  # CI-diff contract actually holds.
  [[ "$output" == "1"$'\t'"1"$'\t'".github/workflows/ci.yml" ]]
}

@test "add refuses a path that already exists" {
  cd "$PROJECT"
  run scaffold add apps/api --adapter nestjs
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
}
@test "add into a mixed-language project leaves other apps' lockfiles alone" {
  # its own project: this file's setup() already generated one at $PROJECT
  local mixed="${WORKDIR}/mixed"
  scaffold new "$mixed" --api laravel-api --web nextjs
  [ -f "${mixed}/apps/web/pnpm-lock.yaml" ]

  cd "$mixed"
  run scaffold add apps/app --adapter nestjs
  assert_ok

  # `reconcile` was keyed on the workspace file existing, but a mixed-language
  # project keeps a settings-only one with no `packages:`. sync_workspace_lockfile
  # then deleted every per-app lockfile at depth 3 and rebuilt a root lockfile
  # that covers no app, leaving both unable to install — with no undo.
  [ -f "${mixed}/apps/web/pnpm-lock.yaml" ]
}

@test "a successful add leaves no temporary workspace relaxation behind" {
  cd "$PROJECT"
  run scaffold add apps/worker --adapter nestjs
  assert_ok
  # The success path disarms the cleanup trap, so the strip has to be explicit —
  # and it lived inside the reconcile branch only, so a project without a shared
  # workspace kept confirmModulesPurge and frozenLockfile forever.
  run grep -cE 'confirmModulesPurge|frozenLockfile' "${PROJECT}/pnpm-workspace.yaml"
  [ "$output" = "0" ] || { echo "left behind:"; grep -nE 'confirmModulesPurge|frozenLockfile' "${PROJECT}/pnpm-workspace.yaml"; false; }
}
