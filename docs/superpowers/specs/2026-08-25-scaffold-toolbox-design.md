# Scaffold Toolbox — Design

Status: approved for planning
Date: 2026-08-25
Upstream reference: `immich-app/immich@351be95`

## 1. Context

The author is a mid-level developer moving into freelance work. Individual
feature tasks are familiar territory; whole-repository setup is not. What is
missing is the stack-agnostic layer every production repository shares —
contribution rules, toolchain pinning, build orchestration, CI, release
automation, a documentation site — and a way to stand that layer up quickly for
each new client without copying files by hand and without understanding them.

immich was chosen as the reference implementation after comparing it against
`withastro/astro`, `Effect-TS/effect` and `makeplane/plane`. It is the only one
of the four that carries the full matrix of a production *application* — as
opposed to a published *library* — in a single repository: pinned toolchains,
polyglot task orchestration, containerisation, release automation, an in-repo
docs site with per-pull-request previews, and dependency and security
maintenance.

## 2. Goals

1. Create a new client project, fully configured, in a single command.
2. The generated project contains exactly one stack and no trace of any other.
3. Every file in the toolbox is explainable — where it came from, why it exists,
   and what breaks without it.
4. Adding support for a new stack takes about one working session.
5. A pipeline fix reaches every project already generated, not just future ones.

## 3. Non-goals

- Business logic, application features, or UI of any kind.
- A published CLI (`npm create`). Deferred until the shell script has proven
  itself across several real engagements.
- Automated deployment. Deferred, with explicit seams — see section 11.
- Kubernetes.
- Reproducing immich's own infrastructure (`deployment/`, Terragrunt, OpenTofu).
  That code manages Cloudflare domains for immich's documentation sites and has
  no bearing on how the application runs.

## 4. Architecture

Three repositories, two of which the author owns permanently.

| Repository | Lifetime | Contents | Delivered to a client |
| --- | --- | --- | --- |
| `you/scaffold` | Permanent | Adapters, the common layer, internal documentation | No |
| `you/.github` | Permanent | Reusable workflows called by every project | No, but every project depends on it |
| `<client-project>` | Per engagement | One stack, nothing else | Yes |

Splitting `you/.github` out solves a specific failure: a project generated in
January would otherwise carry January's pipeline forever. Because projects
reference the reusable workflows rather than embedding them, one fix reaches
every project at once.

### 4.1 Generation model

Adapters do not vendor application code. `scaffold` invokes each framework's own
generator (`laravel new`, `nest new`, `create-next-app`) and then overlays four
small files. The toolbox owns roughly 40–80 lines per stack instead of an entire
application, so upstream framework releases are the framework's problem rather
than a maintenance debt.

The trade-off accepted: generation requires network access, and a breaking
change in an upstream generator surfaces as a failing smoke test rather than as
code the toolbox controls.

## 5. The task contract

CI never learns what language a project is written in. It runs one command per
directory, and the adapter decides what that command means.

Task names are taken verbatim from immich (`server/mise.toml`,
`web/mise.toml`, `machine-learning/mise.toml`) so the two repositories read
alike.

| Task | Meaning | Called by CI |
| --- | --- | --- |
| `install` | Install dependencies from the lockfile | Yes |
| `format` | Check formatting; makes no changes | Yes |
| `format-fix` | Apply formatting | No |
| `lint` | Lint with zero tolerance for warnings | Yes |
| `check` | Static analysis and type checking | Yes |
| `test` | Unit tests | Yes |
| `build` | Produce the build artifact | Yes |
| `ci-unit` | Aggregate of the above, in order — CI calls only this | Yes |
| `checklist` | What a developer runs before pushing | No |

Two rules carry the whole design:

1. `format`, `lint` and `check` check only. The `-fix` variants are separate
   tasks. A linter that repairs its own input passes locally and fails in CI.
2. CI knows one command: `mise run //<root>:ci-unit`.

A task name joins the contract only when every configured root implements it and
CI needs to call it. Anything else — `migrate`, `queue`, `tinker` — lives in the
adapter and is simply never called by CI.

