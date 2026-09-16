# syntax=docker/dockerfile:1

FROM node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f AS build
WORKDIR /app
RUN corepack enable
# pnpm-workspace.yaml holds the allowBuilds policy (ADR-0017); without it pnpm
# refuses unrs-resolver's postinstall build non-interactively.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY . .
# @SERVICE_SETUP@
RUN pnpm exec nest build && pnpm prune --prod

FROM node:24.15.0-alpine@sha256:d1b3b4da11eefd5941e7f0b9cf17783fc99d9c6fc34884a665f40a06dbdfc94f AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
# The migrate service reads the schema from here. `pris[m]a` copies nothing on a
# --db none project, where a bare `prisma` would fail the build.
COPY --from=build /app/pris[m]a ./prisma
USER node
# The container port compose.yaml publishes; main.ts reads PORT.
ENV PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://localhost:8080/health/live || exit 1
CMD ["node", "dist/main.js"]
