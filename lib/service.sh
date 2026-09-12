# ═══════════════════════════════════════════════════════════════════════════
# Script      : lib/service.sh
# Description : Compose services, host ports, and per-framework service drivers.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck shell=bash

COMPOSE_FILE="compose.yaml"
EXAMPLE_ENV_FILE="example.env"

COMPOSE_LANES=(prod dev test)

# Every application listens on this port inside its container; the host port is
# allocated per application from FIRST_APP_PORT upward (ADR-0022).
APP_CONTAINER_PORT=8080
FIRST_APP_PORT=8080

SERVICE_SETUP_ANCHOR="# @SERVICE_SETUP@"

# ─── services ──────────────────────────────────────────────────────────────

# load_service <name>
# Same guard as load_adapter, for the same reason: `source` below executes
# whatever it reads, so the name must not be able to leave services/.
load_service() {
  local name="$1"

  case "$name" in
    ''|*[!a-z0-9-]*|-*) die "not a usable service name: ${name} (run: scaffold list)" ;;
  esac

  local dir="${SCAFFOLD_ROOT}/services/${name}"
  [ -d "$dir" ] || die "unknown service: ${name} (run: scaffold list)"

  # shellcheck disable=SC2034 # read by the caller
  SERVICE_DIR="$dir"
  unset -v SERVICE_NAME SERVICE_KIND SERVICE_IMAGE
  # shellcheck source=/dev/null
  source "${dir}/service.env" || return 1

  [ -n "${SERVICE_NAME:-}" ] && [ -n "${SERVICE_KIND:-}" ] \
    && [ -n "${SERVICE_IMAGE:-}" ] || return 1
}

# service_compose_key <kind> — the compose service name a kind publishes under.
# A function, not a bare expansion, so an unrecognised kind fails here instead
# of writing a service nothing depends on and nothing reports missing.
service_compose_key() {
  case "$1" in
    database) printf 'database\n' ;;
    cache) printf 'cache\n' ;;
    *) die "unknown service kind: ${1}" ;;
  esac
}

record_services() {
  local project="$1" database="$2" cache="$3"
  local file="${project}/mise.toml"

  sed -i.bak -e "s|@DATABASE@|${database}|" -e "s|@CACHE@|${cache}|" "$file"
  rm -f "${file}.bak"

  grep -Eq '@DATABASE@|@CACHE@' "$file" \
    && die "could not record the selected services in ${file} — has [vars] been reformatted?"
  return 0
}

# project_service <project> <database|cache>
# Prints nothing for `none`, so a caller can test the value rather than compare
# it to a word.
project_service() {
  local project="$1" key="$2" value

  value="$(yq -p toml -oy -r ".vars.${key} // \"\"" "${project}/mise.toml" 2>/dev/null || true)"
  [ "$value" = "none" ] || [ "$value" = "null" ] && return 0
  printf '%s' "$value"
}

# ─── applications ──────────────────────────────────────────────────────────

# app_service_key <rel> — the compose service name and image suffix for an
# application. Its own directory name, because `scaffold add` can place one at
# any path and a role would not answer for apps/worker.
app_service_key() {
  basename "$1"
}

# app_port_variable <rel> — WEB_PORT for apps/web. The same name in example.env
# and in compose.yaml, derived rather than recorded, so the two cannot disagree.
app_port_variable() {
  local key; key="$(app_service_key "$1")"
  key="${key//-/_}"
  key="${key//./_}"
  printf '%s_PORT' "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
}

# next_app_port <project> — FIRST_APP_PORT, then one more per application
# already published (ADR-0022). Read off compose.yaml, so `scaffold add` months
# later allocates from the state `scaffold new` left behind. Seeded one below
# the first port because yq's `max` over an empty sequence prints nothing at
# all, which `// default` does not catch.
next_app_port() {
  local project="$1" highest
  highest="$(SEED="$((FIRST_APP_PORT - 1))" yq -r '[(env(SEED) | tonumber), (.services[].ports[]?
      | capture("\{[A-Za-z0-9_]+:-(?P<port>[0-9]+)\}").port | tonumber)] | max' \
    "${project}/${COMPOSE_FILE}")"
  printf '%s' "$((highest + 1))"
}

