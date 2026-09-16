# Compose services, host ports, and per-framework service drivers.
# shellcheck shell=bash

COMPOSE_FILE="compose.yaml"
EXAMPLE_ENV_FILE="example.env"

COMPOSE_LANES=(prod dev test)

# ADR-0022: one container port, host ports allocated upward per application.
APP_CONTAINER_PORT=8080
FIRST_APP_PORT=8080

SERVICE_SETUP_ANCHOR="# @SERVICE_SETUP@"

# `source` below executes what it reads, so the name must not leave services/.
load_service() {
  local -r name="$1"

  case "$name" in
    '' | *[!a-z0-9-]* | -*) die "not a usable service name: ${name} (run: scaffold list)" ;;
  esac

  local -r dir="${SCAFFOLD_ROOT}/services/${name}"
  [[ -d "$dir" ]] || die "unknown service: ${name} (run: scaffold list)"

  # shellcheck disable=SC2034 # read by the caller
  SERVICE_DIR="$dir"
  unset -v SERVICE_NAME SERVICE_KIND SERVICE_IMAGE
  # shellcheck source=/dev/null # path varies by service
  source "${dir}/service.env" || return 1

  [[ -n "${SERVICE_NAME:-}" ]] && [[ -n "${SERVICE_KIND:-}" ]] &&
    [[ -n "${SERVICE_IMAGE:-}" ]] || return 1
}

# A function, so an unknown kind fails here instead of writing a service
# nothing depends on.
service_compose_key() {
  local -r kind="$1"

  case "$kind" in
    database) printf 'database\n' ;;
    cache) printf 'cache\n' ;;
    *) die "unknown service kind: ${kind}" ;;
  esac
}

record_services() {
  local -r project="$1" database="$2" cache="$3"
  local -r file="${project}/mise.toml"

  sed -i.bak -e "s|@DATABASE@|${database}|" -e "s|@CACHE@|${cache}|" "$file"
  rm -f "${file}.bak"

  grep -Eq '@DATABASE@|@CACHE@' "$file" &&
    die "could not record the selected services in ${file} — has [vars] been reformatted?"
  return 0
}

# Prints nothing for `none`.
project_service() {
  local -r project="$1" key="$2"
  local value

  value="$(yq -p toml -oy -r ".vars.${key} // \"\"" "${project}/mise.toml" 2>/dev/null || true)"
  [[ "$value" == "none" ]] || [[ "$value" == "null" ]] && return 0
  printf '%s' "$value"
}

# The directory name, not the role: `scaffold add` can place an app at any path.
app_service_key() {
  basename "$1"
}

# WEB_PORT for apps/web; derived, so example.env and compose.yaml agree.
app_port_variable() {
  local -r rel="$1"
  local key
  key="$(app_service_key "$rel")"
  key="${key//-/_}"
  key="${key//./_}"
  printf '%s_PORT' "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
}

# Read off compose.yaml, so `scaffold add` continues where `scaffold new` left
# off. Seeded one below the first port: yq's `max` over an empty sequence prints
# nothing, which `// default` does not catch.
next_app_port() {
  local -r project="$1"
  local highest
  highest="$(SEED="$((FIRST_APP_PORT - 1))" yq -r '[(env(SEED) | tonumber), (.services[].ports[]?
      | capture("\{[A-Za-z0-9_]+:-(?P<port>[0-9]+)\}").port | tonumber)] | max' \
    "${project}/${COMPOSE_FILE}")"
  printf '%s' "$((highest + 1))"
}

# Read back out of the project, so a later `scaffold add` lands where the first
# application did. build.yml is the fallback for projects that predate
# [vars] image.
project_image_base() {
  local -r project="$1"
  local value

  value="$(yq -p toml -oy -r '.vars.image // ""' "${project}/mise.toml" 2>/dev/null || true)"
  if [[ -z "$value" ]] || [[ "$value" == "null" ]]; then
    value="$(grep -oE 'ghcr\.io/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' \
      "${project}/.github/workflows/build.yml" 2>/dev/null | head -1 || true)"
  fi
  [[ -n "$value" ]] ||
    die "cannot tell which registry path ${project} publishes under — neither [vars] image in mise.toml nor a ghcr.io reference in .github/workflows/build.yml"
  printf '%s' "$value"
}

compose_lane_file() {
  local -r lane="$1"

  case "$lane" in
    prod) printf '%s\n' "$COMPOSE_FILE" ;;
    dev | test) printf 'compose.%s.yaml\n' "$lane" ;;
    *) die "unknown compose lane: ${lane}" ;;
  esac
}

