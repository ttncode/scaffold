setup() {
  load 'helpers/setup'
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/contract.sh"
  source "${SCAFFOLD_ROOT}/lib/lint.sh"
}

@test "the contract has exactly nine task names" {
  [ "${#CONTRACT_TASKS[@]}" -eq 9 ]
}

@test "lint_adapters accepts an adapter that satisfies the contract" {
  run lint_adapters "${SCAFFOLD_ROOT}/tests/fixtures/lint/complete"
  assert_ok
  [ -z "$output" ]
}

@test "lint_adapters reports a missing contract task" {
  run lint_adapters "${SCAFFOLD_ROOT}/tests/fixtures/lint/missing-task"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample: missing task check"* ]]
}

@test "lint_adapters reports a missing required file" {
  run lint_adapters "${SCAFFOLD_ROOT}/tests/fixtures/lint/missing-file"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample: missing file Dockerfile"* ]]
}

@test "lint_adapters reports the broken adapter but not the complete one" {
  run lint_adapters "${SCAFFOLD_ROOT}/tests/fixtures/lint/mixed"
  [ "$status" -eq 1 ]
  [[ "$output" == *"broken: missing file Dockerfile"* ]]
  [[ "$output" != *"good:"* ]]
}

@test "lint_adapters accepts a quoted task header" {
  run grep -q '^\[tasks\."format-fix"\]' \
    "${SCAFFOLD_ROOT}/tests/fixtures/lint/complete/sample/mise.toml"
  assert_ok
}

@test "test-unit's suites never run an adapter generator to completion" {
  # mise.toml's test-unit membership is an explicit file list backed by a
  # comment claiming "no adapter generator anywhere in setup" — the same
  # "synced by a comment, drifts silently" shape task 13's review round 1
  # existed to fix elsewhere. this greps the claim instead of trusting it.
  local run_line files f
  run_line="$(awk '/^\[tasks\."test-unit"\]/{f=1} f && /^run = /{print; exit}' "${SCAFFOLD_ROOT}/mise.toml")"
  files="$(grep -oE 'tests/[A-Za-z0-9_-]+\.bats' <<< "$run_line")"
  [ -n "$files" ]
  # The whole file, not just setup(): a generator call in a test body costs the
  # lane the same, and one added here reached CI before anyone noticed the lane
  # had stopped being offline. A call the next two lines assert fails does not
  # count — those are refused before any generator runs, which is the point of
  # the error suite.
  for f in $files; do
    run bash -c "grep -A2 -E 'scaffold (new|add) .*--(api|web|app|adapter)' '${SCAFFOLD_ROOT}/${f}' \
      | grep -B2 -E '^\s*\[ .status. -eq 0 \]|^\s*assert_ok' \
      | grep -E 'scaffold (new|add) .*--(api|web|app|adapter)'"
    [ "$status" -ne 0 ] || {
      echo "${f} runs an adapter generator to completion, so test-unit is no longer offline:"
      echo "$output"
      false
    }
  done
}

@test "lint_adapters rejects a checking task that repairs its own input" {
  # ADR-0011 states the read-only split is "enforced by the linter rather than
  # by convention". It was not: lint_adapters checked that a task exists, never
  # what it runs, so an adapter whose `lint` ran `prettier --write .` passed.
  run lint_adapters "${SCAFFOLD_ROOT}/tests/fixtures/lint/writing-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample: lint writes"* ]]
}

@test "lint_adapters reports an adapter.env with no generator" {
  # apply_adapter evals ADAPTER_GENERATOR, so an adapter missing it passed lint
  # and then died mid-generation with `unbound variable`.
  run lint_adapters "${SCAFFOLD_ROOT}/tests/fixtures/lint/no-generator"
  [ "$status" -eq 1 ]
  [[ "$output" == *"adapter.env does not set ADAPTER_GENERATOR"* ]]
}

@test "lint_services accepts the services that ship" {
  run lint_services "${SCAFFOLD_ROOT}/services" "${SCAFFOLD_ROOT}/adapters"
  assert_ok
  [ -z "$output" ]
}

@test "lint_services reports a service missing a driver" {
  # The gate exists so an adapter in a new family cannot merge until every
  # service has been taught about it. A gate that cannot fail is worse than
  # no gate, so this fixture proves this one can.
  run lint_services \
    "${SCAFFOLD_ROOT}/tests/fixtures/lint-services/missing-driver" \
    "${SCAFFOLD_ROOT}/adapters"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample: no driver for laravel"* ]]
}

@test "lint_services reports a missing required file" {
  run lint_services \
    "${SCAFFOLD_ROOT}/tests/fixtures/lint-services/missing-file" \
    "${SCAFFOLD_ROOT}/adapters"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample: missing file env.fragment"* ]]
}

@test "lint_services reports service.env missing a required variable" {
  run lint_services \
    "${SCAFFOLD_ROOT}/tests/fixtures/lint-services/missing-var" \
    "${SCAFFOLD_ROOT}/adapters"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample: service.env does not set SERVICE_KIND"* ]]
}

