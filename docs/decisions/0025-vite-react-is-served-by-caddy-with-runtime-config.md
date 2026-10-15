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
