# 0012 — Tiered adapter support

Status: Accepted
Date: 2026-08-27

## Context

The overlay mechanism supports any number of stacks, but each stack CI
guarantees is a pipeline branch that must stay green through every dependency
bump.

Task 13 measured the suite instead of assuming it: 67 tests, 35-50 minutes
clean, and `tests/new-laravel-inertia.bats` alone accounts for roughly 25 of
those minutes — each of its five tests runs a full `composer create-project`,
`npm install` and Vite build. `nextjs`, `nestjs` and `laravel-api` together
cost a fraction of that. The tier list below originally put `laravel-inertia`
in Tier A on the strength of the argument in "Alternatives considered"; the
measurement contradicts that placement, so this decision is revised here
rather than left to quietly diverge from what CI actually does.

## Decision

Three tiers, by measured cost. Tier A (`nextjs`, `nestjs`, `laravel-api`)
runs on every pull request and nightly. Tier B (`laravel-inertia`) runs when
its own directory changes plus weekly — 25 minutes is far past what anyone
will wait on before pushing. Tier C has no automated verification and is
allowed to rot.

Tier membership lives in one place: each adapter's own `ADAPTER_TIER`
(`adapter.env`). Workflows read it (`scripts/adapter-matrix.sh`, backed by
`scaffold list`) rather than repeating the adapter list in YAML, so the tier
recorded on the adapter and the tier CI actually runs cannot drift apart
silently. Moving an adapter between tiers means editing its `ADAPTER_TIER`,
not the workflow.

## Consequences

"Supported" and "guaranteed" are different words and the README says so, now
naming which adapter carries which guarantee.

A weekly-only lane is easy to stop watching; `.github/workflows/adapters.yml`
opens an issue on a scheduled-run failure so Tier B rot surfaces where a
person will see it, not just in a run nobody opens.

## Alternatives considered

- Verifying every adapter on every pull request. Rejected: a fifteen-minute
  pull-request cycle gets switched off within a fortnight — and
  `laravel-inertia` alone measures at ~25 minutes, confirming the original
  worry more strongly than assumed.
