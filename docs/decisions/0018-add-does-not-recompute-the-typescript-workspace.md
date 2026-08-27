# 0018 — `scaffold add` does not recompute the typescript workspace

Status: Accepted
Date: 2026-08-27

## Context

`scaffold new` decides, once, whether a project is all-typescript: if
every requested adapter's `ADAPTER_LANGUAGE` is `typescript`,
`enable_typescript_workspace` moves `packages-types` into
`packages/types`, registers it as a config root, and keeps
`pnpm-workspace.yaml`; otherwise both are removed outright
(`rm -rf "${target}/packages-types" "${target}/pnpm-workspace.yaml"`) —
see `lib/project.sh`'s `cmd_new`.

`scaffold add` installs one more adapter into a project that already made
that decision. Its choice of adapter can contradict the inputs the
decision was originally made from in either direction:

- a project created all-typescript (so `packages/types` exists and is
  live in the pnpm workspace) can have a non-typescript adapter (e.g.
  `laravel-api`) added to it, making the project mixed-language while
  `packages/types` remains;
- a project created mixed (so `packages-types` was deleted at generation
  time and `packages/types` never existed) can have a typescript adapter
  added to it, without ever becoming "all typescript" by the same rule
  `cmd_new` used, because that rule was evaluated once and is not
  re-evaluated.

## Decision

`scaffold add` leaves the typescript-workspace decision exactly as
`scaffold new` made it. It does not delete `packages/types` when a
non-typescript adapter is added, and it does not create `packages/types`
retroactively when an added adapter happens to be typescript.

## Rationale

- **Recompute-and-remove is destructive.** By the time `scaffold add`
  runs, any existing typescript app may already depend on
  `packages/types` via the workspace protocol (`"@types/shared":
  "workspace:*"` or similar) and have that dependency resolved into its
  own `node_modules`. Deleting `packages/types` because the project is now
  "mixed" would silently break every app that already relies on it — a
  far worse outcome than a project that is mixed but still fully
  functional. `scaffold add` has no reliable way to check "does anything
  already import this" from the manifest alone, and guessing wrong here
  is a build break for the client's *existing* code, months after
  `scaffold new` ran and nobody is reviewing the diff.
- **Recompute-and-create replays `cmd_new`'s pipeline for a case nobody
  asked for.** Creating `packages/types` after the fact needs the
  `packages-types` template `scaffold new` already deleted for a mixed
  project (there is nothing to `mv`), a fresh `pnpm-workspace.yaml`,
  `sync_workspace_lockfile`, and `resolve_minimum_release_age` — most of
  `cmd_new`'s typescript-specific machinery, run again, to retrofit a
  feature (shared types) the caller did not request. `scaffold add`'s
  contract is "install one adapter, re-sync CI" (task 8's brief); turning
  it into a workspace-policy re-evaluator is scope well beyond that, and
  the six-week-later feature growth this command exists for ("a client's
  scope grows... they want a worker, or a second service") is about
  adding an app, not about re-deciding how apps share code.
- **Leaving it alone is the only option that keeps `scaffold add` a small,
  mechanical, additive operation** — which is also what the CI-diff
  contract (task 8's own test: adding an app touches exactly one line of
  `ci.yml`) is arguing for at the process level. A command that sometimes
  also deletes a package or replays a multi-step lockfile pipeline,
  depending on what adapter you pick, is a much harder command to reason
  about than one that always does the same small thing.

## Consequences

- A project can end up mixed-language with `packages/types` still present
  and still valid for its original typescript apps. This is not a defect;
  `packages/types` exists to share types between typescript apps in the
  workspace, and it can keep doing that for however many of them there
  are, even after a non-typescript app joins the project.
- A project created mixed never gains a shared types package through
  `scaffold add`, even if every adapter added after the fact happens to
  be typescript. Setting up type sharing after the fact is a manual step
  (or a future, explicitly-requested command) — `scaffold add` will not
  do it implicitly.
- `scaffold add apps/worker --adapter nestjs` into an all-typescript
  project installs into the existing `pnpm-workspace.yaml` glob without
  `scaffold add` touching that file at all: the workspace's own package
  glob (e.g. `apps/*`) already covers a new directory under `apps/`, so
  the new app participates in the existing workspace's install/lockfile
  the next time someone runs `pnpm install`, with no extra step from
  `scaffold add`.

## Alternatives considered

- **Recompute and remove `packages/types` when the project becomes
  mixed.** Rejected: destroys a package other apps may already depend on;
  see Rationale.
- **Recompute and create `packages/types` when the project becomes
  all-typescript again.** Rejected: not possible in general (the source
  template is already deleted for a project that started mixed) and, even
  where possible, replays most of `cmd_new`'s typescript pipeline for a
  case outside `scaffold add`'s stated scope.
- **Warn, but do nothing.** Considered and dropped as unnecessary noise:
  the "leave it alone" behavior is already the correct, final state in
  every case above, not a stopgap pending a follow-up action from the
  caller.
