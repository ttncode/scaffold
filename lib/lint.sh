# ═══════════════════════════════════════════════════════════════════════════
# Script      : lib/lint.sh
# Description : Check every adapter and service against the contract.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck shell=bash

# adapter_env_value <adapter.env> <var> — the value of one quoted assignment.
adapter_env_value() {
  sed -n "s/^${2}=\"\(.*\)\"\$/\1/p" "$1"
}

# task_body <mise.toml> <task> — every line of one task's table. A `run` value
# can be a string or an array spanning several lines, and printing the whole
# table covers both without parsing either.
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

# driver_families <adapters-dir> — the families that take a driver, read from
# the adapters themselves rather than listed here: a list would be a second
# copy of the same fact, and the copy is what goes stale.
driver_families() {
  local adapter role family
  local -a families=()

  for adapter in "$1"/*/; do
    [ -f "${adapter}adapter.env" ] || continue
    role="$(adapter_env_value "${adapter}adapter.env" ADAPTER_ROLE)"
    case " ${DRIVEN_ROLES[*]} " in
      *" ${role} "*) ;;
      *) continue ;;
    esac
    family="$(adapter_env_value "${adapter}adapter.env" ADAPTER_FAMILY)"
    [ -n "$family" ] || continue
    case " ${families[*]-} " in
      *" ${family} "*) ;;
      *) families+=("$family") ;;
    esac
  done

  [ "${#families[@]}" -gt 0 ] || return 0
  printf '%s\n' "${families[@]}"
}

# lint_adapters <adapters-dir>
# prints one line per problem and returns 1 when any adapter is incomplete.
# Every lint_* function prints one line per problem and returns 1 when it found
# any, so a caller can run them all and still fail once at the end.

lint_required_files() {
  local name="$1" dir="$2"; shift 2
  local file status=0

  for file in "$@"; do
    if [ ! -f "${dir}${file}" ]; then
      printf '%s: missing file %s\n' "$name" "$file"
      status=1
    fi
  done
  return "$status"
}

lint_adapter_env() {
  local name="$1" file="$2"
  local var role value status=0

  for var in "${REQUIRED_ADAPTER_VARS[@]}"; do
    grep -Eq "^${var}=" "$file" || {
      printf '%s: adapter.env does not set %s\n' "$name" "$var"
      status=1
    }
  done

  # Conditional on the role rather than required outright: a web adapter has no
  # connection to probe, and demanding a readiness path from it would only
  # produce one that returns 200 without doing anything.
  role="$(adapter_env_value "$file" ADAPTER_ROLE)"
  case " ${DRIVEN_ROLES[*]} " in
    *" ${role} "*)
      grep -Eq '^ADAPTER_READINESS_PATH=' "$file" || {
        printf '%s: adapter.env does not set ADAPTER_READINESS_PATH (required for role %s)\n' "$name" "$role"
        status=1
      }
      ;;
  esac

  # A path variable that merely exists is not a route: an empty value satisfies
  # every check above, then collapses compose.bats' HEALTHCHECK assertion and
  # the deploy gate's readiness curl into matching any probe on localhost:8080 —
  # the defect these exist to stop.
  for var in ADAPTER_LIVENESS_PATH ADAPTER_READINESS_PATH; do
    grep -Eq "^${var}=" "$file" || continue
    value="$(adapter_env_value "$file" "$var")"
    case "$value" in
      /*) ;;
      *)
        printf '%s: adapter.env sets %s to "%s", not a path starting with /\n' "$name" "$var" "$value"
        status=1
        ;;
    esac
  done

  return "$status"
}

lint_adapter_tasks() {
  local name="$1" file="$2"
  local task body flag status=0

  for task in "${CONTRACT_TASKS[@]}"; do
    # both the bare and quoted spelling are valid toml, so tolerate either
    if ! grep -Eq "^\[tasks\.\"?${task}\"?\]" "$file"; then
      printf '%s: missing task %s\n' "$name" "$task"
      status=1
    fi
  done

  for task in "${READ_ONLY_TASKS[@]}"; do
    body="$(task_body "$file" "$task")"
    for flag in "${WRITING_FLAGS[@]}"; do
      case " $body " in
        *" ${flag} "*|*" ${flag}="*)
          printf '%s: %s writes (%s) — %s must report, not repair; see docs/decisions/0011\n' \
            "$name" "$task" "$flag" "$task"
          status=1
          ;;
      esac
    done
  done

  return "$status"
}

lint_adapters() {
  local dir="$1"
  local adapter name status=0

  for adapter in "$dir"/*/; do
    [ -d "$adapter" ] || continue
    name="$(basename "$adapter")"

    lint_required_files "$name" "$adapter" "${REQUIRED_ADAPTER_FILES[@]}" || status=1
    [ -f "${adapter}adapter.env" ] && { lint_adapter_env "$name" "${adapter}adapter.env" || status=1; }
    [ -f "${adapter}mise.toml" ] && { lint_adapter_tasks "$name" "${adapter}mise.toml" || status=1; }
  done

  return "$status"
}

