# 0004 — Keep the toolbox out of generated projects

Status: Accepted
Date: 2026-08-26

## Context

A generated project must not carry stacks it does not use.

## Decision

The toolbox is a separate repository. `scaffold` copies `common/` and the
chosen adapters into a fresh repository and nothing else; there is no prune
step.

## Consequences

Generated projects are clean, but they do not receive toolbox fixes — which is
why CI lives in reusable workflows (ADR-0005).

## Alternatives considered

- A GitHub template repository plus a prune script. Rejected: the initial
  state contains other stacks, and pruning misses things.