### 5.2 Task runner

`mise` serves as both the toolchain pin and the task runner, matching immich's
`monorepo_root` / `config_roots` layout. `mise` was already required for pinning
versions, and `[tasks.*]` with `depends`, `sources` and `outputs` covers what a
separate task runner or build orchestrator would provide.

Consequences: no `just`, no `make`, no Turborepo, and no separate project
manifest — `config_roots` *is* the manifest.

## 6. Adapters

Four files each:

```
adapters/<name>/
├── adapter.env             NAME, ROLE, GENERATOR, TOOLS
├── mise.toml               the task contract, plus a local [tools] block
├── Dockerfile              multi-stage
├── .env.example
└── lefthook.fragment.yml   merged into the project's lefthook.yml
```

The local `[tools]` block is the mechanism that keeps generated projects clean.
A Laravel adapter declares `php` and `composer` inside `apps/api/mise.toml`; the
project root never mentions PHP. immich does exactly this — `machine-learning/`
declares `python` and `uv` locally while the root knows nothing about them.

### 6.1 Support tiers

- **Tier A** — verified on every pull request and nightly. Initially `nestjs`,
  `laravel-api`, `laravel-inertia`, `nextjs`.
- **Tier B** — verified when that adapter's directory changes, plus a weekly run.
- **Tier C** — written ad hoc for one engagement, no automated verification.

The mechanism supports any number of stacks from day one. Only the count that CI
guarantees is limited, because each guaranteed stack is a pipeline branch that
must stay green through every dependency bump.

Naming follows the shape of the output, not the framework: `laravel-api` and
`laravel-inertia` are separate adapters rather than one adapter behind a flag,
because flags multiply the combinations that must be tested.

## 7. Common layer

Copied verbatim into every generated project:

- Five thin workflow files that call into `you/.github`.
- A seeded VitePress documentation site under `docs/`, registered as a config
  root so a broken documentation build fails CI like any other test.
- `.editorconfig`, `.gitattributes`, `.gitignore`, `.git-blame-ignore-revs`.
- `lefthook.yml`, `commitlint.config.js`, `renovate.json`.
- `release-please-config.json`, `.release-please-manifest.json`.
- `compose.yaml`, `compose.dev.yaml`, `compose.test.yaml`, `example.env`.
- `AGENTS.md`, `CODEOWNERS`, `CONTRIBUTING.md`, `SECURITY.md`.

Tooling choices and their reasons:

- **lefthook**, not husky — husky requires Node, which a PHP-only project should
  not need for git hooks.
- **ESLint and Prettier**, not oxlint/oxfmt — despite oxlint being faster and
  already adopted by Vite and Plane, `eslint-config-next` and the React and
  accessibility plugins have no full equivalent yet. The lint configuration is
  isolated so the swap is a single change later.
- **release-please**, not changesets — see section 9.1. A client project has one
  version and publishes no packages, so changesets contributes cost only.

## 8. CI

Adopted from immich, each for a stated reason:

| Practice | Reason |
| --- | --- |
| `permissions: {}` at workflow level, granted per job | GitHub's default is broad; a compromised third-party action would inherit write access |
| Actions pinned by SHA with a version comment | Tags are mutable |
| `persist-credentials: false` on checkout | Otherwise the token is written into `.git/config` for every later step |
| `concurrency` with `cancel-in-progress` | Cancels superseded runs |
| Path filters computed per config root | Editing `docs/` must not run the API test suite |
| `zizmor` linting the workflows themselves | Catches injection patterns and excess permissions in YAML |
| `fail-fast: false` on the matrix | Report every broken root, not only the first |

Deliberately not adopted: immich's GitHub App token flow
(`create-workflow-token`). It exists because immich is an organisation with many
repositories and untrusted forks. A solo operator uses `GITHUB_TOKEN` with
least privilege; copying the token dance would add ten lines per job and a
secret to manage, in exchange for nothing.

`immich-app/devtools/actions/pre-job` is likewise internal to them and is
replaced with `dorny/paths-filter`.

## 9. Release and distribution

### 9.1 Building is not releasing

