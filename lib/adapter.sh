# shellcheck shell=bash

# load_adapter <name> — read one adapter's metadata into the current shell.
load_adapter() {
  local name="$1"
  local dir="${SCAFFOLD_ROOT}/adapters/${name}"

  [ -d "$dir" ] || die "unknown adapter: ${name} (run: scaffold list)"

  # shellcheck disable=SC2034 # ADAPTER_DIR is consumed by apply_adapter, which Task 4 adds
  ADAPTER_DIR="$dir"
  # shellcheck source=/dev/null
  source "${dir}/adapter.env"
}
