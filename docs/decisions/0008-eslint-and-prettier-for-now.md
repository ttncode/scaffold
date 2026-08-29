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

`@nestjs/cli`'s v12 application template dropped ESLint for oxlint upstream,
which looked like this ADR's own trigger condition firing for `nestjs` —
it is not, yet. v12 also drops jest for a vitest config with no
decorator-metadata transform, so Nest's own DI breaks in the generated
project's own default unit test (`adapters/nestjs/adapter.env` has the
full reproduction). `nestjs` stays pinned to `@nestjs/cli@11` and stays on
ESLint until that is fixed upstream, not because this ADR was revisited.

## Alternatives considered

- oxlint immediately. Rejected: loses rules that matter more than speed at
  this size.
