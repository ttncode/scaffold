# `vite-react` Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `vite-react` web adapter: a React single-page app built by Vite and served as static files by Caddy, with runtime config at `/config.json`.

**Architecture:** Like every adapter, it runs the framework's own generator (`create-vite`) and overlays files on its output (ADR-0003). The Docker image builds with Node and serves `dist/` from a Caddy runtime stage. Caddy answers the health probe itself, falls back to `index.html` for client routes, and renders `/config.json` from the container's environment at start.

**Tech Stack:** bash 4 + bats, mise, pnpm, create-vite 9, React 19, Vite 8, TypeScript 6, ESLint, prettier, vitest, Caddy 2.11.7, Node 24.15.0.

**Spec:** `docs/superpowers/specs/2026-10-14-vite-react-adapter-design.md`

## Global Constraints

- Base images pinned by digest. Node: `node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f`. Caddy: `caddy:2.11.7-alpine@sha256:d8542f48d34a9cf4e4c11a478865229840e87e4c96ea3f439101f31a5d35f75f`.
- Generator: `pnpm create vite@9 "$APP_DIR" --template react-ts --eslint --no-immediate --no-interactive </dev/null`.
- Every Dockerfile: multi-stage, `EXPOSE 8080`, `HEALTHCHECK` on `http://127.0.0.1:8080/health/live`, `USER nobody` in the runtime stage, no `.env` copied, `# @SERVICE_SETUP@` in the build stage, no Node in the runtime stage.
- `format`, `lint`, `check` never write (`scaffold lint` rejects `--write`, `--fix`, `-w`, `--in-place`, `--overwrite` in them).
- Role `web`: no service driver, and `--db` without a backend stays rejected.
- Comments only for a why, a landmine or a deliberate omission, as in the existing adapters.
- Commits follow Conventional Commits. The pre-commit hook runs gitleaks, shellcheck and shfmt.

## Review Focus

1. **A deep link.** `GET /some/client/route` must return `index.html` with 200, not 404 (Task 1, Step 10).
2. **No `API_URL` set.** `/config.json` must still be valid JSON (`{"apiUrl":""}`), meaning same origin (Task 1, Step 10).
3. **The image as non-root.** Caddy must start as `nobody` even though the image's `/config` and `/data` are root-owned (Task 1, Step 10).
4. **A second TypeScript app in the workspace.** `Dockerfile.workspace`'s `--filter` must match the app's `package.json` name, or `pnpm` installs nothing and the build fails late (Task 3, Step 2, runbook checks).
5. **A changed setting without a rebuild.** Changing `API_URL` and restarting the container, with no rebuild, must change `/config.json` (Task 1, Step 10).

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `adapters/vite-react/adapter.env` | Name, role, tier, generator, post-generate, liveness path |
| `adapters/vite-react/mise.toml` | The nine contract tasks |
| `adapters/vite-react/Caddyfile` | Health route, runtime config route, SPA fallback |
| `adapters/vite-react/Dockerfile`, `Dockerfile.workspace` | Standalone and workspace builds, Caddy runtime |
| `adapters/vite-react/.dockerignore`, `.env.example`, `.prettierignore`, `lefthook.fragment.yml` | Supporting overlay files |
| `adapters/vite-react/public/config.json` | Config for `vite dev` |
| `adapters/vite-react/src/config.ts`, `src/config.test.ts` | `loadConfig()` seam and its test |
| `tests/new-vite-react.bats` | Adapter suite |
| `docs/decisions/0025-vite-react-is-served-by-caddy-with-runtime-config.md` | Decision record |
| `README.md`, `docs/tour/08-adapters.md` | Adapter tables |

---

### Task 1: `vite-react` adapter

**Files:**
- Create: everything under `adapters/vite-react/` listed above
- Test: `tests/new-vite-react.bats`

**Interfaces:**
- Produces: `loadConfig(): Promise<RuntimeConfig>`, where `RuntimeConfig` is `{ apiUrl: string }` (`src/config.ts`). The runtime image serves `GET /health/live` and `GET /config.json`.

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
  run grep -c '^FROM node' "${PROJECT}/apps/web/Dockerfile"
  [ "$output" = "1" ]
}