The two are separate workflows, because they answer to different clocks.

```
push to main      → build and push  :main  and  :sha-<commit>
                    no bot pull request stands in the way

merge the release → tag, GitHub Release, compose.yaml and example.env attached
pull request        :1.4.0  :1.4  :latest
```

Continuous builds keep "merge and it is live" available. Cut releases give a
number to pin, a changelog, and a marker to roll back to. Neither blocks the
other.

Release Please is chosen over changesets because changesets solves a problem
these repositories do not have: independently versioned packages published to
npm, each pull request carrying a hand-written changeset file. A client project
has exactly one version and publishes no packages, so changesets would
contribute cost and nothing else. Release Please, reading conventional commits,
produces the four things self-hosting actually needs — a version to pin, a
changelog, a Release to attach the compose file and `example.env` to, and a
rollback marker.

Conventional commits are enforced twice — by `commitlint` at `commit-msg`, and
by a pull-request check that still fires when someone commits with
`--no-verify`. Merging the release pull request produces the tag and four image
tags: the exact version to pin against, the minor line that follows patches,
`latest` for development, and the commit SHA for provenance during a rollback.

### 9.2 Two delivery modes, one pipeline

Both are supported, selected per engagement. They differ by one variable.

| | Client operates the host | Author operates the host |
| --- | --- | --- |
| Image tag in use | `1.4.0`, pinned deliberately | `main`, moving |
| Upgrades | The client chooses when | Every merge |
| `install.sh` | Handed to the client | Used by the author |
| Release cadence | Every shipped change | Periodic, for the changelog and rollback markers |
| Documentation audience | An outside operator | The author |

The generated documentation covers both paths and states which one the project
uses. `IMAGE_TAG` is the only difference at the compose level.

Distribution follows immich's model, which is worth stating plainly: **immich
does not deploy the application, it distributes it.** Images are published, and
`docker-compose.yml` plus `example.env` are attached to the GitHub Release; an
`install.sh` downloads those from `releases/latest/download`, generates a random
database password, and starts the stack.

Adopted from that model:

- Third-party images pinned by digest, not tag
  (`valkey:9@sha256:…`) — stricter than pinning by tag.
- The compose file and `example.env` attached to each release, so a client
  always retrieves a matching set rather than whatever is on `main`. immich
  warns about precisely this mismatch in a header comment on the file.
- A per-project `install.sh`, idempotent, that prints the resulting URL.
- A release-notes template, after `misc/release/notes.tmpl`.

## 10. Documentation

Four artefacts, each answering a different question, all anchored to real files.

- **`PROVENANCE.md`** — where each file came from. Every row is `verbatim`,
  `adapted` (which requires a reason and an ADR) or `original`. The pinned
  upstream commit lives in a single `UPSTREAM` file, and
  `scripts/check-provenance.sh` re-diffs the `verbatim` rows against it.
- **`docs/decisions/`** — ADRs 0001–0015, each with Context, Decision,
  Consequences and Alternatives considered. ADRs are never edited to reflect a
  change of mind; a new ADR supersedes the old one, which is marked
  `Superseded`.
- **`docs/tour/`** — eight numbered pages in reading order, each with the same
  four headings: what it does, what to read, what breaks if the file is deleted,
  and one command to try.
- **`docs/runbook/`** — procedures with copy-paste commands and a stated
  completion criterion. `add-an-adapter.md` doubles as a design test: if it
  cannot fit on one page, the contract is wrong and the contract gets fixed.

Three checks run inside `docs:ci-unit`: dead-link checking, verification that
every file path named in the documentation exists, and an ADR lint for required
sections and unique numbering. Documentation that CI does not verify will be
wrong within six months, and wrong documentation is worse than none.

The toolbox's own documentation never ships to a client. A generated project
receives a documentation site about *itself* and an empty `decisions/` directory
with a template.

### 10.1 House style

Comments follow immich's observed conventions: rare, explaining *why* rather
than *what*, beginning lowercase, `TODO` without an owner tag, and tool
directives justified inline
(`# zizmor: ignore[dangerous-triggers] no attacker inputs are used here`). The
verbose banner comments in immich's `codeql-analysis.yml` come from GitHub's
stock template and are not their style.

