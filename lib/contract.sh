# shellcheck shell=bash
# The contract every adapter satisfies — see docs/decisions/0011.
# shellcheck disable=SC2034 # all read by lib/lint.sh once sourced

CONTRACT_TASKS=(install format format-fix lint check test build ci-unit checklist)

REQUIRED_ADAPTER_FILES=(adapter.env mise.toml Dockerfile .env.example)

# apply_adapter evals ADAPTER_GENERATOR, so a missing one dies mid-generation
# with `unbound variable` instead of failing at `scaffold lint`. ADAPTER_FAMILY
# is the same story one step later: apply_service_drivers looks up
# drivers/${family}.sh only once generation is already underway.
REQUIRED_ADAPTER_VARS=(ADAPTER_NAME ADAPTER_ROLE ADAPTER_FAMILY ADAPTER_GENERATOR)

READ_ONLY_TASKS=(format lint check)

# Catches a read-only task copied from its own -fix sibling. Cannot catch a
# tool that writes by default with no flag saying so.
WRITING_FLAGS=(--write --fix -w --in-place --overwrite)

# apply_service_drivers sources these and calls both, so a service shipping
# neither fails at generation rather than at lint.
REQUIRED_SERVICE_FILES=(
  service.env
  compose.fragment.yaml
  compose.prod.fragment.yaml
  compose.dev.fragment.yaml
  compose.test.fragment.yaml
  env.fragment
)

REQUIRED_SERVICE_VARS=(SERVICE_NAME SERVICE_KIND SERVICE_IMAGE)

# The web tier is the presentation layer and opens no connection, so it takes
# no driver — stated once, about the role, rather than as a "not applicable"
# entry repeated in every service.
DRIVEN_ROLES=(api app)
