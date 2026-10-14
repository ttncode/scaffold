# `vite-react` and `hono` Adapters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `vite-react` web adapter and a `hono` api adapter (with Drizzle, redis and mongodb drivers), fix two `scaffold add` bugs the `opensocial` command sequence hits, and document the mixed TypeScript + Python shape.

**Architecture:** Each adapter is a directory under `adapters/` that runs the framework's own generator and overlays files (ADR-0003). Hono's database wiring lives in `services/<service>/drivers/hono.sh`; the two SQL drivers share a parameterised body in `services/shared/hono.sh`, the same pattern as `services/shared/nest.sh`. The SPA's runtime is Caddy serving `dist/`, with runtime config at `/config.json`.

**Tech Stack:** bash 4 + bats, mise, pnpm, yq/jq, create-hono 0.19, create-vite 9, Hono 4 on `@hono/node-server`, Drizzle ORM 0.45 / drizzle-kit 0.31, `pg` 8, `mysql2` 3, `redis` 6, `mongodb` 7, Caddy 2.11.7, Node 24.15.0.

**Spec:** `docs/superpowers/specs/2026-10-14-vite-react-hono-adapters-design.md`

## Global Constraints

- Every base image is pinned by digest. Node: `node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f`. Caddy: `caddy:2.11.7-alpine@sha256:d8542f48d34a9cf4e4c11a478865229840e87e4c96ea3f439101f31a5d35f75f`.
- Generators: `pnpm create hono@0.19 …` and `pnpm create vite@9 …`, each with `</dev/null` so a new prompt fails instead of hanging.
- Hono pins `typescript@~6.0`: `typescript-eslint@8` peers `typescript <6.1.0`, and create-hono installs 7.
- Every Dockerfile: multi-stage, `EXPOSE 8080`, `HEALTHCHECK` on `http://127.0.0.1:8080<ADAPTER_LIVENESS_PATH>`, non-root `USER`, never copies `.env`, carries the `# @SERVICE_SETUP@` anchor in its build stage.
- `format`, `lint`, `check` tasks never write (`--write`, `--fix`, `-w`, `--in-place`, `--overwrite` are rejected by `scaffold lint`).
- Hono TypeScript is ESM (`module: NodeNext`): relative imports end in `.js`. All generated TypeScript uses prettier's default style (double quotes), because post-generate runs `prettier --write .` with no config and the drivers match the formatted text.
- A web-role adapter takes no driver.
- Comment density matches the repo: a comment only for a why, a landmine, or a deliberate omission.
- Scripts pass `shellcheck` and `shfmt -i 2 -ci` (the repo's pre-commit `lint` hook runs both).
- Commits follow Conventional Commits (commitlint runs in the `commit-msg` hook).

## Review Focus

1. **The database goes away while the api runs.** `/health/ready` must return 503 and the process must stay up. pg re-emits an idle client's failure on the pool, and that kills Node unless the pool has an `"error"` listener (Task 4 adds the listener; Task 8 stops the database by hand).
2. **A dependency is unreachable when `/health/ready` is called.** It must answer 503 within a few seconds, not hang. node-redis queues commands and retries forever by default, and mongodb waits 30 s for server selection. Task 3 ships `src/health.test.ts`, and the drivers keep it valid: with every URL pointing at `127.0.0.1:1`, `/ready` returns 503 within vitest's 5 s timeout, for every service combination (Tasks 4 and 5 run `ci-unit` per driver).
3. **A second backend added later.** `migrate` must keep pointing at the first backend's image (Task 1).
4. **A TypeScript app added outside `apps/`.** It must keep its own lockfile and install (Task 2).
5. **The SPA deep link.** `GET /some/client/route` must serve `index.html` with 200. `/health/live` must answer even if `index.html` were missing. `/config.json` must reflect the container's `API_URL` without a rebuild (Task 6 checks all three on the built image).

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `lib/service.sh` (modify) | `apply_service_compose_migrate`: keep an existing `migrate` service |
| `scaffold` (modify) | `joins_shared_workspace`: also require workspace membership |
| `adapters/hono/` (create) | `adapter.env`, `mise.toml`, `Dockerfile`, `Dockerfile.workspace`, `.dockerignore`, `.env.example`, `.prettierignore`, `eslint.config.js`, `lefthook.fragment.yml`, `src/index.ts`, `src/health.ts`, `src/health.test.ts` |
| `services/shared/hono.sh` (create) | Drizzle driver body, plus `splice_hono_anchor` / `assert_hono_spliced` used by all four hono drivers |
| `services/{postgres,mysql}/drivers/hono.sh` (create) | Drizzle parameters, then source the shared body |
| `services/{redis,mongodb}/drivers/hono.sh` (create) | Self-contained; source the shared body only for the splice helpers |
| `adapters/vite-react/` (create) | `adapter.env`, `mise.toml`, `Caddyfile`, `Dockerfile`, `Dockerfile.workspace`, `.dockerignore`, `.env.example`, `.prettierignore`, `lefthook.fragment.yml`, `public/config.json`, `src/config.ts`, `src/config.test.ts` |
| `tests/add-app.bats` (modify) | Tests for Tasks 1 and 2 |
| `tests/new-hono.bats`, `tests/new-vite-react.bats`, `tests/mixed-project.bats` (create) | Adapter and mixed-project suites |
| `docs/decisions/0025-…`, `0026-…` (create); `0018-…`, `0022-…` (amend) | Decisions |
| `docs/tour/08-adapters.md`, `README.md` (modify) | Adapter list, mixed-project section |

---

### Task 1: `migrate` keeps its first owner

**Files:**
- Modify: `lib/service.sh` (`apply_service_compose_migrate`, and the comment above its call in `apply_service_drivers`)
- Modify: `docs/decisions/0022-one-image-per-application.md` (append an amendment above `## Alternatives considered`)
- Test: `tests/add-app.bats`

**Interfaces:**
- Produces: `apply_service_compose_migrate <project> <service> <env_block> <command>`, unchanged signature; now a no-op when `services.migrate` exists.

- [ ] **Step 1: Write the failing test.** Append to `tests/add-app.bats`. Its `setup()` already generates `scaffold new "$PROJECT" --api nestjs`, whose default database (ADR-0020) gives it a `migrate` service.

```bash
@test "add keeps the migrate service on the first backend's image" {
  cd "$PROJECT"
  local before
  before="$(yq '.services.migrate.image' compose.yaml)"
  [[ "$before" == *"-api:"* ]]

  run scaffold add apps/worker --adapter nestjs
  assert_ok

  # merge_compose_fragment's `*` overwrote the image and command, so migrations
  # ran against whichever backend was added last, and still exited 0.
  run yq '.services.migrate.image' compose.yaml
  [ "$output" = "$before" ]
}
```

- [ ] **Step 2: Run it and confirm it fails.**

Run: `bats tests/add-app.bats -f "first backend"`
Expected: FAIL. `$output` names `…-worker:${IMAGE_TAG:-latest}`.

- [ ] **Step 3: Implement.** In `lib/service.sh`, `apply_service_compose_migrate`, after `[[ -f "$file" ]] || die …`:

```bash
  # ADR-0022: the first backend owns migrations; a later `scaffold add` must not
  # repoint the service at its own image.
  yq -e '.services.migrate' "$file" >/dev/null 2>&1 && return 0
```

In `apply_service_drivers`, replace:

```bash
  # Runs the first driven application's image; a second backend would need its
  # own migrate service, and nothing generates that shape (ADR-0022).
```

with:

```bash
  # A no-op when a migrate service exists: the first driven application keeps
  # it (ADR-0022).
```

- [ ] **Step 4: Run the test and the neighbouring suites.**

Run: `bats tests/add-app.bats tests/service.bats`
Expected: all PASS.

- [ ] **Step 5: Amend ADR-0022.** Insert before `## Alternatives considered`:

```markdown
**Amended 2026-10-14.** `scaffold add` of a second backend no longer repoints
`migrate`: `apply_service_compose_migrate` keeps an existing service, so the
first backend owns migrations. An added backend that needs its own runs them
itself; no second migrate service is generated.
```

- [ ] **Step 6: Commit.**

```bash
git add lib/service.sh tests/add-app.bats docs/decisions/0022-one-image-per-application.md
git commit -m "fix(add): keep the migrate service on the first backend"
```

---

### Task 2: A TypeScript app outside the workspace globs stays standalone

**Files:**
- Modify: `scaffold` (`joins_shared_workspace` at ~line 456, and its caller in `cmd_add` at ~line 538)
- Modify: `docs/decisions/0018-add-does-not-recompute-the-typescript-workspace.md` (append an amendment after the existing 2026-09-17 one)
- Test: `tests/add-app.bats`

**Interfaces:**
- Consumes: `app_is_workspace_member <project> <rel>` (`lib/pnpm.sh:43`, existing).
- Produces: `joins_shared_workspace <project> <rel> <adapter>`. The `rel` argument is new.

- [ ] **Step 1: Write the failing test.** Append to `tests/add-app.bats`:

```bash
@test "a typescript app added outside the workspace globs keeps its own lockfile" {
  cd "$PROJECT"
  run scaffold add services/worker --adapter nestjs
  assert_ok

  # services/* is not a workspace glob: reconciling the workspace deleted this
  # lockfile, and the root install never covered the app.
  [ -f "${PROJECT}/services/worker/pnpm-lock.yaml" ]
  run grep -c -- '--filter' "${PROJECT}/services/worker/Dockerfile"
  [ "$output" = "0" ]
  run mise run //services/worker:install
  assert_ok
}
```

- [ ] **Step 2: Run it and confirm it fails.**

Run: `bats tests/add-app.bats -f "outside the workspace globs"`
Expected: FAIL at the `pnpm-lock.yaml` check.

- [ ] **Step 3: Implement.** Replace `joins_shared_workspace` in `scaffold`:

```bash
# Keyed on membership, not on the file existing: a mixed-language project keeps
# a settings-only file, and an app outside the globs keeps its own lockfile;
# reconciling either would delete per-app lockfiles.
joins_shared_workspace() {
  local -r project="$1" rel="$2" adapter="$3"

  app_is_workspace_member "$project" "$rel" && adapter_is_typescript "$adapter"
}
```

In `cmd_add`, change the call to `joins_shared_workspace "$project" "$rel" "$adapter" && reconcile=1`. `app_is_workspace_member` already returns 1 when the file or its `packages:` key is absent, so the old two checks are covered.

- [ ] **Step 4: Run the whole add suite.** The mixed-language test at line ~49 must still pass.

Run: `bats tests/add-app.bats tests/add-app-errors.bats tests/pnpm.bats`
Expected: all PASS. If `mise run //services/worker:install` fails with a release-age or `allowBuilds` error, the standalone path is missing `sync_standalone_build_policy`. Call `sync_standalone_build_policy "${project}/${rel}" "$project"` from `reconcile_standalone_app` for a TypeScript adapter (it is `lib/pnpm.sh:223`'s call, which `new` already makes), then re-run.

- [ ] **Step 5: Amend ADR-0018.** After the existing amendment block:

```markdown
> **Amended 2026-10-14.** A TypeScript app added outside the workspace globs
> (`scaffold add services/render --adapter hono`) stays standalone with its own
> lockfile: `joins_shared_workspace` requires `app_is_workspace_member`. Such an
> app cannot import `packages/types`; place it under `apps/` for that.
```

- [ ] **Step 6: Commit.**

```bash
git add scaffold tests/add-app.bats docs/decisions/0018-add-does-not-recompute-the-typescript-workspace.md
git commit -m "fix(add): keep a typescript app outside the workspace standalone"
```

---

### Task 3: `hono` adapter, no database

**Files:**
- Create: `adapters/hono/adapter.env`, `mise.toml`, `Dockerfile`, `Dockerfile.workspace`, `.dockerignore`, `.env.example`, `.prettierignore`, `eslint.config.js`, `lefthook.fragment.yml`, `src/index.ts`, `src/health.ts`, `src/health.test.ts`
- Test: `tests/new-hono.bats`

**Interfaces:**
- Produces, used by Tasks 4 and 5: `src/health.ts` after prettier contains these lines, each alone on its line, in this order:
  - `// @DB_CLIENT@`
  - `// @CACHE_CLIENT@`
  - `// @CACHE_PROBE@`
  - `// @DB_PROBE@`
  - `throw new Error("no database is configured for this project");`
- Produces: the `migrate` task in `mise.toml`, and runtime `WORKDIR` equal to the app directory in both Dockerfiles, so `node dist/db/migrate.js` resolves.

`scaffold lint` reports missing `hono` drivers until Task 5. That is expected; tests here use `--db none`.

- [ ] **Step 1: Write the failing tests.** `tests/new-hono.bats`:

```bash
setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
}

teardown() {
  remove_workdir "$WORKDIR"
}

@test "hono generates an app at apps/api" {
  run scaffold new "$PROJECT" --api hono --db none
  assert_ok
  [ -f "${PROJECT}/apps/api/package.json" ]
  [ -f "${PROJECT}/apps/api/src/health.ts" ]
  [ -f "${PROJECT}/apps/api/mise.toml" ]
}

@test "hono adds no tool to the project root" {
  scaffold new "$PROJECT" --api hono --db none
  [ "$(yq -p toml -oy '.tools' "${PROJECT}/mise.toml")" = \
    "$(yq -p toml -oy '.tools' "${SCAFFOLD_ROOT}/common/mise.root.toml")" ]
}

@test "hono pins a typescript its linter supports" {
  scaffold new "$PROJECT" --api hono --db none
  run jq -r '.devDependencies.typescript' "${PROJECT}/apps/api/package.json"
  [[ "$output" == "~6.0"* ]]
}

@test "the generated hono api passes its own ci-unit" {
  scaffold new "$PROJECT" --api hono --db none
  cd "$PROJECT"
  run mise run //apps/api:ci-unit
  assert_ok
}

@test "hono and nextjs share one workspace" {
  scaffold new "$PROJECT" --api hono --web nextjs --db none
  [ -f "${PROJECT}/packages/types/package.json" ]
  run find "$PROJECT" -name pnpm-lock.yaml -not -path '*/node_modules/*'
  [ "$output" = "${PROJECT}/pnpm-lock.yaml" ]
  run grep -c confirmModulesPurge "${PROJECT}/pnpm-workspace.yaml"
  [ "$output" = "0" ]
}

@test "a role mismatch is rejected" {
  run scaffold new "$PROJECT" --web hono
  [ "$status" -eq 1 ]
  [[ "$output" == *"adapter hono has role api"* ]]
}
```

- [ ] **Step 2: Run them and confirm they fail.**

Run: `bats tests/new-hono.bats`
Expected: FAIL with `unknown adapter: hono`.

- [ ] **Step 3: Write `adapters/hono/adapter.env`.**

```bash
ADAPTER_NAME="hono"
ADAPTER_ROLE="api"
ADAPTER_TIER="A"
ADAPTER_LANGUAGE="typescript"
ADAPTER_FAMILY="hono"
# 0.19, not a major: create-hono is pre-1.0. </dev/null turns a new prompt into
# a failure instead of a hang.
ADAPTER_GENERATOR='pnpm create hono@0.19 "$APP_DIR" --template nodejs --pm pnpm --install </dev/null'
# create-hono ships TypeScript 7, which typescript-eslint does not support yet,
# and no linter, formatter or test runner. tsconfig's `include` keeps
# drizzle.config.ts outside rootDir. The grep set fails an add or a jq that
# wrote nothing.
ADAPTER_POST_GENERATE='pnpm add -D typescript@~6.0 prettier vitest eslint @eslint/js typescript-eslint && jq ".include = [\"src\"]" tsconfig.json >tsconfig.json.tmp && mv tsconfig.json.tmp tsconfig.json && { grep -q "\"vitest\"" package.json && grep -q "\"typescript-eslint\"" package.json && grep -q "\"typescript\": \"~6\.0" package.json && grep -q "\"include\"" tsconfig.json || { echo "post-generate: devDependencies or the tsconfig include are missing; create-hono likely changed its output — update ADAPTER_POST_GENERATE" >&2; exit 1; }; } && pnpm exec prettier --write .'
ADAPTER_LIVENESS_PATH="/health/live"
ADAPTER_READINESS_PATH="/health/ready"
```

- [ ] **Step 4: Write the overlay sources.**

`adapters/hono/src/index.ts`:

```ts
import { serve } from "@hono/node-server";
import { Hono } from "hono";

import { health } from "./health.js";

const app = new Hono();
app.route("/health", health);

serve({
  fetch: app.fetch,
  port: Number(process.env.PORT ?? 8080),
  hostname: "0.0.0.0",
});
```

`adapters/hono/src/health.ts`:

```ts
import { Hono } from "hono";
// @DB_CLIENT@
// @CACHE_CLIENT@

export const health = new Hono();

health.get("/live", (c) => c.json({ status: "ok" }));

health.get("/ready", async (c) => {
  try {
    // @CACHE_PROBE@
    // @DB_PROBE@
    throw new Error("no database is configured for this project");
  } catch (error) {
    // Logged, not returned: the error names host and user, and this route is
    // unauthenticated.
    console.warn(`readiness probe failed: ${(error as Error).message}`);
    return c.json({ status: "unavailable" }, 503);
  }
});
```

`adapters/hono/src/health.test.ts`:

```ts
import { beforeAll, expect, test } from "vitest";

import { health } from "./health.js";

beforeAll(() => {
  // Port 1 refuses at once, so whichever driver is wired must fail fast.
  process.env.DATABASE_URL = "postgresql://nobody@127.0.0.1:1/none";
  process.env.REDIS_URL = "redis://127.0.0.1:1";
});

test("live answers 200", async () => {
  const response = await health.request("/live");
  expect(response.status).toBe(200);
});

test("ready answers 503 when nothing is reachable", async () => {
  const response = await health.request("/ready");
  expect(response.status).toBe(503);
  expect(await response.json()).toEqual({ status: "unavailable" });
});
```

- [ ] **Step 5: Write the config files.**

`adapters/hono/eslint.config.js`:

```js
import js from "@eslint/js";
import { defineConfig, globalIgnores } from "eslint/config";
import tseslint from "typescript-eslint";

export default defineConfig([
  globalIgnores(["dist"]),
  js.configs.recommended,
  tseslint.configs.recommended,
]);
```

`adapters/hono/mise.toml`:

```toml
[tasks.install]
# The first frozen install after packages/types joins the workspace relinks
# node_modules, and pnpm must not stop to ask.
env = { npm_config_confirm_modules_purge = "false" }
run = "pnpm install --frozen-lockfile"

[tasks.format]
run = "pnpm exec prettier --check ."

[tasks."format-fix"]
run = "pnpm exec prettier --write ."

[tasks.lint]
run = "pnpm exec eslint . --max-warnings 0"

[tasks.check]
run = "pnpm exec tsc --noEmit"

[tasks.test]
run = "pnpm exec vitest --run"

[tasks.build]
run = "pnpm exec tsc"

[tasks.migrate]
# Only a SQL database writes drizzle.config.ts; mongodb migrates in its image.
run = "if [ -f drizzle.config.ts ]; then pnpm exec drizzle-kit migrate; fi"

[tasks.ci-unit]
# same reason as :install's env above — ci-unit calls :install too.
env = { npm_config_confirm_modules_purge = "false" }
run = [
  { task = ":install" },
  { task = ":format" },
  { task = ":lint" },
  { task = ":check" },
  { task = ":test" },
]

[tasks.checklist]
run = [{ task = ":ci-unit" }, { task = ":build" }]
```

`adapters/hono/.env.example`:

```
PORT=3001
# the database and cache variables are written by the selected services' drivers
```

`adapters/hono/.prettierignore`:

```
pnpm-lock.yaml
dist
drizzle/meta
```

`adapters/hono/.dockerignore`:

```
# copied from a pinned build stage; a host copy would overwrite it
node_modules
dist
coverage

.env
.env.*
!.env.example
.git
```

`adapters/hono/lefthook.fragment.yml`:

```yaml
# prettier in the common layer already covers typescript sources.
{}
```

- [ ] **Step 6: Write `adapters/hono/Dockerfile`.**

```dockerfile
# syntax=docker/dockerfile:1

FROM node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f AS build
WORKDIR /app
RUN corepack enable
# pnpm-workspace.yaml holds the allowBuilds policy (ADR-0017); without it pnpm
# refuses esbuild's postinstall build non-interactively.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY . .
# @SERVICE_SETUP@
RUN pnpm exec tsc && pnpm prune --prod

FROM node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f AS runtime
WORKDIR /app
ENV NODE_ENV=production
# package.json carries "type": "module"; without it node reads dist/ as CommonJS.
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
# The migrate service reads migrations from here. `drizzl[e]` copies nothing
# without a SQL database, where a bare `drizzle` would fail the build.
COPY --from=build /app/drizzl[e] ./drizzle
USER node
# The container port compose.yaml publishes; src/index.ts reads PORT.
ENV PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://127.0.0.1:8080/health/live || exit 1
CMD ["node", "dist/index.js"]
```

- [ ] **Step 7: Write `adapters/hono/Dockerfile.workspace`.**

```dockerfile
# syntax=docker/dockerfile:1

# Used instead of Dockerfile when every app is typescript: apps/api is then a
# pnpm workspace member with no manifests of its own.
FROM node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f AS build
WORKDIR /app
RUN corepack enable
# pnpm-workspace.yaml holds the allowBuilds policy (ADR-0017); without it pnpm
# refuses esbuild's postinstall build non-interactively.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/@APP_FILTER@/package.json apps/@APP_FILTER@/package.json
RUN pnpm --filter @APP_FILTER@ install --frozen-lockfile
COPY . .
WORKDIR /app/apps/@APP_FILTER@
# @SERVICE_SETUP@
RUN pnpm exec tsc
WORKDIR /app
# At the root, where dependencies are hoisted; a purge prompt would abort
# without a TTY (ADR-0017).
RUN pnpm prune --prod --config.confirm-modules-purge=false

FROM node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/apps/@APP_FILTER@/node_modules ./apps/@APP_FILTER@/node_modules
# package.json carries "type": "module"; without it node reads dist/ as CommonJS.
COPY --from=build /app/apps/@APP_FILTER@/package.json ./apps/@APP_FILTER@/package.json
COPY --from=build /app/apps/@APP_FILTER@/dist ./apps/@APP_FILTER@/dist
# The migrate service reads migrations from here. `drizzl[e]` copies nothing
# without a SQL database, where a bare `drizzle` would fail the build.
COPY --from=build /app/apps/@APP_FILTER@/drizzl[e] ./apps/@APP_FILTER@/drizzle
# The app's own directory, so the migrate service's `node dist/db/migrate.js`
# is one path for both Dockerfile shapes.
WORKDIR /app/apps/@APP_FILTER@
USER node
# The container port compose.yaml publishes; src/index.ts reads PORT.
ENV PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://127.0.0.1:8080/health/live || exit 1
CMD ["node", "dist/index.js"]
```

- [ ] **Step 8: Run the suite and the static Dockerfile checks.**

Run: `bats tests/new-hono.bats tests/compose.bats`
Expected: all PASS. If `ci-unit` fails at `format`, post-generate's prettier ran before an overlay file existed: overlay files are copied before post-generate (`apply_adapter` in `lib/adapter.sh`), so check `.prettierignore` instead. If a lint rule fires on generated code, fix the overlay file, never the rule set.

- [ ] **Step 9: Commit.**

```bash
git add adapters/hono tests/new-hono.bats
git commit -m "feat(adapters): add the hono api adapter"
```

---

### Task 4: Hono Drizzle drivers for postgres and mysql

**Files:**
- Create: `services/shared/hono.sh`, `services/postgres/drivers/hono.sh`, `services/mysql/drivers/hono.sh`
- Test: `tests/new-hono.bats` (append)

**Interfaces:**
- Consumes: the anchors from Task 3; `write_env_lines` and `die` (sourced into the driver process by `run_driver_apply`); `SCAFFOLD_ROOT`.
- Produces, for Task 5:
  - `splice_hono_anchor <file> <line> <text>`: replaces each line whose trimmed text equals `<line>` with `<text>`.
  - `assert_hono_spliced <file> <line>...`: dies if any `<line>` is still present.
- Produces: `src/db/client.ts` exporting `db()`; `src/db/migrate.ts`; `drizzle.config.ts`; `drizzle/meta/_journal.json`.

- [ ] **Step 1: Write the failing tests.** Append to `tests/new-hono.bats`:

```bash
@test "hono with postgres wires drizzle and passes its own ci-unit" {
  scaffold new "$PROJECT" --api hono --db postgres
  [ -f "${PROJECT}/apps/api/drizzle/meta/_journal.json" ]
  run grep -c '@DB_PROBE@\|no database is configured' "${PROJECT}/apps/api/src/health.ts"
  [ "$output" = "0" ]
  run grep -q '^DATABASE_URL=postgresql://' "${PROJECT}/apps/api/.env.example"
  assert_ok
  run yq '.services.migrate.command | join(" ")' "${PROJECT}/compose.yaml"
  [ "$output" = "node dist/db/migrate.js" ]
  cd "$PROJECT"
  run mise run //apps/api:checklist
  assert_ok
}

@test "hono with mysql wires drizzle and passes its own ci-unit" {
  scaffold new "$PROJECT" --api hono --db mysql
  run jq -r '.dependencies.mysql2' "${PROJECT}/apps/api/package.json"
  [ "$output" != "null" ]
  cd "$PROJECT"
  run mise run //apps/api:ci-unit
  assert_ok
}
```

- [ ] **Step 2: Run them and confirm they fail.**

Run: `bats tests/new-hono.bats -f "drizzle"`
Expected: FAIL with `postgres has no driver for hono`.

- [ ] **Step 3: Write `services/shared/hono.sh`.**

```bash
# The shared Drizzle driver body, and the splice helpers every hono driver uses.
# shellcheck shell=bash
# A SQL service's drivers/hono.sh sets the parameters below and sources this.
# redis and mongodb source it only for the splice helpers and override every
# driver function.
#
#   DRIZZLE_DIALECT       drizzle-kit's dialect
#   DRIZZLE_MODULE        the drizzle-orm entry: drizzle-orm/<module>
#   DRIZZLE_PACKAGES      the database client package(s)
#   DRIZZLE_DEV_PACKAGES  its type packages, if any
#   DRIZZLE_CLIENT        src/db/client.ts, which exports db()
#   DRIZZLE_URL           DATABASE_URL for .env.example, host-side
#   DRIZZLE_COMPOSE_URL   the same DSN on the compose network

service_driver_apply() {
  pnpm add drizzle-orm@0.45 "${DRIZZLE_PACKAGES[@]}" || return 1
  pnpm add -D drizzle-kit@0.31 "${DRIZZLE_DEV_PACKAGES[@]}" || return 1
  mkdir -p src/db drizzle/meta || return 1

  printf '%s\n' "$DRIZZLE_CLIENT" >src/db/client.ts || return 1
  # Models describe the client's domain, which this toolbox does not know.
  printf 'export {};\n' >src/db/schema.ts || return 1
  write_drizzle_migrate || return 1
  write_drizzle_config || return 1
  # drizzle-orm's migrate() throws on a missing journal; an empty one migrates
  # nothing, and drizzle-kit generate appends to it.
  printf '{"version":"7","dialect":"%s","entries":[]}\n' "$DRIZZLE_DIALECT" \
    >drizzle/meta/_journal.json || return 1

  write_env_lines .env.example "DATABASE_URL=${DRIZZLE_URL}" || return 1

  splice_hono_anchor src/health.ts "// @DB_CLIENT@" 'import { sql } from "drizzle-orm";

import { db } from "./db/client.js";' || return 1
  # shellcheck disable=SC2016 # a TypeScript template literal, not a shell expansion
  splice_hono_anchor src/health.ts "// @DB_PROBE@" 'await db().execute(sql`select 1`);' || return 1
  splice_hono_db_success || return 1
  assert_hono_spliced src/health.ts "// @DB_CLIENT@" "// @DB_PROBE@" "no database is configured"

  pnpm exec prettier --write src drizzle.config.ts
}

write_drizzle_migrate() {
  cat >src/db/migrate.ts <<EOF
import { migrate } from "drizzle-orm/${DRIZZLE_MODULE}/migrator";

import { db } from "./client.js";

// Run by the compose migrate service, never at startup (ADR-0014).
await migrate(db(), { migrationsFolder: "drizzle" });
await db().\$client.end();
EOF
}

write_drizzle_config() {
  cat >drizzle.config.ts <<EOF
import { defineConfig } from "drizzle-kit";

try {
  process.loadEnvFile();
} catch {
  // no .env: DATABASE_URL comes from the environment
}

export default defineConfig({
  dialect: "${DRIZZLE_DIALECT}",
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  dbCredentials: { url: process.env.DATABASE_URL ?? "" },
});
EOF
}

splice_hono_db_success() {
  splice_hono_anchor src/health.ts \
    'throw new Error("no database is configured for this project");' \
    'return c.json({ status: "ok" });'
}

# awk, not sed: the text is multi-line TypeScript carrying /, quotes and
# backticks. Matched on the trimmed line, so prettier's indentation is not part
# of the contract; prettier re-indents afterwards.
splice_hono_anchor() {
  local -r file="$1" line="$2" text="$3"

  LINE="$line" TEXT="$text" awk '
    { trimmed = $0; sub(/^[ \t]+/, "", trimmed) }
    trimmed == ENVIRON["LINE"] { print ENVIRON["TEXT"]; next }
    { print }
  ' "$file" >"${file}.tmp" || return 1
  mv "${file}.tmp" "$file"
}

# Absence, not presence: live() already returns { status: "ok" }, so a grep
# for the success line would pass whether or not the splice landed.
assert_hono_spliced() {
  local -r file="$1"
  shift
  local line

  for line in "$@"; do
    if grep -qF -- "$line" "$file"; then
      die "could not splice '${line}' in ${file} — has the anchor moved?"
    fi
  done
}

service_driver_dockerfile() {
  :
}

# An operator's own .env wins; otherwise compose builds the URL from the same
# DB_* variables the database container reads.
service_driver_compose_env() {
  # shellcheck disable=SC2016 # literal ${DATABASE_URL} written into compose.yaml, not expanded here
  printf 'DATABASE_URL: ${DATABASE_URL:-%s}\n' "$DRIZZLE_COMPOSE_URL"
}

service_driver_compose_migrate() {
  printf 'command: ["node", "dist/db/migrate.js"]\n'
}
```

- [ ] **Step 4: Write `services/postgres/drivers/hono.sh`.**

```bash
# PostgreSQL parameters for the shared Drizzle driver.
# shellcheck shell=bash
# shellcheck disable=SC2034 # read by services/shared/hono.sh, sourced below
DRIZZLE_DIALECT="postgresql"
DRIZZLE_MODULE="node-postgres"
DRIZZLE_PACKAGES=(pg@8)
DRIZZLE_DEV_PACKAGES=(@types/pg@8)
DRIZZLE_URL="postgresql://app:app@localhost:5432/app"
# shellcheck disable=SC2016 # literal ${...} written into compose.yaml, not expanded here
DRIZZLE_COMPOSE_URL='postgresql://${DB_USERNAME:-app}:${DB_PASSWORD}@database:5432/${DB_DATABASE:-app}'
# shellcheck disable=SC2016 # TypeScript source, not a shell expansion
DRIZZLE_CLIENT='import { drizzle } from "drizzle-orm/node-postgres";

let instance: ReturnType<typeof connect> | undefined;

function connect() {
  const database = drizzle({
    connection: {
      connectionString: process.env.DATABASE_URL,
      connectionTimeoutMillis: 2000,
    },
  });
  // pg re-emits an idle connection'"'"'s failure on the pool; unhandled, it kills
  // the process when the database restarts.
  database.$client.on("error", (error) => {
    console.warn(`database pool error: ${error.message}`);
  });
  return database;
}

// One pool per process, made on first use: a pool per readiness poll leaks
// connections toward max_connections.
export function db() {
  instance ??= connect();
  return instance;
}'
# shellcheck source=services/shared/hono.sh
. "${SCAFFOLD_ROOT}/services/shared/hono.sh"
```

- [ ] **Step 5: Write `services/mysql/drivers/hono.sh`.**

```bash
# MySQL parameters for the shared Drizzle driver.
# shellcheck shell=bash
# shellcheck disable=SC2034 # read by services/shared/hono.sh, sourced below
DRIZZLE_DIALECT="mysql"
DRIZZLE_MODULE="mysql2"
DRIZZLE_PACKAGES=(mysql2@3)
DRIZZLE_DEV_PACKAGES=()
DRIZZLE_URL="mysql://app:app@localhost:3306/app"
# shellcheck disable=SC2016 # literal ${...} written into compose.yaml, not expanded here
DRIZZLE_COMPOSE_URL='mysql://${DB_USERNAME:-app}:${DB_PASSWORD}@database:3306/${DB_DATABASE:-app}'
DRIZZLE_CLIENT='import { drizzle } from "drizzle-orm/mysql2";

let instance: ReturnType<typeof connect> | undefined;

function connect() {
  return drizzle({
    connection: { uri: process.env.DATABASE_URL, connectTimeout: 2000 },
  });
}

// One pool per process, made on first use: a pool per readiness poll leaks
// connections toward max_connections.
export function db() {
  instance ??= connect();
  return instance;
}'
# shellcheck source=services/shared/hono.sh
. "${SCAFFOLD_ROOT}/services/shared/hono.sh"
```

- [ ] **Step 6: Run the tests.**

Run: `bats tests/new-hono.bats`
Expected: all PASS. Each failure mode below points at one place:
- `pnpm add` refused with `ERR_PNPM_IGNORED_BUILDS`: add the named package to `allowBuilds` with `yq` the way `services/shared/nest.sh` does.
- `ready answers 503` times out: a client has no connect timeout. Fix that client, not the test.
- `tsc` rejects `ReturnType<typeof connect>`: declare `connect` above `instance`.

- [ ] **Step 7: Lint the drivers.**

Run: `shellcheck services/shared/hono.sh services/*/drivers/hono.sh && shfmt -i 2 -ci -d services/shared/hono.sh services/*/drivers/hono.sh`
Expected: no output.

- [ ] **Step 8: Commit.**

```bash
git add services/shared/hono.sh services/postgres/drivers/hono.sh services/mysql/drivers/hono.sh tests/new-hono.bats
git commit -m "feat(services): wire postgres and mysql into hono through drizzle"
```

---

### Task 5: Hono redis and mongodb drivers

**Files:**
- Create: `services/redis/drivers/hono.sh`, `services/mongodb/drivers/hono.sh`
- Test: `tests/new-hono.bats` (append)

**Interfaces:**
- Consumes: `splice_hono_anchor`, `assert_hono_spliced`, `splice_hono_db_success` from `services/shared/hono.sh` (Task 4).
- Produces: `src/cache.ts` exporting `pingCache(): Promise<void>`; `src/db/mongo.ts` exporting `mongo(): MongoClient`; `src/db/migrate.ts` for mongodb.

- [ ] **Step 1: Write the failing tests.** Append to `tests/new-hono.bats`:

```bash
@test "hono with postgres and redis probes both and passes its own ci-unit" {
  scaffold new "$PROJECT" --api hono --db postgres --cache redis
  run grep -c 'pingCache\|db().execute' "${PROJECT}/apps/api/src/health.ts"
  [ "$output" -ge 2 ]
  run yq '.services.api.environment.REDIS_URL' "${PROJECT}/compose.yaml"
  [[ "$output" == *"@cache:6379"* ]]
  cd "$PROJECT"
  run mise run //apps/api:ci-unit
  assert_ok
}

@test "hono with mongodb ships a migrate command and passes its own ci-unit" {
  scaffold new "$PROJECT" --api hono --db mongodb
  [ -f "${PROJECT}/apps/api/src/db/migrate.ts" ]
  run yq '.services.migrate.command | join(" ")' "${PROJECT}/compose.yaml"
  [ "$output" = "node dist/db/migrate.js" ]
  cd "$PROJECT"
  run mise run //apps/api:checklist
  assert_ok
}
```

- [ ] **Step 2: Run them and confirm they fail.**

Run: `bats tests/new-hono.bats -f "redis|mongodb"`
Expected: FAIL with `redis has no driver for hono` / `mongodb has no driver for hono`.

- [ ] **Step 3: Write `services/redis/drivers/hono.sh`.**

```bash
# How Hono talks to Redis.
# shellcheck shell=bash
# Sources services/shared/hono.sh only for its splice helpers, then overrides
# every driver function: redis is not a Drizzle database.
# shellcheck source=services/shared/hono.sh
. "${SCAFFOLD_ROOT}/services/shared/hono.sh"

service_driver_apply() {
  pnpm add redis@6 || return 1
  write_env_lines .env.example "REDIS_URL=redis://:app@localhost:6379" || return 1

  cat >src/cache.ts <<'EOF' || return 1
import { createClient } from "redis";

// A connection per probe, not one shared client: node-redis queues commands
// while disconnected and reconnects forever, so a shared client's ping hangs
// instead of failing when the cache is down.
export async function pingCache(): Promise<void> {
  const client = createClient({
    url: process.env.REDIS_URL,
    socket: { connectTimeout: 2000, reconnectStrategy: false },
  });
  // Failures also arrive as "error" events; unhandled, one kills the process.
  client.on("error", () => {});
  try {
    await client.connect();
    await client.ping();
  } finally {
    if (client.isOpen) client.destroy();
  }
}
EOF

  splice_hono_anchor src/health.ts "// @CACHE_CLIENT@" 'import { pingCache } from "./cache.js";' || return 1
  splice_hono_anchor src/health.ts "// @CACHE_PROBE@" "await pingCache();" || return 1
  assert_hono_spliced src/health.ts "// @CACHE_CLIENT@" "// @CACHE_PROBE@"

  pnpm exec prettier --write src
}

service_driver_dockerfile() {
  :
}

# Same override-then-compose shape as the database URL: the password lives
# only in REDIS_PASSWORD, which the cache container reads too.
service_driver_compose_env() {
  # shellcheck disable=SC2016 # literal ${...} written into compose.yaml, not expanded here
  printf 'REDIS_URL: ${REDIS_URL:-redis://:${REDIS_PASSWORD}@cache:6379}\n'
}

# a cache has no schema to migrate — printing nothing keeps the migrate
# service absent from a project that selected only a cache.
service_driver_compose_migrate() {
  :
}
```

- [ ] **Step 4: Write `services/mongodb/drivers/hono.sh`.**

```bash
# How Hono talks to MongoDB.
# shellcheck shell=bash
# Drizzle has no MongoDB dialect, so this uses the official driver. Sources
# services/shared/hono.sh only for its splice helpers, then overrides every
# driver function.
# shellcheck source=services/shared/hono.sh
. "${SCAFFOLD_ROOT}/services/shared/hono.sh"

service_driver_apply() {
  pnpm add mongodb@7 || return 1
  # authSource=admin: the container creates the user in `admin`.
  write_env_lines .env.example \
    "DATABASE_URL=mongodb://app:app@localhost:27017/app?authSource=admin" || return 1

  mkdir -p src/db || return 1
  cat >src/db/mongo.ts <<'EOF' || return 1
import { MongoClient } from "mongodb";

let instance: MongoClient | undefined;

// One client per process, made on first use; it pools and reconnects itself.
// The short server selection fails a probe in 2 s, not the default 30.
export function mongo(): MongoClient {
  instance ??= new MongoClient(process.env.DATABASE_URL ?? "", {
    serverSelectionTimeoutMS: 2000,
  });
  return instance;
}
EOF
  # common/install.sh refuses a database with no migrate service, so mongodb
  # gets one: a real command against the real database, and the seam for a
  # client's indexes.
  cat >src/db/migrate.ts <<'EOF' || return 1
import { mongo } from "./mongo.js";

// Run by the compose migrate service, never at startup (ADR-0014).
await mongo().db().command({ ping: 1 });
await mongo().close();
EOF

  splice_hono_anchor src/health.ts "// @DB_CLIENT@" 'import { mongo } from "./db/mongo.js";' || return 1
  splice_hono_anchor src/health.ts "// @DB_PROBE@" "await mongo().db().command({ ping: 1 });" || return 1
  splice_hono_db_success || return 1
  assert_hono_spliced src/health.ts "// @DB_CLIENT@" "// @DB_PROBE@" "no database is configured"

  pnpm exec prettier --write src
}

service_driver_dockerfile() {
  :
}

service_driver_compose_env() {
  # shellcheck disable=SC2016 # literal ${...} written into compose.yaml, not expanded here
  printf 'DATABASE_URL: ${DATABASE_URL:-%s}\n' \
    'mongodb://${DB_USERNAME:-app}:${DB_PASSWORD}@database:27017/${DB_DATABASE:-app}?authSource=admin'
}

service_driver_compose_migrate() {
  printf 'command: ["node", "dist/db/migrate.js"]\n'
}
```

- [ ] **Step 5: Run the tests and the toolbox linter.**

Run: `bats tests/new-hono.bats && ./scaffold lint`
Expected: all PASS; `scaffold lint` prints nothing and exits 0. `MongoClient("")` throws `MongoParseError` synchronously inside the readiness `try`, so the shipped test's 503 still holds. `"postgresql://…"` is not a mongodb URL either.

- [ ] **Step 6: Lint the drivers.**

Run: `shellcheck services/*/drivers/hono.sh && shfmt -i 2 -ci -d services/*/drivers/hono.sh`
Expected: no output.

- [ ] **Step 7: Commit.**

```bash
git add services/redis/drivers/hono.sh services/mongodb/drivers/hono.sh tests/new-hono.bats
git commit -m "feat(services): wire redis and mongodb into hono"
```

---

### Task 6: `vite-react` adapter

**Files:**
- Create: `adapters/vite-react/adapter.env`, `mise.toml`, `Caddyfile`, `Dockerfile`, `Dockerfile.workspace`, `.dockerignore`, `.env.example`, `.prettierignore`, `lefthook.fragment.yml`, `public/config.json`, `src/config.ts`, `src/config.test.ts`
- Test: `tests/new-vite-react.bats`

**Interfaces:**
- Produces: `loadConfig(): Promise<RuntimeConfig>`, where `RuntimeConfig` is `{ apiUrl: string }` (`src/config.ts`); `GET /config.json` and `GET /health/live` from the runtime image.

- [ ] **Step 1: Write the failing tests.** `tests/new-vite-react.bats`:

```bash
setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
}

teardown() {
  remove_workdir "$WORKDIR"
}

@test "vite-react generates an app at apps/web" {
  run scaffold new "$PROJECT" --web vite-react
  assert_ok
  [ -f "${PROJECT}/apps/web/index.html" ]
  [ -f "${PROJECT}/apps/web/Caddyfile" ]
  [ -f "${PROJECT}/apps/web/mise.toml" ]
}

@test "vite-react adds no tool to the project root" {
  scaffold new "$PROJECT" --web vite-react
  [ "$(yq -p toml -oy '.tools' "${PROJECT}/mise.toml")" = \
    "$(yq -p toml -oy '.tools' "${SCAFFOLD_ROOT}/common/mise.root.toml")" ]
}

@test "vite-react lints with eslint, not oxlint" {
  scaffold new "$PROJECT" --web vite-react
  [ -f "${PROJECT}/apps/web/eslint.config.js" ]
  run jq -r '.devDependencies.oxlint // "absent"' "${PROJECT}/apps/web/package.json"
  [ "$output" = "absent" ]
}

@test "the generated web app passes its own checklist" {
  scaffold new "$PROJECT" --web vite-react
  cd "$PROJECT"
  run mise run //apps/web:checklist
  assert_ok
}

@test "the caddy runtime answers health and config without index.html" {
  scaffold new "$PROJECT" --web vite-react
  run grep -c 'handle /health/live\|handle /config.json' "${PROJECT}/apps/web/Caddyfile"
  [ "$output" = "2" ]
  run grep -c 'FROM node' "${PROJECT}/apps/web/Dockerfile"
  [ "$output" = "1" ]
}

@test "a role mismatch is rejected" {
  run scaffold new "$PROJECT" --api vite-react
  [ "$status" -eq 1 ]
  [[ "$output" == *"adapter vite-react has role web"* ]]
}
```

- [ ] **Step 2: Run them and confirm they fail.**

Run: `bats tests/new-vite-react.bats`
Expected: FAIL with `unknown adapter: vite-react`.

- [ ] **Step 3: Write `adapters/vite-react/adapter.env`.**

```bash
ADAPTER_NAME="vite-react"
ADAPTER_ROLE="web"
ADAPTER_TIER="A"
ADAPTER_LANGUAGE="typescript"
ADAPTER_FAMILY="vite"
# Pinned to the major. --eslint: v9 defaults React templates to oxlint
# (docs/decisions/0008). </dev/null turns a new prompt into a failure instead of
# a hang.
ADAPTER_GENERATOR='pnpm create vite@9 "$APP_DIR" --template react-ts --eslint --no-immediate --no-interactive </dev/null'
# create-vite ships neither prettier nor vitest, and does not install.
ADAPTER_POST_GENERATE='pnpm add -D prettier vitest && { grep -q "\"vitest\"" package.json && grep -q "\"prettier\"" package.json || { echo "post-generate: prettier or vitest missing from package.json after pnpm add" >&2; exit 1; }; } && pnpm exec prettier --write .'
# answered by Caddy itself, so the probe never depends on the SPA's index.html
ADAPTER_LIVENESS_PATH="/health/live"
```

- [ ] **Step 4: Write the runtime config seam.**

`adapters/vite-react/src/config.ts`:

```ts
export interface RuntimeConfig {
  apiUrl: string;
}

// Fetched at run time, not read from import.meta.env: a VITE_* value is baked
// into the bundle at build time, and one image must serve every environment
// (ADR-0014).
export async function loadConfig(): Promise<RuntimeConfig> {
  const response = await fetch("/config.json");
  if (!response.ok) {
    throw new Error(`/config.json answered ${response.status}`);
  }
  return (await response.json()) as RuntimeConfig;
}
```

`adapters/vite-react/src/config.test.ts`:

```ts
import { afterEach, expect, test, vi } from "vitest";

import { loadConfig } from "./config";

afterEach(() => {
  vi.unstubAllGlobals();
});

test("loadConfig returns the served config", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => Response.json({ apiUrl: "https://api.example" })),
  );
  await expect(loadConfig()).resolves.toEqual({ apiUrl: "https://api.example" });
});

test("loadConfig rejects when the server has no config", async () => {
  vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 404 })));
  await expect(loadConfig()).rejects.toThrow("/config.json answered 404");
});
```

(No `.js` suffix: the Vite template uses `moduleResolution: bundler`.)

`adapters/vite-react/public/config.json` (for `vite dev`; Caddy's route shadows it in the image):

```json
{ "apiUrl": "http://localhost:3001" }
```

- [ ] **Step 5: Write `adapters/vite-react/Caddyfile`.**

```
{
	admin off
	auto_https off
	persist_config off
}

:8080 {
	handle /health/live {
		respond "ok" 200
	}

	# {$API_URL} is read when Caddy loads this file at container start, so one
	# image serves every environment (ADR-0014). Unset means same origin.
	handle /config.json {
		header Content-Type application/json
		header Cache-Control no-store
		respond `{"apiUrl":"{$API_URL}"}` 200
	}

	handle {
		root * /srv
		try_files {path} /index.html
		file_server
	}
}
```

- [ ] **Step 6: Write `adapters/vite-react/Dockerfile`.**

```dockerfile
# syntax=docker/dockerfile:1

FROM node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f AS build
WORKDIR /app
RUN corepack enable
# pnpm-workspace.yaml holds the allowBuilds policy (ADR-0017); without it pnpm
# refuses esbuild's postinstall build non-interactively.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY . .
# @SERVICE_SETUP@
RUN pnpm exec vite build

FROM caddy:2.11.7-alpine@sha256:d8542f48d34a9cf4e4c11a478865229840e87e4c96ea3f439101f31a5d35f75f AS runtime
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=build /app/dist /srv
# The image's /config and /data are root-owned; caddy writes state there even
# with persist_config off.
ENV XDG_CONFIG_HOME=/tmp/caddy XDG_DATA_HOME=/tmp/caddy
USER nobody
EXPOSE 8080
# 127.0.0.1, not localhost: busybox wget takes the ::1 answer first and does
# not fall back (see adapters/nextjs/Dockerfile).
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://127.0.0.1:8080/health/live || exit 1
```

- [ ] **Step 7: Write `adapters/vite-react/Dockerfile.workspace`.**

```dockerfile
# syntax=docker/dockerfile:1

# Used instead of Dockerfile when every app is typescript: apps/web is then a
# pnpm workspace member with no manifests of its own.
FROM node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f AS build
WORKDIR /app
RUN corepack enable
# pnpm-workspace.yaml holds the allowBuilds policy (ADR-0017); without it pnpm
# refuses esbuild's postinstall build non-interactively.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/@APP_FILTER@/package.json apps/@APP_FILTER@/package.json
RUN pnpm --filter @APP_FILTER@ install --frozen-lockfile
COPY . .
WORKDIR /app/apps/@APP_FILTER@
# @SERVICE_SETUP@
RUN pnpm exec vite build

FROM caddy:2.11.7-alpine@sha256:d8542f48d34a9cf4e4c11a478865229840e87e4c96ea3f439101f31a5d35f75f AS runtime
COPY apps/@APP_FILTER@/Caddyfile /etc/caddy/Caddyfile
COPY --from=build /app/apps/@APP_FILTER@/dist /srv
# The image's /config and /data are root-owned; caddy writes state there even
# with persist_config off.
ENV XDG_CONFIG_HOME=/tmp/caddy XDG_DATA_HOME=/tmp/caddy
USER nobody
EXPOSE 8080
# 127.0.0.1, not localhost: busybox wget takes the ::1 answer first and does
# not fall back (see adapters/nextjs/Dockerfile).
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://127.0.0.1:8080/health/live || exit 1
```

- [ ] **Step 8: Write the remaining files.**

`adapters/vite-react/mise.toml`:

```toml
[tasks.install]
# The first frozen install after packages/types joins the workspace relinks
# node_modules, and pnpm must not stop to ask.
env = { npm_config_confirm_modules_purge = "false" }
run = "pnpm install --frozen-lockfile"

[tasks.format]
run = "pnpm exec prettier --check ."

[tasks."format-fix"]
run = "pnpm exec prettier --write ."

[tasks.lint]
run = "pnpm exec eslint . --max-warnings 0"

[tasks.check]
# tsconfig.app.json and tsconfig.node.json set noEmit; -b only writes
# tsbuildinfo under node_modules/.tmp.
run = "pnpm exec tsc -b"

[tasks.test]
run = "pnpm exec vitest --run"

[tasks.build]
run = "pnpm exec vite build"

[tasks.ci-unit]
# same reason as :install's env above — ci-unit calls :install too.
env = { npm_config_confirm_modules_purge = "false" }
run = [
  { task = ":install" },
  { task = ":format" },
  { task = ":lint" },
  { task = ":check" },
  { task = ":test" },
]

[tasks.checklist]
run = [{ task = ":ci-unit" }, { task = ":build" }]
```

`adapters/vite-react/.env.example`:

```
# Read by Caddy when the container starts and served at /config.json; empty
# means the api is on the same origin.
API_URL=
# Only VITE_* variables reach client code, and they are baked in at build time:
# anything that differs per environment belongs in /config.json (ADR-0014).
```

`adapters/vite-react/.prettierignore`:

```
pnpm-lock.yaml
dist
```

`adapters/vite-react/.dockerignore`: same content as `adapters/hono/.dockerignore` (Task 3, Step 5). `adapters/vite-react/lefthook.fragment.yml`: same as hono's.

- [ ] **Step 9: Run the suite and the static Dockerfile checks.**

Run: `bats tests/new-vite-react.bats tests/compose.bats && ./scaffold lint`
Expected: all PASS; lint silent.

- [ ] **Step 10: Prove the runtime image.** This is the check that couldn't run during brainstorming.

```bash
./scaffold new ../probe-web --web vite-react
cd ../probe-web/apps/web
docker build -t probe-web .
docker run -d --name probe-web -e API_URL=https://api.example -p 18080:8080 probe-web
```

Then check each of these:
- `curl -s -o /dev/null -w '%{http_code}' localhost:18080/health/live` prints `200`.
- `curl -s localhost:18080/config.json` prints `{"apiUrl":"https://api.example"}`.
- `curl -s localhost:18080/some/client/route` returns `index.html`.
- `docker inspect -f '{{.State.Health.Status}} {{.Config.User}}' probe-web` prints `healthy nobody` (allow 30 s).
- `docker exec probe-web sh -c 'command -v node || echo none'` prints `none`.

If Caddy fails to start as `nobody`, read `docker logs probe-web`. A permission error on `/config` or `/data` means the `XDG_*` values did not apply; fix the Dockerfiles. Clean up with `docker rm -f probe-web && rm -rf ../probe-web`.

- [ ] **Step 11: Commit.**

```bash
git add adapters/vite-react tests/new-vite-react.bats
git commit -m "feat(adapters): add the vite-react web adapter served by caddy"
```

---

### Task 7: The mixed project, ADRs and docs

**Files:**
- Create: `tests/mixed-project.bats`, `docs/decisions/0025-vite-react-is-served-by-caddy-with-runtime-config.md`, `docs/decisions/0026-hono-uses-drizzle-for-sql-and-official-clients-otherwise.md`
- Modify: `docs/tour/08-adapters.md`, `README.md` (adapter table, lines ~75–81)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write the mixed-project test.** `tests/mixed-project.bats`:

```bash
setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/opensocial"
}

teardown() {
  remove_workdir "$WORKDIR"
}

# The command sequence docs/tour/08-adapters.md documents, run verbatim.
@test "an all-typescript project keeps shared types after a python app is added" {
  run scaffold new "$PROJECT" --web vite-react --api hono --db postgres
  assert_ok
  cd "$PROJECT"
  local migrate_image
  migrate_image="$(yq '.services.migrate.image' compose.yaml)"

  run scaffold add workers/media --adapter flask
  assert_ok
  run scaffold add services/render --adapter hono
  assert_ok

  [ -f packages/types/package.json ]
  [ -f pnpm-lock.yaml ]
  [ -f services/render/pnpm-lock.yaml ]
  run find . -name pnpm-lock.yaml -path './apps/*' -not -path '*/node_modules/*'
  [ -z "$output" ]
  run grep -c confirmModulesPurge pnpm-workspace.yaml
  [ "$output" = "0" ]
  run yq -p toml -oy '.apps["services/render"]' .scaffold.toml
  [ "$output" = "hono" ]
  run yq '.services.migrate.image' compose.yaml
  [ "$output" = "$migrate_image" ]
  run yq -p toml -oy '.tools.node' mise.toml
  [ "$output" = "24.15.0" ]

  run mise run //services/render:ci-unit
  assert_ok
  run mise run //workers/media:ci-unit
  assert_ok
}
```

- [ ] **Step 2: Run it.**

Run: `bats tests/mixed-project.bats`
Expected: PASS (Tasks 1–6 are in). If `.scaffold.toml`'s app table is named differently, read `lib/manifest.sh` and adjust the `yq` path only.

- [ ] **Step 3: Write ADR 0025.** Use this exact header and the four required sections:

```markdown
# 0025 — vite-react is served by Caddy, with runtime config at /config.json

Status: Accepted
Date: 2026-10-14

## Context

A Vite SPA builds to static files. Its only runtime need is a server that
answers a health probe, serves `dist/`, and falls back to `index.html` for
client-side routes. Vite inlines `VITE_*` variables into the bundle at build
time, which breaks ADR-0014's second seam: one image, configured by its
environment.

## Decision

The runtime stage is `caddy:2.11.7-alpine`, pinned by digest, running as
`nobody`. Its `Caddyfile` answers `/health/live` itself, so the probe never
depends on `index.html`. `/config.json` is rendered from the container's
`API_URL` when Caddy starts. Every other path is `try_files {path} /index.html`.
Client code reads per-environment values through `src/config.ts`'s
`loadConfig()`, never `import.meta.env`.

## Consequences

- The runtime image has no Node.
- A new per-environment value means a new key in the `Caddyfile`'s
  `/config.json` response and in `RuntimeConfig`.
- `VITE_*` remains usable for values that never differ between environments.
- `vite dev` serves `public/config.json` instead; the image's route shadows it.

## Alternatives considered

- **nginx-unprivileged.** Works, but SPA fallback, a health route and env
  rendering need `envsubst` templates and a longer config.
- **Build-time `VITE_*` only.** One image per environment, contradicting
  ADR-0014.
- **Same-origin `/api` behind a reverse proxy.** Needs the proxy ADR-0022
  declines to generate.
```

- [ ] **Step 4: Write ADR 0026.**

```markdown
# 0026 — hono uses Drizzle for SQL databases and the official clients otherwise

Status: Accepted
Date: 2026-10-14

## Context

The `hono` adapter exists for projects that cannot afford NestJS's footprint
(`opensocial`: an 8 GB, 4-core host). Its drivers need a database layer that
is light at runtime, works with postgres and mysql, and can migrate from the
released image, which has no pnpm and only production dependencies.

## Decision

- postgres and mysql go through Drizzle ORM (`services/shared/hono.sh`).
  Migrations run through drizzle-orm's own `migrate()`, compiled to
  `dist/db/migrate.js`. `drizzle-kit` stays a devDependency and generates
  migrations into `drizzle/`. An empty `drizzle/meta/_journal.json` ships so a
  fresh project migrates cleanly.
- redis uses the official `redis` client; mongodb uses the official `mongodb`
  driver, because Drizzle has no MongoDB dialect. Its migrate command pings,
  because `common/install.sh` refuses a database with no migrate service.
- `/health/ready` checks the database and, unlike nestjs and flask, the
  cache. Every probe fails within about two seconds.

## Consequences

- The hono and nestjs drivers do not share code: Prisma (`services/shared/nest.sh`) and
  Drizzle have different shapes.
- A client writes models in `src/db/schema.ts` and runs
  `pnpm exec drizzle-kit generate`; `mise run migrate` applies them locally.
- Cache readiness is not back-ported to nestjs or flask.

## Alternatives considered

- **Prisma, as nestjs.** A heavier runtime with an engine binary and
  install-time builds, against this adapter's reason to exist.
- **`drizzle-kit migrate` in the runtime image.** Puts a dev CLI and esbuild
  into production.
- **Drizzle for MongoDB.** Not supported by Drizzle.
```

- [ ] **Step 5: Check the ADRs.**

Run: `adr="$(mktemp -d)" && mkdir "$adr/scripts" && cp common/docs/scripts/check-adrs.mjs "$adr/scripts/" && ln -s "$PWD/docs/decisions" "$adr/decisions" && node "$adr/scripts/check-adrs.mjs"`
Expected: exit 0, no output. The script resolves `../decisions` from its own location, hence the symlink.

- [ ] **Step 6: Update docs.**

In `README.md`'s adapter table, add these rows after `nestjs`:

```markdown
| `vite-react` | web | A |
| `hono` | api | A |
```

Add the same two rows to any adapter table in `docs/tour/08-adapters.md`. Then append this section to `docs/tour/08-adapters.md` (before `## Delete test`):

~~~markdown
## Mixed TypeScript + Python project with shared types

`packages/types` exists only when every application `scaffold new` creates
is TypeScript (`settle_workspace_shape`). `scaffold add` never recomputes
that decision (ADR-0018). So create the TypeScript applications first, then
add the Python one:

```bash
scaffold new opensocial --web vite-react --api hono --db postgres
cd opensocial
scaffold add workers/media   --adapter flask
scaffold add services/render --adapter hono
```

- `apps/web` and `apps/api` share one root lockfile and can import
  `packages/types`.
- `workers/media` installs from its own `uv.lock`.
- `services/render` is outside the workspace globs (`apps/*`, `packages/*`),
  so it keeps its own lockfile and cannot import `packages/types`. Add it as
  `apps/render` if it needs the shared types.
- The compose `migrate` service stays on `apps/api`'s image; an added backend
  runs its own migrations (ADR-0022).
~~~

Run: `bats tests/documentation.bats tests/docs.bats`
Expected: all PASS, including the line limit and ADR-reference checks.

- [ ] **Step 7: Commit.**

```bash
git add tests/mixed-project.bats docs/decisions/0025-*.md docs/decisions/0026-*.md docs/tour/08-adapters.md README.md
git commit -m "docs: record the vite-react and hono decisions and the mixed project"
```

---

### Task 8: Acceptance run

No new code. Each step maps to a criterion in the spec's Verification table. Record the outputs in the PR description. A failure goes back to the task that owns the file, fixed there with a test first.

- [ ] **Step 1 (criteria 1, 2):** `./scaffold lint` prints nothing and exits 0. `./scaffold list --adapters` shows `vite-react web A` and `hono api A`.

- [ ] **Step 2 (criterion 3):** Run the runbook "Verify" block for each adapter:

```bash
./scaffold new ../probe --api hono && (cd ../probe && mise run //apps/api:checklist)
./scaffold new ../probe-w --web vite-react && (cd ../probe-w && mise run //apps/web:checklist)
./scaffold new ../probe2 --api hono --web nextjs
./scaffold new ../probe3 --api nestjs
toolbox="$PWD"
(cd ../probe3 && "$toolbox/scaffold" add apps/hono --adapter hono && "$toolbox/scaffold" add apps/vite --adapter vite-react)
find ../probe3 -name pnpm-lock.yaml -not -path '*/node_modules/*'   # exactly one, at the root
test -f ../probe3/packages/types/package.json && echo "types package: ok"
grep confirmModulesPurge ../probe3/pnpm-workspace.yaml             # no match
```

`scaffold add apps/vite --adapter vite-react` has role web; `add` does not check roles, so this is allowed.

- [ ] **Step 3 (criterion 4):** `bats tests/new-vite-react.bats tests/new-hono.bats tests/add-app.bats tests/mixed-project.bats` all PASS.

- [ ] **Step 4 (criterion 5):**

```bash
./scripts/deploy-check.sh vite-react hono --db postgres
```

Expected: PASS. Then by hand, on `../probe5` from `./scaffold new ../probe5 --web vite-react --api hono --db postgres`:

```bash
cd ../probe5 && mise run //apps/web:checklist && mise run //apps/api:checklist
cp example.env .env   # then set DB_PASSWORD and the image names to local builds, as common/install.sh documents
docker compose up -d --wait
curl -s -o /dev/null -w '%{http_code}\n' "localhost:${WEB_PORT:-8080}/health/live"   # 200
curl -s -o /dev/null -w '%{http_code}\n' "localhost:${API_PORT:-8081}/health/ready"  # 200
docker compose stop database
curl -s -o /dev/null -w '%{http_code}\n' "localhost:${API_PORT:-8081}/health/ready"  # 503, within ~2 s
docker compose ps api   # still running, not restarting: Review Focus 1
docker compose start database && sleep 5
curl -s -o /dev/null -w '%{http_code}\n' "localhost:${API_PORT:-8081}/health/ready"  # 200 again
docker compose down -v
```

Repeat the stop/start check with `--db mysql`. If the api restarts when mysql stops, add an `"error"` listener on `database.$client` in `services/mysql/drivers/hono.sh`'s `DRIZZLE_CLIENT`, like postgres's, and re-run Task 4's tests.

- [ ] **Step 5 (criterion 6):** In the `tests/mixed-project.bats` sequence run by hand in `../probe6`, build all four images and `docker compose up -d --wait`. `docker compose ps` shows `web`, `api`, `media`, `render` and `database` healthy.

- [ ] **Step 6 (criterion 7):** `./scripts/adapter-matrix.sh pull_request ""` lists `vite-react` and `hono` in the Tier A matrix. `git diff main -- .github/workflows/adapters.yml` is empty.

- [ ] **Step 7 (criterion 8):** Re-run Task 7 Step 5's ADR check.

- [ ] **Step 8:** Delete every probe: `rm -rf ../probe ../probe-w ../probe2 ../probe3 ../probe5 ../probe6` and `docker image rm` the local tags `deploy-check` and the probes built.