# Removes the fragment on both paths, since `die` leaves immediately.
merge_compose_fragment() {
  local -r file="$1" fragment="$2" what="$3"

  if ! yq eval-all --inplace 'select(fileIndex==0) * select(fileIndex==1)' \
    "$file" "$fragment"; then
    rm -f "$fragment"
    die "could not merge ${what} into ${file}"
  fi
  rm -f "$fragment"
}

assemble_compose() {
  local -r project="$1"
  shift
  local service lane key

  for service in "$@"; do
    load_service "$service"
    key="$(service_compose_key "$SERVICE_KIND")"

    # add_app_service's depends_on names the key the kind implies.
    yq -e ".services.${key} != null" "${SERVICE_DIR}/compose.fragment.yaml" >/dev/null ||
      die "${service}'s compose fragment does not define services.${key}"

    for lane in "${COMPOSE_LANES[@]}"; do
      assemble_service_lane "${project}/$(compose_lane_file "$lane")" "$service" "$key" "$lane"
    done
  done
}

# The image is injected here, so a service's digest lives only in service.env.
assemble_service_lane() {
  local -r file="$1" service="$2" key="$3" lane="$4"
  local merged

  merged="$(mktemp)"
  if ! yq eval-all 'select(fileIndex==0) * select(fileIndex==1)' \
    "${SERVICE_DIR}/compose.fragment.yaml" \
    "${SERVICE_DIR}/compose.${lane}.fragment.yaml" >"$merged"; then
    rm -f "$merged"
    die "could not assemble ${service}'s ${lane} block"
  fi

  if ! SERVICE_IMAGE="$SERVICE_IMAGE" yq --inplace \
    ".services.${key}.image = strenv(SERVICE_IMAGE)" "$merged"; then
    rm -f "$merged"
    die "could not set ${service}'s image"
  fi

  merge_compose_fragment "$file" "$merged" "$service"
}

# The infrastructure side only: each driver writes what its framework calls the
# connection into the app's own .env.example.
assemble_example_env() {
  local -r project="$1"
  shift
  local service

  for service in "$@"; do
    load_service "$service"
    [[ -f "${SERVICE_DIR}/env.fragment" ]] || continue
    printf '\n' >>"${project}/${EXAMPLE_ENV_FILE}"
    cat "${SERVICE_DIR}/env.fragment" >>"${project}/${EXAMPLE_ENV_FILE}"
  done
}

# ADR-0022: one compose service per application, its image named from the base
# the build workflows push to.
add_app_service() {
  local -r project="$1" rel="$2" role="$3"
  local -r file="${project}/${COMPOSE_FILE}"
  local key port_var port image fragment

  [[ -f "$file" ]] || die "no ${COMPOSE_FILE} in ${project}"

  key="$(app_service_key "$rel")"
  port_var="$(app_port_variable "$rel")"
  port="$(next_app_port "$project")"
  image="$(project_image_base "$project")-${key}"

  fragment="$(mktemp)"
  app_service_fragment "$key" "$image" "$port_var" "$port" >"$fragment"
  merge_compose_fragment "$file" "$fragment" "the ${key} service"

  printf '\n%s=%s\n' "$port_var" "$port" >>"${project}/${EXAMPLE_ENV_FILE}"

  depend_on_project_services "$project" "$key" "$role"
}

app_service_fragment() {
  local -r key="$1" image="$2" port_var="$3" port="$4"

  printf 'services:\n'
  printf '  %s:\n' "$key"
  # shellcheck disable=SC2016 # ${IMAGE_TAG} and ${<NAME>_PORT} are compose's own interpolation
  printf '    image: %s:${IMAGE_TAG:-latest}\n' "$image"
  # required: false validates before a .env exists; install.sh writes one first.
  printf '    env_file:\n      - path: .env\n        required: false\n'
  printf '    restart: always\n'
  # shellcheck disable=SC2016 # same as the image line above
  printf "    ports:\n      - '\${%s:-%s}:%s'\n" "$port_var" "$port" "$APP_CONTAINER_PORT"
}

# Only a driven role waits: a web app never connects to the services.
depend_on_project_services() {
  local -r project="$1" key="$2" role="$3"
  local -r file="${project}/${COMPOSE_FILE}"
  local kind recorded dependency

  case " ${DRIVEN_ROLES[*]} " in
    *" ${role} "*) ;;
    *) return 0 ;;
  esac

  for kind in database cache; do
    recorded="$(project_service "$project" "$kind")"
    [[ -n "$recorded" ]] || continue
    dependency="$(service_compose_key "$kind")"
    yq --inplace \
      ".services.\"${key}\".depends_on.${dependency}.condition = \"service_healthy\"" \
      "$file"
  done
}

