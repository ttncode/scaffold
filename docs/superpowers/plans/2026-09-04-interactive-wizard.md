# Interactive Wizard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `scaffold`, run bare in a terminal, walks a first-time user to a complete project selection and generates it.

**Architecture:** Three layers with a hard line between them. `lib/wizard.sh` holds pure functions — given the rows `scaffold list` prints and a shape, which questions follow and what command the answers produce. `lib/tui.sh` holds the terminal machinery adapted from the `bootstrap` script's `lib/menu.sh`, with its boolean-per-row selection model replaced by one index per question. `cmd_wizard` in `scaffold` joins them and guards the whole thing behind a TTY check.

**Tech Stack:** bash, `awk`, `tput`, `stty`, bats, `script` (pty) for the one rendering test.

**Spec:** `docs/superpowers/specs/2026-09-04-interactive-wizard-design.md`

## Global Constraints

- Chat is Vietnamese; **every file, comment, commit message and document is English**.
- Comment style follows immich and the surrounding repository: explain *why*, never *what*. No comment asserting a mechanism does something unless a check enforces it — the previous branch found six of those.
- **The wizard hardcodes no adapter name, no service name and no tier.** Every option comes from `cmd_list`'s output. A second copy of that list is the defect that broke `scripts/adapter-matrix.sh` on the last branch.
- **The TTY guard is load-bearing.** `scaffold` runs in scripts, in CI, and in this repository's own tests. A bare invocation that blocks on a menu hangs all of them, and the failure looks like a timeout rather than an error.
- Tests isolated: everything a test writes goes under `BATS_TEST_TMPDIR`.
- `mise run lint` must pass before every commit; `lib/*.sh` is in its glob.
- Work on `feat/interactive-wizard`, already cut from `main` at `b23d6dc`.

## File Structure

| Path | Responsibility |
| --- | --- |
| `lib/wizard.sh` (new) | pure: options per question, question order per shape, answers → command |
| `lib/tui.sh` (new) | terminal: cursor, echo, key reading, banner, one single-select screen |
| `scaffold` (modify) | `cmd_wizard`, the TTY guard in `main`, `usage` |
| `tests/wizard.bats` (new) | the pure functions, exhaustively; one pty smoke test |
| `docs/tour/09-wizard.md` (new) | what it is and when it runs |
| `README.md`, `CONTRIBUTING.md` (modify) | the bare-`scaffold` entry point |

---

### Task 1: The pure layer

**Files:**
- Create: `lib/wizard.sh`
- Create: `tests/wizard.bats`
- Modify: `scaffold` (source the library)

**Interfaces:**
- Produces: `wizard_options <listing> <kind>` — `<listing>` is `cmd_list`'s tab-separated output; `<kind>` is `web`, `api`, `app`, `database` or `cache`. Prints `value<TAB>meta` rows, plus the `none` row where one belongs. Dies on an unknown kind.
- Produces: `wizard_questions <shape>` — prints one kind per line in order. Dies on an unknown shape.
- Produces: `wizard_command <name> <kind=value>...` — prints the equivalent `scaffold new` command.

- [ ] **Step 1: Write the failing test**

Create `tests/wizard.bats`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
mise exec -- bats tests/wizard.bats
```

Expected: FAIL — `lib/wizard.sh` does not exist.

- [ ] **Step 3: Write `lib/wizard.sh`**

```bash
# shellcheck shell=bash

# wizard_options <listing> <kind>
# <listing> is cmd_list's tab-separated output; every option the wizard offers
# comes from there rather than a list of its own. A second copy of what the
# adapters and services already declare is what broke scripts/adapter-matrix.sh
# on the previous branch — it parsed `scaffold list` while the workflow beside
# it carried its own list.
wizard_options() {
  local listing="$1" kind="$2"

  case "$kind" in
    web|api|app)
      awk -F'\t' -v role="$kind" \
        '$2 == role { printf "%s\ttier %s\n", $1, $3 }' <<< "$listing"
      # A shape that asked for this role wants one, but the frontend of a
      # web+api project is still optional in a way the api is not — the flags
      # allow it, so the wizard does too.
      [ "$kind" = "web" ] && printf 'none\tno frontend\n'
      ;;
    database)
      awk -F'\t' '$2 == "database" { printf "%s\t%s\n", $1, $2 }' <<< "$listing"
      printf 'none\tno database service\n'
      ;;
    cache)
      awk -F'\t' '$2 == "cache" { printf "%s\t%s\n", $1, $2 }' <<< "$listing"
      printf 'none\tno cache service\n'
      ;;
    *) die "unknown question kind: ${kind}" ;;
  esac
}

