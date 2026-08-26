# shellcheck shell=bash

# lint_adapters <adapters-dir>
# prints one line per problem and returns 1 when any adapter is incomplete.
lint_adapters() {
  local dir="$1"
  local adapter name file task status=0

  for adapter in "$dir"/*/; do
    [ -d "$adapter" ] || continue
    name="$(basename "$adapter")"

    for file in "${REQUIRED_ADAPTER_FILES[@]}"; do
      if [ ! -f "${adapter}${file}" ]; then
        printf '%s: missing file %s\n' "$name" "$file"
        status=1
      fi
    done

    [ -f "${adapter}mise.toml" ] || continue

    for task in "${CONTRACT_TASKS[@]}"; do
      # the header is quoted when the task name contains a dash
      if ! grep -Eq "^\[tasks\.\"?${task}\"?\]" "${adapter}mise.toml"; then
        printf '%s: missing task %s\n' "$name" "$task"
        status=1
      fi
    done
  done

  return "$status"
}