# project_image_base <project> — the registry path this project publishes under,
# read back out of it so `scaffold add` in month six lands where the first
# application did. The build.yml fallback is what lets `scaffold update` work on
# a project generated before [vars] image existed.
project_image_base() {
  local project="$1" value

  value="$(yq -p toml -oy -r '.vars.image // ""' "${project}/mise.toml" 2>/dev/null || true)"
  if [ -z "$value" ] || [ "$value" = null ]; then
    value="$(grep -oE 'ghcr\.io/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+' \
      "${project}/.github/workflows/build.yml" 2>/dev/null | head -1 || true)"
  fi
  [ -n "$value" ] \
    || die "cannot tell which registry path ${project} publishes under — neither [vars] image in mise.toml nor a ghcr.io reference in .github/workflows/build.yml"
  printf '%s' "$value"
}

# ─── compose ───────────────────────────────────────────────────────────────

# compose_lane_file <lane> — compose.yaml is the prod lane; dev and test are
# overlays beside it.
compose_lane_file() {
  case "$1" in
    prod) printf '%s\n' "$COMPOSE_FILE" ;;
    dev|test) printf 'compose.%s.yaml\n' "$1" ;;
    *) die "unknown compose lane: ${1}" ;;
  esac
}

# merge_compose_fragment <file> <fragment> <what>
# Removes the fragment on both paths: under `set -e` a yq failure leaves
# immediately and the temporary file would survive the run.
merge_compose_fragment() {
  local file="$1" fragment="$2" what="$3"

  if ! yq eval-all --inplace 'select(fileIndex==0) * select(fileIndex==1)' \
    "$file" "$fragment"; then
    rm -f "$fragment"
    die "could not merge ${what} into ${file}"
  fi
  rm -f "$fragment"
}

# assemble_compose <project> <service>...
# The common compose files ship no services; each selected service's block is
# merged in per lane. The image is injected here rather than written in a
# fragment so a service's digest lives only in its service.env.
assemble_compose() {
  local project="$1"; shift
  local service lane file key merged

  for service in "$@"; do
    load_service "$service"
    key="$(service_compose_key "$SERVICE_KIND")"

    # The fragment has to publish under the key its kind implies, or the
    # depends_on in add_app_service would name a service that is not there.
    yq -e ".services.${key} != null" "${SERVICE_DIR}/compose.fragment.yaml" >/dev/null \
      || die "${service}'s compose fragment does not define services.${key}"

    for lane in "${COMPOSE_LANES[@]}"; do
      file="${project}/$(compose_lane_file "$lane")"

      merged="$(mktemp)"
      if ! yq eval-all 'select(fileIndex==0) * select(fileIndex==1)' \
        "${SERVICE_DIR}/compose.fragment.yaml" \
        "${SERVICE_DIR}/compose.${lane}.fragment.yaml" > "$merged"; then
        rm -f "$merged"
        die "could not assemble ${service}'s ${lane} block"
      fi

      if ! SERVICE_IMAGE="$SERVICE_IMAGE" yq --inplace \
        ".services.${key}.image = strenv(SERVICE_IMAGE)" "$merged"; then
        rm -f "$merged"
        die "could not set ${service}'s image"
      fi

      merge_compose_fragment "$file" "$merged" "$service"
    done
  done
}

# assemble_example_env <project> <service>...
# The infrastructure side only. What the application needs is written by that
# service's driver, into the app's own .env.example: DB_CONNECTION is Laravel's
# phrasing and DATABASE_URL is Prisma's for the same server.
assemble_example_env() {
  local project="$1"; shift
  local service

  for service in "$@"; do
    load_service "$service"
    [ -f "${SERVICE_DIR}/env.fragment" ] || continue
    printf '\n' >> "${project}/${EXAMPLE_ENV_FILE}"
    cat "${SERVICE_DIR}/env.fragment" >> "${project}/${EXAMPLE_ENV_FILE}"
  done
}

