# `vite-react` and `hono` adapters — design

Date: 2026-10-14
Source request: `~/tmp/scaffold-request-vite-react-hono-adapters.md` (from the
`opensocial` project)

## Goal

`opensocial` runs a React SPA, a Hono API, a Python media worker and a Node
render service on an ~8 GB, 4-core machine, so it avoids Next.js and NestJS.
It will be generated with:

```bash
scaffold new opensocial --web vite-react --api hono --db postgres
cd opensocial
scaffold add workers/media   --adapter flask
scaffold add services/render --adapter hono
```

Success is the request's acceptance criteria 1–8, restated in
[Verification](#verification).

## Decisions taken while brainstorming

| Question | Decision |
| --- | --- |
| `scaffold add` repoints the compose `migrate` service at the last-added backend | Fix: an existing `migrate` service is kept; the first backend owns migrations |
| SPA config without a rebuild (ADR-0014 seam 2) | Caddy serves `GET /config.json` rendered from the container's environment |
| How the hono image runs Drizzle migrations | drizzle-orm's own `migrate()`, compiled to `dist/db/migrate.js`; `drizzle-kit` stays a devDependency |
| `scaffold add <dir>` of a TypeScript app outside the workspace globs deletes its lockfile | Fix: such an app stays standalone with its own lockfile |
| How hono's health routes reach the app | Overlay files, no `sed`: the overlay's `src/index.ts` replaces create-hono's 10-line entry |

## Facts checked during brainstorming

Run in a scratch directory on 2026-10-14:

- `pnpm create hono@0.19 h --template nodejs --pm pnpm --install </dev/null`
  exits 0 without prompting. Output: ESM (`"type": "module"`),
  `module: NodeNext`, `rootDir: ./src`, no `include`, `typescript@^7.0.2`, its
  own `pnpm-workspace.yaml` (`allowBuilds: esbuild`), `src/index.ts` listening
  on 3000.
- `typescript-eslint@8` peers `typescript >=4.8.4 <6.1.0`, so create-hono's
  TypeScript 7 cannot be linted. Latest 6.0 is `6.0.3`.
- create-vite is `9.2.1`. Its React templates default to oxlint; `--eslint`
  restores ESLint (ADR-0008). `pnpm create vite@9 v --template react-ts --eslint
  --no-immediate --no-interactive </dev/null` exits 0 without prompting and
  does not install. After `pnpm add -D prettier vitest`, `tsc -b` writes only
  `node_modules/.tmp/*.tsbuildinfo`, `eslint . --max-warnings 0` passes and
  `vite build` writes `dist/`. Template ships `typescript@~6.0.2`.
- drizzle-orm `0.45`'s `readMigrationFiles` throws `Can't find
  meta/_journal.json file` when the journal is absent.
- Not yet run: the Caddy runtime image (a Docker run was not permitted while
  brainstorming). The plan's first vite-react task proves it.

## 1. `adapters/hono`

`adapter.env`:

```bash
ADAPTER_NAME="hono"
ADAPTER_ROLE="api"
ADAPTER_TIER="A"
ADAPTER_LANGUAGE="typescript"
ADAPTER_FAMILY="hono"
ADAPTER_GENERATOR='pnpm create hono@0.19 "$APP_DIR" --template nodejs --pm pnpm --install </dev/null'
# ADAPTER_POST_GENERATE: the four steps below, joined with &&
ADAPTER_LIVENESS_PATH="/health/live"
ADAPTER_READINESS_PATH="/health/ready"
```

`0.19`, not a major: create-hono is pre-1.0, where a minor is the breaking
unit. `</dev/null` turns any new prompt into an EOF failure instead of a hang.

`ADAPTER_POST_GENERATE`, in order:

1. `pnpm add -D typescript@~6.0 prettier vitest eslint @eslint/js typescript-eslint`
   — TypeScript pinned below 6.1 for typescript-eslint.
2. `jq '.include = ["src"]'` into `tsconfig.json`, so a root-level
   `drizzle.config.ts` stays outside `rootDir`.
3. Guard: `grep` that `vitest`, `eslint` and `"typescript": "~6.0` are in
   `package.json` and `"include"` in `tsconfig.json`, else fail with a message
   naming the generator.
4. `pnpm exec prettier --write .`

Overlay files:

| File | Content |
| --- | --- |
| `src/index.ts` | `new Hono()`, `app.route('/health', health)`, `serve({ fetch, port: Number(process.env.PORT ?? 8080), hostname: '0.0.0.0' })` |
| `src/health.ts` | A `Hono` router. `GET /live` returns `{ status: 'ok' }`. `GET /ready` runs `// @DB_PROBE@` then `// @CACHE_PROBE@`, returns `{ status: 'ok' }`; any error is logged (it names host and user) and answered `503 { status: 'unavailable' }`. With no database the shipped body throws `no database is configured for this project`, matching nestjs and flask |
| `src/health.test.ts` | `app.request('/health/live')` is 200; `/health/ready` with no database is 503 |
| `eslint.config.js` | `@eslint/js` recommended + `typescript-eslint` recommended, ignores `dist` |
| `mise.toml` | The nine contract tasks plus `migrate` (below) |
| `Dockerfile`, `Dockerfile.workspace` | Below |
| `.dockerignore` | As `adapters/nestjs` |
| `.env.example` | `PORT=8080` |
| `lefthook.fragment.yml` | `{}` |
| `.prettierignore` | `dist`, `drizzle/meta` |

Relative imports carry `.js` suffixes (`NodeNext`).

`mise.toml` tasks: `install` (with the `npm_config_confirm_modules_purge`
env, as nestjs), `format` = `prettier --check .`, `format-fix`, `lint` =
`eslint . --max-warnings 0`, `check` = `tsc --noEmit`, `test` = `vitest --run`,
`build` = `tsc`, `ci-unit`, `checklist`, and `migrate`:
`if [ -f drizzle.config.ts ]; then pnpm exec drizzle-kit migrate; fi`.

`Dockerfile` (standalone) and `Dockerfile.workspace`: `node:24.15.0-alpine`
pinned by the digest the other adapters use. Build stage installs with
`--frozen-lockfile`, carries `# @SERVICE_SETUP@`, runs `tsc`, prunes to
production dependencies. Runtime stage: `NODE_ENV=production`, production
`node_modules`, `dist/`, and `drizzl[e]` (copies nothing without a SQL
database), `USER node`, `ENV PORT=8080`, `EXPOSE 8080`, `HEALTHCHECK` on
`http://127.0.0.1:8080/health/live`, `CMD ["node", "dist/index.js"]`. In both
variants the runtime `WORKDIR` is the app's own directory, so the migrate
command is one path for both shapes.

Compiled `dist/health.test.js` is inert in the image (vitest is pruned); not
worth a second tsconfig.

## 2. Hono service drivers

`services/shared/hono.sh` holds the Drizzle body; `services/{postgres,mysql}/drivers/hono.sh`
set parameters and source it, as `services/shared/nest.sh` does.
`services/{redis,mongodb}/drivers/hono.sh` are self-contained.

| Service | `service_driver_apply` | Probe spliced at its anchor | `compose_env` | `compose_migrate` |
| --- | --- | --- | --- | --- |
| postgres | `drizzle-orm` `pg`; dev `drizzle-kit` `@types/pg` | ``await db().execute(sql`select 1`)`` | `DATABASE_URL`, same override-then-compose shape as `services/postgres/drivers/nest.sh`, `database:5432` | `command: ["node", "dist/db/migrate.js"]` |
| mysql | `drizzle-orm` `mysql2`; dev `drizzle-kit` | same | same shape, `mysql://`, `database:3306` | same |
| redis | `redis` | `await (await cache()).ping()` | `REDIS_URL: ${REDIS_URL:-redis://:${REDIS_PASSWORD}@cache:6379}` | none |
| mongodb | `mongodb` | `await (await mongo()).db().command({ ping: 1 })` | `DATABASE_URL` with `authSource=admin` | none: no schema |

The Drizzle body writes:

- `src/db/client.ts`: a lazily created, module-level pool and `drizzle()`
  instance (one pool per process, not per poll; see the nest driver's
  connection-leak comment).
- `src/db/schema.ts`: empty, exported; models belong to the client.
- `src/db/migrate.ts`: `migrate(db, { migrationsFolder: 'drizzle' })` from
  `drizzle-orm/node-postgres/migrator` or `drizzle-orm/mysql2/migrator`, then
  closes the pool.
- `drizzle.config.ts`: dialect, `schema: './src/db/schema.ts'`, `out: './drizzle'`,
  `dbCredentials.url` from `DATABASE_URL`.
- `drizzle/meta/_journal.json`: `{"version":"7","dialect":"<dialect>","entries":[]}`,
  so `migrate()` succeeds on a fresh project and `drizzle-kit generate` appends.
- `DATABASE_URL` into `.env.example` through `write_env_lines`.

The redis and mongodb drivers write a lazily connected client module
(`src/cache.ts`, `src/db/mongo.ts`) the same way. Each driver splices the
import at `// @DB_CLIENT@` (or `// @CACHE_CLIENT@`) and the probe at its probe
anchor, removes the no-database throw only for a database, and asserts the
splice with `grep` checks in the shape of `assert_nest_probe_spliced`, then
runs prettier on `src/health.ts`.

The hono readiness pings redis; the nestjs and flask readiness routes do not.
This follows the request and is recorded in the hono ADR, not back-ported.

`service_driver_dockerfile` prints nothing for all four.

## 3. `adapters/vite-react`

```bash
ADAPTER_NAME="vite-react"
ADAPTER_ROLE="web"
ADAPTER_TIER="A"
ADAPTER_LANGUAGE="typescript"
ADAPTER_FAMILY="vite"
ADAPTER_GENERATOR='pnpm create vite@9 "$APP_DIR" --template react-ts --eslint --no-immediate --no-interactive </dev/null'
ADAPTER_POST_GENERATE='pnpm add -D prettier vitest && { grep -q "\"vitest\"" package.json && grep -q "\"prettier\"" package.json || { echo "post-generate: prettier or vitest missing from package.json after pnpm add" >&2; exit 1; }; } && pnpm exec prettier --write .'
ADAPTER_LIVENESS_PATH="/health/live"
```

Overlay files:

| File | Content |
| --- | --- |
| `Caddyfile` | Global `admin off`, `auto_https off`, `persist_config off`. Site `:8080`: `handle /health/live { respond "ok" 200 }`; `handle /config.json` responds `{"apiUrl":"{$API_URL:}"}` with `Content-Type: application/json` and `Cache-Control: no-store`; `handle { root * /srv; try_files {path} /index.html; file_server }` |
| `public/config.json` | `{"apiUrl":"http://localhost:8081"}` for `vite dev`; Caddy's route shadows it in the image |
| `src/config.ts` | `loadConfig(): Promise<{ apiUrl: string }>` fetching `/config.json` once. The template's `App` is left alone; this is the seam |
| `src/config.test.ts` | `loadConfig` parses a stubbed fetch |
| `mise.toml` | `install`, `format`, `format-fix`, `lint` = `eslint . --max-warnings 0`, `check` = `tsc -b`, `test` = `vitest --run`, `build` = `vite build` (`tsc -b` already ran in `check`), `ci-unit`, `checklist` |
| `Dockerfile`, `Dockerfile.workspace` | Node stage installs and runs `vite build`. Runtime: `caddy:2-alpine` pinned by digest, `Caddyfile` → `/etc/caddy/Caddyfile`, `dist/` → `/srv`, `XDG_CONFIG_HOME`/`XDG_DATA_HOME` under a writable dir, a non-root `USER`, `EXPOSE 8080`, `HEALTHCHECK` with busybox `wget` on `http://127.0.0.1:8080/health/live`. No Node in the runtime image. The Node stage carries `# @SERVICE_SETUP@` (web takes no driver, but `apply_service_dockerfile` requires the anchor) |
| `.dockerignore` | As `adapters/nextjs` |
| `.env.example` | `API_URL=` (runtime, read by Caddy; empty means same origin). A comment: only `VITE_*` variables reach client code, and they are baked in at build time, so anything that differs per environment goes through `/config.json` instead (ADR-0014) |
| `lefthook.fragment.yml` | `{}` |
| `.prettierignore` | `dist` |

`{$API_URL:}` is substituted when Caddy loads its config at container start,
so one image serves every environment. The value is not HTML/JS-escaped; it
comes from the operator, not a visitor.

## 4. Toolbox fixes

1. **`migrate` keeps its first owner.** `apply_service_compose_migrate`
   (`lib/service.sh`) returns early when `compose.yaml` already has
   `services.migrate`. The code comment there ("nothing generates that
   shape") is corrected. ADR-0022 gets an amendment note.
2. **A TypeScript app outside the workspace globs stays standalone.**
   `joins_shared_workspace` (`scaffold`) additionally requires
   `app_is_workspace_member "$project" "$rel"`. Its signature gains `rel`.
   ADR-0018 gets an amendment note: such an app cannot import
   `packages/types`; place it under `apps/` for that.

Neither changes a role rule, ADR-0018's "add does not recompute", or adds a
role.

## 5. Tests

- `tests/new-hono.bats`, `tests/new-vite-react.bats`: copied from
  `tests/new-laravel-api.bats` per the runbook, including the assertion that
  the language never reaches the root `mise.toml`. Plus: hono with
  `--db postgres` writes `drizzle/meta/_journal.json` and splices the probe;
  vite-react's `Caddyfile` has the `/health/live` and `/config.json` routes.
- `tests/add-app.bats`: an added second backend leaves `migrate.image`
  unchanged; `scaffold add services/x --adapter nestjs` (the cheapest TS api)
  into an all-TypeScript project keeps `services/x/pnpm-lock.yaml`.
- `tests/mixed-project.bats`: runs the four `opensocial` commands verbatim and
  asserts each "already supported" claim: `packages/types/package.json`
  survives, one root lockfile for `apps/*`, `services/render` has its own
  lockfile, no `confirmModulesPurge` in `pnpm-workspace.yaml`, two `api`-role
  apps recorded, `migrate.image` still names `apps/api`'s image, and the root
  `mise.toml` pins node `24.15.0`.

Compose health (criteria 5 and 6) is verified by hand with probe projects;
`tests/compose.bats` gains only the static checks it already makes for the
new Dockerfiles (no `.env` copied).

## 6. Docs and ADRs

- ADR 0025 (new) — The `vite-react` runtime is Caddy serving static files, with
  runtime config at `/config.json`. Alternatives: nginx-unprivileged,
  build-time `VITE_*` only, same-origin `/api` behind a proxy.
- ADR 0026 (new) — `hono` talks to SQL databases through Drizzle, migrated by
  drizzle-orm's own migrator; redis and mongodb through their official
  clients; readiness also pings the cache. Alternatives: Prisma (as nestjs),
  `drizzle-kit migrate` in the runtime image, Drizzle for mongodb (not
  supported).
- Amendment notes on ADR-0018 and ADR-0022 for section 4.
- `docs/tour/08-adapters.md`: a section "Mixed TypeScript + Python project
  with shared types" — the `opensocial` order of operations, why `new`
  all-TypeScript first keeps `packages/types`, why `add` of the Python app
  second does not recompute it (ADR-0018), and that a TypeScript app needing
  shared types belongs under `apps/`.
- README and `docs/tour/08-adapters.md` adapter lists gain the two adapters.
- ADRs are checked with `common/docs/scripts/check-adrs.mjs` pointed at
  `docs/decisions` (the request's `docs/scripts/` path does not exist).

## Verification

| # | Criterion | How |
| --- | --- | --- |
| 1 | `./scaffold lint` prints nothing, exits 0 | run |
| 2 | `./scaffold list --adapters` shows both, Tier A | run |
| 3 | Runbook "Verify" for each adapter, including the second-TypeScript-app checks | run per adapter |
| 4 | `bats tests/new-vite-react.bats tests/new-hono.bats` | run |
| 5 | Probe `--web vite-react --api hono --db postgres`: both checklists pass; `docker compose up` healthy; `curl` web `/health/live` and api `/health/ready` 200; stop `database`, `/health/ready` 503 | by hand |
| 6 | Mixed-project commands clean, `packages/types` survives, `media` and `render` healthy in compose | `tests/mixed-project.bats` plus by hand |
| 7 | `.github/workflows/adapters.yml` picks both up with no edit | `scripts/adapter-matrix.sh` output |
| 8 | New ADRs pass the checker | run |

Probe projects are deleted afterwards.

## Out of scope

As the request: no reverse proxy, no opensocial libraries (Better Auth, DBOS,
Zod), no `worker` role, no Bun/Deno. Not back-ported: cache readiness for
nestjs and flask.
