# 0002 — No monorepo build orchestrator

Status: Accepted
Date: 2026-08-26

## Context

Monorepos commonly add Turborepo or Nx to orchestrate builds across
directories.

## Decision

None. mise `sources`/`outputs` already provides incremental caching if needed.

## Consequences

No pipeline configuration to learn. Revisit when `mise run checklist` becomes
slow enough to measure.

## Alternatives considered

- Turborepo. Rejected as premature for two applications.