All code, comments and documentation are written in English.

## 11. Deferred: deployment

Out of scope for the first version, because the right deployment target depends
on the client — whether they already run a VPS, whether they have operations
staff, whether data must stay in-country. Choosing early means choosing wrong.

Seven seams are built now so that adding a deploy adapter later is roughly one
session rather than several days:

1. The published image is the boundary; no deploy target ever rebuilds.
2. Configuration passes only through environment variables. The Dockerfile never
   copies `.env`, and `.env.example` is the configuration contract.
3. `compose.yaml` is parameterised: `image: …:${IMAGE_TAG:-latest}`.
4. A health endpoint and a `HEALTHCHECK` exist from day one — every target
   requires one, and retrofitting means editing every adapter.
5. Migrations are a separate task, never run from the container entrypoint.
   Running them at start-up corrupts data as soon as the service scales past one
   replica.
6. Secret naming and GitHub Environments (`staging`, `production`) are fixed by
   convention now, even while unused.
7. `app-release.yml` carries a `deploy` job gated on
   `if: vars.DEPLOY_TARGET != ''`, so adding a target fills in a body rather than
   restructuring the workflow.

`deploy-adapters/` exists as an empty directory with a README describing the
intended shape. ADR-0014 records the deferral and these seams.

## 12. Testing the toolbox

Three layers, cheapest first.

- **Contract lint** (~1s, every pull request, no network): assert that every
  adapter declares all nine contract tasks and ships its four required files.
  The highest value per unit of cost in the suite.
- **Smoke tests** (2–5 min per adapter, `bats`): generate a project into a
  temporary directory and run `mise run checklist` inside it — literally what
  the client's CI will run. Each also asserts an architectural promise, for
  example that a Laravel project's root `mise.toml` contains no reference to
  PHP. Tier A runs on every pull request; Tier B runs on directory change plus
  weekly.
- **Provenance drift** (~30s, monthly cron): `check-provenance.sh`. Not on pull
  requests — upstream changing a file is not the fault of the branch under
  review.

`bats` is chosen so the toolbox does not acquire a test stack of its own to
maintain.

Not tested on purpose: code produced by upstream generators, container images
beyond `docker build` in the weekly run, and anything about the generated
application's UI.

The reusable workflows have the largest blast radius and cannot test themselves.
Projects pin the moving tag `@v1`; before `v1` is moved, the smoke suite runs
against `@main`, and rollback is moving `v1` back.

## 13. Definition of done

On a clean machine: `git clone`, then `mise install && bats tests/` passes with
no manual steps.

## 14. Decision record index

| ADR | Decision |
| --- | --- |
| 0001 | mise tasks as the task runner |
| 0002 | No monorepo build orchestrator |
| 0003 | Adapter overlay instead of vendored presets |
| 0004 | Keep the toolbox out of generated projects |
| 0005 | Share CI through reusable workflows |
| 0006 | release-please over changesets |
| 0007 | lefthook over husky |
| 0008 | ESLint and Prettier for now |
| 0009 | One docs workflow instead of three |
| 0010 | `GITHUB_TOKEN` over a GitHub App |
| 0011 | Task contract names follow immich |
| 0012 | Tiered adapter support |
| 0013 | `config_roots` is the manifest |
| 0014 | Deployment deferred, with seams |
| 0015 | Continuous builds separate from cut releases; both delivery modes supported |

## 15. Risks

| Risk | Mitigation |
| --- | --- |
| An upstream generator changes its output | Tier A smoke tests fail nightly rather than during an engagement |
| A reusable workflow change breaks every project at once | Moving-tag discipline plus a smoke run against `@main` before moving `v1` |
| Adapter count grows past what one person can maintain | Tiering makes the cost explicit; Tier C is allowed to rot |
| Documentation drifts from the files it describes | Path and link checks run inside `docs:ci-unit` |
| The toolbox becomes a product in its own right | The CLI is explicitly deferred; the entrypoint stays a shell script |
