# 0012 — Tiered adapter support

Status: Accepted
Date: 2026-08-27

## Context

The overlay mechanism supports any number of stacks, but each stack CI
guarantees is a pipeline branch that must stay green through every dependency
bump.

## Decision

Three tiers. Tier A (`nextjs`, `nestjs`, `laravel-api`, `laravel-inertia`)
runs on every pull request and nightly. Tier B runs when its own directory
changes plus weekly. Tier C has no automated verification and is allowed to
rot.

## Consequences

"Supported" and "guaranteed" are different words and the README says so.

## Alternatives considered

- Verifying every adapter on every pull request. Rejected: a fifteen-minute
  pull-request cycle gets switched off within a fortnight.
