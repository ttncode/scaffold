# 0014 — Deployment deferred, with seams

Status: Accepted
Date: 2026-08-27
Superseded in part by 0021 (seams 1 and 4)

## Context

Every client this toolbox generates a project for ends up running it
somewhere different — a VPS, a client's own Kubernetes cluster, a PaaS they
already pay for. The right deployment target depends entirely on who is
asking, so picking one now, before any client exists, means picking wrong
for most of them.

What does not depend on the client is the shape of a stack that can be
deployed *to* whatever they choose: an image to run, a way to configure it
without rebuilding it, and a way to tell whether it is healthy. Task 9
builds that shape. It does not build a deploy target.

## Decision

Ship no deploy adapter. Build seven seams instead — the boundary a real
deploy target plugs into later without restructuring anything above it:

1. **A published image is the boundary.** `compose.yaml`'s `app` service
   runs `ghcr.io/<owner>/<project>:${IMAGE_TAG:-latest}` — a client's
   target only ever needs to know how to run one image, never how to build
   one.
2. **Configuration only through the environment.** No Dockerfile in any
   adapter copies a `.env` file into the image (enforced by
   `tests/compose.bats`); every value a container needs arrives through
   `env_file`/`environment` at run time, so the same image runs unchanged
   in every client's environment.
3. **A parameterised `IMAGE_TAG`.** `compose.yaml` never hardcodes a
   version; a deploy target sets `IMAGE_TAG` and gets that release.
4. **A health endpoint and `HEALTHCHECK` from day one**, where the
   protocol allows one. `nextjs` and `nestjs` already ship an HTTP
   `HEALTHCHECK` (Task 7). The Laravel adapters deliberately ship none:
   php-fpm speaks FastCGI on its exposed port, not HTTP, and a check that
   can never fail (`php -r 'exit(0);'`) is worse than no check at all — an
   orchestrator with no `HEALTHCHECK` knows it does not know; one with an
   always-green check believes it does. `compose.yaml`'s `database`
   service gets a real `pg_isready` check, and `app` depends on it being
   healthy before it starts — a check that can actually fail, on a
   protocol where probing for real costs nothing extra.
5. **Migrations as a separate task, never run from the entrypoint.**
   Deferred beyond this task: no adapter yet runs an entrypoint that could
   run one. Recorded here as a seam a deploy adapter must respect once one
   exists, not as something Task 9 builds.
6. **Fixed secret naming and GitHub Environments.** Deferred to Task 10,
   which owns the release workflow secrets flow through.
7. **A `deploy` job gated on `vars.DEPLOY_TARGET`.** Also Task 10: the
   reusable release workflow will carry a `deploy` job that does nothing
   until a client sets that variable.

**Update, 2026-09-06 (0021).** Seams 1 and 4 as written above are now
false, and the record stays rather than being rewritten: seam 4's premise
was that php-fpm speaks FastCGI and no HTTP check is possible, so no check
ships; the Laravel adapters now serve HTTP through FrankenPHP, so a real
`HEALTHCHECK` exists and ships. The reasoning that check-that-cannot-fail is
worse than no check was correct then and stays correct — only the premise
under it changed. Seam 1's claim ("a client's target only ever needs to
know how to run one image") was already in tension with seam 4 admitting
one of those images could not be usefully run at all without protocol-aware
infrastructure a target would have to supply on its own; that tension now
resolves in seam 1's favour, since every adapter speaks HTTP on the same
port and a target genuinely only ever has to run one image. See 0021 for
the working implementation.

`common/deploy-adapters/` ships empty, with a `README.md` explaining why and
pointing at this ADR.

**Update, 2026-09-11.** It no longer ships at all. An empty directory whose
only content explained its own emptiness was shipped into every client
project, where it answered a question nobody there had asked — the reasoning
lives in this ADR, which is where a reader looking for it goes. Seam 7 is not
weakened by the removal: the `deploy` job it describes already exists,
gated on `vars.DEPLOY_TARGET`, in the reusable release workflow. A deploy
adapter still fills in a body rather than restructuring anything, and
`common/deploy-adapters/` is one `mkdir` away on the day one exists.

`install.sh` is the one deploy mechanism that exists today: a human runs it,
by hand, on the target host, after cloning nothing more than the two files a
release publishes (`compose.yaml`, `example.env`).

