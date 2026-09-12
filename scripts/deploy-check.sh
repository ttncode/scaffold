#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : scripts/deploy-check.sh
# Description : Prove a generated project's released stack serves HTTP and
#               reaches its database.
# Author      : ttncode
#
# Usage:
#   ./scripts/deploy-check.sh <adapter>... [--db <service>]
#
# Example:
#   ./scripts/deploy-check.sh nextjs nestjs --db postgres
# ═══════════════════════════════════════════════════════════════════════════
#
# Everything before this gate validated YAML; nothing started a container — see
# docs/superpowers/plans/2026-09-06-deployable-stack.md.

set -euo pipefail

# What this gate calls itself: the substituted GitHub owner, the local image
# tags, and the compose project. Never a real account or a real stack.
GATE_NAME="deploy-check"

# Long enough for a cold `docker pull` of the database image plus the app's own
# startup, short enough that a stack that will never come up fails the job
# instead of eating its whole timeout budget.
HEALTH_TIMEOUT_SECONDS=120
HEALTH_POLL_INTERVAL_SECONDS=2

DEFAULT_APP_PORT=8080

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/log.sh
source "${ROOT}/lib/log.sh"
# shellcheck source=lib/adapter.sh
source "${ROOT}/lib/adapter.sh"
# app_service_key and app_port_variable: the same two rules that named the
# compose service and the port variable when the project was generated, rather
# than a second copy here that can drift from them.
# shellcheck source=lib/service.sh
source "${ROOT}/lib/service.sh"

ADAPTERS=()
DB_SERVICE=""
APPS=()
MIGRATE_APP=""
TMP_DIR=""
PROJECT_DIR=""
declare -A ADAPTER_OF ROLE_OF LIVENESS_OF READINESS_OF TAG_OF

# ─── what this run is checking ─────────────────────────────────────────────

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --db)
        [ $# -ge 2 ] || die "--db requires a service name"
        DB_SERVICE="$2"
        shift 2
        ;;
      -*) die "unknown option: ${1}" ;;
      *) ADAPTERS+=("$1"); shift ;;
    esac
  done
  [ "${#ADAPTERS[@]}" -ge 1 ] || die "usage: deploy-check.sh <adapter>... [--db <service>]"
}

# load_adapter is the reader `scaffold new` itself uses: a second copy drifts,
# which is how nestjs's Dockerfile came to probe a /health nothing served.
resolve_adapters() {
  local adapter app readiness

  SCAFFOLD_ROOT="$ROOT"
  export SCAFFOLD_ROOT

  for adapter in "${ADAPTERS[@]}"; do
    load_adapter "$adapter" || die "unknown adapter: ${adapter}"
    app="$(app_service_key "$(role_path "$ADAPTER_ROLE")")"

    # lib/lint.sh only checks the line is present. An empty path probes "/",
    # which nextjs answers 200 for reasons unrelated to its real liveness.
    [ -n "$ADAPTER_LIVENESS_PATH" ] || die "${adapter} declares an empty ADAPTER_LIVENESS_PATH"

    # `${ADAPTER_READINESS_PATH:-}` alone cannot tell "not declared" (skip, and
    # say so) from "declared empty" (a malformed adapter.env): both collapse to
    # "". The `+x` test keeps them apart.
    readiness=""
    if [ -n "${ADAPTER_READINESS_PATH+x}" ]; then
      [ -n "$ADAPTER_READINESS_PATH" ] || die "${adapter} declares an empty ADAPTER_READINESS_PATH"
      readiness="$ADAPTER_READINESS_PATH"
    fi
    # With --db none the route still ships and correctly reports 503, so curling
    # it expecting 200 would fail a combination the spec says is fine.
    [ "$DB_SERVICE" = none ] && readiness=""

    APPS+=("$app")
    ADAPTER_OF["$app"]="$adapter"
    ROLE_OF["$app"]="$ADAPTER_ROLE"
    LIVENESS_OF["$app"]="$ADAPTER_LIVENESS_PATH"
    READINESS_OF["$app"]="$readiness"
    TAG_OF["$app"]="${GATE_NAME}/${app}:local"
  done
}

# migrate has no application of its own and runs a driven application's image.
resolve_migrate_app() {
  local app
  for app in "${APPS[@]}"; do
    [ "${ROLE_OF[$app]}" = web ] && continue
    MIGRATE_APP="$app"
    return 0
  done
  return 0
}

# ─── the throwaway environment ─────────────────────────────────────────────

