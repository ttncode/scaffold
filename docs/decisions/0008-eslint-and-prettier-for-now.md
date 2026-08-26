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

## Alternatives considered

- oxlint immediately. Rejected: loses rules that matter more than speed at
  this size.
