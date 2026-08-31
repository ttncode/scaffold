# shellcheck shell=bash
# The contract every adapter satisfies — see docs/decisions/0011.
# shellcheck disable=SC2034 # all read by lib/lint.sh once sourced

CONTRACT_TASKS=(install format format-fix lint check test build ci-unit checklist)

REQUIRED_ADAPTER_FILES=(adapter.env mise.toml Dockerfile .env.example)

# apply_adapter evals ADAPTER_GENERATOR, so a missing one dies mid-generation
# with `unbound variable` instead of failing at `scaffold lint`.
REQUIRED_ADAPTER_VARS=(ADAPTER_NAME ADAPTER_ROLE ADAPTER_GENERATOR)

READ_ONLY_TASKS=(format lint check)

# Catches a read-only task copied from its own -fix sibling. Cannot catch a
# tool that writes by default with no flag saying so.
WRITING_FLAGS=(--write --fix -w --in-place --overwrite)