# Replaces an existing key rather than appending: an adapter's .env.example may
# already set it, and two values let the reader pick the loser.
write_env_lines() {
  local -r file="$1"
  shift
  local line key

  [[ -f "$file" ]] || : >"$file"
  for line in "$@"; do
    key="${line%%=*}"
    if grep -q "^${key}=" "$file"; then
      replace_env_line "$file" "$key" "$line"
    else
      # else the key lands on the end of a last line with no newline
      if [[ -s "$file" ]] && [[ -n "$(tail -c1 "$file")" ]]; then
        printf '\n' >>"$file"
      fi
      printf '%s\n' "$line" >>"$file"
    fi
  done
}

# awk, not sed: a value can carry `&` or `|` (a MongoDB DATABASE_URL does).
# ENVIRON, not -v, which would read a backslash as an escape.
replace_env_line() {
  local -r file="$1" key="$2" line="$3"
  local rendered

  rendered="$(mktemp)"
  if ! KEY="$key" LINE="$line" awk '
    BEGIN { prefix = ENVIRON["KEY"] "=" }
    substr($0, 1, length(prefix)) == prefix { print ENVIRON["LINE"]; next }
    { print }
  ' "$file" >"$rendered"; then
    rm -f "$rendered"
    die "could not set ${key} in ${file}"
  fi
  mv "$rendered" "$file"
}

# Blocks concatenate, so a database and a cache both land. Both Dockerfile
# variants are resolved: which one survives is decided after this runs.
apply_service_dockerfile() {
  local -r app="$1"
  local block="$2"
  local file found=0

  for file in "${app}/Dockerfile" "${app}/Dockerfile.workspace"; do
    [[ -f "$file" ]] || continue
    found=1
    grep -q "^${SERVICE_SETUP_ANCHOR}\$" "$file" ||
      die "no @SERVICE_SETUP@ anchor in ${file}"
    splice_service_setup "$file" "$block"
  done

  ((found == 1)) || return 0
}

# ENVIRON, not -v: -v would consume a backslash in the block as an escape.
splice_service_setup() {
  local -r file="$1"
  local block="$2" rendered

  rendered="$(mktemp)"
  block="$block" anchor="$SERVICE_SETUP_ANCHOR" awk '
    $0 == ENVIRON["anchor"] { if (ENVIRON["block"] != "") printf "%s\n", ENVIRON["block"]; next }
    { print }
  ' "$file" >"$rendered"
  mv "$rendered" "$file"
}

# No -P, unlike merge_lefthook_fragment: this fragment is always block style,
# and -P rewrites nodes the merge never touched.
apply_service_compose_env() {
  local -r project="$1" service="$2" block="$3"
  local -r file="${project}/${COMPOSE_FILE}"
  local fragment

  [[ -n "$block" ]] || return 0
  [[ -f "$file" ]] || die "no ${COMPOSE_FILE} in ${project}"

  fragment="$(mktemp)"
  {
    printf 'services:\n'
    printf '  %s:\n' "$service"
    printf '    environment:\n'
    printf '%s\n' "$block" | sed 's/^/      /'
  } >"$fragment"

  merge_compose_fragment "$file" "$fragment" "the service environment"
}

apply_service_compose_service() {
  local -r project="$1" block="$2"
  local -r file="${project}/${COMPOSE_FILE}"
  local fragment

  [[ -n "$block" ]] || return 0
  [[ -f "$file" ]] || die "no ${COMPOSE_FILE} in ${project}"

  fragment="$(mktemp)"
  printf '%s\n' "$block" >"$fragment"

  merge_compose_fragment "$file" "$fragment" "the service"
}

# Behind a profile, so it never starts with the stack; install.sh runs it once,
# after the stack is up.
apply_service_compose_migrate() {
  local -r project="$1" service="$2" env_block="$3" command="$4"
  local -r file="${project}/${COMPOSE_FILE}"
  local image block

  [[ -n "$command" ]] || return 0
  [[ -f "$file" ]] || die "no ${COMPOSE_FILE} in ${project}"

  image="$(yq ".services.\"${service}\".image" "$file")" ||
    die "could not read ${service}'s image out of ${file}"
  [[ -n "$image" ]] && [[ "$image" != "null" ]] ||
    die "${file} has no ${service} service to migrate from"

  block="$(migrate_service_block "$image" "$env_block" "$command")"

  apply_service_compose_service "$project" "$block"
}

