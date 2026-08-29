# 0000 — Record architecture decisions

Status: Accepted
Date: 2026-08-29

## Context

A decision worth making is worth writing down: why it was made, what it cost,
and what would justify revisiting it. Without a record, that reasoning lives
only in whoever was in the room, and leaves with them.

## Decision

Every decision worth defending later gets one file in `docs/decisions`,
following `_template.md`: a number, a title, a status, the four sections
below, and nothing else. `check-adrs.mjs` enforces the shape; it does not
enforce that the reasoning inside it is good.

A decision is never edited to reflect a change of mind. A new ADR supersedes
the old one, which is marked `Superseded`.

## Consequences

Reading `docs/decisions` in order is reading this project's history of
tradeoffs, not just its current state. A future contributor can tell the
difference between "nobody thought of this" and "this was considered and
rejected, for a stated reason."

## Alternatives considered

- No record, relying on commit messages and memory. Rejected: a commit
  message explains a change, not the alternatives it beat.
