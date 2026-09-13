# Immich Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Delete this file when every task is checked off.** PR #18 removed five plans
> that outlived their execution and still claimed 305 undone tasks. A plan is a
> work order, not a record; the record is the ADRs, the tour, and the code.

**Goal:** close the gaps a full-repository survey found between this toolbox and
immich — files immich has that we never added, and a presentation style we
adopted in prose but not in mechanism.

**Architecture:** four independent pull requests, each verified the same way and
each revertable on its own. Nothing changes behaviour except one test, which is
strengthened so it can fail for the reason it was written.

**Tech Stack:** bash, YAML, bats, mise, shellcheck, yq, zizmor.

**Spec:** `docs/superpowers/specs/2026-09-13-immich-parity-design.md`

## Global Constraints

- Chat is Vietnamese; **every file, comment, commit message and document is
  English**.
- Comment rule: a comment earns its place only when it is not obvious in ten
  seconds AND sits at a different abstraction level than the line below it.
  Third-party landmines stay; narration around them goes.
- `mise run lint` must pass before every commit — lefthook's pre-commit hook
  runs it and will block the commit otherwise.
- Commit messages are Conventional Commits; lefthook's commit-msg hook greps for
  the prefix.
- Work on `chore/immich-parity`, already cut from `main` at `277d8a8`. The spec
  is already committed there as `18913b5`.
- Every task ends green on: `mise run lint`, `mise run test-runner`,
  `mise exec -- zizmor --min-severity medium .github/workflows/`.
- `mise run test-runner` takes about 25 minutes. Run it once per task, at the
  end, not per step.

---

## File Structure

| Path | Responsibility | Task |
| --- | --- | --- |
| `SECURITY.md` | the toolbox's own vulnerability contact | A |
| `CODEOWNERS` | the toolbox's own owner | A |
| `.vscode/extensions.json` | recommend the tools `mise.toml` pins | A |
| `.vscode/settings.json` | teach an editor that `scaffold` is bash | A |
| `common/.github/pull_request_template.md` | ships a PR template to clients | A |
| `common/.vscode/extensions.json` | ships editor hints to clients | A |
| `tests/new-project.bats` | assert the owner is right, not merely non-placeholder | A |
| `.github/workflows/*.yml` | a `name:` on all 49 steps | B |
| `common/install.sh`, `lib/*.sh`, `services/shared/*.sh` | `local -r`, comments to their facts | C |
| `tests/*.bats`, `tests/helpers/setup.bash` | comments to their facts | D |
| `adapters/*/adapter.env`, `common/*ignore`, `common/example.env` | comments to their facts | D |

---

## Task A: Files immich has and we do not

**Files:**
- Create: `SECURITY.md`, `CODEOWNERS`, `.vscode/extensions.json`,
  `.vscode/settings.json`, `common/.github/pull_request_template.md`,
  `common/.vscode/extensions.json`
- Modify: `tests/new-project.bats`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: nothing other tasks rely on.

- [ ] **Step 1: Write the failing assertion**

`tests/new-project.bats` has a test named `no placeholder account survives into
the generated project`. Its body currently ends with a `grep` for `@you\b|you/`
asserting the output is empty. That proves a placeholder is gone, not that the
owner is right — `* @ttncode` passes it. Add this to the end of that test body,
after the existing `grep` assertion:

```bash
  # Absence of the placeholder is not presence of the owner: a hardcoded or
  # mistyped account passes the grep above. tests/helpers/setup.bash exports
  # SCAFFOLD_GITHUB_OWNER=test-owner.
  run cat "${PROJECT}/CODEOWNERS"
  [ "$output" = "* @test-owner" ] \
    || { echo "CODEOWNERS says '${output}', not the account this run resolved"; false; }
```

- [ ] **Step 2: Prove the new assertion can fail**

```bash
sed -i 's|^\* @you$|* @someone-else|' common/CODEOWNERS
mise exec -- bats tests/new-project.bats -f "no placeholder account"
```

Expected: FAIL, with `CODEOWNERS says '* @someone-else', not the account this run resolved`.

Then restore:

