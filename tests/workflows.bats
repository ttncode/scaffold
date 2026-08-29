setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
  # generation happens per-test below, not here: bats runs setup() before
  # every test in this file, and most of them don't touch $PROJECT at all
  # (see tests/add-app.bats etc. for suites where every test needs it).
  # the reusable-workflow repository is a separate checkout with no fixed
  # relationship to this one; DOT_GITHUB_ROOT lets a caller (e.g. CI) say
  # where it put it, and the sibling-directory default matches how this
  # toolbox and that repository are checked out side by side in dev.
  DOT_GITHUB="${DOT_GITHUB_ROOT:-$(dirname "$SCAFFOLD_ROOT")/dot-github}"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "the project ships five workflows" {
  scaffold new "$PROJECT" --api nestjs
  run bash -c "ls '${PROJECT}/.github/workflows' | wc -l"
  [ "$output" = "5" ]
}

@test "every workflow starts from a closed permission set" {
  scaffold new "$PROJECT" --api nestjs
  for f in "${PROJECT}"/.github/workflows/*.yml; do
    run yq '.permissions' "$f"
    [ "$output" = "{}" ]
  done
}

@test "every workflow only calls into the shared repository" {
  scaffold new "$PROJECT" --api nestjs
  run bash -c "yq -r '.jobs[].uses' '${PROJECT}'/.github/workflows/*.yml | sort -u"
  [[ "$output" != *"null"* ]]
  [[ "$output" == *"you/.github/.github/workflows/"* ]]
}

@test "a web-only project builds and releases from apps/web" {
  local web_project="${WORKDIR}/web-only"
  scaffold new "$web_project" --web nextjs
  run yq '.jobs.build.with.context' "${web_project}/.github/workflows/build.yml"
  [ "$output" = "apps/web" ]
  run yq '.jobs.release.with.context' "${web_project}/.github/workflows/release.yml"
  [ "$output" = "apps/web" ]
}

@test "every reusable workflow pins its actions by sha" {
  [ -d "$DOT_GITHUB" ] || skip "dot-github checkout not found at ${DOT_GITHUB} (set DOT_GITHUB_ROOT)"
  run bash -c "grep -rhoE 'uses: [^ ]+@[^ ]+' '${DOT_GITHUB}/.github/workflows/' | grep -vE '@[0-9a-f]{40}$' || true"
  [ -z "$output" ]
}

@test "every checkout disables credential persistence" {
  [ -d "$DOT_GITHUB" ] || skip "dot-github checkout not found at ${DOT_GITHUB} (set DOT_GITHUB_ROOT)"
  run bash -c "grep -c 'persist-credentials: false' '${DOT_GITHUB}/.github/workflows/app-ci.yml'"
  [ "$output" -ge 1 ]
}

@test "the toolbox workflows pin every action by sha" {
  run bash -c "grep -rhoE 'uses: [^ ]+@[^ ]+' '${SCAFFOLD_ROOT}/.github/workflows/' | grep -vE '@[0-9a-f]{40}$' || true"
  [ -z "$output" ]
}

@test "the toolbox workflows start from a closed permission set" {
  for f in "${SCAFFOLD_ROOT}"/.github/workflows/*.yml; do
    run yq '.permissions' "$f"
    [ "$output" = "{}" ]
  done
}

@test "the toolbox workflows declare a cancel-in-progress concurrency group" {
  for f in "${SCAFFOLD_ROOT}"/.github/workflows/*.yml; do
    run yq '.concurrency.cancel-in-progress' "$f"
    [ "$output" = "true" ]
  done
}

@test "every job in the toolbox workflows has a timeout" {
  run bash -c "yq '.jobs.*.timeout-minutes // \"MISSING\"' '${SCAFFOLD_ROOT}'/.github/workflows/*.yml"
  [[ "$output" != *"MISSING"* ]]
}

@test "every checkout in the toolbox workflows disables credential persistence" {
  run bash -c "yq -r '.jobs.*.steps.[] | select(.uses? | test(\"^actions/checkout\")) | .with.\"persist-credentials\"' '${SCAFFOLD_ROOT}'/.github/workflows/*.yml"
  [[ "$output" != *"null"* ]]
  [[ "$output" != *"true"* ]]
  [ -n "$output" ]
}

@test "an adapter with an unrecognised ADAPTER_TIER fails loudly instead of vanishing" {
  local env_file="${SCAFFOLD_ROOT}/adapters/nextjs/adapter.env"
  cp "$env_file" "${BATS_TEST_TMPDIR}/adapter.env.bak"
  sed -i 's/ADAPTER_TIER="A"/ADAPTER_TIER="Z"/' "$env_file"
  run "${SCAFFOLD_ROOT}/scripts/adapter-matrix.sh" schedule "23 2 * * 1"
  cp "${BATS_TEST_TMPDIR}/adapter.env.bak" "$env_file"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nextjs"* ]]
  [[ "$output" == *"Z"* ]]
}

@test "exactly one of adapters.yml's schedule crons runs tier b" {
  # reads the crons out of the workflow itself rather than hand-typing them
  # here: adapters.yml and adapter-matrix.sh's WEEKLY_CRON could otherwise
  # drift apart silently (one edited, not the other) with nothing to catch
  # it. this fails the moment they disagree.
  local crons cron nonempty=0
  mapfile -t crons < <(yq '.on.schedule[].cron' "${SCAFFOLD_ROOT}/.github/workflows/adapters.yml")
  [ "${#crons[@]}" -eq 2 ]
  for cron in "${crons[@]}"; do
    run "${SCAFFOLD_ROOT}/scripts/adapter-matrix.sh" schedule "$cron"
    [ "$status" -eq 0 ]
    [[ "$output" == *'tier-b=[]'* ]] || nonempty=$((nonempty + 1))
  done
  [ "$nonempty" -eq 1 ]
}

@test "the schedule matrix matches each adapter's own ADAPTER_TIER on the cron that runs tier b" {
  local crons cron weekly=""
  mapfile -t crons < <(yq '.on.schedule[].cron' "${SCAFFOLD_ROOT}/.github/workflows/adapters.yml")
  for cron in "${crons[@]}"; do
    run "${SCAFFOLD_ROOT}/scripts/adapter-matrix.sh" schedule "$cron"
    [[ "$output" == *'tier-b=[]'* ]] || weekly="$cron"
  done
  [ -n "$weekly" ]

  run "${SCAFFOLD_ROOT}/scripts/adapter-matrix.sh" schedule "$weekly"
  [ "$status" -eq 0 ]
  for name in "${SCAFFOLD_ROOT}"/adapters/*/; do
    adapter="$(basename "$name")"
    tier="$(grep '^ADAPTER_TIER=' "${name}/adapter.env" | cut -d'"' -f2)"
    case "$tier" in
      A) [[ "$output" == *"tier-a="*"\"${adapter}\""* ]] ;;
      B) [[ "$output" == *"tier-b="*"\"${adapter}\""* ]] ;;
    esac
  done
}

@test "a pull request runs tier b only when its own directory changed" {
  local commit
  commit="$(git -C "$SCAFFOLD_ROOT" log --format=%H -- adapters/laravel-inertia | tail -1)"
  run "${SCAFFOLD_ROOT}/scripts/adapter-matrix.sh" pull_request "" "${commit}^" "$commit"
  [ "$status" -eq 0 ]
  [[ "$output" == *'tier-b=["laravel-inertia"]'* ]]

  run "${SCAFFOLD_ROOT}/scripts/adapter-matrix.sh" pull_request "" "$commit" "$commit"
  [ "$status" -eq 0 ]
  [[ "$output" == *'tier-b=[]'* ]]
}
