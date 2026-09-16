#!/usr/bin/env bash
# Prove a generated project's released stack serves HTTP and reaches its
# database: the first gate that starts a container (ADR-0021).
#
# Usage:   ./scripts/deploy-check.sh <adapter>... [--db <service>]
# Example: ./scripts/deploy-check.sh nextjs nestjs --db postgres
set -euo pipefail

# The substituted GitHub owner, the local image tags and the compose project:
# never a real account or a real stack.
GATE_NAME="deploy-check"

# A cold pull of the database image plus app startup, without eating the job's
# whole timeout on a stack that will never come up.
HEALTH_TIMEOUT_SECONDS=120
HEALTH_POLL_INTERVAL_SECONDS=2

DEFAULT_APP_PORT=8080

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/log.sh
source "${ROOT}/lib/log.sh"
# shellcheck source=lib/adapter.sh
source "${ROOT}/lib/adapter.sh"
# shellcheck source=lib/service.sh
source "${ROOT}/lib/service.sh"

ADAPTERS=()
DB_SERVICE=""
APPS=()
MIGRATE_APP=""
TMP_DIR=""
PROJECT_DIR=""
declare -A ADAPTER_OF ROLE_OF LIVENESS_OF READINESS_OF TAG_OF

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --db)
        (($# >= 2)) || die "--db requires a service name"
        DB_SERVICE="$2"
        shift 2
        ;;
      -*) die "unknown option: ${1}" ;;
      *)
        ADAPTERS+=("$1")
        shift
        ;;
    esac
  done
  ((${#ADAPTERS[@]} >= 1)) || die "usage: deploy-check.sh <adapter>... [--db <service>]"
}

# Through load_adapter, the reader `scaffold new` uses: a second copy is how
# nestjs's Dockerfile came to probe a /health nothing served.
resolve_adapters() {
  local adapter app readiness

  SCAFFOLD_ROOT="$ROOT"
  export SCAFFOLD_ROOT

  for adapter in "${ADAPTERS[@]}"; do
    load_adapter "$adapter" || die "unknown adapter: ${adapter}"
    app="$(app_service_key "$(role_path "$ADAPTER_ROLE")")"

    # The linter only checks the line exists; an empty path probes "/", which
    # nextjs answers 200 regardless.
    [[ -n "$ADAPTER_LIVENESS_PATH" ]] || die "${adapter} declares an empty ADAPTER_LIVENESS_PATH"
    readiness="$(readiness_path_to_check "$adapter")"

    APPS+=("$app")
    ADAPTER_OF["$app"]="$adapter"
    ROLE_OF["$app"]="$ADAPTER_ROLE"
    LIVENESS_OF["$app"]="$ADAPTER_LIVENESS_PATH"
    READINESS_OF["$app"]="$readiness"
    TAG_OF["$app"]="${GATE_NAME}/${app}:local"
  done
}

# `+x` tells "not declared" (skip) from "declared empty" (malformed). With
# --db none the route correctly answers 503, so it is not checked.
readiness_path_to_check() {
  local -r adapter="$1"
  local readiness=""

  if [[ -n "${ADAPTER_READINESS_PATH+x}" ]]; then
    [[ -n "$ADAPTER_READINESS_PATH" ]] || die "${adapter} declares an empty ADAPTER_READINESS_PATH"
    readiness="$ADAPTER_READINESS_PATH"
  fi
  [[ "$DB_SERVICE" == "none" ]] && readiness=""
  printf '%s' "$readiness"
}

# migrate has no application of its own and runs a driven application's image.
resolve_migrate_app() {
  local app
  for app in "${APPS[@]}"; do
    [[ "${ROLE_OF[$app]}" == "web" ]] && continue
    MIGRATE_APP="$app"
    return 0
  done
  return 0
}

# A trap, because die() exits directly; INT/TERM so a cancelled job leaves no
# containers behind.
cleanup() {
  if [[ -f "${PROJECT_DIR}/compose.yaml" ]]; then
    (cd "$PROJECT_DIR" && docker compose down -v --remove-orphans) || true
  fi
  rm -rf "$TMP_DIR"
}

# `scaffold new` needs an account and a trust store a runner has neither of;
# each is owned by this run unless the caller supplied one.
prepare_workspace() {
  TMP_DIR="$(mktemp -d)"
  PROJECT_DIR="${TMP_DIR}/demo"

  export SCAFFOLD_GITHUB_OWNER="${SCAFFOLD_GITHUB_OWNER:-$GATE_NAME}"

  # mise records every trusted path, and this project dir does not outlive the run.
  if [[ -z "${MISE_STATE_DIR:-}" ]]; then
    MISE_STATE_DIR="${TMP_DIR}/mise-state"
    export MISE_STATE_DIR
  fi

  # Every generated compose.yaml is `name: app`: without this, `down -v` would
  # take any real "app" project on this machine, volumes included.
  COMPOSE_PROJECT_NAME="${GATE_NAME}-$(
    IFS=-
    printf '%s' "${APPS[*]}"
  )"
  export COMPOSE_PROJECT_NAME

  trap cleanup EXIT INT TERM
}

generate_project() {
  local app
  local -a new_args=("$PROJECT_DIR")

  log "generating ${ADAPTERS[*]} into ${PROJECT_DIR}..."
  for app in "${APPS[@]}"; do
    new_args+=("--${ROLE_OF[$app]}" "${ADAPTER_OF[$app]}")
  done
  [[ -n "$DB_SERVICE" ]] && new_args+=(--db "$DB_SERVICE")

  "${ROOT}/scaffold" new "${new_args[@]}" || die "scaffold new failed for ${ADAPTERS[*]}"
}

# Asserted against this run's request: an extra target would come up on a
# registry's image, and a missing one was never deployed.
build_targets() {
  local -r build_yml="${PROJECT_DIR}/.github/workflows/build.yml"
  local images

  [[ -f "$build_yml" ]] || die "generated project has no .github/workflows/build.yml"
  images="$(yq -r '[.jobs[] | select(has("with")) | .with.images] | .[0] // "[]"' "$build_yml")"
  [[ "$(jq 'length' <<<"$images")" == "${#APPS[@]}" ]] ||
    die "expected ${#APPS[@]} build target(s) in ${build_yml}, got: ${images}"

  jq -r '.[] | [.context, .dockerfile] | @tsv' <<<"$images"
}

build_images() {
  local context dockerfile app

  while IFS=$'\t' read -r context dockerfile; do
    app="$(app_service_key "$(dirname "$dockerfile")")"
    [[ -n "${TAG_OF[$app]:-}" ]] || die "the build workflow builds ${app}, which this run did not ask for"
    log "building ${TAG_OF[$app]} from ${dockerfile} (context: ${context})..."
    docker build -f "${PROJECT_DIR}/${dockerfile}" -t "${TAG_OF[$app]}" "${PROJECT_DIR}/${context}" ||
      die "docker build failed for ${ADAPTER_OF[$app]} (${dockerfile})"
  done < <(build_targets)
}

has_migrate_service() {
  [[ -n "$MIGRATE_APP" ]] &&
    yq -e '.services.migrate' "${PROJECT_DIR}/compose.yaml" >/dev/null 2>&1
}

rewrite_compose_images() {
  local app

  for app in "${APPS[@]}"; do
    TAG="${TAG_OF[$app]}" yq --inplace ".services.\"${app}\".image = strenv(TAG)" \
      "${PROJECT_DIR}/compose.yaml" || die "could not rewrite ${app}'s image"
  done

  if has_migrate_service; then
    TAG="${TAG_OF[$MIGRATE_APP]}" yq --inplace '.services.migrate.image = strenv(TAG)' \
      "${PROJECT_DIR}/compose.yaml" || die "could not rewrite migrate's image"
  fi
}

# yq exits 0 on a path that matches nothing, and the stack would then come up
# on a pulled image: a green run proving nothing.
assert_image_is_built_tag() {
  local -r service="$1" want="$2"
  local actual
  actual="$(yq ".services.\"${service}\".image" "${PROJECT_DIR}/compose.yaml")"
  [[ "$actual" == "$want" ]] ||
    die "compose.yaml's ${service} image is ${actual}, not the image just built (${want})"
}

