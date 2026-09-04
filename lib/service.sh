# shellcheck shell=bash

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

# service_compose_key <kind>
# The compose service name a kind is published under. An identity mapping
# today, and a function rather than a bare expansion so an unrecognised kind
# fails here instead of writing a service that nothing depends on and nothing
# reports missing.
service_compose_key() {
  case "$1" in
    database) printf 'database\n' ;;
    cache) printf 'cache\n' ;;
    *) die "unknown service kind: ${1}" ;;
  esac
}

# assemble_compose <project> <service>...
# The common compose files ship the application service alone; each selected
# service's block is merged in per lane. The image is injected here rather
# than written in a fragment so a service's digest lives only in its
# service.env.
assemble_compose() {
  local project="$1"; shift
  local service lane file key merged

  for service in "$@"; do
    load_service "$service"
    key="$(service_compose_key "$SERVICE_KIND")"

    # The fragment has to publish under the key its kind implies, or the
    # depends_on below would name a service that is not there.
    yq -e ".services.${key} != null" "${SERVICE_DIR}/compose.fragment.yaml" >/dev/null \
      || die "${service}'s compose fragment does not define services.${key}"

    for lane in prod dev test; do
      case "$lane" in
        prod) file="${project}/compose.yaml" ;;
        dev) file="${project}/compose.dev.yaml" ;;
        test) file="${project}/compose.test.yaml" ;;
      esac

      merged="$(mktemp)"
      # cleaned up on both paths: under `set -e` a yq failure leaves
      # immediately and the temporary file survives the run.
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

      if ! yq eval-all --inplace 'select(fileIndex==0) * select(fileIndex==1)' \
        "$file" "$merged"; then
        rm -f "$merged"
        die "could not merge ${service} into ${file}"
      fi
      rm -f "$merged"
    done

    # Only the production lane carries an application service to wait on; the
    # dev and test lanes are the service on its own.
    yq --inplace \
      ".services.app.depends_on.${key}.condition = \"service_healthy\"" \
      "${project}/compose.yaml"
  done
}

# assemble_example_env <project> <service>...
# The infrastructure side of a service's configuration. What the application
# itself needs is written by that service's driver, in the application's own
# .env.example, because DB_CONNECTION is Laravel's phrasing and DATABASE_URL
# is Prisma's for the same server.
assemble_example_env() {
  local project="$1"; shift
  local service

  for service in "$@"; do
    load_service "$service"
    [ -f "${SERVICE_DIR}/env.fragment" ] || continue
    printf '\n' >> "${project}/example.env"
    cat "${SERVICE_DIR}/env.fragment" >> "${project}/example.env"
  done
}

# apply_service_setup <app-dir> <block>
# Replaces the Dockerfile's anchor comment with the concatenated output of
# every selected service's driver. Concatenated rather than substituted per
# service, so `--db mongodb --cache redis` produces two blocks instead of one
# overwriting the other.
apply_service_setup() {
  local app="$1" block="$2"
  local file="${app}/Dockerfile"

  [ -f "$file" ] || return 0
  grep -q '^# @SERVICE_SETUP@$' "$file" \
    || die "no @SERVICE_SETUP@ anchor in ${file}"

  local rendered; rendered="$(mktemp)"
  # ENVIRON, not -v: awk's -v does C-style escape processing on the assigned
  # value, so a literal backslash in the block (e.g. \t, \") is consumed
  # instead of passed through. ENVIRON does none of that.
  block="$block" awk '
    /^# @SERVICE_SETUP@$/ { if (ENVIRON["block"] != "") printf "%s\n", ENVIRON["block"]; next }
    { print }
  ' "$file" > "$rendered"
  mv "$rendered" "$file"
}

