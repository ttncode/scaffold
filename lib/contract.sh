# ═══════════════════════════════════════════════════════════════════════════
# Script      : lib/contract.sh
# Description : The contract every adapter and service satisfies (ADR-0011).
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck shell=bash
# shellcheck disable=SC2034 # all read by lib/lint.sh once sourced

CONTRACT_TASKS=(install format format-fix lint check test build ci-unit checklist)

READ_ONLY_TASKS=(format lint check)

# Catches a read-only task copied from its own -fix sibling. Cannot catch a
# tool that writes by default with no flag saying so.
WRITING_FLAGS=(--write --fix -w --in-place --overwrite)

REQUIRED_ADAPTER_FILES=(adapter.env mise.toml Dockerfile .env.example)

# Both are read mid-generation — ADAPTER_GENERATOR by apply_adapter's eval,
# ADAPTER_FAMILY by the drivers/ lookup — so missing, they fail there with
# `unbound variable` instead of at `scaffold lint`.
REQUIRED_ADAPTER_VARS=(ADAPTER_NAME ADAPTER_ROLE ADAPTER_FAMILY ADAPTER_GENERATOR ADAPTER_LIVENESS_PATH)

REQUIRED_SERVICE_FILES=(
  service.env
  compose.fragment.yaml
  compose.prod.fragment.yaml
  compose.dev.fragment.yaml
  compose.test.fragment.yaml
  env.fragment
)

REQUIRED_SERVICE_VARS=(SERVICE_NAME SERVICE_KIND SERVICE_IMAGE)

# Holds the parameterised driver bodies every service sources, not a service.
SHARED_DRIVERS_DIR=shared

# A cache implements compose_migrate too: it has no schema and prints nothing.
REQUIRED_DRIVER_FUNCTIONS=(service_driver_apply service_driver_dockerfile service_driver_compose_env service_driver_compose_migrate)

# The web tier opens no connection, so it takes no driver. Stated once about the
# role rather than as a "not applicable" entry in every service.
DRIVEN_ROLES=(api app)

# What cmd_new picks when a project has a backend and --db was not given
# (ADR-0020). The wizard's default ordering reads this too, so a plain Enter
# cannot drift from what an omitted flag would pick.
DEFAULT_DATABASE_SERVICE=mysql
