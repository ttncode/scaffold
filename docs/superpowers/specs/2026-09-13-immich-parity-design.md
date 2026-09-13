# Immich Parity Design

**Goal:** close the remaining gaps between this toolbox and the project it was
derived from, in the two places a survey found them — files immich has that we
never added, and a presentation style we adopted in prose but not in mechanism.

**Scope:** every tracked file in this repository was measured. Four work items
fall out. Nothing here changes behaviour except one test, which is strengthened
so it can fail for the reason it was written.

## What the survey found

Comment density, measured over every tracked file with at least five lines:

| Area | scaffold | immich equivalent |
| --- | --- | --- |
| `tests/*.bats` + helpers (4,345 lines) | 19% | 0.9% (`e2e/src/*.ts`) |
| `.github/workflows/*` | 17.5% | 3.8% |
| `adapters/*/adapter.env` | 53–76% | — |
| `common/.dockerignore` | 79% | 0% |
| `common/example.env` | 80% | — |
| `common/.prettierignore` | 73% | — |
| `common/install.sh` | 36% | 3% (`install.sh`) |
| Steps carrying `name:` | 0 of 49 | 297 |

The gap is not that immich explains less. It is that immich explains through
mechanisms a reader already has to look at:

- **`name:` on a workflow step.** The name appears in the GitHub log while the
  job runs. A comment above the step appears only to someone reading the file.
  Same words, better placement, and it cannot go stale unnoticed because it is
  on screen every run.
- **Function names that narrate.** immich's `install.sh` is 107 lines with three
  comments, because `main()` reads as prose: `create_immich_directory`,
  `download_docker_compose_file`, `generate_random_password`. Ours already has
  this shape; what it still carries is a paragraph above each function.
- **`local -r`.** immich uses it for locals that never change (`local -r
  Tgt='./immich-app'`). This is not the file-level `readonly` this repository
  correctly rejected — that breaks re-sourcing into child processes, which this
  codebase does by design. Function scope has no such problem.

## Decisions

**Adopt the mechanisms, keep the facts.** The comments that remain after the two
previous passes are largely third-party landmines: `mise exec` trusting and
executing a parent config, pnpm turning on frozen lockfiles whenever `CI` is set,
yq collapsing a document without `-P`, prisma 2.x changing `bsonSerialize()`,
`gh repo create --push` setting the default branch. immich sits at 3–4% because
it has no such layer — it calls its own tools. Those facts stay. What goes is
the narration around them.

**Community assets go to both the toolbox and `common/`, rewritten for each
audience.** This repository ships `SECURITY.md` and `CODEOWNERS` to every
generated project and carries neither itself. It enforces a pull request body on
its own pull requests, with a CI job, and ships no template to clients.

**No issue or discussion templates.** immich's are a triage funnel for thousands
of strangers, with a `config.yml` of Discord links. A client project is one to
three developers who sit together. Copying them produces ceremony, not
discipline.

## Work items

### A — Files immich has and we do not

Toolbox root:

- `SECURITY.md` — the text `common/SECURITY.md` already ships, unchanged.
- `CODEOWNERS` — `* @ttncode`. Hardcoded is correct here; this repository has
  one owner and no substitution step.
- `.vscode/extensions.json` — `timonwong.shellcheck`,
  `foxundermoon.shell-format`, `editorconfig.editorconfig`. Exactly the tools
  `mise.toml` already pins and `.editorconfig` already configures.
- `.vscode/settings.json` — minimal. `files.associations` so an editor
  recognises `scaffold`, an extensionless bash file, as shell.

Shipped into every generated project:

- `common/.github/pull_request_template.md` — the three headings this repository
  enforces on itself, with a checklist written for a client project's own
  commands.
- `common/.vscode/extensions.json` — the language-agnostic set. Per-adapter
  extensions would need a fragment-merge mechanism like `lefthook.fragment.yml`;
  that is not built, and nothing yet needs it.