```bash
git checkout -- common/CODEOWNERS
mise exec -- bats tests/new-project.bats -f "no placeholder account"
```

Expected: PASS.

- [ ] **Step 3: Create the toolbox's own SECURITY.md**

Same text `common/SECURITY.md` already ships. Create `SECURITY.md`:

```markdown
# Security policy

Report vulnerabilities privately rather than opening a public issue. Email the
maintainer listed in `CODEOWNERS` with a description and reproduction steps.
Expect an initial response within a few business days.
```

- [ ] **Step 4: Create the toolbox's own CODEOWNERS**

Create `CODEOWNERS`:

```
* @ttncode
```

Hardcoded is correct here: this repository has one owner and no substitution
step. `common/CODEOWNERS` keeps its `@you` placeholder — do not touch it.

- [ ] **Step 5: Create the editor hints**

Create `.vscode/extensions.json`:

```json
{
  "recommendations": [
    "timonwong.shellcheck",
    "foxundermoon.shell-format",
    "editorconfig.editorconfig"
  ]
}
```

Create `.vscode/settings.json`:

```json
{
  "files.associations": {
    "scaffold": "shellscript"
  }
}
```

`scaffold` has no extension, so an editor treats it as plain text and offers no
shell diagnostics for the largest file in the repository.

- [ ] **Step 6: Ship a pull request template to generated projects**

Create `common/.github/pull_request_template.md`:

```markdown
## What this changes

<!-- What behaviour is different after this, and why it needed to be. -->

## How it was verified

<!-- The commands you ran and what they said. -->

## Checklist

- [ ] `mise run checklist` passes
- [ ] New behaviour has a test that fails without the change
- [ ] Docs that describe changed behaviour were updated in the same commit
- [ ] No unrelated changes
```

The three headings match the ones this repository enforces on itself. The
checklist names the generated project's own command, `mise run checklist`, not
this repository's `mise run test-runner`.

- [ ] **Step 7: Ship editor hints to generated projects**

Create `common/.vscode/extensions.json`:

```json
{
  "recommendations": [
    "editorconfig.editorconfig",
    "esbenp.prettier-vscode",
    "timonwong.shellcheck"
  ]
}
```

Language-agnostic only. A generated project can be TypeScript, PHP, or both;
per-adapter extensions would need a fragment-merge mechanism like
`lefthook.fragment.yml`, which does not exist and nothing yet needs.

- [ ] **Step 8: Verify a generated project carries the new files**

```bash
T=$(mktemp -d)
SCAFFOLD_GITHUB_OWNER=acme-corp MISE_STATE_DIR="$T/s" GIT_CONFIG_GLOBAL="$T/g" \
  ./scaffold new "$T/demo" --db none
ls "$T/demo/.vscode/extensions.json" "$T/demo/.github/pull_request_template.md"
cat "$T/demo/CODEOWNERS"
rm -rf "$T"
```

Expected: both files listed, `CODEOWNERS` reads `* @acme-corp`.

Neither new file carries `you/`, `@you`, or `@PROJECT_NAME@`, so neither needs
adding to `PROJECT_OWNER_FILES` or `PROJECT_NAME_FILES` in `lib/project.sh`. If
a future template does carry one, it must be added there or it ships with the
placeholder intact.

- [ ] **Step 9: Run the full suite**

```bash
mise run lint
mise run test-runner
mise exec -- zizmor --min-severity medium .github/workflows/
```

Expected: lint clean, 262 tests passing with none failing, zizmor reporting no
findings.

- [ ] **Step 10: Commit**

```bash
git add SECURITY.md CODEOWNERS .vscode common/.vscode \
  common/.github/pull_request_template.md tests/new-project.bats
git commit -m "feat: carry the files this toolbox already asks of its projects

SECURITY.md and CODEOWNERS ship to every generated project and were missing
here. A pull request template is enforced on this repository's own pull
requests by a CI job and was shipped to nobody. .vscode recommends the tools
mise.toml already pins, and tells an editor that the extensionless scaffold
file is bash.

The placeholder test asserted that no @you survived generation, which a
hardcoded account passes. It now asserts CODEOWNERS names the account the run
resolved."
```