# add_app_service <project> <rel> <role>
# One compose service per application (ADR-0022). The image is written from the
# same base the build workflows get, because this is the path they push to: the
# two cannot be written independently without drifting apart.
add_app_service() {
  local project="$1" rel="$2" role="$3"
  local file="${project}/${COMPOSE_FILE}"
  local key port_var port image fragment kind recorded

  [ -f "$file" ] || die "no ${COMPOSE_FILE} in ${project}"

  key="$(app_service_key "$rel")"
  port_var="$(app_port_variable "$rel")"
  port="$(next_app_port "$project")"
  image="$(project_image_base "$project")-${key}"

  fragment="$(mktemp)"
  {
    printf 'services:\n'
    printf '  %s:\n' "$key"
    # shellcheck disable=SC2016 # ${IMAGE_TAG} and ${<NAME>_PORT} are compose's
    # own interpolation; expanding them here bakes this machine's environment
    # into a client's file. Quoted as the service fragments quote theirs,
    # because yq keeps the style it is given.
    printf '    image: %s:${IMAGE_TAG:-latest}\n' "$image"
    # required: false so this validates before a .env exists; install.sh always
    # writes one before starting the stack.
    printf '    env_file:\n      - path: .env\n        required: false\n'
    printf '    restart: always\n'
    # shellcheck disable=SC2016 # same as the image line above
    printf "    ports:\n      - '\${%s:-%s}:%s'\n" "$port_var" "$port" "$APP_CONTAINER_PORT"
  } > "$fragment"

  merge_compose_fragment "$file" "$fragment" "the ${key} service"

  printf '\n%s=%s\n' "$port_var" "$port" >> "${project}/${EXAMPLE_ENV_FILE}"

  # Only an application that opens a connection waits for one. A web
  # application in a project with a database has no driver and no client, so
  # making it wait would only delay it behind a service it never reaches.
  case " ${DRIVEN_ROLES[*]} " in
    *" ${role} "*) ;;
    *) return 0 ;;
  esac

  local dependency
  for kind in database cache; do
    recorded="$(project_service "$project" "$kind")"
    [ -n "$recorded" ] || continue
    dependency="$(service_compose_key "$kind")"
    yq --inplace \
      ".services.\"${key}\".depends_on.${dependency}.condition = \"service_healthy\"" \
      "$file"
  done
}

# ─── drivers ───────────────────────────────────────────────────────────────

# write_env_lines <file> <line>...
# Sets each KEY=value, replacing the key if it is already there. A driver runs
# against an .env.example the adapter shipped, so appending blindly would leave
# two values for one key and let the loser win depending on the reader.
write_env_lines() {
  local file="$1"; shift
  local line key rendered

  [ -f "$file" ] || : > "$file"
  for line in "$@"; do
    key="${line%%=*}"
    if grep -q "^${key}=" "$file"; then
      rendered="$(mktemp)"
      # awk, not sed: a value can carry sed's own replacement syntax (&, |) — a
      # MongoDB DATABASE_URL's query string does. ENVIRON, not -v, so a
      # backslash in the value survives instead of being read as an escape.
      if ! KEY="$key" LINE="$line" awk '
        BEGIN { prefix = ENVIRON["KEY"] "=" }
        substr($0, 1, length(prefix)) == prefix { print ENVIRON["LINE"]; next }
        { print }
      ' "$file" > "$rendered"; then
        rm -f "$rendered"
        die "could not set ${key} in ${file}"
      fi
      mv "$rendered" "$file"
    else
      # a file with no trailing newline would otherwise get this key
      # concatenated onto the end of the last line
      if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then
        printf '\n' >> "$file"
      fi
      printf '%s\n' "$line" >> "$file"
    fi
  done
}