@test "lint_services reports SERVICE_IMAGE not pinned by digest" {
  run lint_services \
    "${SCAFFOLD_ROOT}/tests/fixtures/lint-services/unpinned-image" \
    "${SCAFFOLD_ROOT}/adapters"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample: SERVICE_IMAGE is not pinned by digest"* ]]
}

@test "lint_services does not misreport a driver gap when no adapter drives any family" {
  # "${families[@]-}" looped once with family="" whenever families was empty
  # (bash 5.2: an empty array under the "-" default operator still yields one
  # blank element), printing "$service: no driver for " for every service.
  run lint_services \
    "${SCAFFOLD_ROOT}/services" \
    "${SCAFFOLD_ROOT}/tests/fixtures/lint-services/web-only-adapters"
  assert_ok
  [ -z "$output" ]
}

@test "lint_adapters requires a framework family" {
  run lint_adapters "${SCAFFOLD_ROOT}/tests/fixtures/lint/no-generator"
  [ "$status" -eq 1 ]
  [[ "$output" == *"adapter.env does not set ADAPTER_FAMILY"* ]]
}

@test "lint_adapters requires a readiness path for a role that takes a driver" {
  run lint_adapters "${SCAFFOLD_ROOT}/tests/fixtures/lint/no-readiness-path"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample: adapter.env does not set ADAPTER_READINESS_PATH"* ]]
}

@test "lint_adapters does not require a readiness path for a role that takes no driver" {
  # a web adapter opens no connection, so demanding one here would fail every
  # web adapter for a check it can never satisfy honestly.
  run lint_adapters "${SCAFFOLD_ROOT}/tests/fixtures/lint/web-no-readiness-path"
  assert_ok
  [ -z "$output" ]
}

@test "lint_adapters rejects a readiness path declared but left empty" {
  # Both checks above only grep that the line is present, not that it holds
  # a route: an empty value passed both, and downstream that same empty
  # value collapses tests/compose.bats' HEALTHCHECK assertion and the deploy
  # gate's readiness curl into matching any localhost probe on 8080 — the
  # exact defect those checks exist to stop.
  run lint_adapters "${SCAFFOLD_ROOT}/tests/fixtures/lint/empty-readiness-path"
  [ "$status" -eq 1 ]
  [[ "$output" == *'sample: adapter.env sets ADAPTER_READINESS_PATH to "", not a path starting with /'* ]]
}

@test "scaffold lint covers the services that ship" {
  run scaffold lint
  assert_ok
}

@test "tests/service.bats runs in a lane" {
  # Scoped to test-unit's own `run = ` line, not the whole file: the name
  # also greps clean out of a comment, or out of [tasks.test]'s "tests/"
  # (which ci.yml never invokes) — passing for a suite that never actually
  # runs is the exact failure this test was written against.
  local run_line
  run_line="$(awk '/^\[tasks\."test-unit"\]/{f=1} f && /^run = /{print; exit}' "${SCAFFOLD_ROOT}/mise.toml")"
  [[ "$run_line" == *"tests/service.bats"* ]]
}

@test "tests/wizard.bats runs in a lane" {
  # A suite in no lane is a suite that never runs: the service branch shipped
  # thirty tests into that state and nobody noticed until a review read
  # mise.toml against ci.yml.
  local run_line
  run_line="$(awk '/^\[tasks\."test-unit"\]/{f=1} f && /^run = /{print; exit}' "${SCAFFOLD_ROOT}/mise.toml")"
  [[ "$run_line" == *"tests/wizard.bats"* ]]
}

@test "tests/wizard-integration.bats runs in a lane" {
  local run_line
  run_line="$(awk '/^\[tasks\."test-integration"\]/{f=1} f && /^run = /{print; exit}' "${SCAFFOLD_ROOT}/mise.toml")"
  [[ "$run_line" == *"tests/wizard-integration.bats"* ]]
}

@test "every adapter declares a liveness path" {
  local missing=""
  for dir in "${SCAFFOLD_ROOT}"/adapters/*/; do
    grep -q '^ADAPTER_LIVENESS_PATH=' "${dir}adapter.env" \
      || missing="${missing}$(basename "$dir")"$'\n'
  done
  [ -z "$missing" ] || { echo "missing ADAPTER_LIVENESS_PATH:"; echo "$missing"; false; }
}

@test "an adapter whose role takes a driver declares a readiness path" {
  # a web adapter opens no connection (DRIVEN_ROLES), so it has nothing to
  # probe; anything else must, or the deploy gate has no way to prove the
  # application actually reaches its database.
  local missing=""
  for dir in "${SCAFFOLD_ROOT}"/adapters/*/; do
    role="$(grep '^ADAPTER_ROLE=' "${dir}adapter.env" | cut -d'"' -f2)"
    case " ${DRIVEN_ROLES[*]} " in *" ${role} "*) ;; *) continue ;; esac
    grep -q '^ADAPTER_READINESS_PATH=' "${dir}adapter.env" \
      || missing="${missing}$(basename "$dir")"$'\n'
  done
  [ -z "$missing" ] || { echo "missing ADAPTER_READINESS_PATH:"; echo "$missing"; false; }
}
