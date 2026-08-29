# Add an adapter

Time: about one session. Tier B when the smoke test lands; Tier A when a
real project depends on it.

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
# ADAPTER_POST_GENERATE='<one-time fixup for a real generator bug>'
```

`ADAPTER_POST_GENERATE` is optional — most adapters omit it. It's a
one-time shell command run right after the generator, for fixups the
generator itself gets wrong: `adapters/nestjs/adapter.env` sets it to
un-await `bootstrap()` and run prettier once. Only reach for it once
you've hit a real generator bug — it's a patch, not a default step.

## 3. Write `mise.toml`

All nine contract tasks. Declare the language in a local `[tools]` block so
it never reaches the project root. `format`, `lint`, and `check` must not
write.

## 4. Write `Dockerfile`, `.env.example`, `lefthook.fragment.yml`

The Dockerfile is multi-stage. Add a `HEALTHCHECK` only if you can make it
fail on a real broken state — a check that always passes is worse than no
check (see docs/tour/07). It must never copy a `.env` file. An adapter with
no extra git hook ships `{}` as its fragment.

## 5. Verify

```bash
scaffold lint
./scaffold new /tmp/probe --api <name>
cd /tmp/probe && mise run "//apps/api:checklist"
```

(the project root's own `mise run checklist` also runs this once
`register_config_root` picks it up — see `lib/project.sh` — but the
`//apps/api:` prefix runs only the new app, without waiting on every other
config root along with it.)

If `ADAPTER_LANGUAGE="typescript"`, that alone doesn't prove the thing
that has actually broken before: a *second* typescript app sharing the
same workspace. That happens on two different code paths, and only one
still carries a known, open gap.

**Via `scaffold new`** (both requested together — no known gap):

```bash
./scaffold new /tmp/probe2 --api <name> --web nextjs
```

**Via `scaffold add`** (joining a workspace that's already installed —
`cmd_add` relaxes `confirmModulesPurge` in `pnpm-workspace.yaml` then
strips the line back out by blind text match; if the caller had already
added that exact line themselves, on purpose, this silently deletes it
too — known, not fixed, see the comment above `reconcile=` in `scaffold`
and ADR-0017's Consequences):

```bash
./scaffold new /tmp/probe3 --api nestjs
cd /tmp/probe3 && scaffold add apps/<name> --adapter <name>
```

Either way, confirm the workspace itself, not just a green checklist —
this is the part that broke:

```bash
find /tmp/probe3 -name pnpm-lock.yaml -not -path '*/node_modules/*'
test -f /tmp/probe3/packages/types/package.json && echo "types package: ok"
grep confirmModulesPurge /tmp/probe3/pnpm-workspace.yaml   # expect no match
```

The first command must list exactly one lockfile, at the project root.

## 6. Add the smoke test

Copy `tests/new-laravel-api.bats`, change the adapter name, and keep the
assertion that the language never appears in the project's root
`mise.toml`.

## 7. Promote to Tier A

Change `ADAPTER_TIER` to `A` in `adapter.env`. Nothing in
`.github/workflows/adapters.yml` names an adapter directly — it reads tiers
from `scripts/adapter-matrix.sh`, which reads `ADAPTER_TIER` for every
adapter via `scaffold list` — so this one-line edit is the whole promotion
(ADR-0012).

## Done when

`scaffold lint` is silent, `bats tests/new-<name>.bats` passes, and
`scaffold list` shows the adapter with the intended tier.
