# Scaffold Toolbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a shell toolbox that generates a fully configured, single-stack client project in one command, plus the reusable-workflow repository every generated project calls into.

**Architecture:** `scaffold` is a bash entrypoint over a `lib/` of focused sourceable modules. Adapters do not vendor application code — they invoke each framework's own generator and overlay four small files, one of which is a `mise.toml` implementing a fixed nine-task contract. CI in generated projects is five thin files that delegate to reusable workflows in a separate `.github` repository, so a pipeline fix reaches projects already shipped.

**Tech Stack:** bash, `mise` (toolchain pin + task runner), `bats` (tests), `yq` and `jq` (config rewriting), `shellcheck`, GitHub Actions, Docker Compose, VitePress, Release Please, lefthook, commitlint, gitleaks, zizmor, Renovate.

**Spec:** `docs/superpowers/specs/2026-08-25-scaffold-toolbox-design.md`

## Global Constraints

- All code, comments, and documentation are written in English. Chat may be in another language; files never are.
- Comments are rare and explain *why*, not *what*. They begin lowercase. `TODO` carries no owner tag. Tool suppressions are justified inline, e.g. `# zizmor: ignore[dangerous-triggers] no attacker inputs are used here`.
- Upstream reference is pinned in the `UPSTREAM` file: `immich-app/immich@351be95`. A local shallow clone exists at `/home/ttndev/workspace/playground/immich`.
- The nine contract task names are exactly: `install`, `format`, `format-fix`, `lint`, `check`, `test`, `build`, `ci-unit`, `checklist`.
- `format`, `lint`, and `check` must never modify files. Only the `-fix` variants write.
- CI calls exactly one command per config root: `mise run //<root>:ci-unit`.
- A generated project must contain no reference to a stack it does not use. In particular, a Laravel project's root `mise.toml` must not mention `php`.
- Every GitHub Actions workflow starts with `permissions: {}` and grants the minimum per job. Every action is pinned by commit SHA with a trailing version comment. Every `actions/checkout` sets `persist-credentials: false`.
- Every shell file passes `shellcheck`.
- Adapter tiers: Tier A is `nextjs`, `nestjs`, `laravel-api`, `laravel-inertia`.
- Third-party container images are pinned by digest, not tag.
- Commits follow Conventional Commits.

---

## File Structure

**Toolbox repository** (`/home/ttndev/workspace/personal/scaffold`):

| Path | Responsibility |
| --- | --- |
| `scaffold` | Argument parsing and command dispatch only. No logic. |
| `lib/log.sh` | `log`, `warn`, `die`. |
| `lib/contract.sh` | `CONTRACT_TASKS`, `REQUIRED_ADAPTER_FILES`. The single source of truth both the linter and tests read. |
| `lib/lint.sh` | `lint_adapters` — validates adapters against the contract. |
| `lib/project.sh` | `init_project`, `register_config_root`, `collect_config_roots`, `sync_ci_roots`, `finalize_project`. |
| `lib/adapter.sh` | `load_adapter`, `apply_adapter`, `merge_lefthook_fragment`. |
| `adapters/<name>/` | Five files: `adapter.env`, `mise.toml`, `Dockerfile`, `.env.example`, `lefthook.fragment.yml`. |
| `common/` | Everything copied verbatim into a generated project. |
| `scripts/check-provenance.sh` | Diffs `verbatim` rows in `PROVENANCE.md` against the pinned upstream commit. |
| `tests/` | `bats` suites plus fixtures. |
| `docs/decisions/` | ADR 0001–0015. |
| `docs/tour/` | Eight numbered reading-order pages. |
| `docs/runbook/` | Procedures. |
| `mise.toml` | The toolbox's own toolchain and tasks. |
| `UPSTREAM` | The pinned immich commit. |

**Reusable workflow repository** (`/home/ttndev/workspace/personal/dot-github`, published as `you/.github`):

| Path | Responsibility |
| --- | --- |
| `.github/workflows/app-ci.yml` | Path-filtered matrix running `ci-unit` per root. |
| `.github/workflows/app-security.yml` | CodeQL, zizmor, gitleaks. |
| `.github/workflows/app-build.yml` | Continuous image build on `main`. |
| `.github/workflows/app-release.yml` | Release Please, release image tags, release assets, deploy seam. |
| `.github/workflows/app-docs.yml` | Documentation build gate. |

---

## Task 1: Toolbox skeleton and the contract linter

**Files:**
- Create: `mise.toml`, `UPSTREAM`, `README.md`, `.editorconfig`, `.gitattributes`, `.gitignore`
- Create: `lib/log.sh`, `lib/contract.sh`, `lib/lint.sh`
- Create: `tests/helpers/setup.bash`
- Create: `tests/fixtures/lint/complete/sample/{adapter.env,mise.toml,Dockerfile,.env.example}`
- Create: `tests/fixtures/lint/missing-task/sample/{adapter.env,mise.toml,Dockerfile,.env.example}`
- Create: `tests/fixtures/lint/missing-file/sample/{adapter.env,mise.toml,.env.example}`
- Test: `tests/contract.bats`
- Create: `docs/decisions/0011-task-contract-names-follow-immich.md`, `docs/decisions/0013-config-roots-is-the-manifest.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `CONTRACT_TASKS` (bash array of 9 strings), `REQUIRED_ADAPTER_FILES` (bash array of 4 strings), `lint_adapters <adapters-dir>` (prints one line per problem to stdout, returns 0 when clean and 1 otherwise), `die <message>` (prints `error: <message>` to stderr, exits 1), `log`, `warn`.

- [ ] **Step 1: Write the failing test**

`tests/helpers/setup.bash`:

```bash
# shellcheck shell=bash
SCAFFOLD_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export SCAFFOLD_ROOT
PATH="${SCAFFOLD_ROOT}:${PATH}"
export PATH
```

`tests/contract.bats`:

```bash
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
```

Fixture `tests/fixtures/lint/complete/sample/mise.toml` — all nine headers, `format-fix` quoted because of the dash:

```toml
[tasks.install]
run = "true"

[tasks.format]
run = "true"

[tasks."format-fix"]
run = "true"

[tasks.lint]
run = "true"

[tasks.check]
run = "true"

[tasks.test]
run = "true"

[tasks.build]
run = "true"

[tasks.ci-unit]
run = "true"

[tasks.checklist]
run = "true"
```

Fixture `tests/fixtures/lint/complete/sample/adapter.env`:

```bash
ADAPTER_NAME="sample"
ADAPTER_ROLE="api"
ADAPTER_TIER="C"
ADAPTER_GENERATOR='mkdir -p "$APP_DIR"'
```

Fixture `tests/fixtures/lint/complete/sample/Dockerfile`:

```dockerfile
FROM scratch
```

Fixture `tests/fixtures/lint/complete/sample/.env.example`:

```bash
APP_ENV=local
```

`tests/fixtures/lint/missing-task/sample/` is a copy of `complete/sample/` with the `[tasks.check]` block deleted. `tests/fixtures/lint/missing-file/sample/` is a copy of `complete/sample/` with `Dockerfile` deleted.

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/contract.bats`
Expected: FAIL — `lib/log.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

`lib/log.sh`:

```bash
# shellcheck shell=bash
log()  { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
```

`lib/contract.sh`:

```bash
# shellcheck shell=bash

# the task names ci is allowed to call. a name joins this list only when every
# adapter implements it and ci needs to call it — see docs/decisions/0011.
CONTRACT_TASKS=(install format format-fix lint check test build ci-unit checklist)

# every adapter directory must ship these four files.
REQUIRED_ADAPTER_FILES=(adapter.env mise.toml Dockerfile .env.example)
```

`lib/lint.sh`:

```bash
# shellcheck shell=bash

# lint_adapters <adapters-dir>
# prints one line per problem and returns 1 when any adapter is incomplete.
lint_adapters() {
  local dir="$1"
  local adapter name file task status=0

  for adapter in "$dir"/*/; do
    [ -d "$adapter" ] || continue
    name="$(basename "$adapter")"

    for file in "${REQUIRED_ADAPTER_FILES[@]}"; do
      if [ ! -f "${adapter}${file}" ]; then
        printf '%s: missing file %s\n' "$name" "$file"
        status=1
      fi
    done

    [ -f "${adapter}mise.toml" ] || continue

    for task in "${CONTRACT_TASKS[@]}"; do
      # the header is quoted when the task name contains a dash
      if ! grep -Eq "^\[tasks\.\"?${task}\"?\]" "${adapter}mise.toml"; then
        printf '%s: missing task %s\n' "$name" "$task"
        status=1
      fi
    done
  done

  return "$status"
}
```

`mise.toml` for the toolbox itself:

```toml
[tools]
bats = "1.13.0"
shellcheck = "0.11.0"
yq = "4.48.1"
jq = "1.8.1"

[settings]
pin = true
lockfile = true

[tasks.lint]
run = "shellcheck scaffold lib/*.sh scripts/*.sh"

[tasks.test]
run = "bats tests/"

[tasks."test-unit"]
description = "the suites that need no network"
run = "bats tests/contract.bats tests/cli.bats tests/new-project.bats"

[tasks.ci-unit]
run = [{ task = ":lint" }, { task = ":test-unit" }]

[tasks.checklist]
run = [{ task = ":lint" }, { task = ":test" }]
```

`UPSTREAM`:

```
immich-app/immich@351be95
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise install && bats tests/contract.bats`
Expected: PASS, 5 tests.

Run: `mise run lint`
Expected: no output, exit 0.

- [ ] **Step 5: Write the two ADRs this task settles**

`docs/decisions/0011-task-contract-names-follow-immich.md`:

```markdown
# 0011 — Task contract names follow immich

Status: Accepted
Date: 2026-08-25

## Context

CI must run the same command for every application regardless of language. That
requires a fixed vocabulary of task names each adapter implements.

## Decision

Use immich's names verbatim: `install`, `format`, `format-fix`, `lint`,
`check`, `test`, `build`, plus the aggregates `ci-unit` and `checklist`.
`format`, `lint`, and `check` never modify files; the `-fix` variants do.

A name joins the contract only when every configured root implements it and CI
needs to call it. Tasks outside the contract — `migrate`, `queue`, `tinker` —
live in the adapter and are never called by CI.

## Consequences

Reading `immich/server/mise.toml` teaches this repository's layout directly. A
checking task that repairs its own input would pass locally and fail in CI, so
the split is enforced by the linter rather than by convention.

## Alternatives considered

- Inventing clearer names such as `verify` or `typecheck`. Rejected: the value
  of matching a real production repository outweighs marginal clarity.
- A per-role contract, where API adapters additionally guarantee `migrate`.
  Rejected as premature. Promotion is available once every API adapter
  implements it and CI needs to call it.
```

`docs/decisions/0013-config-roots-is-the-manifest.md`:

```markdown
# 0013 — config_roots is the manifest

Status: Accepted
Date: 2026-08-25

## Context

The toolbox needs to know which directories in a generated project are
independently buildable so CI can iterate over them.

## Decision

Use mise's `[monorepo] config_roots` as that list. Do not introduce a separate
`project.yaml`.

## Consequences

One file states which directories are apps. `scaffold` edits that array when it
adds an application, and derives the CI matrix input from it.

## Alternatives considered

- A dedicated `project.yaml` describing apps and roles. Rejected: a second file
  stating the same fact, which drifts from the first.
```

- [ ] **Step 6: Commit**

```bash
git add mise.toml UPSTREAM README.md .editorconfig .gitattributes .gitignore \
        lib tests docs/decisions
git commit -m "feat: add the adapter contract linter

The linter reads CONTRACT_TASKS from lib/contract.sh so the task vocabulary has
one definition that both tests and validation share."
```

---

## Task 2: Command dispatch and `scaffold list`

**Files:**
- Create: `scaffold`
- Modify: `lib/adapter.sh` (create)
- Test: `tests/cli.bats`

**Interfaces:**
- Consumes: `die` from `lib/log.sh`; `lint_adapters` from `lib/lint.sh`.
- Produces: `load_adapter <name>` — sets `ADAPTER_DIR`, `ADAPTER_NAME`, `ADAPTER_ROLE`, `ADAPTER_TIER`, `ADAPTER_GENERATOR` in the caller's shell, dies on an unknown name. `scaffold list` prints one `name<TAB>role<TAB>tier` line per adapter, sorted by name.

- [ ] **Step 1: Write the failing test**

`tests/cli.bats`:

```bash
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

@test "scaffold list prints name, role and tier for each adapter" {
  run scaffold list
  [ "$status" -eq 0 ]
  [[ "$output" == *"nextjs"* ]]
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
  SCAFFOLD_ROOT="${SCAFFOLD_ROOT}/tests/fixtures/lint/complete/.." \
    load_adapter sample || true
  [ "$ADAPTER_ROLE" = "api" ]
}
```

Note: the last test relies on `load_adapter` resolving adapters under
`${SCAFFOLD_ROOT}/adapters`, so point `SCAFFOLD_ROOT` at
`tests/fixtures/lint/complete` after renaming its `sample` parent to
`adapters`. Create `tests/fixtures/project/adapters/sample/` as a copy of
`tests/fixtures/lint/complete/sample/` and use that path instead:

```bash
@test "load_adapter exports the adapter metadata" {
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/adapter.sh"
  SCAFFOLD_ROOT="${SCAFFOLD_ROOT}/tests/fixtures/project" load_adapter sample
  [ "$ADAPTER_ROLE" = "api" ]
  [ "$ADAPTER_NAME" = "sample" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/cli.bats`
Expected: FAIL — `scaffold: command not found`.

- [ ] **Step 3: Write minimal implementation**

`lib/adapter.sh`:

```bash
# shellcheck shell=bash

# load_adapter <name> — read one adapter's metadata into the current shell.
load_adapter() {
  local name="$1"
  local dir="${SCAFFOLD_ROOT}/adapters/${name}"

  [ -d "$dir" ] || die "unknown adapter: ${name} (run: scaffold list)"

  ADAPTER_DIR="$dir"
  # shellcheck source=/dev/null
  source "${dir}/adapter.env"
}
```

`scaffold`:

```bash
#!/usr/bin/env bash
# scaffold — create and extend projects that follow the task contract.

set -euo pipefail

SCAFFOLD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCAFFOLD_ROOT

# shellcheck source=lib/log.sh
source "${SCAFFOLD_ROOT}/lib/log.sh"
# shellcheck source=lib/contract.sh
source "${SCAFFOLD_ROOT}/lib/contract.sh"
# shellcheck source=lib/lint.sh
source "${SCAFFOLD_ROOT}/lib/lint.sh"
# shellcheck source=lib/adapter.sh
source "${SCAFFOLD_ROOT}/lib/adapter.sh"

usage() {
  cat <<'EOF'
usage:
  scaffold new <name> [--web <adapter>] [--api <adapter>] [--app <adapter>]
  scaffold add <dir> --adapter <adapter>
  scaffold list
  scaffold lint
EOF
}

cmd_list() {
  local adapter
  for adapter in "${SCAFFOLD_ROOT}"/adapters/*/; do
    [ -d "$adapter" ] || continue
    ( load_adapter "$(basename "$adapter")"
      printf '%s\t%s\t%s\n' "$ADAPTER_NAME" "$ADAPTER_ROLE" "$ADAPTER_TIER" )
  done | sort
}

cmd_lint() {
  lint_adapters "${SCAFFOLD_ROOT}/adapters"
}

main() {
  [ $# -gt 0 ] || { usage >&2; exit 1; }

  local command="$1"; shift
  case "$command" in
    list) cmd_list "$@" ;;
    lint) cmd_lint "$@" ;;
    -h|--help) usage ;;
    *) die "unknown command: ${command}" ;;
  esac
}

