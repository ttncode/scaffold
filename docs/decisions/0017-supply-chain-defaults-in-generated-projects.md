# 0017 — supply-chain defaults in generated projects

Status: Accepted
Date: 2026-08-27

## Context

`packages/types` joins the pnpm workspace only after each app's own
generator has already run its own install — nothing else can know, before
every requested adapter has loaded, whether the project will end up
all-typescript. The contract's own `install` task is therefore always the
first `pnpm install --frozen-lockfile` to see every workspace member
together, and pnpm 11 has three defaults that turn that first frozen
install (and, for one of them, every later one too) into a non-interactive
failure:

- **`confirmModulesPurge`** — relinking `node_modules` for the new member
  needs pnpm to remove and rebuild it, and by default pnpm asks for
  confirmation before doing that. No contract task has a TTY to answer.
- **`allowBuilds`** — `unrs-resolver` (pulled in transitively by
  `typescript-eslint`) ships a native postinstall build. The first time
  pnpm links it in a workspace it treats an unapproved build script as a
  hard error, not the soft warning a re-run shows once it is already
  known.
- **`minimumReleaseAge`** — pnpm rejects a lockfile entry published within
  its default 1440-minute window. A generator's own lockfile can
  legitimately name a transitive dependency published hours earlier;
  established empirically that this check **re-applies on every future
  `--frozen-lockfile` install of the same lockfile**, not only the first
  one — a second, otherwise-idempotent frozen install, with nothing
  resolved and nothing to link, still re-verified and still failed on the
  same entries.

Two further, unrelated defects surfaced only once a real multi-app
workspace (`nestjs` + `nextjs` + `packages/types`) was exercised end to
end: `nextjs`'s own generator does not notice the ambient
`pnpm-workspace.yaml` `init_project` already wrote before it ran, and
writes an orphaned `apps/web/pnpm-lock.yaml` of its own (leaving `apps/web`
entirely absent from the root lockfile) plus its own nested
`apps/web/pnpm-workspace.yaml` (which shadows the real root one for any
task whose cwd is the app itself — every contract task's cwd). Both are
harmless for a standalone `nextjs` project and both broke a multi-app
workspace outright.

`common/pnpm-workspace.yaml` is copied verbatim into every project this
toolbox generates. Anything written there is a permanent, silent decision
made on a client's behalf, for a project no one is actively reviewing
months later — the bar for what belongs there is higher than "makes the
test pass."

## Decision

Judge each setting on what it costs a project that ships it, not only on
whether it clears the immediate failure:

- **`allowBuilds: { unrs-resolver: false }` ships in `common/pnpm-workspace.yaml`.**
  This matches the reference implementation's own house style (immich's
  `pnpm-workspace.yaml` carries the same kind of per-package `allowBuilds`
  map), the package has a pure-JS fallback, and denying one specific,
  named, native build is a narrow, auditable decision — not a blanket
  policy change.
- **`confirmModulesPurge` does not ship in `common/pnpm-workspace.yaml`.**
  It is set instead as `env = { npm_config_confirm_modules_purge = "false" }`
  on the `install` and `ci-unit` mise tasks, in every adapter's
  `mise.toml` and in `common/packages-types/mise.toml`. Scoped this way it
  unblocks only the unattended contract tasks; a developer running
  `pnpm install` by hand months later still gets pnpm's real interactive
  prompt before anything gets purged. Verified directly, both ways: the
  env var propagates correctly through a `mise run` task (confirmed by
  patching a task, forcing a fresh purge-requiring install, and observing
  no TTY-abort) and does *not* propagate through a bare `mise exec --`
  wrapper (confirmed independently; `mise exec` does not reliably forward
  ambient environment variables to the tool it launches — a fact this
  decision had to design around, not rely on, for `resolve_minimum_release_age`
  below).
