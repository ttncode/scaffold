# syntax=docker/dockerfile:1

FROM node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f AS deps
WORKDIR /app
RUN corepack enable
# pnpm-workspace.yaml carries the allowBuilds decisions ADR-0017 records —
# without it in the build context, pnpm has nothing to check unrs-resolver's
# postinstall build against and refuses non-interactively.
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
# next standalone output carries only the server files it actually needs
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public
USER node
# 8080 because that is the container port common/compose.yaml publishes, and
# nothing rewrites it — an adapter listening anywhere else publishes a dead
# port. next's standalone server.js reads PORT itself.
ENV PORT=8080
# Docker sets HOSTNAME to the container's own id, and the standalone
# server.js binds to `process.env.HOSTNAME || '0.0.0.0'` — so without this it
# listens on that id-derived address. Traffic from outside still reaches it,
# but the HEALTHCHECK below dials localhost from inside the container and
# fails forever while the app answers everyone else.
ENV HOSTNAME="0.0.0.0"
EXPOSE 8080
# 127.0.0.1, not localhost: "0.0.0.0" above is an IPv4-only bind, but this
# image's resolver hands wget the ::1 address for "localhost" first, and
# busybox wget does not fall back to the IPv4 result.
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://127.0.0.1:8080/api/health/live || exit 1
CMD ["node", "server.js"]
