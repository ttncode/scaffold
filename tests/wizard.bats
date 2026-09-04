#!/usr/bin/env bats

setup() {
  load 'helpers/setup'
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/contract.sh"
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

@test "wizard_options carries no meta for a database or cache entry" {
  # The kind is the only per-service column the listing has, and the
  # question is already titled "Database"/"Cache" — repeating it as meta
  # said nothing "mysql" didn't already.
  run wizard_options "$LISTING" database
  assert_ok
  [[ "$output" == *"mysql"$'\t'* ]]
  [[ "$output" != *"mysql"$'\t'"database"* ]]
  run wizard_options "$LISTING" cache
  assert_ok
  [[ "$output" == *"redis"$'\t'* ]]
  [[ "$output" != *"redis"$'\t'"cache"* ]]
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

@test "every shape wizard_shapes lists is accepted by wizard_questions" {
  # wizard_shapes is the one place cmd_wizard's menu and wizard_questions'
  # accepted shapes both read (see wizard_shapes' comment). A shape added to
  # only one of them must fail here instead of reaching a user four screens
  # into the wizard.
  local shapes count=0
  shapes="$(wizard_shapes | cut -f1)"

  local shape
  while IFS= read -r shape; do
    run wizard_questions "$shape"
    assert_ok
    count=$((count + 1))
  done <<< "$shapes"

  [ "$count" -eq "$(wc -l <<< "$shapes")" ]
}

@test "wizard_questions asks about services exactly when a shape's roles need drivers" {
  # DRIVEN_ROLES (lib/contract.sh) is where "only api and app carry services"
  # actually lives — asserting against it, rather than against one shape's
  # fixed output, means a role that later gains drivers breaks this test
  # instead of leaving a stale "web equals web" assertion nobody would notice
  # go silent. A shape's own name is its role list, api-only shapes and
  # web+api alike.
  local shape roles role driven questions
  for shape in $(wizard_shapes | cut -f1); do
    IFS='+' read -ra roles <<< "$shape"
    driven=0
    for role in "${roles[@]}"; do
      case " ${DRIVEN_ROLES[*]} " in
        *" ${role} "*) driven=1 ;;
      esac
    done

    questions="$(wizard_questions "$shape")"
    if [ "$driven" -eq 1 ]; then
      [[ "$questions" == *"database"* ]]
      [[ "$questions" == *"cache"* ]]
    else
      [[ "$questions" != *"database"* ]]
      [[ "$questions" != *"cache"* ]]
    fi
  done
}

@test "every kind wizard_questions yields is accepted by wizard_prompt_for, wizard_options and wizard_new_args" {
  # wizard_prompt_for used to live in scaffold, unreachable by any unit test —
  # a kind added to wizard_questions and not there died mid-wizard, after the
  # name and shape screens were already answered. wizard_shapes' own test
  # closed this hole for shapes; this closes it for kinds.
  local shape kind
  for shape in $(wizard_shapes | cut -f1); do
    for kind in $(wizard_questions "$shape"); do
      run wizard_prompt_for "$kind"
      assert_ok
      run wizard_options "$LISTING" "$kind"
      assert_ok
      run wizard_new_args "${kind}=none"
      assert_ok
    done
  done
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

@test "the name prompt enforces init_project's rule before anything is created" {
  # tui_name_is_usable calls project_name_is_usable (lib/project.sh) — the
  # same function init_project calls — so catching a bad name at the prompt
  # means the user retypes a word rather than reading a failure after the
  # rest of the wizard's screens.
  source "${SCAFFOLD_ROOT}/lib/project.sh"
  source "${SCAFFOLD_ROOT}/lib/tui.sh"
  run tui_name_is_usable "Demo Project"
  [ "$status" -ne 0 ]
  run tui_name_is_usable "demo-01"
  assert_ok
  run tui_name_is_usable "-leading"
  [ "$status" -ne 0 ]
}

@test "Ctrl-D at the name prompt exits instead of spinning forever" {
  # read returns 1 on EOF, leaving name empty; tui_name_is_usable "" fails,
  # and pre-fix the loop just re-asked forever. The TTY guard in main only
  # keeps a non-terminal stdin out — it does nothing about Ctrl-D on a real
  # one, so this drives tui_prompt_name itself under a pty. Bounded by an
  # outer timeout so a regression here fails this test instead of hanging it.
  command -v script >/dev/null || skip "script(1) not available"

  local driver="${BATS_TEST_TMPDIR}/drive-name-prompt.sh"
  cat > "$driver" <<EOF
#!/usr/bin/env bash
source "${SCAFFOLD_ROOT}/lib/log.sh"
source "${SCAFFOLD_ROOT}/lib/project.sh"
source "${SCAFFOLD_ROOT}/lib/tui.sh"
tui_prompt_name >/dev/null
EOF

  local out="${BATS_TEST_TMPDIR}/eof.log" status=0
  { sleep 1; printf '\x04'; sleep 1; } \
    | timeout 10 script -qec "bash '${driver}'" /dev/null > "$out" 2>&1 || status=$?

  # 124 is timeout(1) killing a still-spinning process; 130 is exit's own
  # Ctrl-C/Ctrl-D convention (128 + SIGINT) and what the fix now returns.
  [ "$status" -ne 124 ] || { echo "tui_prompt_name spun until the outer timeout killed it:"; cat "$out"; false; }
  [ "$status" -eq 130 ]
}

@test "the wizard reaches a command without generating anything" {
  # Drives the real screens through a pty and asserts only on the command it
  # prints. Frames are not asserted: this proves the loop reads keys, applies
  # the answers and terminates, which is what the rendering layer can get
  # wrong that the pure functions cannot.
  command -v script >/dev/null || skip "script(1) not available"

  local out="${BATS_TEST_TMPDIR}/session.log"
  {
    sleep 1; printf 'wizard-demo\n'
    sleep 1; printf '\x1b[B'; sleep 0.3; printf '\n'   # shape: app
    sleep 1; printf '\n'                               # fullstack: laravel-inertia
    sleep 1; printf '\n'                               # database: mysql
    sleep 1; printf '\n'                               # cache: none
    sleep 1; printf 'n\n'                              # do not generate
    sleep 1
  } | COLUMNS=90 LINES=45 script -qec \
        "TERM=xterm-256color SCAFFOLD_WIZARD_DRY_RUN=1 '${SCAFFOLD_ROOT}/scaffold'" /dev/null \
      > "$out" 2>&1 || true

  grep -q 'scaffold new wizard-demo --app laravel-inertia --db mysql --cache none' "$out" \
    || { echo "the wizard did not reach the expected command:"; cat "$out"; false; }
}

@test "typing an option's first letter selects it, not whatever Enter would default to" {
  # tui_select used to read only arrows and Enter — every typed letter was
  # silently discarded, so a first-time user who types the walkthrough's
  # answer ("postgres") actually got whatever was already highlighted
  # (mysql, the flags' own default) with no error and no sign anything went
  # wrong. mysql sorts before postgres in the database menu, so reaching
  # postgres here proves typing moved the cursor rather than Enter's default
  # winning by coincidence.
  command -v script >/dev/null || skip "script(1) not available"

  local out="${BATS_TEST_TMPDIR}/session.log"
  {
    sleep 1; printf 'wizard-demo\n'
    sleep 1; printf '\n'                               # shape: web+api (first option)
    sleep 1; printf '\n'                               # web: nextjs (only option)
    sleep 1; printf 'l\n'                              # api: laravel-api
    sleep 1; printf 'p\n'                              # database: postgres
    sleep 1; printf 'r\n'                              # cache: redis
    sleep 1; printf 'n\n'                              # do not generate
    sleep 1
  } | COLUMNS=90 LINES=45 script -qec \
        "TERM=xterm-256color SCAFFOLD_WIZARD_DRY_RUN=1 '${SCAFFOLD_ROOT}/scaffold'" /dev/null \
      > "$out" 2>&1 || true

  grep -q 'scaffold new wizard-demo --web nextjs --api laravel-api --db postgres --cache redis' "$out" \
    || { echo "typing did not select the named options:"; cat "$out"; false; }
}