main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x scaffold && bats tests/cli.bats`
Expected: PASS except `scaffold list prints name, role and tier` which is empty until Task 4 adds the first adapter. Change that assertion to accept an empty listing for now:

```bash
@test "scaffold list succeeds even with no adapters installed" {
  run scaffold list
  [ "$status" -eq 0 ]
}
```

Task 4 replaces it with the `nextjs` assertion.

- [ ] **Step 5: Commit**

```bash
git add scaffold lib/adapter.sh tests
git commit -m "feat: add command dispatch and adapter listing"
```

---

## Task 3: The common layer and `scaffold new` for an empty project

**Files:**
- Create: `lib/project.sh`
- Create: `common/.editorconfig`, `common/.gitattributes`, `common/.gitignore`, `common/.git-blame-ignore-revs`
- Create: `common/lefthook.yml`, `common/commitlint.config.js`, `common/renovate.json`
- Create: `common/CONTRIBUTING.md`, `common/SECURITY.md`, `common/CODEOWNERS`, `common/AGENTS.md`
- Create: `common/mise.root.toml` (template for the generated root `mise.toml`)
- Modify: `scaffold` (add `cmd_new`)
- Test: `tests/new-project.bats`
- Create: `docs/decisions/0004-keep-the-toolbox-out-of-generated-projects.md`, `docs/decisions/0007-lefthook-over-husky.md`

**Interfaces:**
- Consumes: `die`, `load_adapter`.
- Produces:
  - `init_project <dir> <name>` — creates the directory, `git init` on `main`, copies `common/`, renders the root `mise.toml` with `config_roots = ["docs"]`.
  - `register_config_root <project-dir> <relative-path>` — inserts the path into the `config_roots` array, idempotent.
  - `collect_config_roots <project-dir>` — echoes the roots, one per line, in file order.
  - `sync_ci_roots <project-dir>` — rewrites the `roots:` input in `.github/workflows/ci.yml` from the current roots.
  - `finalize_project <project-dir>` — runs `sync_ci_roots`, then stages everything and makes the initial commit.

- [ ] **Step 1: Write the failing test**

`tests/new-project.bats`:

```bash
setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "new creates a git repository on main" {
  run scaffold new "$PROJECT"
  [ "$status" -eq 0 ]
  run git -C "$PROJECT" rev-parse --abbrev-ref HEAD
  [ "$output" = "main" ]
}

@test "new copies the common layer" {
  scaffold new "$PROJECT"
  [ -f "${PROJECT}/lefthook.yml" ]
  [ -f "${PROJECT}/commitlint.config.js" ]
  [ -f "${PROJECT}/renovate.json" ]
  [ -f "${PROJECT}/CONTRIBUTING.md" ]
  [ -f "${PROJECT}/.editorconfig" ]
}

@test "new leaves no toolbox files in the project" {
  scaffold new "$PROJECT"
  [ ! -e "${PROJECT}/adapters" ]
  [ ! -e "${PROJECT}/common" ]
  [ ! -e "${PROJECT}/mise.root.toml" ]
  [ ! -e "${PROJECT}/UPSTREAM" ]
}

@test "new writes a root mise.toml with docs as the only config root" {
  scaffold new "$PROJECT"
  run collect_roots "$PROJECT"
  [ "$output" = "docs" ]
}

@test "register_config_root is idempotent" {
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/project.sh"
  scaffold new "$PROJECT"
  register_config_root "$PROJECT" "apps/api"
  register_config_root "$PROJECT" "apps/api"
  run bash -c "grep -c '\"apps/api\",' '${PROJECT}/mise.toml'"
  [ "$output" = "1" ]
}

@test "sync_ci_roots writes the roots as a JSON array" {
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/project.sh"
  scaffold new "$PROJECT"
  register_config_root "$PROJECT" "apps/api"
  sync_ci_roots "$PROJECT"
  run grep 'roots:' "${PROJECT}/.github/workflows/ci.yml"
  [[ "$output" == *'["apps/api","docs"]'* ]]
}

@test "new refuses to overwrite an existing path" {
  mkdir -p "$PROJECT"
  run scaffold new "$PROJECT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to overwrite"* ]]
}

