# 0003 — Adapter overlay instead of vendored presets

Status: Accepted
Date: 2026-08-26

## Context

Supporting many stacks cheaply, without owning an entire generated
application per stack.

## Decision

Invoke each framework's own generator and overlay four files.

## Consequences

About 40–80 lines owned per stack instead of an entire application.
Generation requires network. Upstream generator changes surface as
smoke-test failures.

## Alternatives considered

- Vendoring a complete application per stack. Rejected: 800–2000 lines per
  stack that fall behind upstream.
