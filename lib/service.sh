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