# wizard_questions <shape>
# The order the answers constrain each other in. `web` asks nothing about a
# database because `scaffold new` refuses --db without an api or app adapter,
# and a refusal the user can walk into is worse than one they cannot.
wizard_questions() {
  case "$1" in
    web+api) printf 'web\napi\ndatabase\ncache\n' ;;
    app) printf 'app\ndatabase\ncache\n' ;;
    api) printf 'api\ndatabase\ncache\n' ;;
    web) printf 'web\n' ;;
    *) die "unknown project shape: ${1}" ;;
  esac
}

# wizard_command <name> <kind=value>...
# What the answers would have been typed as. Printed before the run so the
# second project is scripted rather than clicked.
wizard_command() {
  local name="$1"; shift
  local out="scaffold new ${name}" pair kind value

  for pair in "$@"; do
    kind="${pair%%=*}"
    value="${pair#*=}"
    case "$kind" in
      web|api|app) [ "$value" = none ] || out+=" --${kind} ${value}" ;;
      database) out+=" --db ${value}" ;;
      cache) out+=" --cache ${value}" ;;
      *) die "unknown answer: ${pair}" ;;
    esac
  done

  printf '%s\n' "$out"
}
```

- [ ] **Step 4: Source it from `scaffold`**

Below the `lib/service.sh` source line:

```bash
# shellcheck source=lib/wizard.sh
source "${SCAFFOLD_ROOT}/lib/wizard.sh"
```

- [ ] **Step 5: Run the tests and lint**

```bash
mise exec -- bats tests/wizard.bats
mise run lint
```

- [ ] **Step 6: Commit**

```bash
git add lib/wizard.sh tests/wizard.bats scaffold
git commit -m "feat: the wizard's questions, derived from what scaffold list prints"
```

---

### Task 2: The terminal layer

**Files:**
- Create: `lib/tui.sh`
- Modify: `tests/wizard.bats`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `tui_select <prompt> <footer> <option>...` — renders one single-select screen, leaves the chosen value in `TUI_CHOICE`, returns 1 if the user pressed Esc. Each `<option>` is `value<TAB>meta`.
- Produces: `tui_begin` / `tui_end` — take and restore the terminal.
- Produces: `tui_prompt_name` — reads a project name, re-asking until it satisfies `init_project`'s rule.

Adapt `~/.dotfiles/scripts/lib/menu.sh` and `lib/banner.sh`. **Read both before writing.** Take the parts that are tedious and easy to get wrong — `stty -echo` for the whole session rather than per-read, the drain of the autorepeat backlog, the 50ms window for the rest of an escape sequence, `tput civis`/`cnorm` with restoration on every exit path including Esc and Ctrl-C, and the one-column-short row width that stops a row triggering the terminal's pending-wrap. Leave behind that menu's boolean-per-row selection: this is one choice per screen, so `SELECTED[]` becomes a single cursor index and `space` is not a key.

- [ ] **Step 1: Write the failing test**

Append to `tests/wizard.bats`:

```bash
@test "the name prompt enforces init_project's rule before anything is created" {
  # init_project refuses a name it cannot substitute into sed and an image
  # reference. Catching it at the prompt means the user retypes a word rather
  # than reading a failure after four screens of answers.
  source "${SCAFFOLD_ROOT}/lib/tui.sh"
  run tui_name_is_usable "Demo Project"
  [ "$status" -ne 0 ]
  run tui_name_is_usable "demo-01"
  assert_ok
  run tui_name_is_usable "-leading"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
mise exec -- bats tests/wizard.bats
```

Expected: FAIL — no `lib/tui.sh`.

- [ ] **Step 3: Write `lib/tui.sh`**

Structure it as: the colour constants, `tui_begin`/`tui_end`, `tui_name_is_usable`, `tui_prompt_name`, a private `_tui_fit`, a private `_tui_render`, and `tui_select`. `tui_name_is_usable` holds `init_project`'s two `case` patterns and nothing else, so the prompt and the generator cannot disagree about what a name is.

The selection loop is `menu.sh`'s `_select` with the boolean array removed:

```bash
tui_select() {
  local prompt="$1" footer="$2"; shift 2
  local -a options=("$@")
  local cursor=0 key

  while true; do
    _tui_render "$prompt" "$footer" "$cursor" "${options[@]}"
    IFS= read -rsn1 key || true

    case "$key" in
      $'\x1b')
        # 50ms, not 10: under autorepeat the rest of an arrow sequence can
        # arrive late, and a truncated read here reads as a bare Esc — which
        # would cancel the wizard mid-scroll.
        if read -rsn2 -t 0.05 key; then
          case "$key" in
            "[A") cursor=$(( (cursor - 1 + ${#options[@]}) % ${#options[@]} )) ;;
            "[B") cursor=$(( (cursor + 1) % ${#options[@]} )) ;;
          esac
        else
          return 1
        fi
        ;;
      "")
        TUI_CHOICE="${options[$cursor]%%$'\t'*}"
        return 0
        ;;
    esac
  done
}
```

- [ ] **Step 4: Run the tests and lint**

```bash
mise exec -- bats tests/wizard.bats
mise run lint
```

- [ ] **Step 5: Commit**

```bash
git add lib/tui.sh tests/wizard.bats
git commit -m "feat: a single-select terminal screen, from the bootstrap menu's machinery"
```

---

### Task 3: `cmd_wizard` and the TTY guard

**Files:**
- Modify: `scaffold`
- Modify: `tests/wizard.bats`, `tests/cli.bats`

**Interfaces:**
- Consumes: everything from Tasks 1 and 2, plus `cmd_list` and `cmd_new`.
- Produces: `cmd_wizard` — the four-screen flow, a summary, and the run.

- [ ] **Step 1: Write the failing test**

Append to `tests/cli.bats`:

```bash
@test "scaffold with no arguments and no terminal still prints usage" {
  # The guard the whole design rests on. scaffold runs in scripts, in CI and
  # in this suite; a bare call that opened a menu would hang all of them, and
  # the failure would look like a timeout rather than an error.
  run bash -c "printf '' | '${SCAFFOLD_ROOT}/scaffold'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage:"* ]]
  [[ "$output" != *"What are you building"* ]]
}
```

Append to `tests/wizard.bats`:

```bash
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
```

- [ ] **Step 2: Run them to verify they fail**

```bash
mise exec -- bats tests/cli.bats tests/wizard.bats
```

- [ ] **Step 3: Write `cmd_wizard`**

It asks for a name, asks the shape, walks `wizard_questions`, and collects `kind=value` answers. Then it prints the summary — the answers, the equivalent command from `wizard_command`, and the one known limit worth saying out loud:

```
  # A web+api project still builds one image: set_image_context records one
  # context per project, whichever role was applied last. The flags made this
  # shape awkward to reach; the wizard makes it the first option, so it is
  # said here rather than discovered after the first release build.
```

Then a confirm. On yes it calls `cmd_new` with the same arguments the printed command shows — built from the answers, not by re-parsing the string. `SCAFFOLD_WIZARD_DRY_RUN=1` stops before that call, which is what lets the pty test run offline.

- [ ] **Step 4: Guard it in `main`**

```bash
main() {
  require_tools

  # A terminal, and only a terminal: everything else keeps today's behaviour.
  if [ $# -eq 0 ]; then
    [ -t 0 ] || { usage >&2; exit 1; }
    cmd_wizard
    return
  fi
  ...
```

Extend `usage` with a first line showing that bare `scaffold` opens the wizard.

- [ ] **Step 5: Run the tests and lint**

```bash
mise exec -- bats tests/wizard.bats tests/cli.bats
mise run lint
```

- [ ] **Step 6: Commit**

```bash
git add scaffold tests/wizard.bats tests/cli.bats
git commit -m "feat: scaffold with no arguments walks you to a project"
```

---

### Task 4: Lanes and documentation

**Files:**
- Modify: `mise.toml`
- Create: `docs/tour/09-wizard.md`
- Modify: `README.md`, `CONTRIBUTING.md`, `docs/tour/02-task-contract.md` (its "Reading path" list if it names the tour pages)

- [ ] **Step 1: Write the failing test**

Append to `tests/contract.bats`:

```bash
@test "tests/wizard.bats runs in a lane" {
  # A suite in no lane is a suite that never runs: the service branch shipped
  # thirty tests into that state and nobody noticed until a review read
  # mise.toml against ci.yml.
  run grep -q 'tests/wizard.bats' "${SCAFFOLD_ROOT}/mise.toml"
  assert_ok
}
```

- [ ] **Step 2: Add the suite to a lane**

`tests/wizard.bats` calls `scaffold list`, which runs no generator, but its pty test drives the real binary. Put it in `test-unit` and confirm `tests/contract.bats`'s offline assertion still passes — that test greps every suite in the lane for a generator call that runs to completion, and the pty test's `SCAFFOLD_WIZARD_DRY_RUN=1` means there is none.

- [ ] **Step 3: Write `docs/tour/09-wizard.md`**

Match the tour's existing shape — read `07-containers.md` and `08-adapters.md` first. Cover: bare `scaffold` opens it, only in a terminal; the shape question and why it comes first; that every option comes from `scaffold list` so a new adapter or service appears without touching the wizard; and that it prints the equivalent command so the second project is scripted.

- [ ] **Step 4: Update `README.md` and `CONTRIBUTING.md`**

README's usage block gains the bare form as its first line. CONTRIBUTING gains a sentence under adding an adapter: nothing needs doing for the wizard, because it reads the listing.

- [ ] **Step 5: Run the documentation tests**

```bash
mise exec -- bats tests/documentation.bats tests/contract.bats
```

`documentation.bats` checks that every path and ADR the tour names exists.

- [ ] **Step 6: Commit**

```bash
git add mise.toml docs README.md CONTRIBUTING.md tests/contract.bats
git commit -m "docs: the wizard, and the lane that runs its tests"
```

---

### Task 5: Full verification

- [ ] **Step 1: Lint, lanes and the suite under runner conditions**

```bash
mise run lint
mise exec -- ./scaffold lint
CI=true GITHUB_ACTIONS=true MISE_YES=1 mise run test-runner
```

- [ ] **Step 2: Drive the wizard by hand, twice**

Once through `web+api` to a real generation, and once through `web` to confirm it never asks about a database. Check the printed command matches what was chosen, and that Ctrl-C at any screen leaves the terminal with a visible cursor and working echo.

- [ ] **Step 3: Confirm nothing else changed shape**

```bash
mise exec -- ./scaffold list | head -3
printf '' | mise exec -- ./scaffold; echo "exit=$?"
git status --short
```

The middle one must print usage and exit 1.

---

## Self-Review

**Spec coverage.** §4's wizard and shape-first order are Task 1's `wizard_questions` and Task 3's flow; §5's derived options are Task 1's `wizard_options` plus its reachability test; §6's terminal layer is Task 2; §7's TTY guard is Task 3 step 4 with its test in `tests/cli.bats`; §8's split testing is Tasks 1 and 3; §9's limits are stated on the summary screen (Task 3) and in the tour (Task 4).

**Known soft spots.**

1. The pty test is timing-based. If it proves flaky, make the dry run take answers from an environment variable and assert on the command with no pty at all — the pure functions already cover the logic, so the pty test's only job is proving the loop terminates.
2. `tui_select` renders the whole screen per keypress with no scrolling. Four options per question is the most any question has today; if a question ever outgrows the terminal, `menu.sh`'s scroll arithmetic is there to port.
3. Task 2's adaptation is the one place a subagent must read an external file (`~/.dotfiles/scripts/lib/menu.sh`) rather than this repository. If it is missing, the machinery has to be written from the spec's description instead, and the comments explaining *why* each piece exists matter more than the code.
