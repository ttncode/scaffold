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

@test "scaffold lint accepts every adapter that ships" {
  # lint_adapters is covered against fixtures, but the runbook's acceptance
  # gate is `scaffold lint` over adapters/ — which no test ran, so a shipped
  # adapter could break the contract without any suite noticing.
  run scaffold lint
  assert_ok
}

@test "scaffold names the tool it cannot find" {
  # require_tools guards against running outside mise, and its own comment says
  # a green suite under `mise exec` proves nothing about that path. This runs it
  # with an empty PATH so the guard is the thing under test.
  # a plain system PATH, without mise's shims — the state a developer is in
  # when they clone and run ./scaffold directly.
  run env PATH=/usr/bin:/bin "${SCAFFOLD_ROOT}/scaffold" list
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required tool"* ]]
}

@test "an adapter name cannot escape the adapters directory" {
  # load_adapter sources ${SCAFFOLD_ROOT}/adapters/${name}/adapter.env, so a
  # traversing name sources — and therefore executes — an arbitrary file. The
  # directory has to exist for the guard being tested to be the one that fires.
  local outside="${BATS_TEST_TMPDIR}/outside"
  mkdir -p "${outside}/evil"
  printf 'ADAPTER_NAME=evil\nADAPTER_ROLE=api\nADAPTER_GENERATOR=true\ntouch %s/SOURCED\n' \
    "$outside" > "${outside}/evil/adapter.env"

  local traversal
  traversal="$(realpath --relative-to="${SCAFFOLD_ROOT}/adapters" "${outside}/evil")"
  run scaffold new "${BATS_TEST_TMPDIR}/never" --api "$traversal"

  [ "$status" -ne 0 ]
  [ ! -e "${outside}/SOURCED" ]
}

@test "an adapter.env that parses but omits a name does not hide the others" {
  # load_adapter succeeded (the file sources fine) and cmd_list then read
  # $ADAPTER_NAME under `set -u`, killing the shell mid-loop — so one
  # incomplete adapter suppressed the listing of every good one. The existing
  # broken-adapter fixture ships no adapter.env at all, which is the other
  # branch.
  run "${SCAFFOLD_ROOT}/tests/fixtures/broken-adapters/scaffold" list
  # the intact adapter must still be listed, whatever it calls itself
  [[ "$output" == *$'\t'"api"$'\t'* ]] \
    || { echo "no intact adapter survived the listing:"; echo "$output"; false; }
}

@test "a role requested twice is refused instead of generating twice into one path" {
  # Both adapters map to the same apps/<role> directory, so the second
  # generator ran against a populated tree and overlaid its own files on the
  # first — two apps' worth of work, one broken result, no error.
  run scaffold new "${BATS_TEST_TMPDIR}/dup" --web nextjs --web nestjs
  [ "$status" -ne 0 ]
  [[ "$output" == *"--web"* ]]
}
