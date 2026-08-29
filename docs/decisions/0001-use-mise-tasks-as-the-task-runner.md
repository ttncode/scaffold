# 0001 — Use mise tasks as the task runner

Status: Accepted
Date: 2026-08-26

## Context

A polyglot project needs one way to invoke per-directory work regardless of
what language that directory is written in.

## Decision

mise, using `monorepo_root` and `config_roots`, serves as both toolchain pin
and task runner.

## Consequences

One tool instead of three. `[tools]` blocks scope a language to a directory.

## Alternatives considered

- `just`. Rejected: a second tool doing what the first already does.
- `make`. Rejected: tab-sensitive syntax and no toolchain pinning.