assert_every_image_is_built_tag() {
  local app

  for app in "${APPS[@]}"; do
    assert_image_is_built_tag "$app" "${TAG_OF[$app]}"
  done
  has_migrate_service && assert_image_is_built_tag migrate "${TAG_OF[$MIGRATE_APP]}"
  return 0
}

# install.sh's own password generation: a gate left at "changeme" runs a
# sequence no real deploy runs.
write_env_file() {
  cp "${PROJECT_DIR}/example.env" "${PROJECT_DIR}/.env"
  # shellcheck source=/dev/null # path is this toolbox's own common/install.sh
  source "${ROOT}/common/install.sh"
  generate_service_passwords "${PROJECT_DIR}/.env" ||
    die "could not generate service passwords for ${ADAPTERS[*]}"
}

wait_until_healthy() {
  local -r service="$1"
  local health="" elapsed=0
  log "waiting for the ${service} container to become healthy (up to ${HEALTH_TIMEOUT_SECONDS}s)..."
  while ((elapsed < HEALTH_TIMEOUT_SECONDS)); do
    # `docker inspect`, not `compose ps --format json`, whose shape varies by
    # compose version and would read as "unknown" for the full timeout.
    health="$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q "$service")" 2>/dev/null || true)"
    [[ "$health" == "healthy" ]] && return 0
    [[ "$health" == "unhealthy" ]] &&
      die "${service} container reported unhealthy — its HEALTHCHECK against ${LIVENESS_OF[$service]} is failing (see: docker compose logs ${service})"
    sleep "$HEALTH_POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + HEALTH_POLL_INTERVAL_SECONDS))
  done
  die "${service} container did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s (last status: ${health:-unknown})"
}