**Update, 2026-09-07.** "The one deploy mechanism that exists today" held
only for a public project. Measured against a real private repository, a
release asset's browser download URL 404s even with a Bearer token — the
token is ignored on that endpoint, not merely absent — and a private ghcr
package refuses an anonymous pull with `unauthorized`, independently of the
repository's own visibility: two failures, not one, so a token with only
`repo` or only `read:packages` fixes one and not the other. `install.sh` now
takes `GITHUB_TOKEN`, reading the release through the API asset endpoint
that does honor it and signing in to `ghcr.io` before pulling; unset, every
line behaves exactly as it did before this note. See
docs/runbook/first-project-walkthrough.md step 10 for what an operator of a
private project needs.

Two choices `install.sh` makes, decided here because nothing upstream
constrains them:

- **Re-running it must not be able to destroy a client's configuration or
  data.** `compose.yaml` is always overwritten with the release's own copy,
  so it and the image it references can never drift apart. `.env` is never
  touched once it exists — it holds the real database password and any
  edits an operator made — so a second run (to pick up a new release)
  cannot lose it. Docker's named `database` volume is never touched by
  `install.sh` at all; `docker compose up -d` does not recreate volumes,
  only containers. This matches immich's own `install.sh`, which overwrites
  `docker-compose.yml` and keeps an existing `.env` for the same reason.
- **The image and repository references are substituted at generation
  time, not parameterised.** Unlike `IMAGE_TAG` (which changes release to
  release, so it has to be a variable with a default), the repository path
  is fixed for the life of the project — a variable would only add a place
  for the default to silently drift from the real value.

  *Revised 2026-09-08.* This bullet originally said both were placeholders
  spelled `CHANGEME/CHANGEME`, on the reasoning that `scaffold new`
  generates a project before it has a GitHub repository and so cannot
  derive either value. That reasoning was wrong, and the file next to them
  disproved it: `build.yml` and `release.yml` have always shipped
  `ghcr.io/you/@PROJECT_NAME@`, filled in by `resolve_github_owner` and the
  project's own directory name. The path compose.yaml pulls and the path
  build.yml pushes have to be one string, so writing one by substitution
  and the other by hand guaranteed a first release nobody could install.
  Both now use the same two values, and `tests/compose.bats` asserts they
  agree. The remaining assumption — the GitHub repository is named after
  the project directory — is one the workflows already carried.

## Consequences

- Adding a deploy target later fills in a body (a `deploy-adapters/<name>/`
  directory and the `deploy` job's contents) rather than restructuring
  anything above it — the seams already exist.
- Today, a human still runs `install.sh` on the target host by hand; there
  is no automated path from a merged pull request to a running client
  instance.
- A generated project's first release is installable without an edit. Under
  the placeholder this bullet used to describe, it never was: the first
  release shipped a `compose.yaml` naming an image nothing had pushed, so
  every project needed a hand-edit and a second release before
  `install.sh` could work at all. `check_image_configured` remains as a
  safety net for a copy edited back to a placeholder, or carried over from
  a project generated before this changed: it greps the downloaded
  `compose.yaml`'s image line for a bare `CHANGEME` before starting the
  stack and says to edit the image line rather than let Docker's own error
  (`invalid reference format: repository name must be lowercase`, confirmed
  against a live daemon) be the only signal. That guard
  only exists in `install.sh` — a client who runs `docker compose up`
  directly against a project's working tree still gets Docker's own
  message, not this project's, though that message is already actionable.
- `install.sh`'s `RepoUrl` is a project-wide, not a per-release, edit: it
  changes once, when the repository is created, and never again — release
  tags are resolved through GitHub's `.../releases/latest/download/...`
  redirect, which `install.sh` never has to know a version number for.

## Alternatives considered

- **Shipping a `compose-vps` adapter now.** Rejected: premature — no client
  has asked for a VPS target yet, and building one now means guessing at
  requirements instead of responding to a real one.
- **Shipping a PaaS adapter now (Render, Fly.io, etc.).** Rejected: binds
  every client generated from this toolbox to one vendor's deploy model,
  for a decision that is the client's to make, not the toolbox's.
- **Parameterising the image repository through an environment variable**
  (`${IMAGE_REPOSITORY:-ghcr.io/changeme/app}`), matching how `IMAGE_TAG`
  works. Rejected: the repository path does not vary release to release
  the way the tag does — it is set once and never touched again, so a
  variable buys nothing a literal placeholder with a comment does not
  already give, at the cost of one more name to keep straight in `.env`.
