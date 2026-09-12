#!/usr/bin/env bash
# deploy-check.sh <adapter>... [--db <service>]
# Proves a generated project's released stack serves HTTP and reaches its
# database. Everything before this validated YAML; nothing started a
# container — see docs/superpowers/plans/2026-09-06-deployable-stack.md.
set -euo pipefail

# Long enough for a cold `docker pull` of the database image plus the app's
# own startup, short enough that a stack that will never come up fails the
# job instead of eating its whole timeout budget.
HEALTH_TIMEOUT_SECONDS=120
HEALTH_POLL_INTERVAL_SECONDS=2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/log.sh
source "${ROOT}/lib/log.sh"
# shellcheck source=lib/adapter.sh
source "${ROOT}/lib/adapter.sh"
# for app_service_key and app_port_variable — the same two rules that named
# the compose service and the port variable when the project was generated,
# rather than a second copy here that can drift from them.
# shellcheck source=lib/service.sh
source "${ROOT}/lib/service.sh"

ADAPTERS=()
DB_SERVICE=""
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

# load_adapter is the same reader `scaffold new` itself uses — reading the
# two paths any other way risks a second copy that drifts from the adapter's
# own, which is exactly how nestjs's Dockerfile came to probe a /health
# nothing served.
SCAFFOLD_ROOT="$ROOT"
export SCAFFOLD_ROOT

APPS=()
declare -A ADAPTER_OF ROLE_OF LIVENESS_OF READINESS_OF TAG_OF

for adapter in "${ADAPTERS[@]}"; do
  load_adapter "$adapter" || die "unknown adapter: ${adapter}"
  app="$(app_service_key "$(role_path "$ADAPTER_ROLE")")"

  # lib/lint.sh only checks the line is present, not that it names a route —
  # an empty path would otherwise probe "/", which nextjs happens to answer
  # 200 for reasons that have nothing to do with the adapter's real liveness.
  [ -n "$ADAPTER_LIVENESS_PATH" ] || die "${adapter} declares an empty ADAPTER_LIVENESS_PATH"

  # `${ADAPTER_READINESS_PATH:-}` alone can't tell "not declared" (skip, and
  # say so) from "declared empty" (a malformed adapter.env — lint only greps
  # for the line's presence, not a non-empty value): both collapse to "". The
  # `+x` test keeps them apart.
  readiness=""
  if [ -n "${ADAPTER_READINESS_PATH+x}" ]; then
    [ -n "$ADAPTER_READINESS_PATH" ] || die "${adapter} declares an empty ADAPTER_READINESS_PATH"
    readiness="$ADAPTER_READINESS_PATH"
  fi
  # A driven adapter still declares a readiness path with --db none: the route
  # ships unconditionally and correctly reports 503 (nothing to connect to),
  # but a gate that curls it expecting 200 would fail a combination the spec
  # says is fine. Skipped the same way a non-driven role's absent path is.
  [ "$DB_SERVICE" = none ] && readiness=""

  APPS+=("$app")
  ADAPTER_OF["$app"]="$adapter"
  ROLE_OF["$app"]="$ADAPTER_ROLE"
  LIVENESS_OF["$app"]="$ADAPTER_LIVENESS_PATH"
  READINESS_OF["$app"]="$readiness"
  TAG_OF["$app"]="deploy-check/${app}:local"
done

TMP_DIR="$(mktemp -d)"
PROJECT_DIR="${TMP_DIR}/demo"

# `scaffold new` needs an account and a trust store that a runner has
# neither of on its own — tests/helpers/setup.bash hands bats both for
# exactly this reason, but this script runs outside bats and never picked
# them up. Each is owned by this run rather than written into real state,
# and skipped when the caller already supplied one, so a developer with a
# real account or trust store keeps theirs. (Identity used to belong to
# this list too — finalize_project's commit now carries its own, so nothing
# here needs a git identity to run.)

# resolve_github_owner (lib/project.sh) substitutes this for the generated
# workflows' placeholder `you/` account, and falls back to `gh auth login`
# or git's github.user before giving up — a runner has none of the three.
export SCAFFOLD_GITHUB_OWNER="${SCAFFOLD_GITHUB_OWNER:-deploy-check}"

# mise records every config it trusts (`mise trust`, below) under its state
# directory keyed by path; a throwaway project dir trusted here has no
# reason to outlive this run, and a repeated local run would otherwise grow
# the developer's real store the way tests/helpers/setup.bash found bats
# had — past 7600 stale entries.
if [ -z "${MISE_STATE_DIR:-}" ]; then
  MISE_STATE_DIR="${TMP_DIR}/mise-state"
  export MISE_STATE_DIR
fi

