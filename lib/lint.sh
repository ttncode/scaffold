# Check every adapter and service against the contract.
# shellcheck shell=bash
#
# Every lint_* function prints one line per problem and returns 1 when it found
# any, so a caller runs them all and fails once at the end.

adapter_env_value() {
  local -r file="$1" var="$2"

  sed -n "s/^${var}=\"\(.*\)\"\$/\1/p" "$file"
}

# Prints the whole table, so a `run` string and a multi-line array both work.
task_body() {
  local -r file="$1" task="$2"

  awk -v task="$task" '
    $0 ~ "^\\[tasks\\.\"?" task "\"?\\]$" { inside = 1; next }
    inside && /^\[/ { exit }
    # a trailing comment belongs to the next table
    inside && /^[[:space:]]*#/ { next }
    inside { print }
  ' "$file"
}

# Read from the adapters, not listed here, so it cannot go stale.
driver_families() {
  local -r adapters="$1"
  local adapter role family
  local -a families=()

  for adapter in "$adapters"/*/; do
    [[ -f "${adapter}adapter.env" ]] || continue
    role="$(adapter_env_value "${adapter}adapter.env" ADAPTER_ROLE)"
    case " ${DRIVEN_ROLES[*]} " in
      *" ${role} "*) ;;
      *) continue ;;
    esac
    family="$(adapter_env_value "${adapter}adapter.env" ADAPTER_FAMILY)"
    [[ -n "$family" ]] || continue
    case " ${families[*]-} " in
      *" ${family} "*) ;;
      *) families+=("$family") ;;
    esac
  done

  ((${#families[@]} > 0)) || return 0
  printf '%s\n' "${families[@]}"
}

lint_required_files() {
  local -r name="$1" dir="$2"
  shift 2
  local file status=0

  for file in "$@"; do
    if [[ ! -f "${dir}${file}" ]]; then
      printf '%s: missing file %s\n' "$name" "$file"
      status=1
    fi
  done
  return "$status"
}

lint_adapter_env() {
  local -r name="$1" file="$2"
  local var status=0

  for var in "${REQUIRED_ADAPTER_VARS[@]}"; do
    grep -Eq "^${var}=" "$file" || {
      printf '%s: adapter.env does not set %s\n' "$name" "$var"
      status=1
    }
  done

  lint_readiness_path_declared "$name" "$file" || status=1
  lint_route_paths "$name" "$file" || status=1

  return "$status"
}

# Only a driven role: a web adapter has no connection, and a required readiness
# path would only produce one that returns 200 doing nothing.
lint_readiness_path_declared() {
  local -r name="$1" file="$2"
  local role

  role="$(adapter_env_value "$file" ADAPTER_ROLE)"
  case " ${DRIVEN_ROLES[*]} " in
    *" ${role} "*) ;;
    *) return 0 ;;
  esac

  grep -Eq '^ADAPTER_READINESS_PATH=' "$file" && return 0
  printf '%s: adapter.env does not set ADAPTER_READINESS_PATH (required for role %s)\n' "$name" "$role"
  return 1
}

# An empty path would make the HEALTHCHECK assertion and the deploy gate's curl
# match any probe on localhost:8080.
lint_route_paths() {
  local -r name="$1" file="$2"
  local var value status=0

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
  local -r name="$1" file="$2"
  local task status=0

  for task in "${CONTRACT_TASKS[@]}"; do
    if ! grep -Eq "^\[tasks\.\"?${task}\"?\]" "$file"; then
      printf '%s: missing task %s\n' "$name" "$task"
      status=1
    fi
  done

  lint_read_only_tasks "$name" "$file" || status=1

  return "$status"
}

lint_read_only_tasks() {
  local -r name="$1" file="$2"
  local task body flag status=0

  for task in "${READ_ONLY_TASKS[@]}"; do
    body="$(task_body "$file" "$task")"
    for flag in "${WRITING_FLAGS[@]}"; do
      case " $body " in
        *" ${flag} "* | *" ${flag}="*)
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
  local -r dir="$1"
  local adapter name status=0

  for adapter in "$dir"/*/; do
    [[ -d "$adapter" ]] || continue
    name="$(basename "$adapter")"

    lint_required_files "$name" "$adapter" "${REQUIRED_ADAPTER_FILES[@]}" || status=1
    [[ -f "${adapter}adapter.env" ]] && { lint_adapter_env "$name" "${adapter}adapter.env" || status=1; }
    [[ -f "${adapter}mise.toml" ]] && { lint_adapter_tasks "$name" "${adapter}mise.toml" || status=1; }
  done

  return "$status"
}

lint_service_env() {
  local -r name="$1" file="$2"
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

# A subshell per function, or one family's LARAVEL_* parameters leak into the
# next driver checked. SERVICE_DIR is set first, as load_service sets it: a
# driver reading it unbound would die under `set -u` and report as a missing
# function.
lint_driver_functions() {
  local -r name="$1" family="$2" driver="$3" service_dir="$4"
  local fn fault status=0

  for fn in "${REQUIRED_DRIVER_FUNCTIONS[@]}"; do
    if ! fault="$({
      # shellcheck disable=SC2034 # read by the driver, not by this loop
      SERVICE_DIR="$service_dir"
      # shellcheck source=/dev/null # family varies, so the path isn't constant
      . "$driver"
      declare -F "$fn" >/dev/null
    } 2>&1)"; then
      if [[ -n "$fault" ]]; then
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
  local -r name="$1" service="$2"
  shift 2
  local family driver status=0

  for family in "$@"; do
    driver="${service}drivers/${family}.sh"
    if [[ ! -f "$driver" ]]; then
      printf '%s: no driver for %s\n' "$name" "$family"
      status=1
      continue
    fi
    lint_driver_functions "$name" "$family" "$driver" "${service%/}" || status=1
  done

  return "$status"
}

lint_services() {
  local -r dir="$1" adapters="$2"
  local service name status=0
  local -a families=()

  mapfile -t families < <(driver_families "$adapters")

  for service in "$dir"/*/; do
    [[ -d "$service" ]] || continue
    name="$(basename "$service")"
    [[ "$name" == "$SHARED_DRIVERS_DIR" ]] && continue

    lint_required_files "$name" "$service" "${REQUIRED_SERVICE_FILES[@]}" || status=1
    [[ -f "${service}service.env" ]] && { lint_service_env "$name" "${service}service.env" || status=1; }
    lint_service_drivers "$name" "$service" ${families[@]+"${families[@]}"} || status=1
  done

  return "$status"
}