@test "vite-react and nestjs share one workspace" {
  scaffold new "$PROJECT" --web vite-react --api nestjs --db none
  [ -f "${PROJECT}/packages/types/package.json" ]
  run find "$PROJECT" -name pnpm-lock.yaml -not -path '*/node_modules/*'
  [ "$output" = "${PROJECT}/pnpm-lock.yaml" ]
  run grep -c -- '--filter web' "${PROJECT}/apps/web/Dockerfile"
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

`adapters/vite-react/src/config.test.ts` (no `.js` suffix: the template uses `moduleResolution: bundler`):

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

`adapters/vite-react/public/config.json` (for `vite dev`; Caddy's route shadows it in the image; 3001 is nestjs's dev port):

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

`adapters/vite-react/.dockerignore`:

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

`adapters/vite-react/lefthook.fragment.yml`:

```yaml
# prettier in the common layer already covers typescript sources.
{}
```

- [ ] **Step 9: Run the suite, the static Dockerfile checks and the linter.**

Run: `bats tests/new-vite-react.bats tests/compose.bats && ./scaffold lint`
Expected: all PASS; `scaffold lint` prints nothing.

If `checklist` fails at `format`, a file the generator wrote is unformatted. Post-generate runs `prettier --write .` after the overlay is copied (`apply_adapter` in `lib/adapter.sh`), so check that `.prettierignore` isn't hiding it. If `vitest` refuses Vite 8 as a peer, pin the vitest major that supports it in `ADAPTER_POST_GENERATE` (`pnpm add -D prettier vitest@<major>`) and record why in its comment.

- [ ] **Step 10: Prove the runtime image.** This check was not run during design.

```bash
./scaffold new ../probe-web --web vite-react
cd ../probe-web/apps/web
docker build -t probe-web .
docker run -d --name probe-web -e API_URL=https://api.example -p 18080:8080 probe-web
```

Check each of these:
- `curl -s -o /dev/null -w '%{http_code}\n' localhost:18080/health/live` prints `200`.
- `curl -s localhost:18080/config.json` prints `{"apiUrl":"https://api.example"}`.
- `curl -s -w '%{http_code}\n' localhost:18080/some/client/route | tail -c 4` ends `200`, and the body is `index.html`.
- `docker inspect -f '{{.State.Health.Status}} {{.Config.User}}' probe-web` prints `healthy nobody` (allow 30 s).
- `docker exec probe-web sh -c 'command -v node || echo none'` prints `none`.

Then check that a restart picks up a new `API_URL`, and that an unset one is still valid JSON:

```bash
docker rm -f probe-web
docker run -d --name probe-web -p 18080:8080 probe-web
curl -s localhost:18080/config.json        # {"apiUrl":""}
docker rm -f probe-web
cd - && rm -rf ../probe-web && docker image rm probe-web
```

If Caddy exits as `nobody`, read `docker logs probe-web`. A permission error on `/config` or `/data` means the `XDG_*` values didn't apply; fix both Dockerfiles and re-run this step.

- [ ] **Step 11: Commit.**

```bash
git add adapters/vite-react tests/new-vite-react.bats
git commit -m "feat(adapters): add the vite-react web adapter served by caddy"
```

---

### Task 2: ADR 0025 and the adapter tables

**Files:**
- Create: `docs/decisions/0025-vite-react-is-served-by-caddy-with-runtime-config.md`
- Modify: `README.md` (adapter table near line 75), `docs/tour/08-adapters.md` (any adapter table)

- [ ] **Step 1: Write the ADR.**

```markdown
# 0025 — vite-react is served by Caddy, with runtime config at /config.json

Status: Accepted
Date: 2026-10-14

## Context

A Vite single-page app builds to static files. At run time it needs only a
server that answers a health probe, serves `dist/`, and falls back to
`index.html` for client-side routes. Vite inlines `VITE_*` variables into the
bundle at build time, which breaks ADR-0014's second seam: one image,
configured by its environment.

## Decision

The runtime stage is `caddy:2.11.7-alpine`, pinned by digest, running as
`nobody`. Its `Caddyfile` answers `/health/live` itself, so the probe never
depends on `index.html`; renders `/config.json` from the container's `API_URL`
when Caddy starts; and serves every other path with
`try_files {path} /index.html`. Client code reads per-environment values
through `src/config.ts`'s `loadConfig()`, not `import.meta.env`.

## Consequences

- The runtime image has no Node.
- A new per-environment value means a new key in the `Caddyfile`'s
  `/config.json` response and in `RuntimeConfig`.
- `VITE_*` stays usable for values that never differ between environments.
- `vite dev` serves `public/config.json`; the image's route shadows it.
- A missing asset path also answers `index.html` with 200, the usual SPA
  fallback trade-off.

## Alternatives considered

- **nginx-unprivileged.** Works, but SPA fallback, a health route and env
  rendering need `envsubst` templates and a longer config.
- **Build-time `VITE_*` only.** One image per environment, contradicting
  ADR-0014.
- **Same-origin `/api` behind a reverse proxy.** Needs the proxy ADR-0022
  declines to generate.
```

- [ ] **Step 2: Check it.**

Run: `adr="$(mktemp -d)" && mkdir "$adr/scripts" && cp common/docs/scripts/check-adrs.mjs "$adr/scripts/" && ln -s "$PWD/docs/decisions" "$adr/decisions" && node "$adr/scripts/check-adrs.mjs"`
Expected: exit 0, no output. The script resolves `../decisions` from its own location, hence the symlink.

- [ ] **Step 3: Add the adapter rows.** In `README.md`'s adapter table, after the `nextjs` row:

```markdown
| `vite-react` | web | A |
```

Add the same row to any adapter table in `docs/tour/08-adapters.md`.

- [ ] **Step 4: Run the docs suites.**

Run: `bats tests/documentation.bats tests/docs.bats`
Expected: all PASS, including "every adr referenced by the tour exists".

- [ ] **Step 5: Commit.**

```bash
git add docs/decisions/0025-vite-react-is-served-by-caddy-with-runtime-config.md README.md docs/tour/08-adapters.md
git commit -m "docs: record serving vite-react with caddy"
```

---

### Task 3: Acceptance run

No new code. Each step maps to a success criterion in the spec. Record the outputs in the PR description. A failure goes back to Task 1 or 2 and is fixed there, test first.

- [ ] **Step 1 (criteria 1, 2):** `./scaffold lint` prints nothing and exits 0. `./scaffold list --adapters` shows `vite-react`, `web`, `A`.

- [ ] **Step 2 (criterion 3):** The runbook "Verify" block, with the second-TypeScript-app checks:

```bash
./scaffold new ../probe --web vite-react
(cd ../probe && mise run //apps/web:checklist)
./scaffold new ../probe2 --web vite-react --api nestjs --db none
./scaffold new ../probe3 --api nestjs
toolbox="$PWD"
(cd ../probe3 && "$toolbox/scaffold" add apps/web --adapter vite-react)
find ../probe3 -name pnpm-lock.yaml -not -path '*/node_modules/*'   # exactly one, at the root
test -f ../probe3/packages/types/package.json && echo "types package: ok"
grep confirmModulesPurge ../probe3/pnpm-workspace.yaml             # no match
(cd ../probe3 && mise run //apps/web:checklist)
```

- [ ] **Step 3 (criterion 4):** `bats tests/new-vite-react.bats` all PASS.

- [ ] **Step 4 (criterion 5):** Run `./scripts/deploy-check.sh vite-react` and `./scripts/deploy-check.sh vite-react nestjs --db postgres`. Both PASS.

- [ ] **Step 5 (criterion 6):** `./scripts/adapter-matrix.sh pull_request ""` lists `vite-react` in the Tier A matrix, and `git diff main -- .github/workflows/adapters.yml` is empty.

- [ ] **Step 6 (criterion 7):** Re-run Task 2 Step 2's ADR check.

- [ ] **Step 7:** Delete the probes: `rm -rf ../probe ../probe2 ../probe3`, and `docker image ls | grep deploy-check` to remove any local images the gate left.
