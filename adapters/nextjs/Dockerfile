# syntax=docker/dockerfile:1

FROM node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f AS deps
WORKDIR /app
RUN corepack enable
# pnpm-workspace.yaml holds the allowBuilds policy (ADR-0017); without it pnpm
# refuses unrs-resolver's postinstall build non-interactively.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

FROM node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f AS build
WORKDIR /app
RUN corepack enable
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# @SERVICE_SETUP@
RUN pnpm exec next build

FROM node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public
USER node
# The container port compose.yaml publishes; server.js reads PORT.
ENV PORT=8080
# Docker sets HOSTNAME to the container id, which server.js would bind to, and
# the HEALTHCHECK's loopback dial would never connect.
ENV HOSTNAME="0.0.0.0"
EXPOSE 8080
# 127.0.0.1, not localhost: "0.0.0.0" above is an IPv4-only bind, but this
# image's resolver hands wget the ::1 address for "localhost" first, and
# busybox wget does not fall back to the IPv4 result.
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://127.0.0.1:8080/api/health/live || exit 1
CMD ["node", "server.js"]
