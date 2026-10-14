# `vite-react` adapter — design

Date: 2026-10-14
Origin: a request from the `opensocial` project for `vite-react` and `hono`
adapters. `opensocial` withdrew it; `vite-react` is kept as a general web
option. `hono`, its drivers and the mixed-project work are dropped. Two
`scaffold add` bugs found while checking the request are recorded separately
in `2026-10-14-scaffold-add-bugs.md`.

## Goal

A second `web` adapter for a React single-page app that builds to static
files, for projects that do not need Next.js's server. It pairs with any
existing api adapter, e.g. `scaffold new demo --web vite-react --api nestjs`.

Success:

1. `./scaffold lint` prints nothing and exits 0.
2. `./scaffold list --adapters` shows `vite-react`, role `web`, Tier A.
3. The runbook's "Verify" passes, including the second-TypeScript-app checks.
4. `bats tests/new-vite-react.bats` passes, including the assertion that the
   adapter adds no tool to the project root `mise.toml`.
5. The built image answers `/health/live` 200, serves `index.html` for an
   unknown path, serves `/config.json` from its `API_URL`, runs as non-root,
   and contains no Node; `./scripts/deploy-check.sh vite-react` passes.
6. `.github/workflows/adapters.yml` picks it up via `ADAPTER_TIER`, no edit.
7. ADR 0025 passes `common/docs/scripts/check-adrs.mjs`.

## Facts checked

Run in a scratch directory on 2026-10-14:

- create-vite is `9.2.1`. Its React templates default to oxlint; `--eslint`
  restores ESLint (ADR-0008).
- `pnpm create vite@9 v --template react-ts --eslint --no-immediate
  --no-interactive </dev/null` exits 0 without prompting and does not install.
- After `pnpm add -D prettier vitest`: `tsc -b` writes only
  `node_modules/.tmp/*.tsbuildinfo`, `eslint . --max-warnings 0` passes,
  `vite build` writes `dist/`. The template ships `typescript@~6.0.2`.
- `caddy:2-alpine` is `v2.11.7`; `caddy:2.11.7-alpine` is
  `sha256:d8542f48d34a9cf4e4c11a478865229840e87e4c96ea3f439101f31a5d35f75f`.
  The image's `XDG_CONFIG_HOME=/config`, `XDG_DATA_HOME=/data`.
- Not yet run: the Caddy runtime image. The plan's first task proves it.

## Adapter

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

`</dev/null` turns any new prompt into an EOF failure instead of a hang.

Overlay files:

| File | Content |
| --- | --- |
| `Caddyfile` | Global `admin off`, `auto_https off`, `persist_config off`. Site `:8080`: `handle /health/live { respond "ok" 200 }`; `handle /config.json` responds `{"apiUrl":"{$API_URL}"}` with `Content-Type: application/json` and `Cache-Control: no-store`; `handle { root * /srv; try_files {path} /index.html; file_server }` |
| `public/config.json` | `{"apiUrl":"http://localhost:3001"}` for `vite dev` (nestjs's dev port); Caddy's route shadows it in the image |
| `src/config.ts` | `loadConfig(): Promise<{ apiUrl: string }>` fetching `/config.json`. The template's `App` is left alone; this is the seam |
| `src/config.test.ts` | `loadConfig` returns a stubbed config, and rejects on a 404 |
| `mise.toml` | `install`, `format` = `prettier --check .`, `format-fix`, `lint` = `eslint . --max-warnings 0`, `check` = `tsc -b`, `test` = `vitest --run`, `build` = `vite build`, `ci-unit`, `checklist` |
| `Dockerfile`, `Dockerfile.workspace` | Node stage installs and runs `vite build`, carrying `# @SERVICE_SETUP@` (web takes no driver, but `apply_service_dockerfile` requires the anchor). Runtime: `caddy:2.11.7-alpine` by digest, `Caddyfile` to `/etc/caddy/Caddyfile`, `dist/` to `/srv`, `XDG_CONFIG_HOME`/`XDG_DATA_HOME` under `/tmp/caddy`, `USER nobody`, `EXPOSE 8080`, `HEALTHCHECK` with busybox `wget` on `http://127.0.0.1:8080/health/live`. No Node in the runtime image |
| `.dockerignore` | As `adapters/nextjs` |
| `.env.example` | `API_URL=` (runtime, read by Caddy; empty means same origin), and a comment: only `VITE_*` reach client code, baked in at build time, so per-environment values go through `/config.json` (ADR-0014) |
| `lefthook.fragment.yml` | `{}` |
| `.prettierignore` | `pnpm-lock.yaml`, `dist` |

`{$API_URL}` is substituted when Caddy loads its config at container start, so
one image serves every environment. The value is not escaped; it comes from
the operator, not a visitor.

## Tests

`tests/new-vite-react.bats`, from `tests/new-nextjs.bats`'s shape:

- generates `apps/web` with `index.html`, `Caddyfile`, `mise.toml`;
- adds no tool to the project root's `[tools]`;
- lints with ESLint, not oxlint;
- the generated app passes its own `checklist`;
- the `Caddyfile` has the health and config routes; the `Dockerfile` has one
  Node stage;
- `--api vite-react` is rejected as a role mismatch.

`tests/compose.bats` already enforces digests, `EXPOSE 8080` and the
liveness probe across every adapter Dockerfile.

## Docs

- ADR 0025: the `vite-react` runtime is Caddy serving static files, with
  runtime config at `/config.json`. Alternatives: nginx-unprivileged,
  build-time `VITE_*` only, same-origin `/api` behind a proxy.
- `README.md` and `docs/tour/08-adapters.md`: add the adapter row.

## Out of scope

`hono`, its service drivers, the mixed TypeScript + Python section, and the
two `scaffold add` bug fixes (separate spec).
