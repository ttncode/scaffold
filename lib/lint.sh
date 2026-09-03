# shellcheck shell=bash

# lint_adapters <adapters-dir>
# prints one line per problem and returns 1 when any adapter is incomplete.
lint_adapters() {
  local dir="$1"
  local adapter name file task task_body flag var status=0

  for adapter in "$dir"/*/; do
    [ -d "$adapter" ] || continue
    name="$(basename "$adapter")"

    for file in "${REQUIRED_ADAPTER_FILES[@]}"; do
      if [ ! -f "${adapter}${file}" ]; then
        printf '%s: missing file %s\n' "$name" "$file"
        status=1
      fi
    done

    if [ -f "${adapter}adapter.env" ]; then
      for var in "${REQUIRED_ADAPTER_VARS[@]}"; do
        grep -Eq "^${var}=" "${adapter}adapter.env" || {
          printf '%s: adapter.env does not set %s\n' "$name" "$var"
          status=1
        }
      done
    fi

    [ -f "${adapter}mise.toml" ] || continue

    for task in "${CONTRACT_TASKS[@]}"; do
      # both the bare and quoted spelling are valid toml, so tolerate either
      if ! grep -Eq "^\[tasks\.\"?${task}\"?\]" "${adapter}mise.toml"; then
        printf '%s: missing task %s\n' "$name" "$task"
        status=1
      fi
    done

    for task in "${READ_ONLY_TASKS[@]}"; do
      task_body="$(task_body "${adapter}mise.toml" "$task")"
      for flag in "${WRITING_FLAGS[@]}"; do
        case " $task_body " in
          *" ${flag} "*|*" ${flag}="*)
            printf '%s: %s writes (%s) — %s must report, not repair; see docs/decisions/0011\n' \
              "$name" "$task" "$flag" "$task"
            status=1
            ;;
        esac
      done
    done
  done

  return "$status"
}

# lint_services <services-dir> <adapters-dir>
# prints one line per problem and returns 1 when any service is incomplete or
# any family that takes a driver has no driver in some service.
lint_services() {
  local dir="$1" adapters="$2"
  local service name file var family status=0
  local -a families=()

  # The families to require, read from the adapters themselves rather than
  # listed here: a list would be a second copy of the same fact, and the copy
  # is what goes stale.
  local adapter role
  for adapter in "$adapters"/*/; do
    [ -f "${adapter}adapter.env" ] || continue
    role="$(sed -n 's/^ADAPTER_ROLE="\(.*\)"$/\1/p' "${adapter}adapter.env")"
    case " ${DRIVEN_ROLES[*]} " in
      *" ${role} "*) ;;
      *) continue ;;
    esac
    family="$(sed -n 's/^ADAPTER_FAMILY="\(.*\)"$/\1/p' "${adapter}adapter.env")"
    [ -n "$family" ] || continue
    case " ${families[*]-} " in
      *" ${family} "*) ;;
      *) families+=("$family") ;;
    esac
  done

  for service in "$dir"/*/; do
    [ -d "$service" ] || continue
    name="$(basename "$service")"
    # services/shared holds the parameterised driver bodies, not a service
    [ "$name" = shared ] && continue

    for file in "${REQUIRED_SERVICE_FILES[@]}"; do
      if [ ! -f "${service}${file}" ]; then
        printf '%s: missing file %s\n' "$name" "$file"
        status=1
      fi
    done

    if [ -f "${service}service.env" ]; then
      for var in "${REQUIRED_SERVICE_VARS[@]}"; do
        grep -Eq "^${var}=" "${service}service.env" || {
          printf '%s: service.env does not set %s\n' "$name" "$var"
          status=1
        }
      done
      grep -q '@sha256:' "${service}service.env" || {
        printf '%s: SERVICE_IMAGE is not pinned by digest\n' "$name"
        status=1
      }
    fi

    for family in "${families[@]}"; do
      [ -f "${service}drivers/${family}.sh" ] || {
        printf '%s: no driver for %s\n' "$name" "$family"
        status=1
      }
    done
  done

  return "$status"
}

# task_body <mise.toml> <task>
# prints every line of one task's table, which is enough to see what it runs:
# a `run` value can be a single string or an array spanning several lines, and
# both are covered by printing the whole table rather than parsing the value.
task_body() {
  awk -v task="$2" '
    $0 ~ "^\\[tasks\\.\"?" task "\"?\\]$" { inside = 1; next }
    inside && /^\[/ { exit }
    # a comment is not what the task runs, and a trailing one belongs to the
    # next table: a note above [tasks.format-fix] otherwise reads as the
    # previous task writing
    inside && /^[[:space:]]*#/ { next }
    inside { print }
  ' "$1"
}