collect_roots() {
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/project.sh"
  collect_config_roots "$1"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/new-project.bats`
Expected: FAIL — `unknown command: new`.

- [ ] **Step 3: Write minimal implementation**

`common/mise.root.toml` — the template, with `@PROJECT_NAME@` substituted at render time:

```toml
monorepo_root = true

[monorepo]
config_roots = [
  "docs",
]

[tools]
node = "24.15.0"
pnpm = "11.21.0"
lefthook = "1.14.0"
gitleaks = "8.30.0"

[settings]
pin = true
lockfile = true

[tasks.dev]
interactive = true
run = "docker compose -f compose.dev.yaml up --remove-orphans"

[tasks."dev-down"]
run = "docker compose -f compose.dev.yaml down --remove-orphans"

[tasks.checklist]
run = [{ task = "//docs:checklist" }]
```

`common/lefthook.yml`:

```yaml
pre-commit:
  parallel: true
  commands:
    prettier:
      glob: "*.{ts,tsx,js,mjs,cjs,json,md,yml,yaml,css}"
      run: pnpm exec prettier --write {staged_files}
      stage_fixed: true
    gitleaks:
      run: gitleaks protect --staged --redact --no-banner

commit-msg:
  commands:
    commitlint:
      run: pnpm exec commitlint --edit {1}

pre-push:
  commands:
    checklist:
      run: mise run checklist
```

`common/commitlint.config.js`:

```js
export default {
  extends: ["@commitlint/config-conventional"],
};
```

`common/.gitattributes`:

```
* text=auto eol=lf
*.sh text eol=lf
pnpm-lock.yaml -diff linguist-generated
composer.lock -diff linguist-generated
```

`common/.git-blame-ignore-revs`:

```
# add the sha of any commit that only reformats, so blame skips it.
# apply with: git config blame.ignoreRevsFile .git-blame-ignore-revs
```

`common/renovate.json` — copy verbatim from `/home/ttndev/workspace/playground/immich/renovate.json`, then record the row in `PROVENANCE.md` in Task 12.

`lib/project.sh`:

```bash
# shellcheck shell=bash

# init_project <dir> <name>
init_project() {
  local dir="$1" name="$2"

  [ -e "$dir" ] && die "refusing to overwrite existing path: ${dir}"

  mkdir -p "$dir"
  git -C "$dir" init --initial-branch=main --quiet
  cp -R "${SCAFFOLD_ROOT}/common/." "${dir}/"

  sed "s|@PROJECT_NAME@|${name}|g" "${dir}/mise.root.toml" > "${dir}/mise.toml"
  rm -f "${dir}/mise.root.toml"
}

# register_config_root <project> <relative-path>
register_config_root() {
  local project="$1" root="$2"
  local file="${project}/mise.toml"

  grep -q "^  \"${root}\",\$" "$file" && return 0

  awk -v root="$root" '
    { print }
    /^config_roots = \[$/ { printf "  \"%s\",\n", root }
  ' "$file" > "${file}.tmp"
  mv "${file}.tmp" "$file"
}

# collect_config_roots <project>
collect_config_roots() {
  sed -n '/^config_roots = \[$/,/^\]$/p' "${1}/mise.toml" \
    | sed -n 's/^  "\(.*\)",$/\1/p'
}

# sync_ci_roots <project> — the ci workflow's matrix input is derived from the
# manifest so the two can never disagree.
sync_ci_roots() {
  local project="$1" json
  json="$(collect_config_roots "$project" | jq -R . | jq -sc .)"
  sed -i.bak "s|^      roots: .*|      roots: '${json}'|" \
    "${project}/.github/workflows/ci.yml"
  rm -f "${project}/.github/workflows/ci.yml.bak"
}

# finalize_project <project>
finalize_project() {
  local project="$1"
  sync_ci_roots "$project"
  git -C "$project" add -A
  git -C "$project" commit --quiet -m "chore: scaffold project"
}
```

Add to `scaffold`, sourcing `lib/project.sh` after `lib/adapter.sh`, and:

```bash
cmd_new() {
  [ $# -gt 0 ] || die "new requires a project name"

  local target="$1"; shift
  local name; name="$(basename "$target")"

  init_project "$target" "$name"
  finalize_project "$target"

  log "created ${target}"
}
```

and the dispatch arm `new) cmd_new "$@" ;;`.

Task 10 creates `common/.github/workflows/ci.yml`; until then `sync_ci_roots`
has no file to rewrite. Create a minimal placeholder now so the test passes,
and Task 10 fills in the rest:

`common/.github/workflows/ci.yml`:

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
permissions: {}
jobs:
  ci:
    uses: you/.github/.github/workflows/app-ci.yml@v1
    with:
      roots: '["docs"]'
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/new-project.bats`
Expected: PASS, 7 tests.

- [ ] **Step 5: Write the two ADRs this task settles**

`docs/decisions/0004-keep-the-toolbox-out-of-generated-projects.md` — Context: a
generated project must not carry stacks it does not use. Decision: the toolbox
is a separate repository; `scaffold` copies `common/` and the chosen adapters
into a fresh repository and nothing else; there is no prune step. Consequences:
generated projects are clean, but they do not receive toolbox fixes — which is
why CI lives in reusable workflows (ADR-0005). Alternatives considered: a
GitHub template repository plus a prune script — rejected because the initial
state contains other stacks and pruning misses things.

`docs/decisions/0007-lefthook-over-husky.md` — Context: git hooks must work in a
PHP-only project. Decision: lefthook, installed by mise. Consequences: hooks run
in parallel and no project needs Node solely for hooks; adapters contribute
fragments merged into one `lefthook.yml`. Alternatives considered: husky —
rejected, Node-only; pre-commit (the Python tool) — rejected, adds a Python
runtime to every project.

- [ ] **Step 6: Commit**

```bash
git add lib/project.sh common scaffold tests docs/decisions
git commit -m "feat: generate a project skeleton from the common layer"
```

---

## Task 4: The `nextjs` adapter and `apply_adapter`

**Files:**
- Create: `adapters/nextjs/{adapter.env,mise.toml,Dockerfile,.env.example,lefthook.fragment.yml}`
- Modify: `lib/adapter.sh` (add `apply_adapter`, `merge_lefthook_fragment`)
- Modify: `scaffold` (`cmd_new` gains `--web`, `--api`, `--app`)
- Test: `tests/new-nextjs.bats`
- Create: `docs/decisions/0001-use-mise-tasks-as-the-task-runner.md`, `0002-no-monorepo-build-orchestrator.md`, `0003-adapter-overlay-instead-of-vendored-presets.md`, `0008-eslint-and-prettier-for-now.md`

**Interfaces:**
- Consumes: `load_adapter`, `register_config_root`, `init_project`, `finalize_project`.
- Produces:
  - `apply_adapter <adapter-name> <project-dir> <relative-path>` — runs the adapter's generator into `<project-dir>/<relative-path>`, copies the three overlay files, registers the config root, merges the lefthook fragment.
  - `merge_lefthook_fragment <fragment-path> <project-dir> <relative-path>` — deep-merges the fragment into `<project-dir>/lefthook.yml`, substituting `@APP_ROOT@` with `<relative-path>/`. A missing fragment is not an error.
  - `role_path <role>` — echoes `apps/web`, `apps/api`, or `apps/app`.

- [ ] **Step 1: Write the failing test**

`tests/new-nextjs.bats`:

```bash
setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "nextjs generates an app at apps/web" {
  run scaffold new "$PROJECT" --web nextjs
  [ "$status" -eq 0 ]
  [ -f "${PROJECT}/apps/web/package.json" ]
  [ -f "${PROJECT}/apps/web/mise.toml" ]
  [ -f "${PROJECT}/apps/web/Dockerfile" ]
  [ -f "${PROJECT}/apps/web/.env.example" ]
}

@test "nextjs registers itself as a config root" {
  scaffold new "$PROJECT" --web nextjs
  run grep -c '"apps/web",' "${PROJECT}/mise.toml"
  [ "$output" = "1" ]
}

@test "the ci workflow lists apps/web" {
  scaffold new "$PROJECT" --web nextjs
  run grep 'roots:' "${PROJECT}/.github/workflows/ci.yml"
  [[ "$output" == *'apps/web'* ]]
}

@test "the generated web app passes its own ci-unit" {
  scaffold new "$PROJECT" --web nextjs
  cd "$PROJECT"
  run mise run //apps/web:ci-unit
  [ "$status" -eq 0 ]
}

@test "a role mismatch is rejected" {
  run scaffold new "$PROJECT" --api nextjs
  [ "$status" -eq 1 ]
  [[ "$output" == *"adapter nextjs has role web"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/new-nextjs.bats`
Expected: FAIL — `unknown adapter: nextjs`.

- [ ] **Step 3: Write minimal implementation**

`adapters/nextjs/adapter.env`:

```bash
ADAPTER_NAME="nextjs"
ADAPTER_ROLE="web"
ADAPTER_TIER="A"
# node and pnpm come from the project root, so this adapter declares no tools
ADAPTER_GENERATOR='pnpm create next-app@latest "$APP_DIR" --ts --app --eslint --tailwind --src-dir --import-alias "@/*" --use-pnpm --skip-install --yes'
```

`adapters/nextjs/mise.toml`:

```toml
[tasks.install]
run = "pnpm install --frozen-lockfile"

[tasks.format]
run = "pnpm exec prettier --check ."

[tasks."format-fix"]
run = "pnpm exec prettier --write ."

[tasks.lint]
run = "pnpm exec next lint --max-warnings 0"

[tasks.check]
run = "pnpm exec tsc --noEmit"

[tasks.test]
run = "pnpm exec vitest --run --passWithNoTests"

[tasks.build]
run = "pnpm exec next build"

[tasks.ci-unit]
run = [
  { task = ":install" },
  { task = ":format" },
  { task = ":lint" },
  { task = ":check" },
  { task = ":test" },
]

[tasks.checklist]
run = [{ task = ":ci-unit" }, { task = ":build" }]
```

`adapters/nextjs/.env.example`:

```bash
NEXT_PUBLIC_API_URL=http://localhost:3001
```

`adapters/nextjs/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1

FROM node:24.15.0-alpine AS deps
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

FROM node:24.15.0-alpine AS build
WORKDIR /app
RUN corepack enable
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN pnpm exec next build

FROM node:24.15.0-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
# next standalone output carries only the server files it actually needs
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://localhost:3000/api/health || exit 1
CMD ["node", "server.js"]
```

`adapters/nextjs/lefthook.fragment.yml` — the common layer already runs Prettier
over every staged file, so this adapter adds nothing:

```yaml
# nextjs needs no extra hook; prettier in the common layer already covers it.
{}
```

Add to `lib/adapter.sh`:

```bash
# role_path <role> — where an adapter of this role is installed.
role_path() {
  case "$1" in
    web) printf 'apps/web\n' ;;
    api) printf 'apps/api\n' ;;
    app) printf 'apps/app\n' ;;
    *) die "unknown adapter role: ${1}" ;;
  esac
}

# merge_lefthook_fragment <fragment> <project> <relative-path>
merge_lefthook_fragment() {
  local fragment="$1" project="$2" rel="$3" rendered

  [ -f "$fragment" ] || return 0

  rendered="$(mktemp)"
  sed "s|@APP_ROOT@|${rel}/|g" "$fragment" > "$rendered"
  yq eval-all --inplace 'select(fileIndex==0) * select(fileIndex==1)' \
    "${project}/lefthook.yml" "$rendered"
  rm -f "$rendered"
}

# apply_adapter <name> <project> <relative-path>
apply_adapter() {
  local name="$1" project="$2" rel="$3"

  load_adapter "$name"

  local dest="${project}/${rel}"
  local parent; parent="$(dirname "$dest")"
  mkdir -p "$parent"

  ( cd "$parent" && APP_DIR="$(basename "$dest")" eval "$ADAPTER_GENERATOR" )

  cp "${ADAPTER_DIR}/mise.toml"    "${dest}/mise.toml"
  cp "${ADAPTER_DIR}/Dockerfile"   "${dest}/Dockerfile"
  cp "${ADAPTER_DIR}/.env.example" "${dest}/.env.example"

  register_config_root "$project" "$rel"
  merge_lefthook_fragment "${ADAPTER_DIR}/lefthook.fragment.yml" "$project" "$rel"
}
```

Replace `cmd_new` in `scaffold`:

```bash
cmd_new() {
  [ $# -gt 0 ] || die "new requires a project name"

  local target="$1"; shift
  local name; name="$(basename "$target")"
  local -a requested=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --web|--api|--app)
        [ $# -ge 2 ] || die "${1} requires an adapter name"
        requested+=("${1#--}:${2}")
        shift 2
        ;;
      *) die "unknown option: ${1}" ;;
    esac
  done

  init_project "$target" "$name"

  local entry flag adapter
  for entry in "${requested[@]}"; do
    flag="${entry%%:*}"
    adapter="${entry#*:}"
    load_adapter "$adapter"
    [ "$ADAPTER_ROLE" = "$flag" ] \
      || die "adapter ${adapter} has role ${ADAPTER_ROLE}, not ${flag}"
    apply_adapter "$adapter" "$target" "$(role_path "$ADAPTER_ROLE")"
  done

  finalize_project "$target"
  log "created ${target}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/new-nextjs.bats`
Expected: PASS, 5 tests. The `ci-unit` test needs network and takes two to three minutes.

Run: `scaffold lint`
Expected: no output.

- [ ] **Step 5: Write the four ADRs this task settles**

`0001-use-mise-tasks-as-the-task-runner.md` — Context: a polyglot project needs
one way to invoke per-directory work. Decision: mise, using `monorepo_root` and
`config_roots`, serves as both toolchain pin and task runner. Consequences: one
tool instead of three; `[tools]` blocks scope a language to a directory.
Alternatives considered: `just` — rejected, a second tool doing what the first
already does; `make` — rejected, tab-sensitive syntax and no toolchain pinning.

`0002-no-monorepo-build-orchestrator.md` — Context: monorepos commonly add
Turborepo or Nx. Decision: none. Consequences: no pipeline configuration to
learn; mise `sources`/`outputs` already provides incremental caching if needed.
Revisit when `mise run checklist` becomes slow enough to measure. Alternatives
considered: Turborepo — rejected as premature for two applications.

`0003-adapter-overlay-instead-of-vendored-presets.md` — Context: supporting many
stacks cheaply. Decision: invoke each framework's own generator and overlay four
files. Consequences: about 40–80 lines owned per stack instead of an entire
application; generation requires network; upstream generator changes surface as
smoke-test failures. Alternatives considered: vendoring a complete application
per stack — rejected, 800–2000 lines per stack that fall behind upstream.

`0008-eslint-and-prettier-for-now.md` — Context: oxlint and oxfmt are markedly
faster and already used by Vite and Plane. Decision: ESLint and Prettier for
now. Consequences: slower linting, full plugin coverage including
`eslint-config-next`. Revisit when oxlint covers the Next.js and accessibility
rule sets. Alternatives considered: oxlint immediately — rejected, loses rules
that matter more than speed at this size.

- [ ] **Step 6: Commit**

```bash
git add adapters/nextjs lib/adapter.sh scaffold tests docs/decisions
git commit -m "feat: add the nextjs adapter and adapter overlay"
```

---

## Task 5: The `nestjs` adapter and the shared types package

**Files:**
- Create: `adapters/nestjs/{adapter.env,mise.toml,Dockerfile,.env.example,lefthook.fragment.yml}`
- Create: `common/packages-types/{package.json,tsconfig.json,mise.toml,src/index.ts}`
- Create: `common/pnpm-workspace.yaml`
- Modify: `lib/project.sh` (add `enable_typescript_workspace`)
- Modify: `scaffold` (`cmd_new` calls it when every applied adapter is TypeScript)
- Test: `tests/new-nestjs.bats`

**Interfaces:**
- Consumes: `apply_adapter`, `register_config_root`.
- Produces: `enable_typescript_workspace <project>` — moves `common/packages-types` to `packages/types`, writes `pnpm-workspace.yaml`, registers `packages/types` as a config root. `adapter_is_typescript <name>` — returns 0 when the adapter declares `ADAPTER_LANGUAGE="typescript"`.

- [ ] **Step 1: Write the failing test**

`tests/new-nestjs.bats`:

```bash
setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "nestjs generates an app at apps/api" {
  run scaffold new "$PROJECT" --api nestjs
  [ "$status" -eq 0 ]
  [ -f "${PROJECT}/apps/api/nest-cli.json" ]
  [ -f "${PROJECT}/apps/api/mise.toml" ]
}

@test "an all-typescript project gets packages/types" {
  scaffold new "$PROJECT" --api nestjs --web nextjs
  [ -f "${PROJECT}/packages/types/src/index.ts" ]
  [ -f "${PROJECT}/pnpm-workspace.yaml" ]
  run grep -c '"packages/types",' "${PROJECT}/mise.toml"
  [ "$output" = "1" ]
}

@test "packages-types never survives as a directory name" {
  scaffold new "$PROJECT" --api nestjs
  [ ! -e "${PROJECT}/packages-types" ]
}

@test "the generated api passes its own ci-unit" {
  scaffold new "$PROJECT" --api nestjs
  cd "$PROJECT"
  run mise run //apps/api:ci-unit
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/new-nestjs.bats`
Expected: FAIL — `unknown adapter: nestjs`.

- [ ] **Step 3: Write minimal implementation**

`adapters/nestjs/adapter.env`:

```bash
ADAPTER_NAME="nestjs"
ADAPTER_ROLE="api"
ADAPTER_TIER="A"
ADAPTER_LANGUAGE="typescript"
ADAPTER_GENERATOR='pnpm dlx @nestjs/cli@latest new "$APP_DIR" --package-manager pnpm --skip-git --skip-install --language TS'
```

Add `ADAPTER_LANGUAGE="typescript"` to `adapters/nextjs/adapter.env` as well.

`adapters/nestjs/mise.toml`:

```toml
[tasks.install]
run = "pnpm install --frozen-lockfile"

[tasks.format]
run = "pnpm exec prettier --check ."

[tasks."format-fix"]
run = "pnpm exec prettier --write ."

[tasks.lint]
run = "pnpm exec eslint \"src/**/*.ts\" \"test/**/*.ts\" --max-warnings 0"

[tasks.check]
run = "pnpm exec tsc --noEmit"

[tasks.test]
run = "pnpm exec vitest --run --passWithNoTests"

[tasks.build]
run = "pnpm exec nest build"

[tasks.ci-unit]
run = [
  { task = ":install" },
  { task = ":format" },
  { task = ":lint" },
  { task = ":check" },
  { task = ":test" },
]

[tasks.checklist]
run = [{ task = ":ci-unit" }, { task = ":build" }]
```

`adapters/nestjs/.env.example`:

```bash
PORT=3001
DATABASE_URL=postgres://app:app@localhost:5432/app
```

`adapters/nestjs/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1

FROM node:24.15.0-alpine AS build
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY . .
RUN pnpm exec nest build && pnpm prune --prod

FROM node:24.15.0-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
USER node
EXPOSE 3001
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://localhost:3001/health || exit 1
CMD ["node", "dist/main.js"]
```

`adapters/nestjs/lefthook.fragment.yml`:

```yaml
# prettier in the common layer already covers typescript sources.
{}
```

`common/pnpm-workspace.yaml`:

```yaml
packages:
  - apps/*
  - packages/*
  - docs
```

`common/packages-types/package.json`:

```json
{
  "name": "@project/types",
  "version": "0.0.0",
  "private": true,
  "type": "module",
  "main": "src/index.ts",
  "types": "src/index.ts"
}
```

`common/packages-types/src/index.ts`:

```ts
// shared types live here so the api and the web app cannot drift.
export interface HealthStatus {
  readonly status: "ok";
  readonly version: string;
}
```

`common/packages-types/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

`common/packages-types/mise.toml`:

```toml
[tasks.install]
run = "pnpm install --frozen-lockfile"

[tasks.format]
run = "pnpm exec prettier --check ."

[tasks."format-fix"]
run = "pnpm exec prettier --write ."

[tasks.lint]
run = "pnpm exec eslint \"src/**/*.ts\" --max-warnings 0"

[tasks.check]
run = "pnpm exec tsc --noEmit"

[tasks.test]
run = "pnpm exec vitest --run --passWithNoTests"

[tasks.build]
run = "true"

[tasks.ci-unit]
run = [{ task = ":install" }, { task = ":format" }, { task = ":check" }]

[tasks.checklist]
run = [{ task = ":ci-unit" }]
```

Add to `lib/project.sh`:

```bash
# enable_typescript_workspace <project>
# only called when every application in the project is typescript; sharing
# types across a language boundary is a different problem, solved by openapi.
enable_typescript_workspace() {
  local project="$1"

  mkdir -p "${project}/packages"
  mv "${project}/packages-types" "${project}/packages/types"
  register_config_root "$project" "packages/types"
}
```

`init_project` always copies `common/packages-types`; `cmd_new` either promotes
it or deletes it. Add to `lib/adapter.sh`:

```bash
# adapter_is_typescript <name>
adapter_is_typescript() {
  ( load_adapter "$1"; [ "${ADAPTER_LANGUAGE:-}" = "typescript" ] )
}
```

and in `cmd_new`, after the adapter loop:

```bash
  local all_typescript=1
  for entry in "${requested[@]}"; do
    adapter_is_typescript "${entry#*:}" || all_typescript=0
  done

  if [ ${#requested[@]} -gt 0 ] && [ "$all_typescript" -eq 1 ]; then
    enable_typescript_workspace "$target"
  else
    rm -rf "${target}/packages-types" "${target}/pnpm-workspace.yaml"
  fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/new-nestjs.bats`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add adapters/nestjs adapters/nextjs/adapter.env common lib scaffold tests
git commit -m "feat: add the nestjs adapter and the shared types package"
```

---

## Task 6: The `laravel-api` adapter and lefthook fragment merging

**Files:**
- Create: `adapters/laravel-api/{adapter.env,mise.toml,Dockerfile,.env.example,lefthook.fragment.yml}`
- Create: `adapters/laravel-api/docker/opcache.ini`
- Test: `tests/new-laravel-api.bats`
- Create: `docs/decisions/0012-tiered-adapter-support.md`

**Interfaces:**
- Consumes: `apply_adapter`, `merge_lefthook_fragment`.
- Produces: nothing new. This task proves the contract holds across a language boundary.

- [ ] **Step 1: Write the failing test**

`tests/new-laravel-api.bats`:

```bash
setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "laravel-api generates an app at apps/api" {
  run scaffold new "$PROJECT" --api laravel-api
  [ "$status" -eq 0 ]
  [ -f "${PROJECT}/apps/api/artisan" ]
  [ -f "${PROJECT}/apps/api/mise.toml" ]
}

@test "php is declared in the app and never at the project root" {
  scaffold new "$PROJECT" --api laravel-api
  run grep -q 'php' "${PROJECT}/mise.toml"
  [ "$status" -ne 0 ]
  run grep -q 'php = "8.4"' "${PROJECT}/apps/api/mise.toml"
  [ "$status" -eq 0 ]
}

@test "the laravel lefthook fragment is merged with the common hooks" {
  scaffold new "$PROJECT" --api laravel-api
  run yq '.pre-commit.commands | has("pint")' "${PROJECT}/lefthook.yml"
  [ "$output" = "true" ]
  run yq '.pre-commit.commands | has("gitleaks")' "${PROJECT}/lefthook.yml"
  [ "$output" = "true" ]
}

@test "the fragment resolves the app root" {
  scaffold new "$PROJECT" --api laravel-api
  run yq '.pre-commit.commands.pint.root' "${PROJECT}/lefthook.yml"
  [ "$output" = "apps/api/" ]
}

@test "a mixed-language project has no packages/types" {
  scaffold new "$PROJECT" --api laravel-api --web nextjs
  [ ! -e "${PROJECT}/packages/types" ]
  [ ! -e "${PROJECT}/packages-types" ]
}

@test "the generated api passes its own ci-unit" {
  scaffold new "$PROJECT" --api laravel-api
  cd "$PROJECT"
  run mise run //apps/api:ci-unit
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/new-laravel-api.bats`
Expected: FAIL — `unknown adapter: laravel-api`.

- [ ] **Step 3: Write minimal implementation**

`adapters/laravel-api/adapter.env`:

```bash
ADAPTER_NAME="laravel-api"
ADAPTER_ROLE="api"
ADAPTER_TIER="A"
ADAPTER_LANGUAGE="php"
ADAPTER_GENERATOR='composer create-project laravel/laravel "$APP_DIR" --no-interaction --prefer-dist && (cd "$APP_DIR" && composer require --dev larastan/larastan phpstan/phpstan --no-interaction)'
```

`adapters/laravel-api/mise.toml`:

```toml
# php lives here and nowhere else in the project. the root mise.toml never
# learns that this app is written in php.
[tools]
php = "8.4"
composer = "2.8"

[tasks.install]
run = "composer install --no-interaction --prefer-dist"

[tasks.format]
run = "./vendor/bin/pint --test"

[tasks."format-fix"]
run = "./vendor/bin/pint"

# pint is both formatter and style linter, so lint runs the same binary. the
# contract requires both names, and they are honestly the same check here.
[tasks.lint]
run = "./vendor/bin/pint --test"

[tasks.check]
run = "./vendor/bin/phpstan analyse --no-progress --memory-limit=512M"

[tasks.test]
run = "./vendor/bin/pest"

[tasks.build]
run = "composer install --no-dev --optimize-autoloader --classmap-authoritative"

[tasks.migrate]
run = "php artisan migrate --force"

[tasks.ci-unit]
run = [
  { task = ":install" },
  { task = ":format" },
  { task = ":check" },
  { task = ":test" },
]

[tasks.checklist]
run = [{ task = ":ci-unit" }, { task = ":build" }]
```

`adapters/laravel-api/.env.example`:

```bash
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=http://localhost:8000
DB_CONNECTION=pgsql
DB_HOST=database
DB_PORT=5432
DB_DATABASE=app
DB_USERNAME=app
DB_PASSWORD=app
```

`adapters/laravel-api/lefthook.fragment.yml`:

```yaml
pre-commit:
  commands:
    pint:
      glob: "*.php"
      root: "@APP_ROOT@"
      run: ./vendor/bin/pint {staged_files}
      stage_fixed: true
```

`adapters/laravel-api/docker/opcache.ini`:

```ini
; safe only because the image is immutable; never enable this against a bind mount
opcache.enable=1
opcache.validate_timestamps=0
opcache.max_accelerated_files=20000
opcache.memory_consumption=192
```

`adapters/laravel-api/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1

FROM composer:2.8 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-interaction \
    --prefer-dist --optimize-autoloader

FROM php:8.4-fpm-alpine AS runtime
RUN apk add --no-cache postgresql-dev \
 && docker-php-ext-install pdo_pgsql opcache
WORKDIR /var/www
COPY --from=vendor /app/vendor ./vendor
COPY . .
COPY docker/opcache.ini /usr/local/etc/php/conf.d/opcache.ini
USER www-data
EXPOSE 9000
HEALTHCHECK --interval=30s --timeout=3s \
  CMD php -r 'exit(0);'
CMD ["php-fpm"]
```

`apply_adapter` must also copy an adapter's `docker/` directory when present.
Add after the three `cp` lines in `lib/adapter.sh`:

```bash
  [ -d "${ADAPTER_DIR}/docker" ] && cp -R "${ADAPTER_DIR}/docker" "${dest}/docker"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/new-laravel-api.bats`
Expected: PASS, 6 tests.

- [ ] **Step 5: Write the ADR this task settles**

`docs/decisions/0012-tiered-adapter-support.md` — Context: the overlay mechanism
supports any number of stacks, but each stack CI guarantees is a pipeline branch
that must stay green through every dependency bump. Decision: three tiers. Tier
A (`nextjs`, `nestjs`, `laravel-api`, `laravel-inertia`) runs on every pull
request and nightly. Tier B runs when its own directory changes plus weekly.
Tier C has no automated verification and is allowed to rot. Consequences:
"supported" and "guaranteed" are different words and the README says so.
Alternatives considered: verifying every adapter on every pull request —
rejected, a fifteen-minute pull-request cycle gets switched off within a
fortnight.

- [ ] **Step 6: Commit**

```bash
git add adapters/laravel-api lib/adapter.sh tests docs/decisions
git commit -m "feat: add the laravel-api adapter

First non-TypeScript adapter, so this is where the task contract is actually
tested across a language boundary."
```

---

## Task 7: The `laravel-inertia` adapter

**Files:**
- Create: `adapters/laravel-inertia/{adapter.env,mise.toml,Dockerfile,.env.example,lefthook.fragment.yml}`
- Create: `adapters/laravel-inertia/docker/opcache.ini`
- Test: `tests/new-laravel-inertia.bats`

**Interfaces:**
- Consumes: `apply_adapter`, `role_path`.
- Produces: nothing new. Proves the `app` role — one application filling both roles.

- [ ] **Step 1: Write the failing test**

`tests/new-laravel-inertia.bats`:

```bash
setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/bakery"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "laravel-inertia generates a single app at apps/app" {
  run scaffold new "$PROJECT" --app laravel-inertia
  [ "$status" -eq 0 ]
  [ -f "${PROJECT}/apps/app/artisan" ]
  [ -f "${PROJECT}/apps/app/vite.config.js" ]
  [ ! -e "${PROJECT}/apps/web" ]
  [ ! -e "${PROJECT}/apps/api" ]
}

@test "the fullstack project has exactly two config roots" {
  scaffold new "$PROJECT" --app laravel-inertia
  run bash -c "source '${SCAFFOLD_ROOT}/lib/log.sh'; source '${SCAFFOLD_ROOT}/lib/project.sh'; collect_config_roots '${PROJECT}' | sort | tr '\n' ' '"
  [ "$output" = "apps/app docs " ]
}

@test "php stays scoped to the app" {
  scaffold new "$PROJECT" --app laravel-inertia
  run grep -q 'php' "${PROJECT}/mise.toml"
  [ "$status" -ne 0 ]
}

@test "the app declares node because vite builds the assets" {
  scaffold new "$PROJECT" --app laravel-inertia
  run grep -q 'node = ' "${PROJECT}/apps/app/mise.toml"
  [ "$status" -eq 0 ]
}

@test "the generated app passes its own ci-unit" {
  scaffold new "$PROJECT" --app laravel-inertia
  cd "$PROJECT"
  run mise run //apps/app:ci-unit
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/new-laravel-inertia.bats`
Expected: FAIL — `unknown adapter: laravel-inertia`.

- [ ] **Step 3: Write minimal implementation**

`adapters/laravel-inertia/adapter.env`:

```bash
ADAPTER_NAME="laravel-inertia"
ADAPTER_ROLE="app"
ADAPTER_TIER="A"
ADAPTER_LANGUAGE="php"
ADAPTER_GENERATOR='composer create-project laravel/laravel "$APP_DIR" --no-interaction --prefer-dist && (cd "$APP_DIR" && composer require laravel/breeze --dev --no-interaction && composer require --dev larastan/larastan --no-interaction && php artisan breeze:install vue --no-interaction)'
```

`adapters/laravel-inertia/mise.toml`:

```toml
# a fullstack laravel app still needs node, because vite builds the assets.
[tools]
php = "8.4"
composer = "2.8"
node = "24.15.0"

[tasks.install]
run = ["composer install --no-interaction --prefer-dist", "npm ci"]

[tasks.format]
run = ["./vendor/bin/pint --test", "npx prettier --check resources/js"]

[tasks."format-fix"]
run = ["./vendor/bin/pint", "npx prettier --write resources/js"]

[tasks.lint]
run = "./vendor/bin/pint --test"

[tasks.check]
run = "./vendor/bin/phpstan analyse --no-progress --memory-limit=512M"

[tasks.test]
run = "./vendor/bin/pest"

[tasks.build]
run = [
  "composer install --no-dev --optimize-autoloader --classmap-authoritative",
  "npm run build",
]

[tasks.migrate]
run = "php artisan migrate --force"

[tasks.ci-unit]
run = [
  { task = ":install" },
  { task = ":format" },
  { task = ":check" },
  { task = ":test" },
]

[tasks.checklist]
run = [{ task = ":ci-unit" }, { task = ":build" }]
```

`adapters/laravel-inertia/.env.example` — same as `laravel-api`, with
`VITE_APP_NAME="${APP_NAME}"` appended.

`adapters/laravel-inertia/lefthook.fragment.yml` — identical shape to
`laravel-api`:

```yaml
pre-commit:
  commands:
    pint:
      glob: "*.php"
      root: "@APP_ROOT@"
      run: ./vendor/bin/pint {staged_files}
      stage_fixed: true
```

`adapters/laravel-inertia/docker/opcache.ini` — identical to `laravel-api`:

```ini
; safe only because the image is immutable; never enable this against a bind mount
opcache.enable=1
opcache.validate_timestamps=0
opcache.max_accelerated_files=20000
opcache.memory_consumption=192
```

`adapters/laravel-inertia/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1

FROM node:24.15.0-alpine AS assets
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY resources ./resources
COPY vite.config.js ./
RUN npm run build

FROM composer:2.8 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-interaction \
    --prefer-dist --optimize-autoloader

FROM php:8.4-fpm-alpine AS runtime
RUN apk add --no-cache postgresql-dev \
 && docker-php-ext-install pdo_pgsql opcache
WORKDIR /var/www
COPY --from=vendor /app/vendor ./vendor
COPY --from=assets /app/public/build ./public/build
COPY . .
COPY docker/opcache.ini /usr/local/etc/php/conf.d/opcache.ini
USER www-data
EXPOSE 9000
HEALTHCHECK --interval=30s --timeout=3s \
  CMD php -r 'exit(0);'
CMD ["php-fpm"]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/new-laravel-inertia.bats`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add adapters/laravel-inertia tests
git commit -m "feat: add the laravel-inertia adapter"
```

---

## Task 8: `scaffold add`

**Files:**
- Modify: `scaffold` (add `cmd_add`)
- Test: `tests/add-app.bats`

**Interfaces:**
- Consumes: `apply_adapter`, `sync_ci_roots`, `load_adapter`.
- Produces: `cmd_add <relative-dir> --adapter <name>` — applies an adapter into an existing project at an arbitrary path, re-syncs the CI roots, and stages the change without committing.

- [ ] **Step 1: Write the failing test**

`tests/add-app.bats`:

```bash
setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
  scaffold new "$PROJECT" --api nestjs
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "add installs an adapter at an arbitrary path" {
  cd "$PROJECT"
  run scaffold add apps/worker --adapter nestjs
  [ "$status" -eq 0 ]
  [ -f "${PROJECT}/apps/worker/mise.toml" ]
}

@test "add registers the new config root" {
  cd "$PROJECT"
  scaffold add apps/worker --adapter nestjs
  run grep -c '"apps/worker",' "${PROJECT}/mise.toml"
  [ "$output" = "1" ]
}

@test "add updates the ci roots input" {
  cd "$PROJECT"
  scaffold add apps/worker --adapter nestjs
  run grep 'roots:' "${PROJECT}/.github/workflows/ci.yml"
  [[ "$output" == *'apps/worker'* ]]
}

@test "add touches exactly one line of the ci workflow" {
  cd "$PROJECT"
  scaffold add apps/worker --adapter nestjs
  run bash -c "git -C '${PROJECT}' diff --numstat -- .github/workflows/ci.yml"
  [[ "$output" == "1"$'\t'"1"* ]]
}

@test "add refuses a path that already exists" {
  cd "$PROJECT"
  run scaffold add apps/api --adapter nestjs
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/add-app.bats`
Expected: FAIL — `unknown command: add`.

- [ ] **Step 3: Write minimal implementation**

Add to `scaffold`:

```bash
cmd_add() {
  [ $# -ge 3 ] || die "usage: scaffold add <dir> --adapter <adapter>"

  local rel="$1"; shift
  local adapter=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --adapter)
        [ $# -ge 2 ] || die "--adapter requires an adapter name"
        adapter="$2"
        shift 2
        ;;
      *) die "unknown option: ${1}" ;;
    esac
  done

  [ -n "$adapter" ] || die "--adapter is required"

  local project; project="$(git rev-parse --show-toplevel)"
  [ -f "${project}/mise.toml" ] || die "not a scaffold project: ${project}"
  [ -e "${project}/${rel}" ] && die "path already exists: ${rel}"

  apply_adapter "$adapter" "$project" "$rel"
  sync_ci_roots "$project"
  git -C "$project" add -A

  log "added ${rel} using ${adapter}; review and commit"
}
```

and the dispatch arm `add) cmd_add "$@" ;;`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/add-app.bats`
Expected: PASS, 5 tests. The fourth test is the design's report card — if adding
an application ever touches more than one line of CI, the contract is wrong.

- [ ] **Step 5: Commit**

```bash
git add scaffold tests/add-app.bats
git commit -m "feat: add applications to an existing project"
```

---

## Task 9: Containers, compose, and `install.sh`

**Files:**
- Create: `common/compose.yaml`, `common/compose.dev.yaml`, `common/compose.test.yaml`, `common/example.env`
- Create: `common/install.sh`
- Create: `common/deploy-adapters/README.md`
- Test: `tests/compose.bats`
- Create: `docs/decisions/0014-deployment-deferred-with-seams.md`

**Interfaces:**
- Consumes: the generated project layout.
- Produces: a compose stack parameterised by `IMAGE_TAG` and fed by `.env`, plus an `install.sh` that downloads a release's assets and starts the stack.

- [ ] **Step 1: Write the failing test**

`tests/compose.bats`:

```bash
setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
  scaffold new "$PROJECT" --api laravel-api
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "the compose files are valid" {
  cd "$PROJECT"
  run docker compose -f compose.yaml config --quiet
  [ "$status" -eq 0 ]
  run docker compose -f compose.dev.yaml config --quiet
  [ "$status" -eq 0 ]
}

@test "the application image tag is parameterised" {
  run grep 'image:.*\${IMAGE_TAG' "${PROJECT}/compose.yaml"
  [ "$status" -eq 0 ]
}

@test "third-party images are pinned by digest" {
  run bash -c "grep -E '^\s+image: (docker\.io|ghcr\.io)' '${PROJECT}/compose.yaml' | grep -v '@sha256:' | grep -v IMAGE_TAG"
  [ -z "$output" ]
}

@test "no dockerfile copies a dotenv file" {
  run bash -c "grep -rn 'COPY .*\.env' '${PROJECT}/apps' || true"
  [ -z "$output" ]
}

@test "install.sh is executable and passes shellcheck" {
  [ -x "${PROJECT}/install.sh" ]
  run shellcheck "${PROJECT}/install.sh"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/compose.bats`
Expected: FAIL — `compose.yaml` does not exist.

- [ ] **Step 3: Write minimal implementation**

`common/compose.yaml`:

```yaml
# production-like stack. clients run this file; it is attached to every release
# so the compose file and the image always match.
name: app

services:
  app:
    image: ghcr.io/you/app:${IMAGE_TAG:-latest}
    env_file:
      - .env
    depends_on:
      database:
        condition: service_healthy
    restart: always
    ports:
      - "${APP_PORT:-8080}:8080"

  database:
    image: docker.io/library/postgres:17-alpine@sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa
    environment:
      POSTGRES_DB: ${DB_DATABASE}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - database:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USERNAME}"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: always

volumes:
  database:
```

Verify the digest before committing:

```bash
docker buildx imagetools inspect postgres:17-alpine --format '{{.Manifest.Digest}}'
```

`common/compose.dev.yaml`:

```yaml
name: app-dev

services:
  database:
    image: docker.io/library/postgres:17-alpine@sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa
    environment:
      POSTGRES_DB: app
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app"]
      interval: 10s
      timeout: 5s
      retries: 5
```

`common/compose.test.yaml` — same as `compose.dev.yaml` with `tmpfs` storage so
each run starts empty:

```yaml
name: app-test

services:
  database:
    image: docker.io/library/postgres:17-alpine@sha256:6567bca8d7bc8c82c5922425a0baee57be8402df92bae5eacad5f01ae9544daa
    environment:
      POSTGRES_DB: app
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app
    tmpfs:
      - /var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app"]
      interval: 5s
      timeout: 3s
      retries: 10
```

`common/example.env`:

```bash
# copy to .env and edit. install.sh does this for you and generates a password.
IMAGE_TAG=latest
APP_PORT=8080
DB_DATABASE=app
DB_USERNAME=app
DB_PASSWORD=changeme
```

`common/install.sh` — modelled on immich's, recorded as `adapted` in
`PROVENANCE.md`:

```bash
#!/usr/bin/env bash
# install.sh — download a release and start the stack.

set -o nounset
set -o pipefail

RepoUrl='https://github.com/you/app/releases/latest/download'
TargetDir='./app'

create_directory() {
  if [[ -e $TargetDir ]]; then
    echo "found existing ${TargetDir}, will overwrite the yaml files"
  else
    mkdir "$TargetDir" || return 1
  fi
  cd "$TargetDir" || return 1
}

download_release_assets() {
  echo "downloading compose.yaml and example.env..."
  curl -fsSL "${RepoUrl}/compose.yaml" -o ./compose.yaml || return 1
  if [[ -f .env ]]; then
    echo "keeping the existing .env"
  else
    curl -fsSL "${RepoUrl}/example.env" -o ./.env || return 1
    generate_database_password
  fi
}

generate_database_password() {
  local password
  password="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  sed -i.bak "s/DB_PASSWORD=changeme/DB_PASSWORD=${password}/" ./.env
  rm -f ./.env.bak
}

start_stack() {
  docker compose up --remove-orphans -d || return 1
  echo "the application is running on http://localhost:$(grep '^APP_PORT=' .env | cut -d= -f2)"
}

main() {
  command -v curl >/dev/null || { echo 'curl is required'; return 1; }
  docker compose version >/dev/null 2>&1 || { echo 'docker compose is required'; return 1; }

  create_directory || { echo 'could not create the target directory'; return 1; }
  download_release_assets || { echo 'could not download the release assets'; return 1; }
  start_stack || { echo 'could not start the stack; check the output above'; return 1; }
}

main
```

`common/deploy-adapters/README.md`:

```markdown
# Deploy adapters

Empty on purpose. Deployment is deferred — see ADR-0014 for the seven seams
that make adding a target roughly one session of work.

An adapter here will hold a `deploy.env` describing the target and a workflow
fragment that fills in the `deploy` job already present, and gated off, in
`app-release.yml`.
```

Add `install.sh` and the compose files to the `chmod` step in `init_project`:

```bash
  chmod +x "${dir}/install.sh"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/compose.bats`
Expected: PASS, 5 tests.

- [ ] **Step 5: Write the ADR this task settles**

`docs/decisions/0014-deployment-deferred-with-seams.md` — Context: the right
deployment target depends on the client, so choosing now means choosing wrong.
Decision: ship no deploy adapter; build seven seams instead — the published
image as the boundary, configuration only through environment variables, a
parameterised `IMAGE_TAG`, a health endpoint and `HEALTHCHECK` from day one,
migrations as a separate task never run from the entrypoint, fixed secret
naming and GitHub Environments, and a `deploy` job gated on
`vars.DEPLOY_TARGET`. Consequences: adding a target later fills in a body rather
than restructuring; today a human still runs `install.sh` on the target host.
Alternatives considered: shipping a `compose-vps` adapter now — rejected,
premature; shipping a PaaS adapter now — rejected, binds every client to one
vendor.

- [ ] **Step 6: Commit**

```bash
git add common tests/compose.bats lib/project.sh docs/decisions
git commit -m "feat: add the compose stack and the client installer"
```

---

## Task 10: The reusable workflow repository

**Files:**
- Create (new repository at `/home/ttndev/workspace/personal/dot-github`): `.github/workflows/{app-ci,app-security,app-build,app-release,app-docs}.yml`, `README.md`
- Modify: `common/.github/workflows/ci.yml`
- Create: `common/.github/workflows/{security,build,release,docs}.yml`
- Create: `common/release-please-config.json`, `common/.release-please-manifest.json`
- Test: `tests/workflows.bats`
- Create: `docs/decisions/0005-share-ci-through-reusable-workflows.md`, `0006-release-please-over-changesets.md`, `0010-github-token-over-a-github-app.md`, `0015-continuous-builds-separate-from-cut-releases.md`

**Interfaces:**
- Consumes: `collect_config_roots`, `sync_ci_roots`.
- Produces: five `workflow_call` entrypoints. `app-ci.yml` takes one input, `roots` (a JSON array as a string). `app-build.yml` and `app-release.yml` take `image` (the `ghcr.io/...` repository, no tag).

- [ ] **Step 1: Write the failing test**

`tests/workflows.bats`:

```bash
setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
  scaffold new "$PROJECT" --api nestjs
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "the project ships five workflows" {
  run bash -c "ls '${PROJECT}/.github/workflows' | wc -l"
  [ "$output" = "5" ]
}

@test "every workflow starts from a closed permission set" {
  for f in "${PROJECT}"/.github/workflows/*.yml; do
    run yq '.permissions' "$f"
    [ "$output" = "{}" ]
  done
}

@test "every workflow only calls into the shared repository" {
  run bash -c "yq -r '.jobs[].uses' '${PROJECT}'/.github/workflows/*.yml | sort -u"
  [[ "$output" != *"null"* ]]
  [[ "$output" == *"you/.github/.github/workflows/"* ]]
}

@test "every reusable workflow pins its actions by sha" {
  run bash -c "grep -rhoE 'uses: [^ ]+@[^ ]+' /home/ttndev/workspace/personal/dot-github/.github/workflows/ | grep -vE '@[0-9a-f]{40}$' || true"
  [ -z "$output" ]
}

@test "every checkout disables credential persistence" {
  run bash -c "grep -c 'persist-credentials: false' /home/ttndev/workspace/personal/dot-github/.github/workflows/app-ci.yml"
  [ "$output" -ge 1 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/workflows.bats`
Expected: FAIL — the project ships one workflow, not five.

- [ ] **Step 3: Write minimal implementation**

Create the repository:

```bash
mkdir -p /home/ttndev/workspace/personal/dot-github/.github/workflows
cd /home/ttndev/workspace/personal/dot-github
git init --initial-branch=main
```

`app-ci.yml`:

```yaml
name: App CI
on:
  workflow_call:
    inputs:
      roots:
        description: mise config roots to run ci-unit for, as a JSON array
        type: string
        required: true

permissions: {}

jobs:
  changes:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
    outputs:
      roots: ${{ steps.filter.outputs.changes }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - id: build-filters
        env:
          ROOTS: ${{ inputs.roots }}
        # a root is dirty when its own directory, a lockfile, or the root
        # mise.toml changed. anything else leaves it alone.
        run: |
          echo "$ROOTS" \
            | jq -r '.[] | "\(.):\n  - \(.)/**\n  - mise.toml\n  - \"*.lock*\""' \
            > "${RUNNER_TEMP}/filters.yml"
      - id: filter
        uses: dorny/paths-filter@de90cc6fb38fc0963ad72b210f1f284cd68cea36 # v3.0.2
        with:
          filters: ${{ runner.temp }}/filters.yml

  ci:
    needs: changes
    if: ${{ needs.changes.outputs.roots != '[]' }}
    runs-on: ubuntu-latest
    permissions:
      contents: read
    strategy:
      # report every broken root in one run, not just the first
      fail-fast: false
      matrix:
        root: ${{ fromJSON(needs.changes.outputs.roots) }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: jdx/mise-action@c37c93293d6b742fc901e1406b8f764f6fb19dac # v2.4.4
      - run: mise run //${{ matrix.root }}:ci-unit
```

`app-security.yml`:

```yaml
name: App Security
on:
  workflow_call:

permissions: {}

jobs:
  codeql:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write
    strategy:
      fail-fast: false
      matrix:
        language: [javascript-typescript]
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: github/codeql-action/init@4e94bd11f71e507f7f87df81788dff88d1dacbfb # v4.32.1
        with:
          languages: ${{ matrix.language }}
      - uses: github/codeql-action/analyze@4e94bd11f71e507f7f87df81788dff88d1dacbfb # v4.32.1

  zizmor:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: zizmorcore/zizmor-action@f52a838cfabf134edcbaa7c8b3677dde20045018 # v0.2.0

  gitleaks:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: gitleaks/gitleaks-action@44c470ffc35caa8b1eb3e8012ca53c2f9bea4eb5 # v2.3.9
        env:
          GITHUB_TOKEN: ${{ github.token }}
```

`app-build.yml` — continuous builds, no release involved:

```yaml
name: App Build
on:
  workflow_call:
    inputs:
      image:
        description: the ghcr repository, without a tag
        type: string
        required: true
      context:
        type: string
        required: true

permissions: {}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: docker/login-action@5e57cd118135c172c3672efd75eb46360885c0ef # v3.6.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ github.token }}
      - id: meta
        uses: docker/metadata-action@318604b99e75e41977312d83839a89be02ca4893 # v5.9.0
        with:
          images: ${{ inputs.image }}
          tags: |
            type=raw,value=main,enable={{is_default_branch}}
            type=sha,prefix=sha-
      - uses: docker/build-push-action@67dc11e451c8b0bb01e1cf5f80fd7ed84a4b8b28 # v6.19.0
        with:
          context: ${{ inputs.context }}
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

`app-release.yml`:

```yaml
name: App Release
on:
  workflow_call:
    inputs:
      image:
        type: string
        required: true
      context:
        type: string
        required: true

permissions: {}

jobs:
  release-please:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    outputs:
      released: ${{ steps.release.outputs.release_created }}
      tag: ${{ steps.release.outputs.tag_name }}
      version: ${{ steps.release.outputs.version }}
    steps:
      - id: release
        uses: googleapis/release-please-action@a02a34c4d625f9be7cb89156071d8567266a2445 # v4.4.0
        with:
          config-file: release-please-config.json
          manifest-file: .release-please-manifest.json

  image:
    needs: release-please
    if: ${{ needs.release-please.outputs.released == 'true' }}
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: docker/login-action@5e57cd118135c172c3672efd75eb46360885c0ef # v3.6.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ github.token }}
      - id: meta
        uses: docker/metadata-action@318604b99e75e41977312d83839a89be02ca4893 # v5.9.0
        with:
          images: ${{ inputs.image }}
          tags: |
            type=semver,pattern={{version}},value=${{ needs.release-please.outputs.version }}
            type=semver,pattern={{major}}.{{minor}},value=${{ needs.release-please.outputs.version }}
            type=raw,value=latest
            type=sha,prefix=sha-
      - uses: docker/build-push-action@67dc11e451c8b0bb01e1cf5f80fd7ed84a4b8b28 # v6.19.0
        with:
          context: ${{ inputs.context }}
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          cache-from: type=gha

  assets:
    needs: release-please
    if: ${{ needs.release-please.outputs.released == 'true' }}
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      # attaching these means a client always gets a compose file that matches
      # the image, instead of whatever is on main.
      - env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ needs.release-please.outputs.tag }}
        run: gh release upload "$TAG" compose.yaml example.env install.sh --clobber

  deploy:
    needs: [release-please, image]
    if: ${{ needs.release-please.outputs.released == 'true' && vars.DEPLOY_TARGET != '' }}
    runs-on: ubuntu-latest
    permissions:
      contents: read
    environment: production
    steps:
      # seam for a future deploy adapter — see ADR-0014. no target is configured
      # yet, so this job never runs.
      - run: echo "no deploy adapter is installed for ${{ vars.DEPLOY_TARGET }}" && exit 1
```

`app-docs.yml`:

```yaml
name: App Docs
on:
  workflow_call:

permissions: {}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: jdx/mise-action@c37c93293d6b742fc901e1406b8f764f6fb19dac # v2.4.4
      - run: mise run //docs:ci-unit
```

Call sites in `common/.github/workflows/`. `ci.yml` keeps the shape from Task 3.
`security.yml`:

```yaml
name: Security
on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: "17 3 * * 1"
permissions: {}
jobs:
  security:
    uses: you/.github/.github/workflows/app-security.yml@v1
```

`build.yml`:

```yaml
name: Build
on:
  push:
    branches: [main]
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
permissions: {}
jobs:
  build:
    uses: you/.github/.github/workflows/app-build.yml@v1
    with:
      image: ghcr.io/you/@PROJECT_NAME@
      context: apps/api
```

`release.yml`:

```yaml
name: Release
on:
  push:
    branches: [main]
permissions: {}
jobs:
  release:
    uses: you/.github/.github/workflows/app-release.yml@v1
    with:
      image: ghcr.io/you/@PROJECT_NAME@
      context: apps/api
```

`docs.yml`:

```yaml
name: Docs
on:
  pull_request:
  push:
    branches: [main]
permissions: {}
jobs:
  docs:
    uses: you/.github/.github/workflows/app-docs.yml@v1
```

`@PROJECT_NAME@` and the build context are substituted in `init_project`.
Extend the `sed` there to cover the workflow files:

```bash
  local file
  for file in "${dir}/.github/workflows/build.yml" "${dir}/.github/workflows/release.yml"; do
    sed -i.bak "s|@PROJECT_NAME@|${name}|g" "$file"
    rm -f "${file}.bak"
  done
```

The build context defaults to `apps/api` and is rewritten by `cmd_new` to
`apps/app` when the applied adapter has role `app`:

```bash
# set_image_context <project> <relative-path>
set_image_context() {
  local project="$1" rel="$2" file
  for file in "${project}/.github/workflows/build.yml" \
              "${project}/.github/workflows/release.yml"; do
    sed -i.bak "s|^      context: .*|      context: ${rel}|" "$file"
    rm -f "${file}.bak"
  done
}
```

Call it from `cmd_new` for the adapter whose role is `api` or `app`.

`common/release-please-config.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "release-type": "simple",
  "include-component-in-tag": false,
  "packages": {
    ".": {
      "changelog-sections": [
        { "type": "feat", "section": "Features" },
        { "type": "fix", "section": "Bug Fixes" },
        { "type": "perf", "section": "Performance" },
        { "type": "deps", "section": "Dependencies" },
        { "type": "docs", "section": "Documentation", "hidden": true },
        { "type": "chore", "section": "Chores", "hidden": true }
      ]
    }
  }
}
```

`common/.release-please-manifest.json`:

```json
{
  ".": "0.1.0"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/workflows.bats`
Expected: PASS, 5 tests.

Then tag the workflow repository:

```bash
cd /home/ttndev/workspace/personal/dot-github
git add -A
git commit -m "feat: add the reusable application workflows"
git tag v1.0.0
git tag -f v1
```

- [ ] **Step 5: Write the four ADRs this task settles**

`0005-share-ci-through-reusable-workflows.md` — Context: a project generated in
January would otherwise carry January's pipeline forever. Decision: the pipeline
lives in `you/.github`; projects reference it by the moving tag `v1`.
Consequences: one fix reaches every project; the blast radius of a bad change is
every project at once, mitigated by running the smoke suite against `@main`
before moving `v1`, and by rolling back with a tag move. Alternatives
considered: embedding workflows in each project — rejected, they diverge
immediately.

`0006-release-please-over-changesets.md` — Context: these are applications
delivered to clients, not packages published to npm. Decision: Release Please
reading conventional commits. Consequences: a version to pin, a changelog, a
Release to attach `compose.yaml` and `example.env` to, and a rollback marker;
every commit must be conventional, enforced at `commit-msg` and again in CI.
Alternatives considered: changesets — rejected, it versions many packages
independently and its output is `npm publish`, so it would contribute cost only.

`0010-github-token-over-a-github-app.md` — Context: immich wraps every job in a
GitHub App token because it is an organisation with many repositories and
untrusted forks. Decision: use `GITHUB_TOKEN` with least privilege.
Consequences: ten fewer lines per job and no secret to manage; cross-repository
operations would need revisiting. Alternatives considered: copying immich's
`create-workflow-token` flow — rejected as cargo cult at this scale.

`0015-continuous-builds-separate-from-cut-releases.md` — Context: the release
pull request must not stand between a merge and a running deployment. Decision:
`app-build.yml` publishes `main` and `sha-<commit>` on every merge;
`app-release.yml` cuts `1.4.0`, `1.4`, and `latest` when the release pull
request merges. Consequences: both delivery modes are supported and differ only
by `IMAGE_TAG`. Alternatives considered: releasing on every merge — rejected,
the changelog becomes noise and there is no deliberate upgrade point for a
client who operates their own host.

- [ ] **Step 6: Commit**

```bash
cd /home/ttndev/workspace/personal/scaffold
git add common lib scaffold tests docs/decisions
git commit -m "feat: delegate project ci to reusable workflows"
```

---

## Task 11: The documentation site and its checks

**Files:**
- Create: `common/docs/{mise.toml,package.json,index.md,getting-started.md,deployment.md}`
- Create: `common/docs/.vitepress/config.ts`
- Create: `common/docs/decisions/{0000-record-architecture-decisions.md,_template.md}`
- Create: `common/docs/scripts/check-paths.mjs`, `common/docs/scripts/check-adrs.mjs`
- Test: `tests/docs.bats`
- Create: `docs/decisions/0009-one-docs-workflow-instead-of-three.md`

**Interfaces:**
- Consumes: the project layout.
- Produces: `docs` as a config root implementing the contract, where `check` runs the path and ADR checks and `build` runs VitePress.

- [ ] **Step 1: Write the failing test**

`tests/docs.bats`:

```bash
setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
  scaffold new "$PROJECT" --api nestjs
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "docs is a config root with the full contract" {
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/contract.sh"
  source "${SCAFFOLD_ROOT}/lib/lint.sh"
  for task in "${CONTRACT_TASKS[@]}"; do
    run grep -Eq "^\[tasks\.\"?${task}\"?\]" "${PROJECT}/docs/mise.toml"
    [ "$status" -eq 0 ]
  done
}

@test "the adr template and the seed adr ship" {
  [ -f "${PROJECT}/docs/decisions/0000-record-architecture-decisions.md" ]
  [ -f "${PROJECT}/docs/decisions/_template.md" ]
}

@test "the path check fails on a path that does not exist" {
  echo 'See `docs/nope-does-not-exist.md`.' >> "${PROJECT}/docs/index.md"
  cd "${PROJECT}/docs"
  run node scripts/check-paths.mjs
  [ "$status" -eq 1 ]
  [[ "$output" == *"nope-does-not-exist.md"* ]]
}

@test "the adr check rejects an adr missing a required section" {
  cat > "${PROJECT}/docs/decisions/0001-broken.md" <<'EOF'
# 0001 — Broken

Status: Accepted

## Context

Nothing else follows.
EOF
  cd "${PROJECT}/docs"
  run node scripts/check-adrs.mjs
  [ "$status" -eq 1 ]
  [[ "$output" == *"0001-broken.md"* ]]
}

@test "the docs site builds" {
  cd "$PROJECT"
  run mise run //docs:build
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/docs.bats`
Expected: FAIL — `docs/mise.toml` does not exist.

- [ ] **Step 3: Write minimal implementation**

`common/docs/mise.toml`:

```toml
[tasks.install]
run = "pnpm install --frozen-lockfile"

[tasks.format]
run = "pnpm exec prettier --check ."

[tasks."format-fix"]
run = "pnpm exec prettier --write ."

[tasks.lint]
run = "node scripts/check-paths.mjs"

# documentation that ci does not verify is wrong within six months, so the
# structural checks run as this root's type check.
[tasks.check]
run = ["node scripts/check-paths.mjs", "node scripts/check-adrs.mjs"]

[tasks.test]
run = "true"

[tasks.build]
run = "pnpm exec vitepress build ."

[tasks.ci-unit]
run = [
  { task = ":install" },
  { task = ":format" },
  { task = ":check" },
  { task = ":build" },
]

[tasks.checklist]
run = [{ task = ":ci-unit" }]
```

`common/docs/package.json`:

```json
{
  "name": "@project/docs",
  "version": "0.0.0",
  "private": true,
  "type": "module",
  "devDependencies": {
    "vitepress": "^2.1.5"
  }
}
```

`common/docs/.vitepress/config.ts`:

```ts
import { defineConfig } from "vitepress";

export default defineConfig({
  title: "@PROJECT_NAME@",
  description: "Project documentation",
  // a dead link is a failed build, not a warning
  ignoreDeadLinks: false,
  themeConfig: {
    sidebar: [
      {
        text: "Guide",
        items: [
          { text: "Getting started", link: "/getting-started" },
          { text: "Deployment", link: "/deployment" },
        ],
      },
    ],
  },
});
```

`common/docs/scripts/check-paths.mjs`:

```js
import { readdir, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";

const DOCS_DIR = resolve(import.meta.dirname, "..");
const PROJECT_ROOT = resolve(DOCS_DIR, "..");
// backticked strings that look like repository paths
const PATH_PATTERN = /`((?:[\w.-]+\/)+[\w.-]+)`/g;

async function markdownFiles(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = await Promise.all(
    entries.map((entry) => {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) return markdownFiles(path);
      return entry.name.endsWith(".md") ? [path] : [];
    }),
  );
  return files.flat();
}

function missingPaths(content) {
  return [...content.matchAll(PATH_PATTERN)]
    .map((match) => match[1])
    .filter((candidate) => !candidate.includes("://"))
    .filter((candidate) => !existsSync(resolve(PROJECT_ROOT, candidate)));
}

const failures = [];
for (const file of await markdownFiles(DOCS_DIR)) {
  for (const path of missingPaths(await readFile(file, "utf8"))) {
    failures.push(`${file}: no such path: ${path}`);
  }
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}
```

`common/docs/scripts/check-adrs.mjs`:

```js
import { readdir, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";

const DECISIONS_DIR = resolve(import.meta.dirname, "..", "decisions");
const REQUIRED_SECTIONS = [
  "## Context",
  "## Decision",
  "## Consequences",
  "## Alternatives considered",
];
const VALID_STATUSES = ["Proposed", "Accepted", "Superseded"];

const failures = [];
const seenNumbers = new Map();

for (const name of await readdir(DECISIONS_DIR)) {
  if (!name.endsWith(".md") || name.startsWith("_")) continue;

  const number = name.slice(0, 4);
  if (seenNumbers.has(number)) {
    failures.push(`${name}: duplicate number, already used by ${seenNumbers.get(number)}`);
  }
  seenNumbers.set(number, name);

  const content = await readFile(join(DECISIONS_DIR, name), "utf8");

  for (const section of REQUIRED_SECTIONS) {
    if (!content.includes(section)) {
      failures.push(`${name}: missing section ${section}`);
    }
  }

  const status = content.match(/^Status:\s*(\w+)/m)?.[1];
  if (!VALID_STATUSES.includes(status)) {
    failures.push(`${name}: status must be one of ${VALID_STATUSES.join(", ")}`);
  }
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}
```

Note: `0000-record-architecture-decisions.md` must itself satisfy the checker,
so it carries all four sections.

`common/docs/decisions/_template.md`:

```markdown
# NNNN — Title

Status: Proposed
Date: YYYY-MM-DD

## Context

## Decision

## Consequences

## Alternatives considered
```

`common/docs/index.md`:

```markdown
# @PROJECT_NAME@

Start with [Getting started](/getting-started), then [Deployment](/deployment).
Architecture decisions live in `docs/decisions`.
```

`common/docs/getting-started.md` — three commands, matching what
`CONTRIBUTING.md` says:

```markdown
# Getting started

```bash
mise install     # exact toolchain versions, from mise.lock
lefthook install # formatting, secret scan, commit-message check
mise run dev     # the compose stack
```

Before opening a pull request, run `mise run checklist`. It runs exactly what CI
runs.
```

`common/docs/deployment.md` documents both delivery modes and the `IMAGE_TAG`
difference described in the spec, section 9.2.

Extend the `@PROJECT_NAME@` substitution loop in `init_project` to cover
`docs/.vitepress/config.ts` and `docs/index.md`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/docs.bats`
Expected: PASS, 5 tests.

- [ ] **Step 5: Write the ADR this task settles**

`docs/decisions/0009-one-docs-workflow-instead-of-three.md` — Context: immich
runs `docs-build`, `docs-deploy`, and `docs-destroy`, because the build runs in
an untrusted pull-request context and must not hold secrets, the deploy needs
Cloudflare credentials and so runs on `workflow_run`, and self-managed
infrastructure must be torn down explicitly. Decision: one workflow that builds
the site as a gate; preview deployments and teardown are handled by connecting
Cloudflare Pages to the repository. Consequences: three workflows become one;
revisit if documentation must be self-hosted or the repository starts accepting
fork pull requests. Alternatives considered: copying all three — rejected,
substantial machinery for a problem that a Pages integration solves.

- [ ] **Step 6: Commit**

```bash
git add common/docs lib/project.sh tests/docs.bats docs/decisions
git commit -m "feat: seed a documentation site that ci verifies"
```

---

## Task 12: Provenance tracking

**Files:**
- Create: `docs/PROVENANCE.md`
- Create: `scripts/check-provenance.sh`
- Test: `tests/provenance.bats`

**Interfaces:**
- Consumes: `UPSTREAM`.
- Produces: `check-provenance.sh` — reads the table in `docs/PROVENANCE.md`, fetches each `verbatim` file from the pinned upstream commit, and reports `ok`, `DRIFTED`, or `MISSING`. Exit 1 when anything drifted or is missing.

- [ ] **Step 1: Write the failing test**

`tests/provenance.bats`:

```bash
setup() {
  load 'helpers/setup'
}

@test "every verbatim row points at a file that exists locally" {
  run bash -c "
    awk -F'|' '/verbatim/ { gsub(/[ \`]/, \"\", \$2); print \$2 }' \
      '${SCAFFOLD_ROOT}/docs/PROVENANCE.md' \
    | while read -r f; do [ -f \"${SCAFFOLD_ROOT}/\$f\" ] || echo \"missing: \$f\"; done"
  [ -z "$output" ]
}

@test "UPSTREAM pins a commit" {
  run grep -Eq '^immich-app/immich@[0-9a-f]{7,40}$' "${SCAFFOLD_ROOT}/UPSTREAM"
  [ "$status" -eq 0 ]
}

@test "check-provenance reports no drift" {
  run "${SCAFFOLD_ROOT}/scripts/check-provenance.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 drifted"* ]]
}

@test "check-provenance detects a modified verbatim file" {
  cp "${SCAFFOLD_ROOT}/common/.editorconfig" "${BATS_TEST_TMPDIR}/backup"
  echo "# drift" >> "${SCAFFOLD_ROOT}/common/.editorconfig"
  run "${SCAFFOLD_ROOT}/scripts/check-provenance.sh"
  cp "${BATS_TEST_TMPDIR}/backup" "${SCAFFOLD_ROOT}/common/.editorconfig"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFTED"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/provenance.bats`
Expected: FAIL — `docs/PROVENANCE.md` does not exist.

- [ ] **Step 3: Write minimal implementation**

`docs/PROVENANCE.md`:

```markdown
# Provenance

Upstream commit is pinned in `UPSTREAM`. Run `scripts/check-provenance.sh`
monthly.

- `verbatim` — byte for byte. Drift is a finding.
- `adapted` — modified; the reason and its ADR are recorded here.
- `original` — no upstream equivalent.

| File | Upstream path | Status | Notes |
| --- | --- | --- | --- |
| `common/.editorconfig` | `.editorconfig` | verbatim | |
| `common/.gitattributes` | `.gitattributes` | verbatim | |
| `common/renovate.json` | `renovate.json` | verbatim | |
| `common/.github/workflows/ci.yml` | `.github/workflows/test.yml` | adapted | GITHUB_TOKEN instead of a GitHub App (ADR-0010); dorny/paths-filter instead of the internal pre-job action |
| `common/docs/` | `docs/` | adapted | VitePress instead of Docusaurus; one workflow instead of three (ADR-0009) |
| `common/compose.yaml` | `docker/docker-compose.yml` | adapted | single application service; digest pinning kept |
| `common/install.sh` | `install.sh` | adapted | release assets renamed; password generation uses /dev/urandom |
| `scaffold` | — | original | immich has no scaffolding tool |
| `common/lefthook.yml` | — | original | immich runs no git hooks (ADR-0007) |
| `adapters/*/mise.toml` | `server/mise.toml` | adapted | task names kept, contents are per stack (ADR-0011) |
```

`scripts/check-provenance.sh`:

```bash
#!/usr/bin/env bash
# check-provenance.sh — diff every verbatim file against the pinned upstream.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="${ROOT}/docs/PROVENANCE.md"
UPSTREAM="$(cat "${ROOT}/UPSTREAM")"
REPO="${UPSTREAM%@*}"
COMMIT="${UPSTREAM#*@}"

drifted=0
missing=0
checked=0

# the local shallow clone is used when present, otherwise raw.githubusercontent
LOCAL_CLONE="/home/ttndev/workspace/playground/immich"

fetch_upstream() {
  local path="$1"
  if [ -d "${LOCAL_CLONE}/.git" ]; then
    git -C "$LOCAL_CLONE" show "${COMMIT}:${path}" 2>/dev/null
  else
    curl -fsSL "https://raw.githubusercontent.com/${REPO}/${COMMIT}/${path}" 2>/dev/null
  fi
}

echo "checking against ${UPSTREAM}"
echo

while IFS='|' read -r _ local_path upstream_path status _; do
  status="$(echo "$status" | tr -d ' ')"
  [ "$status" = "verbatim" ] || continue

  local_path="$(echo "$local_path" | tr -d ' `')"
  upstream_path="$(echo "$upstream_path" | tr -d ' `')"
  checked=$((checked + 1))

  if [ ! -f "${ROOT}/${local_path}" ]; then
    printf '  MISSING   %s\n' "$local_path"
    missing=$((missing + 1))
    continue
  fi

  if fetch_upstream "$upstream_path" | diff -q - "${ROOT}/${local_path}" >/dev/null 2>&1; then
    printf '  ok        %s\n' "$local_path"
  else
    printf '  DRIFTED   %s\n' "$local_path"
    fetch_upstream "$upstream_path" | diff - "${ROOT}/${local_path}" | sed 's/^/              /'
    drifted=$((drifted + 1))
  fi
done < <(grep '^| `' "$TABLE")

echo
echo "${checked} checked, ${drifted} drifted, ${missing} missing"

[ "$drifted" -eq 0 ] && [ "$missing" -eq 0 ]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x scripts/check-provenance.sh && bats tests/provenance.bats`
Expected: PASS, 4 tests.

Run: `mise run lint`
Expected: no output — `scripts/*.sh` is already in the shellcheck glob.

- [ ] **Step 5: Commit**

```bash
git add docs/PROVENANCE.md scripts/check-provenance.sh tests/provenance.bats
git commit -m "feat: track which files were copied from upstream"
```

---

## Task 13: The toolbox's own CI

**Files:**
- Create: `.github/workflows/ci.yml`, `.github/workflows/adapters.yml`, `.github/workflows/provenance.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: `mise run ci-unit`, `bats tests/`, `scripts/check-provenance.sh`.
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Write the failing test**

There is no unit test for a workflow file. The check is `zizmor` plus the
assertion already written in `tests/workflows.bats`. Extend that suite:

```bash
@test "the toolbox workflows pin every action by sha" {
  run bash -c "grep -rhoE 'uses: [^ ]+@[^ ]+' '${SCAFFOLD_ROOT}/.github/workflows/' | grep -vE '@[0-9a-f]{40}$' || true"
  [ -z "$output" ]
}

@test "the toolbox workflows start from a closed permission set" {
  for f in "${SCAFFOLD_ROOT}"/.github/workflows/*.yml; do
    run yq '.permissions' "$f"
    [ "$output" = "{}" ]
  done
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/workflows.bats`
Expected: FAIL — the glob matches nothing, `yq` errors.

- [ ] **Step 3: Write minimal implementation**

`.github/workflows/ci.yml` — the fast suites, on every pull request:

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
permissions: {}
jobs:
  unit:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: jdx/mise-action@c37c93293d6b742fc901e1406b8f764f6fb19dac # v2.4.4
      - run: mise run ci-unit

  zizmor:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: zizmorcore/zizmor-action@f52a838cfabf134edcbaa7c8b3677dde20045018 # v0.2.0
```

`.github/workflows/adapters.yml` — the smoke suites. Tier A on every pull
request; every adapter weekly:

```yaml
name: Adapters
on:
  pull_request:
  schedule:
    - cron: "23 2 * * 1"
  workflow_dispatch:
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
permissions: {}
jobs:
  smoke:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    strategy:
      # a broken adapter must not hide the state of the others
      fail-fast: false
      matrix:
        adapter: [nextjs, nestjs, laravel-api, laravel-inertia]
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: jdx/mise-action@c37c93293d6b742fc901e1406b8f764f6fb19dac # v2.4.4
      - run: bats "tests/new-${{ matrix.adapter }}.bats"
      - name: Build the image
        # expensive, so only on the weekly run
        if: ${{ github.event_name == 'schedule' }}
        run: bats tests/compose.bats
```

`.github/workflows/provenance.yml`:

```yaml
name: Provenance
on:
  schedule:
    - cron: "41 4 1 * *"
  workflow_dispatch:
permissions: {}
jobs:
  check:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      issues: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - id: check
        run: ./scripts/check-provenance.sh | tee "${RUNNER_TEMP}/report.txt"
      - if: failure()
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh issue create --title "Upstream drift detected" \
            --body-file "${RUNNER_TEMP}/report.txt"
```

Add a support table to `README.md` stating which adapters are Tier A, Tier B,
and Tier C, and what each tier guarantees.

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/workflows.bats`
Expected: PASS.

Run: `mise run checklist`
Expected: PASS — the full suite, network included.

- [ ] **Step 5: Commit**

```bash
git add .github README.md tests/workflows.bats
git commit -m "ci: verify the toolbox and its adapters"
```

---

## Task 14: The tour and the runbooks

**Files:**
- Create: `docs/tour/{01-toolchain,02-task-contract,03-ci,04-guardrails,05-release,06-docs-site,07-containers,08-adapters}.md`
- Create: `docs/runbook/{add-an-adapter,bump-a-toolchain-version,cut-a-release,ci-is-red,rotate-a-leaked-secret,sync-with-upstream-immich}.md`
- Modify: `README.md`
- Test: `tests/documentation.bats`

**Interfaces:**
- Consumes: everything built so far.
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Write the failing test**

`tests/documentation.bats`:

```bash
setup() {
  load 'helpers/setup'
}

@test "every tour page has the four required headings" {
  local missing=""
  for page in "${SCAFFOLD_ROOT}"/docs/tour/*.md; do
    for heading in "## What it does" "## Read this" "## Delete test" "## Try it"; do
      grep -q "$heading" "$page" || missing="${missing}${page}: ${heading}"$'\n'
    done
  done
  [ -z "$missing" ]
}

@test "every path named in the tour and runbooks exists" {
  run bash -c "
    grep -rhoE '\`((\w|[.-])+/)+(\w|[.-])+\`' \
      '${SCAFFOLD_ROOT}/docs/tour' '${SCAFFOLD_ROOT}/docs/runbook' \
    | tr -d '\`' | sort -u \
    | while read -r p; do
        [ -e \"${SCAFFOLD_ROOT}/\$p\" ] || echo \"missing: \$p\"
      done"
  [ -z "$output" ]
}

@test "add-an-adapter fits on one page" {
  run wc -l < "${SCAFFOLD_ROOT}/docs/runbook/add-an-adapter.md"
  [ "$output" -le 120 ]
}

@test "every adr referenced by the tour exists" {
  run bash -c "
    grep -rhoE 'ADR-[0-9]{4}' '${SCAFFOLD_ROOT}/docs' | sort -u \
    | while read -r adr; do
        n=\${adr#ADR-}
        ls '${SCAFFOLD_ROOT}'/docs/decisions/\${n}-*.md >/dev/null 2>&1 \
          || echo \"missing: \$adr\"
      done"
  [ -z "$output" ]
}
```

The third test encodes the design standard from the spec: if adding an adapter
cannot be described in one page, the contract is wrong and the contract gets
fixed rather than the documentation extended.

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/documentation.bats`
Expected: FAIL — `docs/tour` does not exist.

- [ ] **Step 3: Write minimal implementation**

Each tour page uses this exact shape. `docs/tour/01-toolchain.md`:

```markdown
# 01 — Toolchain

## What it does

`mise.toml` pins every language and tool the project uses, and `mise.lock`
records the resolved versions. `mise install` reproduces them exactly on any
machine.

## Read this

- `common/mise.root.toml` — the template rendered into a generated project.
- `adapters/laravel-api/mise.toml` — a language scoped to one directory.
- Upstream for comparison: `immich/mise.toml` and
  `immich/machine-learning/mise.toml`.

## Delete test

Delete `mise.lock` and nothing breaks today. Three months later a client's
machine resolves a newer Node, the build fails, and no one can explain why.
`[settings] lockfile = true` is what makes the pin real rather than decorative.

## Try it

```bash
mise install
mise ls
```
```

The remaining seven pages follow the same four headings, covering: the nine-task
contract and why checking and fixing are separate tasks (02); the thin call site
delegating to the reusable matrix (03); lefthook, commitlint, gitleaks, zizmor,
and branch protection (04); conventional commits through Release Please to four
image tags, and the build-versus-release split (05); `docs/` as a config root
whose failure is a CI failure (06); the multi-stage Dockerfiles and the three
compose files (07); and the anatomy of an adapter (08).

`docs/runbook/add-an-adapter.md` — the one-page standard:

```markdown
# Add an adapter

Time: about one session. Tier B when the smoke test lands; Tier A when a real
project depends on it.

## 1. Create the directory

```bash
mkdir -p adapters/<name>
```

## 2. Write `adapter.env`

```bash
ADAPTER_NAME="<name>"
ADAPTER_ROLE="api"          # web, api, or app
ADAPTER_TIER="B"
ADAPTER_LANGUAGE="go"       # "typescript" opts into packages/types
ADAPTER_GENERATOR='<the framework's own generator, writing into "$APP_DIR">'
```

## 3. Write `mise.toml`

All nine contract tasks. Declare the language in a local `[tools]` block so it
never reaches the project root. `format`, `lint`, and `check` must not write.

## 4. Write `Dockerfile`, `.env.example`, `lefthook.fragment.yml`

The Dockerfile is multi-stage and declares a `HEALTHCHECK`. It must never copy
a `.env` file. An adapter with no extra git hook ships `{}` as its fragment.

## 5. Verify

```bash
scaffold lint
./scaffold new /tmp/probe --api <name>
cd /tmp/probe && mise run checklist
```

## 6. Add the smoke test

Copy `tests/new-laravel-api.bats`, change the adapter name, and keep the
assertion that the language never appears in the project's root `mise.toml`.

## 7. Promote to Tier A

Add the name to the matrix in `.github/workflows/adapters.yml` and change
`ADAPTER_TIER` to `A`.

## Done when

`scaffold lint` is silent, `bats tests/new-<name>.bats` passes, and
`scaffold list` shows the adapter with the intended tier.
```

`ci-is-red.md` is the symptom table from the spec, with one row per failing
contract task. `rotate-a-leaked-secret.md` orders the steps rotate first,
rewrite history second, because a rotated secret makes the leaked copy
worthless while history rewriting alone does not.
`sync-with-upstream-immich.md` covers the three permitted responses to a
`DRIFTED` row and forbids leaving it drifted. `cut-a-release.md` and
`bump-a-toolchain-version.md` follow the same shape: commands, then a
completion criterion.

Add the reading path to `README.md`: day one is tour 01–03; week one is tour
04–08 plus ADR-0001, ADR-0003, and ADR-0011; runbooks are consulted when the
situation arises.

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/documentation.bats`
Expected: PASS, 4 tests.

Run: `mise run checklist`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/tour docs/runbook README.md tests/documentation.bats
git commit -m "docs: add the guided tour and the runbooks"
```

---

## Self-Review

**Spec coverage.** Section 4 architecture → Tasks 3 and 10. Section 4.1
generation model → Task 4. Section 5 contract → Tasks 1 and 4–7. Section 5.2
task runner → Task 4 (ADR-0001). Section 6 adapters and tiers → Tasks 4–7,
Task 13 matrix. Section 7 common layer → Tasks 3, 9, 10, 11. Section 8 CI →
Task 10. Section 9 release and distribution → Tasks 9 and 10. Section 10
documentation → Tasks 11, 12, 14. Section 10.1 house style → Global
Constraints. Section 11 deferred deployment → Task 9 (seams 1–6) and Task 10
(seam 7, the gated `deploy` job). Section 12 testing → Tasks 1, 13. Section 13
definition of done → Task 13 Step 4. Section 14 ADR index → one ADR written in
the task that settles it; all fifteen are covered.

**Known deviation from the published walkthrough.** The artifact at
`/home/ttndev/workspace/playground/research/scaffold-toolbox.html` shows
`scaffold new bakery-shop --api laravel-inertia`. This plan uses three
role-matched flags — `--web`, `--api`, `--app` — and rejects a mismatch, so the
correct command is `--app laravel-inertia`. Update the artifact when Task 7
lands.

**Placeholder scan.** No `TBD` or `TODO` remains. Task 14 describes the seven
tour pages after `01-toolchain.md` by content rather than reproducing them; the
required structure is fixed by the four headings and enforced by
`tests/documentation.bats`.

**Type consistency.** `SCAFFOLD_ROOT` is set by `scaffold` and by
`tests/helpers/setup.bash`. `ADAPTER_*` variables are written in `adapter.env`
and read by `load_adapter`. `apply_adapter` takes `(name, project, relative
path)` in that order everywhere. `register_config_root`, `collect_config_roots`,
`sync_ci_roots`, and `finalize_project` all take the project directory as their
first argument. `role_path` is the only place a role maps to a directory.
