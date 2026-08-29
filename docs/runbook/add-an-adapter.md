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
```

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
cd /tmp/probe && mise run checklist
```

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