# apply_service_dockerfile <app-dir> <block>
# Concatenated, so `--db mongodb --cache redis` produces two blocks rather than
# one overwriting the other. Both Dockerfile variants get the anchor resolved:
# cmd_new decides which survives only after this runs.
apply_service_dockerfile() {
  local app="$1" block="$2"
  local file found=0

  for file in "${app}/Dockerfile" "${app}/Dockerfile.workspace"; do
    [ -f "$file" ] || continue
    found=1
    grep -q "^${SERVICE_SETUP_ANCHOR}\$" "$file" \
      || die "no @SERVICE_SETUP@ anchor in ${file}"

    local rendered; rendered="$(mktemp)"
    # ENVIRON, not -v: awk's -v does C-style escape processing on the assigned
    # value, so a literal backslash in the block (e.g. \t, \") is consumed
    # instead of passed through.
    block="$block" anchor="$SERVICE_SETUP_ANCHOR" awk '
      $0 == ENVIRON["anchor"] { if (ENVIRON["block"] != "") printf "%s\n", ENVIRON["block"]; next }
      { print }
    ' "$file" > "$rendered"
    mv "$rendered" "$file"
  done

  [ "$found" -eq 1 ] || return 0
}

# apply_service_compose_env <project> <service> <block>
# No -P, unlike merge_lefthook_fragment: that merge takes a fragment file whose
# style it does not control. This one is built below by printf, always one
# block-style `KEY: value` line per driver — and -P rewrites nodes the merge
# never touched.
apply_service_compose_env() {
  local project="$1" service="$2" block="$3"
  local file="${project}/${COMPOSE_FILE}" fragment

  [ -n "$block" ] || return 0
  [ -f "$file" ] || die "no ${COMPOSE_FILE} in ${project}"

  fragment="$(mktemp)"
  {
    printf 'services:\n'
    printf '  %s:\n' "$service"
    printf '    environment:\n'
    printf '%s\n' "$block" | sed 's/^/      /'
  } > "$fragment"

  merge_compose_fragment "$file" "$fragment" "the service environment"
}

# apply_service_compose_service <project> <block>
# For a driver needing a whole sibling service (the migrate runner below) rather
# than another line under one application's environment.
apply_service_compose_service() {
  local project="$1" block="$2"
  local file="${project}/${COMPOSE_FILE}" fragment

  [ -n "$block" ] || return 0
  [ -f "$file" ] || die "no ${COMPOSE_FILE} in ${project}"

  fragment="$(mktemp)"
  printf '%s\n' "$block" > "$fragment"

  merge_compose_fragment "$file" "$fragment" "the service"
}

# apply_service_compose_migrate <project> <service> <env-block> <command>
# Behind a profile, so it never starts with the stack — install.sh runs it
# explicitly, once, after the stack is up. An empty command (no database, or a
# cache-only driver) merges nothing.
apply_service_compose_migrate() {
  local project="$1" service="$2" env_block="$3" command="$4"
  local file="${project}/${COMPOSE_FILE}" image block

  [ -n "$command" ] || return 0
  [ -f "$file" ] || die "no ${COMPOSE_FILE} in ${project}"

  image="$(yq ".services.\"${service}\".image" "$file")" \
    || die "could not read ${service}'s image out of ${file}"
  [ -n "$image" ] && [ "$image" != null ] \
    || die "${file} has no ${service} service to migrate from"

  block="$(
    printf 'services:\n  migrate:\n'
    printf '    image: %s\n' "$image"
    printf '    env_file:\n      - path: .env\n        required: false\n'
    printf '    profiles:\n      - migrate\n'
    printf '    %s\n' "$command"
    if [ -n "$env_block" ]; then
      printf '    environment:\n'
      printf '%s\n' "$env_block" | sed 's/^/      /'
    fi
  )"

  apply_service_compose_service "$project" "$block"
}

