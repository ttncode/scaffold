# 0022 — One image per application

Status: Accepted
Date: 2026-09-11

## Context

`scaffold new --web nextjs --api nestjs` generates two applications. Both
join `config_roots`, both run the nine-task contract, both go green in CI.
Exactly one of them was ever built into an image.

`set_image_context` wrote one `context`/`dockerfile` pair into `build.yml`
and `release.yml`, and every applied adapter overwrote the previous one, so
the last role applied won. `compose.yaml` shipped a single `app` service
naming a single image. The rest of the project — the web application, in the
common case — passed every check and then disappeared: never built, never
pushed, never in the file a client actually runs.

This was visible in the code and acknowledged in the product: `cmd_wizard`
printed a note saying "web and api still share one build image — whichever
adapter is applied last wins the build context," immediately after offering
`web+api` as the first shape on the first screen. A note is not a design.
Measured on a real repository (`ttncode/acme-portal`, generated from
`--web nextjs --api nestjs --db postgres --cache redis`): all five workflows
green, `ghcr.io/ttncode/acme-portal` published with tags `main` and
`sha-57b1aa9`, and nothing anywhere that had built `apps/web`.

## Decision

A project publishes one image per application, and `compose.yaml` runs one
service per application.

**Naming.** The compose service and the image suffix are both the
application's own directory name: `apps/web` is the service `web` and the
image `ghcr.io/<owner>/<project>-web`. The directory name is what
`scaffold add` already lets a caller choose freely, and what a workspace
Dockerfile's `pnpm --filter` already binds to, so it is the one name that is
correct for an application placed at `apps/worker` as much as for one at
`apps/api`. A role would not be: `scaffold add` does not take one.

Applied without a special case for the single-application project. Its image
becomes `<project>-api` rather than `<project>`, which is a change; two
naming rules that depend on how many applications a project happens to have
is a worse one, and nothing regenerates an already-generated project, so no
existing project is affected.

**Ports.** Each application service publishes a host port from its own
`<NAME>_PORT` variable in `example.env`, allocated in application order from
8080 upward: `WEB_PORT=8080`, `API_PORT=8081`. Allocation rather than a fixed
port per role, because `scaffold add` can place any number of applications at
any path — a table keyed on role runs out at three entries and cannot answer
for the fourth.

**No bundled reverse proxy.** A client fronting these with Caddy, Traefik,
nginx or their existing load balancer is making an infrastructure decision
that is theirs, and they are already making it for TLS. Shipping one would be
the same mistake ADR-0014 declines to make with deploy targets. The ports are
the seam.

**The fan-out lives in the reusable workflow.** `app-build.yml` and
`app-release.yml` in `you/.github` take an `images` array and matrix over it;
the generated `build.yml` and `release.yml` stay single call sites that pass
the array. The alternative — one call-site job per application — is possible
for `build.yml` and impossible for `release.yml`, whose `release-please` and
`assets` jobs must run exactly once per merge. Calling it per application
would cut a release per application.

Those two workflows keep the singular `image`/`context`/`dockerfile` inputs
they took before, resolved into the same matrix, so moving `v1` does not
break a project generated earlier. Passing both shapes is refused rather
than silently preferring one.

## Consequences

- A `web+api` project is deployable. The wizard's first and most common shape
  produces two images and a `compose.yaml` that runs both, and the note
  apologising for it is gone.
- A single-application project's image name changes from
  `ghcr.io/<owner>/<project>` to `ghcr.io/<owner>/<project>-<app>`. Only
  projects generated from this commit onward are affected; an existing
  project keeps the files it was generated with, which is exactly the gap
  ADR-0005 exists to describe and a future `scaffold update` will have to
  close.
- A release publishes N images and one set of release assets. Build time
  grows roughly linearly with applications; the GHA layer cache is scoped per
  image so they do not evict each other.
- `install.sh` reports one URL per application rather than one for the
  project.
- The migrate service runs the image of the first application whose role
  takes a database driver. A project with two backends would need a
  migration story per backend; nothing generates that shape today, and
  inventing one now would be the speculative work this repository keeps
  declining.
- `v1` in `you/.github` moves, which reaches every generated project at once.
  Accepted under ADR-0005's terms and for the reason recorded there; the
  change is additive to the inputs, and the smoke path was run against a real
  repository before the tag moved.

## Alternatives considered

- **One image containing every application.** Rejected: it needs a process
  manager in the container, discards the per-application Dockerfiles every
  adapter already ships, and makes scaling or rolling back one application
  impossible without doing it to all of them.
- **A bundled Caddy service routing `/` and `/api`.** Rejected above: the
  proxy is the client's decision, and a generated one becomes a file they
  must edit and keep in step with a `compose.yaml` that install.sh
  overwrites on every run.
- **Keeping one image and refusing multi-application shapes.** Rejected: the
  shapes are the point of a monorepo generator, and the wizard offers
  `web+api` first because it is what clients ask for.
- **A fixed port per role** (`web` 8080, `api` 8081, `app` 8082). Rejected:
  `scaffold add` places applications at arbitrary paths with no role at all,
  so the table cannot answer for them.
