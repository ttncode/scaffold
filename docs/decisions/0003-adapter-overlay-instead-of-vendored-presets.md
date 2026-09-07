# 0003 — Adapter overlay instead of vendored presets

Status: Accepted
Date: 2026-08-26

## Context

Supporting many stacks cheaply, without owning an entire generated
application per stack.

## Decision

Invoke each framework's own generator and overlay four files.

**Amendment, 2026-09-06 (0021).** The boundary was "an adapter overlays
configuration, it never writes application code." It narrows to: no
application code except the health routes 0021's deploy gate requires — one
liveness route per adapter, and a readiness route for every adapter that
can hold a database. The exception stays narrow on purpose: one route per
concern, owned by the same adapter that already declares the Dockerfile
and the path the route answers on, and nothing else in a generated `apps/`
tree is adapter-authored. A route that only proves a listener answers, or
only proves a database connection opens, is not the same claim as "this
adapter generates the application" — it is the minimum the gate needs to
tell a dead deploy from a live one, which invoking the framework's own
generator cannot provide on its own.

## Consequences

About 40–80 lines owned per stack instead of an entire application.
Generation requires network. Upstream generator changes surface as
smoke-test failures.

## Alternatives considered

- Vendoring a complete application per stack. Rejected: 800–2000 lines per
  stack that fall behind upstream.