lint_service_env() {
  local name="$1" file="$2"
  local var status=0

  for var in "${REQUIRED_SERVICE_VARS[@]}"; do
    grep -Eq "^${var}=" "$file" || {
      printf '%s: service.env does not set %s\n' "$name" "$var"
      status=1
    }
  done
  grep -q '@sha256:' "$file" || {
    printf '%s: SERVICE_IMAGE is not pinned by digest\n' "$name"
    status=1
  }

  return "$status"
}

# A subshell per function, or one family's LARAVEL_* parameters (read unqualified
# in services/shared/laravel.sh) leak into the next driver checked.
#
# SERVICE_DIR set before sourcing, as load_service sets it: a driver that reads
# it at sourcing time and finds it unbound dies under the inherited `set -u`,
# which is not the same problem as a missing function.
lint_driver_functions() {
  local name="$1" family="$2" driver="$3" service_dir="$4"
  local fn fault status=0

  for fn in "${REQUIRED_DRIVER_FUNCTIONS[@]}"; do
    if ! fault="$( {
      # shellcheck disable=SC2034 # read by the driver, not by this loop
      SERVICE_DIR="$service_dir"
      # shellcheck source=/dev/null # family varies, so the path isn't constant
      . "$driver"
      declare -F "$fn" >/dev/null
    } 2>&1 )"; then
      if [ -n "$fault" ]; then
        printf '%s: %s driver failed to source: %s\n' "$name" "$family" "$fault"
      else
        printf '%s: %s driver does not define %s\n' "$name" "$family" "$fn"
      fi
      status=1
    fi
  done

  return "$status"
}

lint_service_drivers() {
  local name="$1" service="$2"; shift 2
  local family driver status=0

  for family in "$@"; do
    driver="${service}drivers/${family}.sh"
    if [ ! -f "$driver" ]; then
      printf '%s: no driver for %s\n' "$name" "$family"
      status=1
      continue
    fi
    lint_driver_functions "$name" "$family" "$driver" "${service%/}" || status=1
  done

  return "$status"
}

# lint_services <services-dir> <adapters-dir>
# Fails when any service is incomplete, or when a family that takes a driver has
# no driver in some service.
lint_services() {
  local dir="$1" adapters="$2"
  local service name status=0
  local -a families=()

  mapfile -t families < <(driver_families "$adapters")

  for service in "$dir"/*/; do
    [ -d "$service" ] || continue
    name="$(basename "$service")"
    [ "$name" = "$SHARED_DRIVERS_DIR" ] && continue

    lint_required_files "$name" "$service" "${REQUIRED_SERVICE_FILES[@]}" || status=1
    [ -f "${service}service.env" ] && { lint_service_env "$name" "${service}service.env" || status=1; }
    lint_service_drivers "$name" "$service" ${families[@]+"${families[@]}"} || status=1
  done

  return "$status"
}
