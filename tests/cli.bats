#!/usr/bin/env bats

setup() {
  load 'helpers/setup'
}

@test "scaffold with no arguments prints usage and fails" {
  run scaffold
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage:"* ]]
}

@test "scaffold rejects an unknown command" {
  run scaffold frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown command: frobnicate"* ]]
}

@test "scaffold list succeeds even with no adapters installed" {
  run scaffold list
  assert_ok
}

@test "load_adapter dies on an unknown adapter" {
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/adapter.sh"
  run load_adapter nonesuch
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown adapter: nonesuch"* ]]
}

@test "load_adapter exports the adapter metadata" {
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/adapter.sh"
  SCAFFOLD_ROOT="${SCAFFOLD_ROOT}/tests/fixtures/project" load_adapter sample
  [ "$ADAPTER_ROLE" = "api" ]
  [ "$ADAPTER_NAME" = "sample" ]
}

@test "scaffold list reports broken adapters and continues" {
  run "${SCAFFOLD_ROOT}/tests/fixtures/broken-adapters/scaffold" list
  [ "$status" -ne 0 ]
  [[ "$output" == *"sample"* ]]
  [[ "$output" == *"[error]"* ]]
  [[ "$output" == *"bad"* ]]
}
