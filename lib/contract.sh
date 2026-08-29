# shellcheck shell=bash

# the task names ci is allowed to call. a name joins this list only when every
# adapter implements it and ci needs to call it — see docs/decisions/0011.
# shellcheck disable=SC2034 # read by lib/lint.sh once sourced
CONTRACT_TASKS=(install format format-fix lint check test build ci-unit checklist)

# every adapter directory must ship these four files.
# shellcheck disable=SC2034 # read by lib/lint.sh once sourced
REQUIRED_ADAPTER_FILES=(adapter.env mise.toml Dockerfile .env.example)
