#!/usr/bin/env bats

setup() {
  load 'helpers/setup'
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/wizard.sh"

  # The real listing, so a new adapter or service shows up here without
  # anyone editing this file — the same reason scripts/adapter-matrix.sh
  # parses it rather than carrying its own copy.
  LISTING="$(mise exec -- "${SCAFFOLD_ROOT}/scaffold" list)"
}

@test "wizard_options groups adapters by role" {
  run wizard_options "$LISTING" api
  assert_ok
  [[ "$output" == *"laravel-api"* ]]
  [[ "$output" == *"nestjs"* ]]
  [[ "$output" != *"nextjs"* ]]
  [[ "$output" != *"laravel-inertia"* ]]
}

@test "wizard_options groups services by kind" {
  run wizard_options "$LISTING" database
  assert_ok
  [[ "$output" == *"mysql"* ]]
  [[ "$output" == *"postgres"* ]]
  [[ "$output" != *"redis"* ]]
}

@test "wizard_options offers none where the command line allows it" {
  run wizard_options "$LISTING" database
  [[ "$output" == *"none"* ]]
  run wizard_options "$LISTING" cache
  [[ "$output" == *"none"* ]]
}

@test "wizard_options carries each adapter's own tier" {
  # laravel-inertia is tier B and the listing says so; the wizard must not
  # hold a second opinion about which adapters are guaranteed.
  run wizard_options "$LISTING" app
  assert_ok
  [[ "$output" == *"laravel-inertia"* ]]
  [[ "$output" == *"B"* ]]
}

@test "wizard_options dies on a kind nothing asks" {
  run wizard_options "$LISTING" storage
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown question kind: storage"* ]]
}

@test "a web-only project is never asked about a database" {
  # scaffold new refuses --db without an api or app adapter, so the wizard
  # must not offer it — a refusal the user can reach is a worse refusal.
  run wizard_questions web
  assert_ok
  [ "$output" = "web" ]
}

@test "wizard_questions orders each shape's questions" {
  run wizard_questions web+api
  assert_ok
  [ "$output" = "$(printf 'web\napi\ndatabase\ncache')" ]
  run wizard_questions app
  [ "$output" = "$(printf 'app\ndatabase\ncache')" ]
  run wizard_questions api
  [ "$output" = "$(printf 'api\ndatabase\ncache')" ]
}

@test "wizard_questions dies on an unknown shape" {
  run wizard_questions monolith
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown project shape: monolith"* ]]
}

@test "wizard_command writes the flags the answers mean" {
  run wizard_command demo web=nextjs api=nestjs database=postgres cache=redis
  assert_ok
  [ "$output" = "scaffold new demo --web nextjs --api nestjs --db postgres --cache redis" ]
}

@test "wizard_command omits an adapter answered none" {
  run wizard_command demo web=nextjs api=none database=none cache=none
  assert_ok
  [ "$output" = "scaffold new demo --web nextjs --db none --cache none" ]
}

@test "every adapter the listing carries is reachable through some question" {
  # The wizard's own version of the test that keeps adapters.yml honest: an
  # adapter or service nobody can select is invisible, and nothing else would
  # say so.
  local row name reachable
  while IFS=$'\t' read -r name _ _; do
    reachable=0
    for kind in web api app database cache; do
      wizard_options "$LISTING" "$kind" | grep -q "^${name}	" && reachable=1
    done
    [ "$reachable" -eq 1 ] || { echo "${name} is in scaffold list but no question offers it"; false; }
  done <<< "$LISTING"
}
