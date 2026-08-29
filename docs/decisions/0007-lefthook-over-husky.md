# 0007 — lefthook over husky

Status: Accepted
Date: 2026-08-26

## Context

Git hooks must work in a PHP-only project.

## Decision

lefthook, installed by mise.

## Consequences

Hooks run in parallel and no project needs Node solely for hooks; adapters
contribute fragments merged into one `lefthook.yml`.

## Alternatives considered

- husky. Rejected: Node-only.
- pre-commit (the Python tool). Rejected: adds a Python runtime to every
  project.