- **`minimumReleaseAge: 0` does not ship anywhere, ever.** Lowering it
  permanently, silently, for every client project this toolbox will ever
  generate is exactly the outcome this decision exists to prevent — a
  scaffolding tool quietly turning off a supply-chain guard on a client's
  behalf, where no one will ever notice it happened. Since the check
  re-applies forever (established above), relaxing it only inside the
  generation path would not hold — the very next `pnpm install` a
  developer runs would fail again. Instead: `enable_typescript_workspace`
  is followed by `sync_workspace_lockfile` (which also deletes any stray
  per-app `pnpm-lock.yaml`/`pnpm-workspace.yaml` an adapter's own
  generator left behind, then runs one ordinary install — confirm-purge
  and release-age both relaxed only for this one in-process resolution,
  neither persisted — to produce a single, correct, root-level lockfile
  covering every workspace member) and then by
  `resolve_minimum_release_age`, which repeatedly runs a real, default
  frozen install (via `mise exec`, so it is checked against the exact
  pnpm version the contract tasks themselves will use — a bare `pnpm` call
  from `scaffold`'s own process resolves a different, unpinned system
  pnpm, confirmed by inspecting `.pnpm-workspace-state-v1.json`'s
  recorded `userAgent`) and, on a minimum-release-age failure, records the
  exact `name@version` entries pnpm names as too fresh into the
  *generated project's own* `pnpm-workspace.yaml`, under
  `minimumReleaseAgeExclude` — the same narrow, named-entry instrument
  immich itself uses. pnpm caps how many violations one failure message
  lists (`MAX_VIOLATIONS_TO_PRINT = 20`, alphabetically sliced, confirmed
  by reading pnpm's own bundled source), so a workspace large enough to
  have more than 20 violations reveals them in alphabetical batches across
  repeated rounds; the loop keeps excluding and retrying until pnpm has
  nothing left to flag, capped at 10 rounds so a genuinely different
  failure cannot loop forever. The guard stays fully live, at its real
  default, for every dependency the project adds from here on.

## Consequences

- A generated project's `pnpm-workspace.yaml` differs project to project:
  `allowBuilds` is fixed (from `common/`), but `minimumReleaseAgeExclude`
  is computed once, at generation time, and is specific to whatever was
  genuinely too fresh that day. Two `scaffold new` runs on different days
  can produce different exclude lists for the same adapters.
- `scaffold new` for an all-typescript project takes longer and needs the
  network more than before: `sync_workspace_lockfile` and
  `resolve_minimum_release_age` each run at least one more real `pnpm
  install` beyond what the adapters' own generators already did.
- `resolve_minimum_release_age`'s `mise exec` calls require `mise`
  to be able to install the project's pinned pnpm version on demand if it
  is not already cached locally — a cost every other pnpm invocation in
  this pipeline already pays.
- `minimumReleaseAgeExclude` names packages by exact version, not by name
  alone, and pnpm's own exclude-merging normalizes ranges — a future
  dependency bump that lands on a *different* version of an already-excluded
  package is not automatically covered; it would need its own (real, not
  toolbox-side) resolution the next time someone runs `pnpm install`
  against a lockfile that has moved on.
- `sync_workspace_lockfile`'s fix is generic (any stray per-app
  `pnpm-lock.yaml`/`pnpm-workspace.yaml` two directories under the project
  root is removed), not specific to `nextjs` — a future adapter with the
  same non-workspace-aware generator behavior is covered by the same code,
  without needing its own fix.
- `scaffold add` (task 8) hits a second instance of the same
  `confirmModulesPurge` problem this decision already named, in a place the
  task-scoped `env =` fix above cannot reach: adding a *second* typescript
  app to a project whose workspace is already installed makes the added
  adapter's own bundled `pnpm install` (`nest new`, `create-next-app` —
  not a mise task, so the `env =` task setting is not in scope) try to
  relink the existing shared `node_modules`, which pnpm treats as a purge
  and refuses non-interactively
  (`ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY`). `cmd_add` relaxes
  `confirmModulesPurge` the same way `resolve_minimum_release_age` relaxes
  minimum-release-age: appended to `pnpm-workspace.yaml` immediately before
  the adapter's generator runs, removed again immediately after (on both
  success and failure, via the same EXIT-trap cleanup that removes a failed
  add's directory), never left in the file handed to the caller. `cmd_add`
  then runs `sync_workspace_lockfile` and `resolve_minimum_release_age`
  again itself, so a second (or third, ...) app joining the workspace gets
  the same lockfile reconciliation and minimum-release-age recording the
  first round of apps got from `scaffold new`.

## Alternatives considered

- **Ship `minimumReleaseAge: 0` in `common/pnpm-workspace.yaml`.** Rejected
  outright — the exact outcome this decision exists to prevent.
- **Relax `minimumReleaseAge` only inside `ADAPTER_GENERATOR`/
  `ADAPTER_POST_GENERATE`, on the theory that the check is a one-time
  generation-time artifact.** Falsified empirically before being adopted:
  the check re-applies on every future frozen install of an unchanged
  lockfile, so a relaxation scoped to generation time would not survive
  past it.
- **`confirmModulesPurge: false` in `common/pnpm-workspace.yaml`.**
  Rejected: correct for the unattended contract tasks, wrong for a human
  running `pnpm install` by hand later, who should still see pnpm's real
  confirmation before anything gets purged. Scoping it to task `env`
  gives both.
- **Prompt-driven `minimumReleaseAgeStrict` / `pnpm approve-builds`
  auto-collection**, which pnpm ships for exactly this situation.
  Rejected after checking pnpm's own source: both require either a TTY or
  `--ci`-relative prompting logic that still throws (not auto-writes) in a
  non-interactive, non-CI-flagged context — not usable from a
  non-interactive generation pipeline as-is.
