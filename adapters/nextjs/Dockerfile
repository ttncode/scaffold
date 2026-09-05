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
EXPOSE 3000
# `/`, not `/api/health`: create-next-app generates no health route, so every
# image built from here reported unhealthy from first boot until somebody
# noticed and wrote one. An app that adds a real health endpoint should point
# this at it.
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://localhost:3000/ || exit 1
CMD ["node", "server.js"]
