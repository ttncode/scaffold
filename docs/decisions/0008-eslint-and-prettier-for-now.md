# 0008 — ESLint and Prettier for now

Status: Accepted
Date: 2026-08-26

## Context

oxlint and oxfmt are markedly faster and already used by Vite and Plane.

## Decision

ESLint and Prettier for now.

## Consequences

Slower linting, full plugin coverage including `eslint-config-next`. Revisit
when oxlint covers the Next.js and accessibility rule sets.

`@nestjs/cli`'s v12 application template dropped ESLint for oxlint upstream
(no choice made here), so the `nestjs` adapter's `lint` task runs oxlint, not
ESLint — the trigger condition above fired for that one adapter before this
project revisited it. `nextjs` is unaffected and still runs ESLint.

## Alternatives considered

- oxlint immediately. Rejected: loses rules that matter more than speed at
  this size.