Any file added under `common/` that carries the owner or the project name must
join `PROJECT_OWNER_FILES` or `PROJECT_NAME_FILES` in `lib/project.sh`, or it
ships with the placeholder intact.

One test changes. `tests/new-project.bats` asserts that no `@you` or `you/`
survives generation. That proves a placeholder is gone, not that the owner is
right: a hardcoded or mistyped account passes it. It becomes an assertion that
`CODEOWNERS` names the account the run resolved.

### B — A name on every workflow step

49 steps across the four workflows in `.github/workflows/`; none has a `name:`.
The five files in `common/.github/workflows/` are pure `uses:` call sites with no
steps, so they are untouched.

Name every step, then delete the comments the name now carries. What stays is
GitHub's own behaviour: SARIF upload refused on a private repository without
Advanced Security, CodeQL needing `actions: read` to read its own run, the job
name `pull-request-body` being load-bearing for branch protection.

Target: 17.5% to 6–8%.

### C — Scripts in immich's shape

- `local -r` for every local that is assigned once.
- `common/install.sh` from 36% to about 15%: each function's comment block down
  to the sentence carrying the fact. The landmines stay — jq rather than grep for
  a release asset's id, two endpoints because a private release's browser URL
  answers 404, the trap baking its path with `printf %q` and naming its signals,
  `sed` delimited on `|` because a base64 value contains `/`, `BASH_SOURCE[0]:-$0`
  because a curl-piped script has no `BASH_SOURCE`.
- The same pass over `lib/*.sh` and `services/shared/*.sh`, which the previous
  two rounds left at 37–52%.

### D — Data files and tests

Not in the original three-part split; the survey found it.

- `tests/*.bats` and `tests/helpers/` — 833 comment lines in 4,345. A bats test
  name is already a sentence; a comment above it that restates the name is the
  dominant pattern here. Keep the ones recording why a test exists at all —
  those are regression notes, and several name a defect that shipped.
- `adapters/*/adapter.env` — 53–76%. The laravel-inertia file is the extreme: a
  seven-line block on `ADAPTER_GENERATOR` and a ten-line block on
  `ADAPTER_POST_GENERATE`. Both record real traps (`rm -rf .github` because the
  starter kit's inert dependabot config fails zizmor; the sed that wires
  `routes/health.php` into `bootstrap/app.php` because Laravel auto-loads
  neither). Compress, do not delete.
- `common/.dockerignore`, `common/.prettierignore`, `common/example.env`,
  `adapters/*/.dockerignore`, `adapters/*/.env.example` — 42–80%. immich's
  `.dockerignore` carries no comment at all and is perfectly legible.

## Not doing

| | Why |
| --- | --- |
| `ISSUE_TEMPLATE`, `DISCUSSION_TEMPLATE` | A triage funnel for a public product; a client project has three developers. |
| `labeler.yml`, `pr-labeler.yml` | One maintainer. |
| `.github/release.yml` changelog categories | Generated projects use Release Please, which writes its own changelog from conventional commits. |
| `.devcontainer`, `.pnpmfile.cjs`, `.prettierrc`, `.nvmrc` | No JS/TS in the toolbox; mise already pins node. |
| Root `.dockerignore` | The toolbox builds no image. |
| Path-filtered CI | Worth doing, deferred by choice. A `paths:` trigger makes a required check never report, which blocks merges forever — the failure this repository already hit with `pull-request-body`. If taken up, gate with `if:` at the job, which still reports. |
| `docker rmi` in `deploy-check.sh` | immich removes no image it builds, anywhere. Reclamation is documented as the operator's `docker image prune`. |

## Verification

Each work item is a pull request, verified the same way:

- `mise run lint`
- `mise run test-runner` — both lanes under the runner's environment
- `mise exec -- zizmor --min-severity medium .github/workflows/`
- every YAML and TOML touched re-parsed with `yq`
- the pull request's own CI, which runs `deploy` and `smoke` against three
  adapters on a real runner

A adds one more: generate a project with an explicit owner and confirm
`CODEOWNERS` names it.