migrate_service_block() {
  local -r image="$1" env_block="$2" command="$3"

  printf 'services:\n  migrate:\n'
  printf '    image: %s\n' "$image"
  printf '    env_file:\n      - path: .env\n        required: false\n'
  printf '    profiles:\n      - migrate\n'
  printf '    %s\n' "$command"
  if [[ -n "$env_block" ]]; then
    printf '    environment:\n'
    printf '%s\n' "$env_block" | sed 's/^/      /'
  fi
}

# Its own `bash -e` process, not a subshell: `( ... ) || die` disables `set -e`
# inside, and a driver's unchecked failure would vanish.
#
# Tools go in by PATH, not `mise exec -C`, which resolves PATH from scratch and
# loses yq. The npm_config_* pair is apply_adapter's.
run_driver_apply() {
  local -r app="$1" project="$2" family="$3" service="$4" driver="$5"
  local pnpm_bin node_bin uv_bin=""

  pnpm_bin="$(dirname "$(mise which pnpm -C "$app")")"
  node_bin="$(dirname "$(mise which node -C "$app")")"
  # Only flask pins uv; resolving it elsewhere fails outright.
  [[ "$family" == "flask" ]] && uv_bin="$(dirname "$(mise which uv -C "$app")")"

  # shellcheck disable=SC2016 # the child expands $1, $2 and SCAFFOLD_ROOT
  local -r driver_script='
        cd "$1"
        . "${SCAFFOLD_ROOT}/lib/log.sh"
        . "${SCAFFOLD_ROOT}/lib/service.sh"
        . "$2"
        service_driver_apply
    '

  step "wiring ${service} into $(app_service_key "$app")"
  run_quietly "wiring ${service} into $(app_service_key "$app") (the ${family} driver)" \
    env PATH="${uv_bin:+${uv_bin}:}${pnpm_bin}:${node_bin}:${PATH}" \
    npm_config_frozen_lockfile=false npm_config_verify_deps_before_run=false \
    SCAFFOLD_PROJECT_ROOT="$project" \
    bash -euo pipefail -c "$driver_script" _ "$app" "$driver"
}

# In a subshell, so one driver's parameters do not leak into the next.
driver_output() {
  local -r driver="$1" hook="$2"

  # shellcheck source=/dev/null # family varies, so the path isn't constant
  (
    . "$driver"
    "$hook"
  )
}

resolve_driver() {
  local -r family="$1" service="$2"

  load_service "$service"
  local -r driver="${SERVICE_DIR}/drivers/${family}.sh"
  [[ -f "$driver" ]] || die "${service} has no driver for ${family} — run 'scaffold lint'"
  printf '%s' "$driver"
}

# project-root is passed, not counted in `..`: `new` and `add` nest apps at
# different depths.
apply_service_drivers() {
  local -r app="$1" project="$2" family="$3"
  shift 3
  local service driver rendered
  local block="" env_block="" migrate_block=""

  # The caller skips web; an empty family here is a wiring mistake.
  if (($# > 0)) && [[ -z "$family" ]]; then
    die "${app} has services selected but no driver family — run 'scaffold lint'"
  fi

  for service in "$@"; do
    driver="$(resolve_driver "$family" "$service")"
    run_driver_apply "$app" "$project" "$family" "$service" "$driver"

    # An empty contribution would splice a blank line into the Dockerfile.
    rendered="$(driver_output "$driver" service_driver_dockerfile)"
    [[ -n "$rendered" ]] && block+="${rendered}"$'\n'

    rendered="$(driver_output "$driver" service_driver_compose_env)"
    [[ -n "$rendered" ]] && env_block+="${rendered}"$'\n'

    rendered="$(driver_output "$driver" service_driver_compose_migrate)"
    [[ -n "$rendered" ]] && migrate_block+="${rendered}"$'\n'
  done

  local key
  key="$(app_service_key "$app")"
  apply_service_dockerfile "$app" "${block%$'\n'}"
  apply_service_compose_env "$project" "$key" "${env_block%$'\n'}"
  # Runs the first driven application's image; a second backend would need its
  # own migrate service, and nothing generates that shape (ADR-0022).
  apply_service_compose_migrate "$project" "$key" "${env_block%$'\n'}" "${migrate_block%$'\n'}"
}