---

## Task B: A name on every workflow step

**Files:**
- Modify: `.github/workflows/adapters.yml`, `.github/workflows/ci.yml`,
  `.github/workflows/provenance.yml`, `.github/workflows/pull-request.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

`common/.github/workflows/*.yml` are pure `uses:` call sites with no steps. Do
not touch them.

- [ ] **Step 1: Count the steps that need a name**

```bash
grep -c '^\s*- uses:\|^\s*- run:\|^\s*- id:' .github/workflows/*.yml
```

Expected: 31 in adapters.yml, 11 in ci.yml, 6 in provenance.yml, 1 in
pull-request.yml — 49 with no `name:` between them.

- [ ] **Step 2: Name every step**

For each step, add `name:` as its first key. The name is a short imperative
phrase describing what the step does, in the same voice immich uses: `Checkout
code`, `Setup Mise`, `Publish`, `Build and push image`.

Where a step has an `id:`, `name:` goes first and `id:` second.

Example, from `.github/workflows/ci.yml`:

```yaml
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
```

becomes:

```yaml
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
```

A step whose purpose was explained by a comment above it takes that explanation
into its name where the name can carry it. Example, from
`.github/workflows/adapters.yml`:

```yaml
      # a broken adapter must not hide the state of the others
      fail-fast: false
```

stays a comment — it annotates `fail-fast:`, not a step.

- [ ] **Step 3: Delete the comments the names now carry**

Remove a comment only when the step's new `name:` says the same thing. Keep
every comment recording GitHub's own behaviour, including:

- SARIF upload refused on a private repository without Advanced Security
- CodeQL needing `actions: read` to read its own workflow run
- the job name `pull-request-body` being load-bearing for branch protection
- the weekly cron string also living in `scripts/adapter-matrix.sh`
- timeout values and the measurement behind them

- [ ] **Step 4: Verify the YAML still parses and the audit is clean**

```bash
for f in .github/workflows/*.yml; do mise exec -- yq -e '.jobs' "$f" >/dev/null && echo "ok $f"; done
mise exec -- zizmor --min-severity medium .github/workflows/
grep -c '^\s*#' .github/workflows/*.yml
```

Expected: four `ok` lines, `No findings to report`, and a comment count of
roughly 35–45 across the four files, down from 100.

- [ ] **Step 5: Run the full suite**

```bash
mise run lint
mise run test-runner
```

Expected: lint clean, 262 tests passing.

`tests/workflows.bats` asserts that every job in these files has a timeout,
starts from a closed permission set, pins every action by sha, and disables
credential persistence on checkout. Adding `name:` changes none of that; if any
of those tests fails, a key was moved or deleted by mistake.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows
git commit -m "refactor(ci): name every step instead of commenting it

49 steps across four workflows, none with a name. immich names 297 of them and
sits at 3.8% comments against our 17.5% — the difference is not that they
explain less, it is where. A step's name appears in the GitHub log while the
job runs; a comment above it appears only to someone reading the file.

What stays is GitHub's own behaviour: SARIF refused without Advanced Security,
CodeQL needing actions: read, the pull-request-body job name being load-bearing
for branch protection."
```

---

## Task C: Scripts in immich's shape

**Files:**
- Modify: `common/install.sh`, `lib/*.sh`, `services/shared/laravel.sh`,
  `services/shared/nest.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Apply `local -r` where a local is assigned once**

immich writes `local -r Tgt='./immich-app'` and `local -r RepoUrl=...`. This is
function scope, not the file-level `readonly` this repository correctly rejects:
these libraries are re-sourced into child processes by design, and a second
file-level `readonly` is an error that `set -e` turns into a dead script. A
`local -r` has no such problem.

Change `local x="$1"` to `local -r x="$1"` only where `x` is never reassigned in
the function. Leave accumulators (`status`, `block`, `env_block`), loop
variables, and anything reassigned.

Do not change the file-level constants (`COMPOSE_FILE`, `GATE_NAME`,
`PROJECT_NAME_RULE`, and the rest). They stay plain assignments.

- [ ] **Step 2: Verify shellcheck is still clean**

```bash
mise run lint
```

Expected: clean. `local -r` on a variable that is later assigned is a shellcheck
error (SC2155 family) and will surface here.

- [ ] **Step 3: Cut `common/install.sh` to its facts**

104 comment lines in 285. immich's equivalent is 3 in 107, because `main()`
reads as prose and the function names narrate. Ours already has that shape.

For each function, reduce its comment block to the sentence carrying the fact.
Keep, in full or close to it:

- `release_asset_id` — jq rather than grep, because an asset's own id precedes
  its name while the uploader's follows it, and the wrong request succeeds
- `fetch_release_asset` — two endpoints, because a private release's browser URL
  answers 404 both anonymously and with a token
- `download_release_assets` — two cleanup mechanisms, and why a plain EXIT trap
  is not enough
- `generate_service_passwords` — the `|` delimiter, because a base64 value
  contains `/`; and the known argv exposure
- `compose_has_service` — grep closing the pipe, SIGPIPE, pipefail
- the `BASH_SOURCE[0]:-$0` guard at the foot of the file

Delete narration that restates the function name or walks through the body.

Target: about 15%, roughly 40 comment lines.

- [ ] **Step 4: Cut `lib/*.sh` and `services/shared/*.sh` the same way**

`lib/project.sh` is at 37%, `lib/contract.sh` at 42%, `services/shared/nest.sh`
at 52%, `services/shared/laravel.sh` at 47%, `services/mongodb/drivers/laravel.sh`
at 42%. Same rule: the fact stays, the narration goes.

The small per-service drivers (`services/{mysql,postgres,mongodb}/drivers/nest.sh`)
read at 67–75%, but that is the six-line header box over a twelve-line file.
Leave them.

- [ ] **Step 5: Run the full suite**

```bash
mise run lint
mise run test-runner
```

Expected: lint clean, 262 tests passing.

`tests/install.bats` exercises `release_asset_id`, `fetch_release_asset`,
`require_private_tools`, `start_stack`, `generate_service_passwords` and
`run_migrations` directly. `tests/cli.bats` greps `lib/adapter.sh` for the exact
string `mise exec -- bash -c "$2"` and asserts it appears once — do not reword
that line. `tests/publish.bats` parses the heredocs in `lib/publish.sh` with
`sed` and `awk` anchored on a line that is exactly `{` and a line that is
exactly `}` — do not indent them.

- [ ] **Step 6: Commit**

```bash
git add common/install.sh lib services/shared
git commit -m "refactor: local -r, and comments down to their facts

immich's install.sh is 107 lines with three comments because main() reads as
prose and the function names narrate. Ours has that shape already and still
carried a paragraph above each function.

local -r for locals assigned once, which is function scope and unlike the
file-level readonly this repository rejects — these libraries are re-sourced
into child processes by design.

What stays is the third-party landmines: jq rather than grep for an asset id,
two endpoints for a private release, the trap baking its path and naming its
signals, sed delimited on | because a base64 value contains /, and
BASH_SOURCE[0]:-\$0 because a curl-piped script has none."
```

---

## Task D: Data files and tests

**Files:**
- Modify: `tests/*.bats`, `tests/helpers/setup.bash`,
  `adapters/*/adapter.env`, `adapters/*/.dockerignore`,
  `adapters/*/.env.example`, `adapters/*/.prettierignore`,
  `common/.dockerignore`, `common/.prettierignore`, `common/example.env`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Cut the test suites**

833 comment lines in 4,345 — 19%, against immich's 0.9% in `e2e/src`. A bats
test name is already a sentence; the dominant pattern here is a comment above a
test that restates its name.

Delete a comment when the test name says it. Keep one when it records why the
test exists at all — several name a defect that shipped, and those are the
reason the test is not deleted as redundant. Example of one to keep, from
`tests/install.bats`:

```bash
  # `docker compose ... | grep -qx migrate` reads correctly and fails about one
  # run in seven: grep closes the pipe on its first match, compose dies of
  # SIGPIPE, and install.sh's own `set -o pipefail` reports the pipeline as
  # failed.
```

Example of one to delete — a comment restating the test name immediately above
it.

- [ ] **Step 2: Cut the adapter.env files**

`adapters/laravel-inertia/adapter.env` is 29 comment lines in 38. Two blocks
carry real traps and must survive, compressed:

- `ADAPTER_GENERATOR` — the commit pin, `SHELL_VERBOSITY=-1` because
  `--no-interaction` does not reach `install:features`, and
  `COMPOSER_PROCESS_TIMEOUT=900` because a cold cache exceeds the 300s default
- `ADAPTER_POST_GENERATE` — `rm -rf .github` because the starter kit's inert
  dependabot config fails zizmor with exit 13, and the sed that wires
  `routes/health.php` into `bootstrap/app.php` because Laravel auto-loads
  neither, plus the grep pair that turns a silent no-op into a failure

Delete the rest, including the `ADAPTER_TIER` block that restates ADR-0012 and
the `/up` note that restates what `ADAPTER_READINESS_PATH` beside it already
shows.

Apply the same rule to `adapters/nextjs`, `adapters/nestjs`,
`adapters/laravel-api`.

- [ ] **Step 3: Cut the ignore and env templates**

immich's `.dockerignore` carries no comment at all and is perfectly legible.
Ours is 11 comment lines in 14.

- `common/.dockerignore` — keep one line on why `node_modules` is ignored
  despite being copied from a build stage; delete the rest
- `common/.prettierignore` — keep one line: prettier rewrites `pnpm-lock.yaml`
  and fights Release Please for `CHANGELOG.md`; neither is written by hand
- `common/example.env` — keep one line: copy to `.env`, install.sh does it and
  replaces every `changeme`
- `adapters/*/.dockerignore`, `adapters/*/.env.example`,
  `adapters/*/.prettierignore` — same rule

- [ ] **Step 4: Run the full suite**

```bash
mise run lint
mise run test-runner
```

Expected: lint clean, 262 tests passing.

`tests/compose.bats` asserts `common/example.env` still carries the literal
`changeme` for every password, and that `.dockerignore` exists for every
adapter. `tests/contract.bats` reads `adapter.env` through
`adapter_env_value` — a comment line cannot break it, but a deleted assignment
can.

- [ ] **Step 5: Commit**

```bash
git add tests adapters common/.dockerignore common/.prettierignore common/example.env
git commit -m "refactor: comments in the data files and the test suites

