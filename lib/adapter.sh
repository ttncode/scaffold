# shellcheck shell=bash

# load_adapter <name> — read one adapter's metadata into the current shell.
load_adapter() {
  local name="$1"
  local dir="${SCAFFOLD_ROOT}/adapters/${name}"

  [ -d "$dir" ] || die "unknown adapter: ${name} (run: scaffold list)"

  export ADAPTER_DIR="$dir"
  # shellcheck source=/dev/null
  source "${dir}/adapter.env"
}
