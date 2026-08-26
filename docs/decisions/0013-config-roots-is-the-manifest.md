# 0013 — config_roots is the manifest

Status: Accepted
Date: 2026-08-25

## Context

The toolbox needs to know which directories in a generated project are
independently buildable so CI can iterate over them.

## Decision

Use mise's `[monorepo] config_roots` as that list. Do not introduce a separate
`project.yaml`.

## Consequences

One file states which directories are apps. `scaffold` edits that array when it
adds an application, and derives the CI matrix input from it.

## Alternatives considered

- A dedicated `project.yaml` describing apps and roles. Rejected: a second file
  stating the same fact, which drifts from the first.
