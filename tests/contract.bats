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

@test "test-unit's suites never generate a real adapter from setup()" {
  # mise.toml's test-unit membership is an explicit file list backed by a
  # comment claiming "no adapter generator anywhere in setup" — the same
  # "synced by a comment, drifts silently" shape task 13's review round 1
  # existed to fix elsewhere. this greps the claim instead of trusting it.
  local run_line files f
  run_line="$(awk '/^\[tasks\."test-unit"\]/{f=1} f && /^run = /{print; exit}' "${SCAFFOLD_ROOT}/mise.toml")"
  files="$(grep -oE 'tests/[A-Za-z0-9_-]+\.bats' <<< "$run_line")"
  [ -n "$files" ]
  for f in $files; do
    run bash -c "sed -n '/^setup() {/,/^}/p' '${SCAFFOLD_ROOT}/${f}' | grep -E 'scaffold (new|add) .*--(api|web|app|adapter)'"
    [ "$status" -ne 0 ]
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