# A trap, not a trailing cleanup line: every die() below is a plain `exit 1`,
# and only a trap runs on that path too. INT/TERM too, so a cancelled CI job or
# a Ctrl-C doesn't leave containers and a temp dir behind.
cleanup() {
  if [ -f "${PROJECT_DIR}/compose.yaml" ]; then
    ( cd "$PROJECT_DIR" && docker compose down -v --remove-orphans ) || true
  fi
  rm -rf "$TMP_DIR"
}

# `scaffold new` needs an account and a trust store a runner has neither of.
# Each is owned by this run rather than written into real state, and skipped
# when the caller already supplied one.
prepare_workspace() {
  TMP_DIR="$(mktemp -d)"
  PROJECT_DIR="${TMP_DIR}/demo"

  export SCAFFOLD_GITHUB_OWNER="${SCAFFOLD_GITHUB_OWNER:-$GATE_NAME}"

  # mise records every config it trusts, keyed by path, and a throwaway project
  # dir has no reason to outlive this run — tests/helpers/setup.bash found the
  # real store past 7600 stale entries.
  if [ -z "${MISE_STATE_DIR:-}" ]; then
    MISE_STATE_DIR="${TMP_DIR}/mise-state"
    export MISE_STATE_DIR
  fi

  # Every generated project's compose.yaml is `name: app` (common/compose.yaml)
  # — without this, a local run reconciles against, and `down -v`s, any real
  # "app" project already running on this machine, database volumes included.
  COMPOSE_PROJECT_NAME="${GATE_NAME}-$(IFS=-; printf '%s' "${APPS[*]}")"
  export COMPOSE_PROJECT_NAME

  trap cleanup EXIT INT TERM
}

# ─── generate and build ────────────────────────────────────────────────────

generate_project() {
  local app
  local -a new_args=("$PROJECT_DIR")

  log "generating ${ADAPTERS[*]} into ${PROJECT_DIR}..."
  for app in "${APPS[@]}"; do
    new_args+=("--${ROLE_OF[$app]}" "${ADAPTER_OF[$app]}")
  done
  [ -n "$DB_SERVICE" ] && new_args+=(--db "$DB_SERVICE")

  "${ROOT}/scaffold" new "${new_args[@]}" || die "scaffold new failed for ${ADAPTERS[*]}"
}

# build_targets — the `images` array the build workflow hands the reusable
# workflow, one entry per application (ADR-0022). Asserted against what this run
# asked for: a target this gate does not build comes up on whatever a registry
# publishes, and a missing one was generated and never deployed.
build_targets() {
  local build_yml="${PROJECT_DIR}/.github/workflows/build.yml"
  local images

  [ -f "$build_yml" ] || die "generated project has no .github/workflows/build.yml"
  images="$(yq -r '[.jobs[] | select(has("with")) | .with.images] | .[0] // "[]"' "$build_yml")"
  [ "$(jq 'length' <<<"$images")" = "${#APPS[@]}" ] \
    || die "expected ${#APPS[@]} build target(s) in ${build_yml}, got: ${images}"

  jq -r '.[] | [.context, .dockerfile] | @tsv' <<<"$images"
}

build_images() {
  local context dockerfile app

  while IFS=$'\t' read -r context dockerfile; do
    app="$(app_service_key "$(dirname "$dockerfile")")"
    [ -n "${TAG_OF[$app]:-}" ] || die "the build workflow builds ${app}, which this run did not ask for"
    log "building ${TAG_OF[$app]} from ${dockerfile} (context: ${context})..."
    docker build -f "${PROJECT_DIR}/${dockerfile}" -t "${TAG_OF[$app]}" "${PROJECT_DIR}/${context}" \
      || die "docker build failed for ${ADAPTER_OF[$app]} (${dockerfile})"
  done < <(build_targets)
}

# ─── point the stack at what was just built ────────────────────────────────

has_migrate_service() {
  [ -n "$MIGRATE_APP" ] \
    && yq -e '.services.migrate' "${PROJECT_DIR}/compose.yaml" >/dev/null 2>&1
}

# Per service, not one tag for the whole file: a project publishes one image per
# application (ADR-0022). migrate follows whichever application it was pointed
# at.
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

# Equality with the tag just built, not just "the rewrite ran": if a path above
# stops matching, yq still exits 0 and the stack comes up on a *pulled* image
# while the one just built is discarded — a green run proving nothing.
assert_image_is_built_tag() {
  local service="$1" want="$2" actual
  actual="$(yq ".services.\"${service}\".image" "${PROJECT_DIR}/compose.yaml")"
  [ "$actual" = "$want" ] \
    || die "compose.yaml's ${service} image is ${actual}, not the image just built (${want})"
}