# write_env_lines <file> <line>...
# Sets each KEY=value, replacing the key if it is already there. A driver runs
# against an .env.example the adapter shipped, so appending blindly would
# leave two values for one key and let the loser win depending on the reader.
write_env_lines() {
  local file="$1"; shift
  local line key rendered

  [ -f "$file" ] || : > "$file"
  for line in "$@"; do
    key="${line%%=*}"
    if grep -q "^${key}=" "$file"; then
      rendered="$(mktemp)"
      # awk, not sed: a value can carry sed's own replacement syntax (&, |)
      # — a MongoDB DATABASE_URL's query string does. ENVIRON, not -v, so a
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

# apply_service_drivers <app-dir> <project-root> <family> <service>...
# A service knows how to run a container; a driver knows how one framework
# talks to it. service_driver_apply runs in its own `bash -e` process, not a
# subshell, and not per driver's own parameters leaking into the next one for
# the same reason: `( ... ) || die` makes the subshell the left operand of
# `||`, and bash disables `set -e` for everything inside that — a fallible
# command a driver forgot to check would keep running and its failure would
# vanish. A separate process keeps its own `-e` no matter how this function is
# invoked; a subshell's suppression is enforced only by every driver body
# remembering `|| return 1`, which is what this replaces.
#
# project-root is a caller-supplied argument, not `app`'s ancestor derived by
# counting `..`: cmd_new's apps/<role> and cmd_add's caller-chosen directory
# nest at different depths, so a driver that needs the project root (a
# pnpm-workspace.yaml edit) cannot recover it from its own cwd.
apply_service_drivers() {
  local app="$1" project="$2" family="$3"; shift 3
  local service driver block="" rendered

  # web is the presentation tier and takes no driver — the caller decides
  # that from ADAPTER_ROLE, so reaching here with a family that has none is a
  # wiring mistake, not a supported case. An api/app adapter with no
  # ADAPTER_FAMILY set is the same mistake one step later: caught here, by
  # name, instead of interpolating a blank into every driver-not-found message
  # below.
  if [ $# -gt 0 ] && [ -z "$family" ]; then
    die "${app} has services selected but no driver family — run 'scaffold lint'"
  fi

  for service in "$@"; do
    load_service "$service"
    driver="${SERVICE_DIR}/drivers/${family}.sh"
    [ -f "$driver" ] \
      || die "${service} has no driver for ${family} — run 'scaffold lint'"

    # die and write_env_lines are shell functions, not exported, so the new
    # process needs its own copies — lib/log.sh and lib/service.sh do nothing
    # but define functions when sourced, so re-sourcing them here re-runs
    # nothing. SCAFFOLD_ROOT reaches the child because `scaffold` exports it;
    # same two npm_config_* variables as apply_adapter's ADAPTER_POST_GENERATE
    # call, and for the same reason: service_driver_apply runs pnpm add /
    # composer require, and pnpm turns the frozen lockfile on by itself
    # whenever CI is set — a driver cannot install what it is adding.
    #
    # pnpm/node go in by PATH, not `mise exec -C`: this script also calls yq
    # (the allowBuilds edit above `pnpm add` in services/shared/nest.sh),
    # which the project's own mise.toml does not pin — `mise exec` resolves
    # PATH from scratch for the directory it is given, so wrapping the whole
    # call in it would satisfy pnpm and lose yq. A bare `pnpm add` here
    # resolves ambient, which just linked node_modules against whatever store
    # the generator's mise-pinned pnpm used, the same skew apply_adapter fixes.
    # composer is left alone either way — not mise-managed (ADR-0016).
    local pnpm_bin node_bin
    pnpm_bin="$(dirname "$(mise which pnpm -C "$app")")"
    node_bin="$(dirname "$(mise which node -C "$app")")"

    PATH="${pnpm_bin}:${node_bin}:${PATH}" \
      npm_config_frozen_lockfile=false npm_config_verify_deps_before_run=false \
      SCAFFOLD_PROJECT_ROOT="$project" \
      bash -euo pipefail -c '
        cd "$1"
        # shellcheck source=/dev/null
        . "${SCAFFOLD_ROOT}/lib/log.sh"
        # shellcheck source=/dev/null
        . "${SCAFFOLD_ROOT}/lib/service.sh"
        # shellcheck source=/dev/null
        . "$2"
        service_driver_apply
      ' _ "$app" "$driver" \
      || die "the ${service} driver failed for ${family}"

    # A driver with nothing to add to the Dockerfile (redis's drivers, on
    # both families) returns an empty string; appending it anyway spliced a
    # blank line into the client's Dockerfile whenever it ran alongside one
    # that does have output.
    # shellcheck source=/dev/null # family varies, so the path isn't constant
    rendered="$( . "$driver"; service_driver_dockerfile )"
    [ -n "$rendered" ] && block+="${rendered}"$'\n'
  done

  apply_service_setup "$app" "${block%$'\n'}"
}

# record_services <project> <database> <cache>
# mise.root.toml ships the two placeholders; substituting them is the same
# technique as @PROJECT_NAME@ rather than a second way of writing toml.
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
# Prints nothing for `none`, and nothing for a project generated before this
# existed, so a caller can test the value rather than compare it to a word.
project_service() {
  local project="$1" key="$2" value

  value="$(yq -p toml -oy -r ".vars.${key} // \"\"" "${project}/mise.toml" 2>/dev/null || true)"
  [ "$value" = "none" ] || [ "$value" = "null" ] && return 0
  printf '%s' "$value"
}