# Every generated project's compose.yaml is `name: app` (common/compose.yaml)
# — without this, a local run reconciles against, and `down -v`s, any real
# "app" project already running on this machine, database volumes included.
COMPOSE_PROJECT_NAME="deploy-check-$(IFS=-; printf '%s' "${APPS[*]}")"
export COMPOSE_PROJECT_NAME

# A trap, not a trailing cleanup line: every die() below is a plain `exit 1`,
# and only a trap runs on that path too. INT/TERM too, so a cancelled CI job
# or a Ctrl-C doesn't leave containers and a temp dir behind.
cleanup() {
  if [ -f "${PROJECT_DIR}/compose.yaml" ]; then
    ( cd "$PROJECT_DIR" && docker compose down -v --remove-orphans ) || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

log "generating ${ADAPTERS[*]} into ${PROJECT_DIR}..."
new_args=("$PROJECT_DIR")
for app in "${APPS[@]}"; do
  new_args+=("--${ROLE_OF[$app]}" "${ADAPTER_OF[$app]}")
done
[ -n "$DB_SERVICE" ] && new_args+=(--db "$DB_SERVICE")
"${ROOT}/scaffold" new "${new_args[@]}" || die "scaffold new failed for ${ADAPTERS[*]}"

BUILD_YML="${PROJECT_DIR}/.github/workflows/build.yml"
[ -f "$BUILD_YML" ] || die "generated project has no .github/workflows/build.yml"

# One entry per application (ADR-0022). Asserted against the applications this
# run asked for: a target this gate does not build would come up on whatever a
# registry publishes, and a missing one is an application that was generated
# and never deployed — the defect ADR-0022 exists to have removed.
IMAGES="$(yq -r '[.jobs[] | select(has("with")) | .with.images] | .[0] // "[]"' "$BUILD_YML")"
[ "$(jq 'length' <<<"$IMAGES")" = "${#APPS[@]}" ] \
  || die "expected ${#APPS[@]} build target(s) in ${BUILD_YML}, got: ${IMAGES}"

while IFS=$'\t' read -r context dockerfile; do
  app="$(app_service_key "$(dirname "$dockerfile")")"
  [ -n "${TAG_OF[$app]:-}" ] || die "${BUILD_YML} builds ${app}, which this run did not ask for"
  log "building ${TAG_OF[$app]} from ${dockerfile} (context: ${context})..."
  docker build -f "${PROJECT_DIR}/${dockerfile}" -t "${TAG_OF[$app]}" "${PROJECT_DIR}/${context}" \
    || die "docker build failed for ${ADAPTER_OF[$app]} (${dockerfile})"
done < <(jq -r '.[] | [.context, .dockerfile] | @tsv' <<<"$IMAGES")

# Every ghcr.io reference becomes the image just built for that service, so
# the stack that comes up is the one that just passed this check rather than
# whatever a registry happens to publish. Per service now, not one tag for the
# whole file: a project publishes one image per application (ADR-0022).
#
# migrate is the exception — it has no application of its own and runs a driven
# application's image, so it follows whichever one it was pointed at.
MIGRATE_APP=""
for app in "${APPS[@]}"; do
  [ "${ROLE_OF[$app]}" = web ] && continue
  MIGRATE_APP="$app"
  break
done

for app in "${APPS[@]}"; do
  TAG="${TAG_OF[$app]}" yq --inplace ".services.\"${app}\".image = strenv(TAG)" \
    "${PROJECT_DIR}/compose.yaml" || die "could not rewrite ${app}'s image"
done
if [ -n "$MIGRATE_APP" ] && yq -e '.services.migrate' "${PROJECT_DIR}/compose.yaml" >/dev/null 2>&1; then
  TAG="${TAG_OF[$MIGRATE_APP]}" yq --inplace '.services.migrate.image = strenv(TAG)' \
    "${PROJECT_DIR}/compose.yaml" || die "could not rewrite migrate's image"
fi

# Asserting equality with the tag just built, not just "the rewrite ran": if a
# path above ever stops matching, yq still exits 0 and the stack comes up on a
# *pulled* image while the one just built is discarded — a green run proving
# nothing. This already caught the change that moved compose.yaml off its
# CHANGEME placeholder.
assert_image_is_built_tag() {
  local service="$1" want="$2" actual
  actual="$(yq ".services.\"${service}\".image" "${PROJECT_DIR}/compose.yaml")"
  [ "$actual" = "$want" ] \
    || die "compose.yaml's ${service} image is ${actual}, not the image just built (${want})"
}
for app in "${APPS[@]}"; do
  assert_image_is_built_tag "$app" "${TAG_OF[$app]}"
done
[ -n "$MIGRATE_APP" ] && yq -e '.services.migrate' "${PROJECT_DIR}/compose.yaml" >/dev/null 2>&1 \
  && assert_image_is_built_tag migrate "${TAG_OF[$MIGRATE_APP]}"