# Not `start_stack`: install.sh, sourced above, defines one.
launch_stack() {
  log "starting the stack..."
  docker compose up -d || die "docker compose up failed for ${ADAPTERS[*]}"
}

wait_for_healthy_apps() {
  local app
  for app in "${APPS[@]}"; do
    wait_until_healthy "$app"
  done
}

# The readiness probe is `select 1`, which passes on an empty database, so the
# migration is asserted on its own. install.sh decides from compose.yaml whether
# a migrate service should exist; this decides from the request, so a driver
# dropping both database and migrate cannot slip past.
assert_migrate_service_exists() {
  [[ -n "$MIGRATE_APP" ]] && [[ "$DB_SERVICE" != "none" ]] || return 0

  compose_has_service migrate --profile migrate ||
    die "expected a migrate service for ${ADAPTER_OF[$MIGRATE_APP]} (role=${ROLE_OF[$MIGRATE_APP]}, db=${DB_SERVICE:-default}) but compose has none — a service, profile, or driver may have silently vanished"
}

assert_http_ok() {
  local -r label="$1" url="$2"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$url")" ||
    die "${label} check failed: could not reach ${url}"
  [[ "$code" == "200" ]] || die "${label} check failed: ${url} returned ${code}, not 200"
  log "${label} (${url}): ${code}"
}

# `|| true`: under pipefail a missing line kills the script before the fallback.
app_base_url() {
  local -r app="$1"
  local port
  port="$(grep "^$(app_port_variable "$app")=" .env | cut -d= -f2 || true)"
  printf 'http://localhost:%s' "${port:-$DEFAULT_APP_PORT}"
}

assert_endpoints_ok() {
  local app base

  for app in "${APPS[@]}"; do
    base="$(app_base_url "$app")"
    assert_http_ok "${app} liveness" "${base}${LIVENESS_OF[$app]}"

    if [[ -n "${READINESS_OF[$app]}" ]]; then
      assert_http_ok "${app} readiness" "${base}${READINESS_OF[$app]}"
    elif [[ "$DB_SERVICE" == "none" ]]; then
      log "${app}: --db none — skipping readiness check"
    else
      log "${app}: ${ADAPTER_OF[$app]} declares no readiness path — skipping readiness check"
    fi
  done
}

# Not `main`: install.sh, sourced by write_env_file, defines one.
run_deploy_check() {
  parse_args "$@"
  resolve_adapters
  resolve_migrate_app
  prepare_workspace

  generate_project
  build_images
  rewrite_compose_images
  assert_every_image_is_built_tag

  write_env_file
  cd "$PROJECT_DIR"
  launch_stack
  wait_for_healthy_apps

  assert_migrate_service_exists
  run_migrations || die "could not run migrations for ${ADAPTERS[*]}; check the output above"
  assert_endpoints_ok

  log "${ADAPTERS[*]} stack serves HTTP and reaches its database"
}

run_deploy_check "$@"