assert_every_image_is_built_tag() {
  local app

  for app in "${APPS[@]}"; do
    assert_image_is_built_tag "$app" "${TAG_OF[$app]}"
  done
  has_migrate_service && assert_image_is_built_tag migrate "${TAG_OF[$MIGRATE_APP]}"
  return 0
}

# ─── start it the way a real deploy would ──────────────────────────────────

# common/install.sh's own generate_service_passwords, not a second copy of the
# substitution: a gate that leaves every password at the literal "changeme" runs
# a sequence no real deploy ever runs.
write_env_file() {
  cp "${PROJECT_DIR}/example.env" "${PROJECT_DIR}/.env"
  # shellcheck source=/dev/null # path is this toolbox's own common/install.sh
  source "${ROOT}/common/install.sh"
  generate_service_passwords "${PROJECT_DIR}/.env" \
    || die "could not generate service passwords for ${ADAPTERS[*]}"
}

wait_until_healthy() {
  local service="$1" health="" elapsed=0
  log "waiting for the ${service} container to become healthy (up to ${HEALTH_TIMEOUT_SECONDS}s)..."
  while [ "$elapsed" -lt "$HEALTH_TIMEOUT_SECONDS" ]; do
    # `docker inspect` on one container id, not `docker compose ps --format
    # json`: that format's shape is compose-version-dependent, and the `|| true`
    # this needs anyway would swallow the resulting jq error into a false
    # "unknown" — a full 120s red on a healthy stack.
    health="$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q "$service")" 2>/dev/null || true)"
    [ "$health" = "healthy" ] && return 0
    [ "$health" = "unhealthy" ] \
      && die "${service} container reported unhealthy — its HEALTHCHECK against ${LIVENESS_OF[$service]} is failing (see: docker compose logs ${service})"
    sleep "$HEALTH_POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + HEALTH_POLL_INTERVAL_SECONDS))
  done
  die "${service} container did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s (last status: ${health:-unknown})"
}

# Not `start_stack`: write_env_file sources common/install.sh, which defines one.
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

# ─── prove it actually works ───────────────────────────────────────────────

# The readiness probe is `select 1` — connectivity, not schema, and 200 against
# an empty database. Asserting the migration's own exit code separately is what
# stops a deploy whose migration silently failed from going green.
#
# install.sh's run_migrations decides whether a migrate service should exist by
# grepping compose.yaml, the artifact this gate just built. The roles and
# DB_SERVICE are known here before the project was generated, so this asserts it
# independently: a driver that drops the database and migrate services together
# would satisfy install.sh's check and slip past unnoticed. compose_has_service
# comes from install.sh, sourced by write_env_file above.
assert_migrate_service_exists() {
  [ -n "$MIGRATE_APP" ] && [ "$DB_SERVICE" != none ] || return 0

  compose_has_service migrate --profile migrate \
    || die "expected a migrate service for ${ADAPTER_OF[$MIGRATE_APP]} (role=${ROLE_OF[$MIGRATE_APP]}, db=${DB_SERVICE:-default}) but compose has none — a service, profile, or driver may have silently vanished"
}

assert_http_ok() {
  local label="$1" url="$2" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$url")" \
    || die "${label} check failed: could not reach ${url}"
  [ "$code" = "200" ] || die "${label} check failed: ${url} returned ${code}, not 200"
  log "${label} (${url}): ${code}"
}

# app_base_url <app> — the host port compose published, named after the app's
# own directory (ADR-0022): WEB_PORT for apps/web, API_PORT for apps/api.
#
# `|| true`: under pipefail a .env with no such line makes grep exit 1, which
# kills the script silently before the fallback below can run.
app_base_url() {
  local port
  port="$(grep "^$(app_port_variable "$1")=" .env | cut -d= -f2 || true)"
  printf 'http://localhost:%s' "${port:-$DEFAULT_APP_PORT}"
}

assert_endpoints_ok() {
  local app base

  for app in "${APPS[@]}"; do
    base="$(app_base_url "$app")"
    assert_http_ok "${app} liveness" "${base}${LIVENESS_OF[$app]}"

    if [ -n "${READINESS_OF[$app]}" ]; then
      assert_http_ok "${app} readiness" "${base}${READINESS_OF[$app]}"
    elif [ "$DB_SERVICE" = none ]; then
      log "${app}: --db none — skipping readiness check"
    else
      log "${app}: ${ADAPTER_OF[$app]} declares no readiness path — skipping readiness check"
    fi
  done
}

# ─── entry point ───────────────────────────────────────────────────────────

# Not `main`: write_env_file sources common/install.sh, which defines one.
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
