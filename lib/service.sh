# shellcheck shell=bash

# load_service <name>
# Same guard as load_adapter, for the same reason: `source` below executes
# whatever it reads, so the name must not be able to leave services/.
load_service() {
  local name="$1"

  case "$name" in
    ''|*[!a-z0-9-]*|-*) die "not a usable service name: ${name}" ;;
  esac

  local dir="${SCAFFOLD_ROOT}/services/${name}"
  [ -d "$dir" ] || die "unknown service: ${name}"

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
