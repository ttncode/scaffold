# The contract every adapter and service satisfies (ADR-0011).
# shellcheck shell=bash
# shellcheck disable=SC2034 # all read by lib/lint.sh once sourced

CONTRACT_TASKS=(install format format-fix lint check test build ci-unit checklist)

READ_ONLY_TASKS=(format lint check)

# Catches a read-only task copied from its -fix sibling, not a tool that writes
# by default.
WRITING_FLAGS=(--write --fix -w --in-place --overwrite)

REQUIRED_ADAPTER_FILES=(adapter.env mise.toml Dockerfile .env.example)

# ADAPTER_GENERATOR and ADAPTER_FAMILY are read mid-generation, where a missing
# one dies as `unbound variable`.
REQUIRED_ADAPTER_VARS=(ADAPTER_NAME ADAPTER_ROLE ADAPTER_FAMILY ADAPTER_GENERATOR ADAPTER_LIVENESS_PATH)

REQUIRED_SERVICE_FILES=(
  service.env
  compose.fragment.yaml
  compose.prod.fragment.yaml
  compose.dev.fragment.yaml
  compose.test.fragment.yaml
  env.fragment
)

# The compose fragments carry no image line: the digest lives only in SERVICE_IMAGE.
REQUIRED_SERVICE_VARS=(SERVICE_NAME SERVICE_KIND SERVICE_IMAGE)

# Parameterised driver bodies every service sources, not a service.
SHARED_DRIVERS_DIR=shared

# A cache implements compose_migrate too, printing nothing.
REQUIRED_DRIVER_FUNCTIONS=(service_driver_apply service_driver_dockerfile service_driver_compose_env service_driver_compose_migrate)

# The web tier opens no connection, so it takes no driver.
DRIVEN_ROLES=(api app)

# ADR-0020. The wizard orders its default from this too.
DEFAULT_DATABASE_SERVICE=mysql
