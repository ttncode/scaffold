# Provenance

This toolbox was built by copying and adapting from
[`immich-app/immich`](https://github.com/immich-app/immich). The commit it
was copied from is pinned in `UPSTREAM`. Run `scripts/check-provenance.sh`
monthly, and whenever `UPSTREAM` moves, to confirm the claims below still
hold.

- `verbatim` — byte for byte identical to the pinned commit today. Any drift
  is a finding, checked by `scripts/check-provenance.sh`.
- `adapted` — modified from an identifiable upstream file; the reason is
  recorded here or in the cited ADR. Not diffed — a diff against a file that
  was deliberately changed has no useful "pass" state.
- `original` — no upstream equivalent, even where the filename or purpose
  looks like it should have one. Every "original" row below was checked with
  `diff` against upstream before being marked this way, not assumed.

## What is in this table, and what is not

A row exists for a file (or a small group of files sharing one claim) only
when its relationship to upstream is something a reader could get wrong by
guessing — because the name is shared with an immich file, because an ADR
says it was derived from one, or because it is exactly copied. Everything in
scope for a row was checked with `diff` against the pinned commit; nothing
below is transcribed from an earlier draft of this document.

Excluded, and why:

- **`you/.github`** (the reusable-workflow repository `common/.github/workflows/`
  calls into). It is a separate repository — checked out, in this
  environment, as the sibling directory `dot-github` — not a subdirectory of
  this checkout. `scripts/check-provenance.sh` only ever reads paths inside
  `SCAFFOLD_ROOT`; there is no local path here for it to diff. If that
  repository's own workflow bodies need a provenance claim against immich,
  that claim belongs in a `PROVENANCE.md` of its own.
- **`tests/fixtures/`** — synthetic input this repo's own test suite invented
  (broken adapters, incomplete lint fixtures). Nothing here was ever copied
  from anywhere.
- **`docs/decisions/`, `docs/superpowers/`** (this repository's own, at the
  root — not `common/docs/decisions/`, which ships and is covered below).
  These are this project's planning record, not files copied from upstream.
- **`lib/*.sh`, `scaffold`, `scripts/*.sh`, `tests/*.bats`, `mise.toml`,
  `mise.lock`, `.github/workflows/*.yml`** (this repository's own CI, not
  `common/.github/workflows/`, which ships and is covered below) — the
  toolbox's own implementation, covered collectively by the `scaffold` row
  below. immich ships files with the same names (`ci.yml`, `security.yml`);
  these are original, built for this toolbox's own test suite, not adapted
  from them.

## Table

| File | Upstream path | Status | Notes |
| --- | --- | --- | --- |
| `common/.editorconfig` | `.editorconfig` | verbatim | |
| `common/renovate.json` | `renovate.json` | original | was `verbatim` (byte-identical) until this task. Replaced: the upstream file extends `local>immich-app/.github:renovate-config` (unresolvable outside that organisation), matches `machine-learning/**`, `mobile/**`, `ghcr.io/immich-app/*`, none of which exist in a generated project, and has a trailing comma that makes it invalid strict JSON — every generated project has shipped a Renovate config that fails on its first parse since Task 3. Replaced with a minimal, generic config (`$schema` plus the public `config:recommended` preset, no per-project rules). |
| `common/.gitattributes` | `.gitattributes` | original | instructed as a byte-for-byte copy originally, then reversed: upstream's version is almost entirely `mobile/**` and `packages/sdk/**` linguist/generated rules that have no counterpart in a generated project. Kept as one line, `* text=auto eol=lf`. |
| `common/compose.yaml` | `docker/docker-compose.yml` | adapted | one application service instead of server/machine-learning/redis/postgres; digest-pinned postgres image kept; every variable defaults so the file validates before `.env` exists (ADR-0014). |
| `common/compose.dev.yaml` | `docker/docker-compose.dev.yml` (`database` service) | adapted | the rest of upstream's dev compose mounts the whole immich monorepo into containers, which has no counterpart here; only its `database` service (port `5432:5432` exposed, postgres env vars) is the real parallel, simplified to a pinned-digest image with hardcoded local-only credentials. |
| `common/compose.test.yaml` | — | original | no `docker-compose.test.yml` exists upstream. Same shape as `compose.dev.yaml` (its sibling in this repo, not an upstream file) with `tmpfs` storage so CI starts from an empty database every run. |
| `common/example.env` | `docker/example.env` | adapted | one image's variables instead of immich's per-service set; same "copy to `.env` and edit" framing and a placeholder `DB_PASSWORD` an operator must change (ADR-0014). |
| `common/install.sh` | `install.sh` | adapted | one image instead of several; never overwrites an existing `.env`; generates the database password from `/dev/urandom` instead of asking the operator to supply one. Rationale recorded inline in the file. |
| `common/.github/workflows/build.yml`, `ci.yml`, `docs.yml`, `release.yml`, `security.yml` | `.github/workflows/test.yml`, `docker.yml`, `docs-build.yml`, `codeql-analysis.yml`, `static_analysis.yml` | adapted | immich's per-repository workflows collapsed into five thin call sites that each delegate to `you/.github` (ADR-0005); `GITHUB_TOKEN` instead of a minted GitHub App token (ADR-0010); one docs workflow instead of three (ADR-0009); build and release split so an ordinary merge never waits on the standing release PR (ADR-0015). |
| `common/docs/` | `docs/` | adapted | VitePress instead of Docusaurus; one docs workflow instead of three (ADR-0009). `common/docs/scripts/check-adrs.mjs` and `check-paths.mjs` have no upstream equivalent — immich has no ADR process — and are original, not adapted. |
| `common/lefthook.yml` | — | original | immich runs no git hooks (ADR-0007). |
| `common/deploy-adapters/` | — | original | seam left by ADR-0014; no upstream equivalent. |
| `common/.gitignore`, `common/CODEOWNERS`, `common/CONTRIBUTING.md`, `common/SECURITY.md`, `common/commitlint.config.js`, `common/.git-blame-ignore-revs`, `common/release-please-config.json`, `common/.release-please-manifest.json`, `common/mise.root.toml`, `common/pnpm-workspace.yaml`, `common/AGENTS.md`, `common/packages-types/` | (various — e.g. `.gitignore`, `CODEOWNERS`, `CONTRIBUTING.md`, `pnpm-workspace.yaml`) | original | conventional files any GitHub/pnpm project carries. Checked against immich's own copies of each — `diff` shows no shared content beyond the two both being, say, a `.gitignore` — so these were written for this project, not adapted from immich's. |
| `adapters/nestjs/mise.toml` | `server/mise.toml` | adapted | task-name vocabulary and the `ci-unit`/`checklist` aggregate pattern kept (ADR-0011); `pnpm exec` instead of a `node_modules/.bin` `PATH` entry; immich's `sql` and `sync-open-api` tasks dropped — nothing in the generator output needs them. |
| `adapters/nextjs/mise.toml` | `web/mise.toml` | adapted | same vocabulary and aggregate pattern (ADR-0011); immich's SDK-build steps and the svelte-specific half of `check` dropped — Next.js has neither. |
| `adapters/laravel-api/mise.toml`, `adapters/laravel-inertia/mise.toml`, `adapters/laravel-api/phpstan.neon`, `adapters/{laravel-api,laravel-inertia}/docker/opcache.ini` | — | original | immich has no PHP stack, so there is no upstream file to adapt for any PHP-specific tooling — phpstan and opcache have no immich equivalent at all. Task names in the two `mise.toml` files still follow the ADR-0011 vocabulary, but that is a shared naming convention, not a derived file. |
| `adapters/{nestjs,nextjs}/Dockerfile.workspace`, `adapters/{nestjs,nextjs}/Dockerfile`'s multi-stage `pnpm install`/`build` shape | `server/Dockerfile` | adapted | the all-typescript shape (apps are pnpm workspace members with no manifests of their own) builds from the workspace root the same way immich's server does: root manifests copied first, then only the app's own `package.json`, `pnpm --filter <app> install --frozen-lockfile` before the rest of the source, and a pruned `node_modules` in the runtime stage instead of the whole workspace's. The per-app `Dockerfile` (standalone/mixed-language shape) keeps the same layering with `pnpm install`/`prune` unfiltered, since there is no workspace to filter against there. |
| `common/.dockerignore` | `.dockerignore` | adapted | same excludes as the per-adapter `.dockerignore` files (`node_modules`, build output, `.env*`, `.git`), only read when the build context is the workspace root; immich's own root `.dockerignore` excludes the same categories (`**/node_modules/`, `**/dist/`, `.env*`, `.git/`) for the same reason. |
| `adapters/*/Dockerfile`'s base image, `USER`/`EXPOSE`/`HEALTHCHECK` shape, `adapters/*/.env.example`, `adapters/*/adapter.env`, `adapters/*/lefthook.fragment.yml`, `adapters/{nestjs,nextjs}/.prettierignore` | — | original | per-stack overlay files invoking each framework's own generator (ADR-0003), not vendored from immich's own `Dockerfile`/`docker/example.env`/`.prettierignore` — checked against all three, no meaningful resemblance; the `.prettierignore` pair shares only one coincidental line (`pnpm-lock.yaml`) with immich's much larger ignore lists. The two laravel Dockerfiles build with composer, not pnpm, and are untouched by the row above. |
| `scaffold`, `lib/*.sh` | — | original | immich has no scaffolding tool. |

## Out of scope, checked and rejected as rows

- `common/renovate.json`'s new `extends` target, `config:recommended`, is a
  public Renovate preset resolvable by anyone using Renovate, not a
  repository to clone or check provenance against — unlike the organisation-
  internal preset it replaced.
- `common/docs/decisions/0000-record-architecture-decisions.md` and
  `_template.md` ship to clients and look like they could be adapted from a
  known ADR format (Michael Nygard's). immich has no `docs/decisions`
  directory at all, so these are original, not adapted from immich.
