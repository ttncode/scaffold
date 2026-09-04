#!/usr/bin/env bats

setup() {
  load 'helpers/setup'
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  # wizard_order_options reads DEFAULT_DATABASE_SERVICE.
  source "${SCAFFOLD_ROOT}/lib/contract.sh"
  source "${SCAFFOLD_ROOT}/lib/wizard.sh"

  # The real listing, so a new adapter or service shows up here without
  # anyone editing this file — the same reason scripts/adapter-matrix.sh
  # parses it rather than carrying its own copy.
  LISTING="$(mise exec -- "${SCAFFOLD_ROOT}/scaffold" list)"
}

@test "the wizard's first-offered database agrees with scaffold new's own default" {
  # cmd_new's unset --db default and wizard_order_options' menu ordering both
  # read DEFAULT_DATABASE_SERVICE (lib/contract.sh) — proving they agree by
  # comparing behavior, not by asserting each against a hardcoded string.
  # Generates a real project (needs an adapter generator), so this lives here
  # rather than in tests/wizard.bats — see mise.toml's test-unit comment.
  source "${SCAFFOLD_ROOT}/lib/service.sh"

  local project="${BATS_TEST_TMPDIR}/db-default"
  run scaffold new "$project" --api nestjs
  assert_ok

  local recorded
  recorded="$(project_service "$project" database)"

  local offered
  offered="$(wizard_order_options database "$LISTING" | head -1 | cut -f1)"

  [ "$offered" = "$recorded" ]
}
