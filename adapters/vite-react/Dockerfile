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