19% of the test suites were comments against immich's 0.9%, and the dominant
pattern was a comment restating the test name below it. The adapter.env files
ran to 76%, and common/.dockerignore to 79% where immich's carries none.

What stays is the traps: the laravel starter kit's inert .github failing zizmor
with exit 13, the sed wiring routes/health.php into bootstrap/app.php because
Laravel auto-loads neither, and the regression notes on tests that exist
because a defect shipped."
```

---

## Task E: Open the pull requests

**Files:** none.

- [ ] **Step 1: Push and open one pull request per task**

One pull request carrying all four commits. They are independent and each
reviewable on its own, and the branch is already cut; splitting into four
branches buys separate revert granularity that `git revert <sha>` already gives.

```bash
git push -u origin chore/immich-parity
gh pr create --title "chore: close the remaining immich parity gaps" --base main
```

The body must carry the three headings `.github/pull_request_template.md`
declares, or the `pull-request-body` check fails.

- [ ] **Step 2: Wait for CI and merge**

```bash
gh pr checks <number>
```

Expected: `unit`, `integration`, `zizmor`, `self-test`, `pull-request-body`,
`discover`, `smoke` for three adapters and `deploy` for three adapters, all
passing. `deploy-tier-b` and `smoke-tier-b` run too, because Task D changes
`adapters/laravel-inertia/`.

- [ ] **Step 3: Delete this plan**

```bash
git rm docs/superpowers/plans/2026-09-13-immich-parity.md
git commit -m "chore: remove the executed parity plan"
```

A plan is a work order. Leaving it behind is what produced the 8,703 lines PR
#18 deleted.