# common/install.sh's own generate_service_passwords, not a second copy of
# the substitution: a gate that leaves every password at the literal
# "changeme" runs a sequence no real deploy ever runs, and proves nothing
# about the password loop, the APP_KEY branch, or anything downstream that
# depends on either.
cp "${PROJECT_DIR}/example.env" "${PROJECT_DIR}/.env"
# shellcheck source=/dev/null # path is this toolbox's own common/install.sh
source "${ROOT}/common/install.sh"
generate_service_passwords "${PROJECT_DIR}/.env" \
  || die "could not generate service passwords for ${ADAPTERS[*]}"

cd "$PROJECT_DIR"

log "starting the stack..."
docker compose up -d || die "docker compose up failed for ${ADAPTERS[*]}"

wait_until_healthy() {
  local service="$1" health="" elapsed=0
  log "waiting for the ${service} container to become healthy (up to ${HEALTH_TIMEOUT_SECONDS}s)..."
  while [ "$elapsed" -lt "$HEALTH_TIMEOUT_SECONDS" ]; do
    # `docker inspect` on the container itself, not `docker compose ps
    # --format json`: that format's shape is compose-version-dependent — a
    # version emitting an array instead of one object per line makes `jq -r
    # '.Health'` error, which the `|| true` this needs anyway would swallow
    # into a false "unknown", producing a full 120s red on an actually-healthy
    # stack. `docker inspect` on one container id has one shape.
    health="$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q "$service")" 2>/dev/null || true)"
    [ "$health" = "healthy" ] && return 0
    [ "$health" = "unhealthy" ] \
      && die "${service} container reported unhealthy — its HEALTHCHECK against ${LIVENESS_OF[$service]} is failing (see: docker compose logs ${service})"
    sleep "$HEALTH_POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + HEALTH_POLL_INTERVAL_SECONDS))
  done
  die "${service} container did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s (last status: ${health:-unknown})"
}

for app in "${APPS[@]}"; do
  wait_until_healthy "$app"
done

# The readiness probe is `select 1` — it proves connectivity, not schema, and
# returns 200 against an empty database. Asserting the migration's own exit
# code, separately, is what stops a deploy whose migration silently failed
# from going green anyway.
#
# install.sh's own run_migrations runs the migration now (see
# docs/decisions/0021-the-released-stack-must-run.md's 2026-09-07 note) — it
# decides whether a migrate service should exist by grepping compose.yaml
# for a "database" service, the same artifact this gate just built. The roles
# and DB_SERVICE are known here before the project was even generated, so this
# still asserts a migrate service independently of what compose.yaml says
# now exists: a driver that drops the database and migrate services
# together would satisfy install.sh's check and slip past unnoticed without
# this.
if [ -n "$MIGRATE_APP" ] && [ "$DB_SERVICE" != "none" ]; then
  docker compose --profile migrate config --services 2>/dev/null | grep -qx migrate \
    || die "expected a migrate service for ${ADAPTER_OF[$MIGRATE_APP]} (role=${ROLE_OF[$MIGRATE_APP]}, db=${DB_SERVICE:-default}) but compose has none — a service, profile, or driver may have silently vanished"
fi

run_migrations || die "could not run migrations for ${ADAPTERS[*]}; check the output above"

# Named after the application's own directory, the same way its compose
# service is (ADR-0022): WEB_PORT for apps/web, API_PORT for apps/api.
#
# `|| true`: under pipefail, a .env with no such line makes grep exit 1 and,
# unguarded, that kills the script here — silently, before the `${PORT:-8080}`
# fallback below ever gets a chance to run.
check_path() {
  local label="$1" url="$2" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$url")" \
    || die "${label} check failed: could not reach ${url}"
  [ "$code" = "200" ] || die "${label} check failed: ${url} returned ${code}, not 200"
  log "${label} (${url}): ${code}"
}

for app in "${APPS[@]}"; do
  # Named after the application's own directory, the same way its compose
  # service is (ADR-0022): WEB_PORT for apps/web, API_PORT for apps/api.
  #
  # `|| true`: under pipefail, a .env with no such line makes grep exit 1 and,
  # unguarded, that kills the script here — silently, before the fallback
  # below ever gets a chance to run.
  port="$(grep "^$(app_port_variable "$app")=" .env | cut -d= -f2 || true)"
  base="http://localhost:${port:-8080}"

  check_path "${app} liveness" "${base}${LIVENESS_OF[$app]}"

  if [ -n "${READINESS_OF[$app]}" ]; then
    check_path "${app} readiness" "${base}${READINESS_OF[$app]}"
  elif [ "$DB_SERVICE" = none ]; then
    log "${app}: --db none — skipping readiness check"
  else
    log "${app}: ${ADAPTER_OF[$app]} declares no readiness path — skipping readiness check"
  fi
done

log "${ADAPTERS[*]} stack serves HTTP and reaches its database"
