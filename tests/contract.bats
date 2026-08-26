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
  [ "$status" -eq 0 ]
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

@test "lint_adapters accepts a quoted task header" {
  run grep -q '^\[tasks\."format-fix"\]' \
    "${SCAFFOLD_ROOT}/tests/fixtures/lint/complete/sample/mise.toml"
  [ "$status" -eq 0 ]
}
