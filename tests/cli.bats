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

@test "scaffold list --adapters prints only adapters" {
  run scaffold list --adapters
  assert_ok
  [[ "$output" == *"laravel-api"* ]]
  [[ "$output" == *"laravel-inertia"* ]]
  [[ "$output" == *"nestjs"* ]]
  [[ "$output" == *"nextjs"* ]]
  [[ "$output" != *"mongodb"* ]]
  [[ "$output" != *"mysql"* ]]
  [[ "$output" != *"postgres"* ]]
  [[ "$output" != *"redis"* ]]
}

@test "scaffold list --services prints only services" {
  run scaffold list --services
  assert_ok
  [[ "$output" == *"mongodb"* ]]
  [[ "$output" == *"mysql"* ]]
  [[ "$output" == *"postgres"* ]]
  [[ "$output" == *"redis"* ]]
  [[ "$output" != *"laravel-api"* ]]
  [[ "$output" != *"laravel-inertia"* ]]
  [[ "$output" != *"nestjs"* ]]
  [[ "$output" != *"nextjs"* ]]
}

@test "scaffold list with no flag prints both adapters and services" {
  run scaffold list
  assert_ok
  [[ "$output" == *"laravel-api"* ]]
  [[ "$output" == *"mongodb"* ]]
}

@test "scaffold list rejects an unknown option" {
  run scaffold list --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option: --bogus"* ]]
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

@test "apply_adapter runs the generator and post-generate through the project's mise toolchain" {
  # A bare `eval "$ADAPTER_GENERATOR"` picked up whatever node/pnpm happened
  # to be on the caller's PATH instead of the project's own pin — the
  # generator writes a lockfile and node_modules with one pnpm major, every
  # later `mise run` reads them with another, and the mismatch only shows up
  # as a missing binary several tasks later. Reproducing that needs an
  # ambient pnpm that disagrees with the project's pin; asserting the
  # invocation shape here costs nothing. Same reasoning as service.bats' "the
  # nest driver decides allowBuilds before it installs anything".
  # Asserted as a negative and a positive, so the shape can be rearranged —
  # it has been once, when the output started being captured — without the
  # guarantee quietly going with it. Neither value may be handed to a shell
  # directly, and the only script that runs either goes through mise exec.
  run grep -nE '(eval|bash -c) "\$ADAPTER_(GENERATOR|POST_GENERATE)"' "${SCAFFOLD_ROOT}/lib/adapter.sh"
  [ -z "$output" ] \
    || { echo "a generator is run outside the project's toolchain:"; echo "$output"; false; }

  run grep -c 'mise exec -- bash -c "\$2"' "${SCAFFOLD_ROOT}/lib/adapter.sh"
  assert_ok
  [ "$output" -eq 1 ]
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
  # A PATH with no mise on it at all: load_toolchain_env has nothing to load
  # from, so require_tools is the thing under test. A green suite under
  # `mise exec` proves nothing about this path.
  run env PATH=/usr/bin:/bin "${SCAFFOLD_ROOT}/scaffold" list
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required tool"* ]]
}

@test "scaffold reports its own version without a toolchain" {
  # The question is usually asked because something is wrong with the install,
  # so it must not fail with "missing required tool(s)" — which is what it did
  # when --version went through the same case as every other command.
  run env PATH=/usr/bin:/bin "${SCAFFOLD_ROOT}/scaffold" --version
  assert_ok
  [ -n "$output" ]
  [[ "$output" != *"missing required tool"* ]]
}

@test "scaffold supplies its own jq and yq when only mise is on PATH" {
  # The state a developer is actually in after `git clone` — mise installed,
  # nothing else. load_toolchain_env reads this toolbox's own mise environment so
  # the command needs no wrapper.
  local mise_bin
  mise_bin="$(command -v mise)" || skip "mise is not on PATH"

  local stub="${BATS_TEST_TMPDIR}/only-mise"
  mkdir -p "$stub"
  ln -s "$mise_bin" "${stub}/mise"

  # The precondition is the whole test: require_tools demands yq by name, so
  # a successful `scaffold list` below can only mean load_toolchain_env supplied
  # it. jq is not asserted absent — some systems ship one, and it would make
  # this test skip on those rather than check anything.
  if env PATH="${stub}:/usr/bin:/bin" sh -c 'command -v yq' >/dev/null 2>&1; then
    skip "this system has a yq outside mise, so the precondition cannot hold"
  fi

  # MISE_STATE_DIR unset on purpose: the config being loaded is this toolbox's
  # own, trusted by whoever ran `mise install` here, not a throwaway project
  # the suite created.
  run env -u MISE_STATE_DIR PATH="${stub}:/usr/bin:/bin" \
    "${SCAFFOLD_ROOT}/scaffold" list
  assert_ok
  [[ "$output" == *nextjs* ]]
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

@test "scaffold list reports a malformed service and continues" {
  # load_service's own completeness check exists so a broken service.env is a
  # per-service error, not a `set -u` crash that kills the rest of the
  # listing — same shape as the adapter case above, now exercised for services.
  run "${SCAFFOLD_ROOT}/tests/fixtures/broken-services/scaffold" list
  [ "$status" -ne 0 ]
  [[ "$output" == *"good"* ]]
  [[ "$output" == *"[error]"* ]]
  [[ "$output" == *"broken"* ]]
}

@test "a role requested twice is refused instead of generating twice into one path" {
  # Both adapters map to the same apps/<role> directory, so the second
  # generator ran against a populated tree and overlaid its own files on the
  # first — two apps' worth of work, one broken result, no error.
  run scaffold new "${BATS_TEST_TMPDIR}/dup" --web nextjs --web nestjs
  [ "$status" -ne 0 ]
  [[ "$output" == *"--web"* ]]
}

@test "scaffold with no arguments and no terminal still prints usage" {
  # The guard the whole design rests on. scaffold runs in scripts, in CI and
  # in this suite; a bare call that opened a menu would hang all of them, and
  # the failure would look like a timeout rather than an error.
  run bash -c "printf '' | '${SCAFFOLD_ROOT}/scaffold'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage:"* ]]
  [[ "$output" != *"What are you building"* ]]
}
