# shellcheck shell=bash

# the task names ci is allowed to call. a name joins this list only when every
# adapter implements it and ci needs to call it — see docs/decisions/0011.
# shellcheck disable=SC2034 # read by lib/lint.sh once sourced
CONTRACT_TASKS=(install format format-fix lint check test build ci-unit checklist)

# every adapter.env must set these. ADAPTER_GENERATOR missing is the one that
# matters: apply_adapter evals it, so a typo'd or absent name fails at
# generation time with `unbound variable` rather than at `scaffold lint`.
# shellcheck disable=SC2034 # read by lib/lint.sh once sourced
REQUIRED_ADAPTER_VARS=(ADAPTER_NAME ADAPTER_ROLE ADAPTER_GENERATOR)

# every adapter directory must ship these four files.
# shellcheck disable=SC2034 # read by lib/lint.sh once sourced
REQUIRED_ADAPTER_FILES=(adapter.env mise.toml Dockerfile .env.example)

# the three contract tasks that report without repairing. ADR-0011: a checking
# task that repairs its own input passes locally and fails in CI, because CI
# runs it against a tree it must not modify.
# shellcheck disable=SC2034 # read by lib/lint.sh once sourced
READ_ONLY_TASKS=(format lint check)

# substrings that mean a command edits what it reads. Matching text rather than
# running anything is a deliberate limit: it catches the mistake this guard
# exists for — a read-only task copied from its own -fix sibling — and cannot
# catch a tool that writes by default with no flag saying so.
# shellcheck disable=SC2034 # read by lib/lint.sh once sourced
WRITING_FLAGS=(--write --fix -w --in-place --overwrite)