# run_driver_apply <app-dir> <project-root> <family> <service> <driver>
# service_driver_apply runs in its own `bash -e` process, not a subshell:
# `( ... ) || die` makes the subshell the left operand of `||`, and bash disables
# `set -e` inside it, so a driver's unchecked failure would vanish.
#
# die and write_env_lines are shell functions, not exported, so the child needs
# its own copies. The npm_config_* pair is apply_adapter's, for the same reason:
# a driver runs pnpm add, and pnpm turns the frozen lockfile on whenever CI is
# set.
#
# pnpm/node go in by PATH, not `mise exec -C`: this script also calls yq, which
# the project's mise.toml does not pin, and `mise exec` resolves PATH from
# scratch. composer stays ambient either way (ADR-0016).
run_driver_apply() {
  local app="$1" project="$2" family="$3" service="$4" driver="$5"
  local pnpm_bin node_bin

  pnpm_bin="$(dirname "$(mise which pnpm -C "$app")")"
  node_bin="$(dirname "$(mise which node -C "$app")")"

  # Held in a variable so it reaches `bash -c` through `env` intact. Its
  # `$1`/`$2` and ${SCAFFOLD_ROOT} are the child's to expand.
  # shellcheck disable=SC2016
  local driver_script='
        cd "$1"
        . "${SCAFFOLD_ROOT}/lib/log.sh"
        . "${SCAFFOLD_ROOT}/lib/service.sh"
        . "$2"
        service_driver_apply
    '

  step "wiring ${service} into $(app_service_key "$app")"
  run_quietly "wiring ${service} into $(app_service_key "$app") (the ${family} driver)" \
    env PATH="${pnpm_bin}:${node_bin}:${PATH}" \
      npm_config_frozen_lockfile=false npm_config_verify_deps_before_run=false \
      SCAFFOLD_PROJECT_ROOT="$project" \
    bash -euo pipefail -c "$driver_script" _ "$app" "$driver"
}

# driver_output <driver> <hook> — one hook's stdout, sourced in a subshell so a
# driver's parameters do not leak into the next one.
driver_output() {
  # shellcheck source=/dev/null # family varies, so the path isn't constant
  ( . "$1"; "$2" )
}

# resolve_driver <family> <service> — the driver file, by name, or die.
resolve_driver() {
  load_service "$2"
  local driver="${SERVICE_DIR}/drivers/${1}.sh"
  [ -f "$driver" ] || die "${2} has no driver for ${1} — run 'scaffold lint'"
  printf '%s' "$driver"
}

# apply_service_drivers <app-dir> <project-root> <family> <service>...
# A service knows how to run a container; a driver knows how one framework talks
# to it.
#
# project-root is an argument, not `app`'s ancestor counted in `..`: cmd_new's
# apps/<role> and cmd_add's caller-chosen directory nest at different depths.
apply_service_drivers() {
  local app="$1" project="$2" family="$3"; shift 3
  local service driver rendered
  local block="" env_block="" migrate_block=""

  # web is the presentation tier and takes no driver — the caller decides that
  # from ADAPTER_ROLE, so reaching here with a family that has none is a wiring
  # mistake. Named here instead of interpolating a blank into every
  # driver-not-found message below.
  if [ $# -gt 0 ] && [ -z "$family" ]; then
    die "${app} has services selected but no driver family — run 'scaffold lint'"
  fi

  for service in "$@"; do
    driver="$(resolve_driver "$family" "$service")"
    run_driver_apply "$app" "$project" "$family" "$service" "$driver"

    # A driver with nothing to contribute returns an empty string; appending it
    # anyway splices a blank line into the client's Dockerfile.
    rendered="$(driver_output "$driver" service_driver_dockerfile)"
    [ -n "$rendered" ] && block+="${rendered}"$'\n'

    rendered="$(driver_output "$driver" service_driver_compose_env)"
    [ -n "$rendered" ] && env_block+="${rendered}"$'\n'

    rendered="$(driver_output "$driver" service_driver_compose_migrate)"
    [ -n "$rendered" ] && migrate_block+="${rendered}"$'\n'
  done

  local key; key="$(app_service_key "$app")"
  apply_service_dockerfile "$app" "${block%$'\n'}"
  apply_service_compose_env "$project" "$key" "${env_block%$'\n'}"
  # The migrate service runs the first driven application's image — it carries
  # the schema and the migration tool. A project with a second backend would
  # need a migrate service per backend; nothing generates that shape (ADR-0022).
  apply_service_compose_migrate "$project" "$key" "${env_block%$'\n'}" "${migrate_block%$'\n'}"
}
