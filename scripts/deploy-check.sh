#!/usr/bin/env bash
# deploy-check.sh <adapter> [--db <service>]
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

[ $# -ge 1 ] || die "usage: deploy-check.sh <adapter> [--db <service>]"

ADAPTER="$1"; shift
DB_SERVICE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --db)
      [ $# -ge 2 ] || die "--db requires a service name"
      DB_SERVICE="$2"
      shift 2
      ;;
    *) die "unknown option: ${1}" ;;
  esac
done

# load_adapter is the same reader `scaffold new` itself uses — reading the
# two paths any other way risks a second copy that drifts from the adapter's
# own, which is exactly how nestjs's Dockerfile came to probe a /health
# nothing served.
SCAFFOLD_ROOT="$ROOT"
export SCAFFOLD_ROOT
load_adapter "$ADAPTER" || die "unknown adapter: ${ADAPTER}"

ROLE="$ADAPTER_ROLE"

# lib/lint.sh only checks the line is present, not that it names a route —
# an empty path would otherwise probe "/", which nextjs happens to answer
# 200 for reasons that have nothing to do with the adapter's real liveness.
[ -n "$ADAPTER_LIVENESS_PATH" ] || die "${ADAPTER} declares an empty ADAPTER_LIVENESS_PATH"
LIVENESS_PATH="$ADAPTER_LIVENESS_PATH"

# `${ADAPTER_READINESS_PATH:-}` alone can't tell "not declared" (skip, and
# say so) from "declared empty" (a malformed adapter.env — lint only greps
# for the line's presence, not a non-empty value): both collapse to "". The
# `+x` test keeps them apart.
if [ -n "${ADAPTER_READINESS_PATH+x}" ]; then
  [ -n "$ADAPTER_READINESS_PATH" ] || die "${ADAPTER} declares an empty ADAPTER_READINESS_PATH"
  READINESS_PATH="$ADAPTER_READINESS_PATH"
else
  READINESS_PATH=""
fi

# A driven adapter still declares a readiness path with --db none: the route
# ships unconditionally and correctly reports 503 (nothing to connect to),
# but a gate that curls it expecting 200 would fail a combination the spec
# says is fine. Skipped the same way a non-driven role's absent path is.
[ "$DB_SERVICE" = none ] && READINESS_PATH=""

TMP_DIR="$(mktemp -d)"
PROJECT_DIR="${TMP_DIR}/demo"
IMAGE_TAG="deploy-check/${ADAPTER}:local"

# A runner has no git identity either, and `scaffold new` commits what it
# creates — tests/helpers/setup.bash gives bats the same thing, but this
# script runs outside bats and never picked it up. Owned by this run rather
# than written into a real global config; skipped when one is already set,
# so a developer with a real identity keeps theirs.
if [ -z "${GIT_CONFIG_GLOBAL:-}" ]; then
  GIT_CONFIG_GLOBAL="${TMP_DIR}/gitconfig"
  export GIT_CONFIG_GLOBAL
  git config --global user.name "deploy-check"
  git config --global user.email "deploy-check@scaffold.invalid"
fi

# Every generated project's compose.yaml is `name: app` (common/compose.yaml)
# — without this, a local run reconciles against, and `down -v`s, any real
# "app" project already running on this machine, database volumes included.
COMPOSE_PROJECT_NAME="deploy-check-${ADAPTER}"
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

log "generating ${ADAPTER} into ${PROJECT_DIR}..."
new_args=("$PROJECT_DIR" "--${ROLE}" "$ADAPTER")
[ -n "$DB_SERVICE" ] && new_args+=(--db "$DB_SERVICE")
"${ROOT}/scaffold" new "${new_args[@]}" || die "scaffold new failed for ${ADAPTER}"

BUILD_YML="${PROJECT_DIR}/.github/workflows/build.yml"
[ -f "$BUILD_YML" ] || die "generated project has no .github/workflows/build.yml"
CONTEXT="$(yq '.jobs.build.with.context' "$BUILD_YML")"
DOCKERFILE="$(yq '.jobs.build.with.dockerfile' "$BUILD_YML")"
[ -n "$CONTEXT" ] && [ "$CONTEXT" != "null" ] || die "could not read build context from ${BUILD_YML}"
[ -n "$DOCKERFILE" ] && [ "$DOCKERFILE" != "null" ] || die "could not read dockerfile path from ${BUILD_YML}"

log "building ${IMAGE_TAG} from ${DOCKERFILE} (context: ${CONTEXT})..."
docker build -f "${PROJECT_DIR}/${DOCKERFILE}" -t "$IMAGE_TAG" "${PROJECT_DIR}/${CONTEXT}" \
  || die "docker build failed for ${ADAPTER} (${DOCKERFILE})"

# compose.yaml's app and migrate services both carry the ghcr.io/CHANGEME
# placeholder scaffold ships before a project has a real registry path (see
# common/compose.yaml) — every reference to it becomes the image just built,
# so the stack that comes up next is the one that just passed this check,
# not whatever a registry happens to publish.
export IMAGE_TAG
yq --inplace \
  '(.services[] | select(.image | test("CHANGEME")) | .image) = strenv(IMAGE_TAG)' \
  "${PROJECT_DIR}/compose.yaml" || die "could not rewrite compose.yaml's image"

# Asserting equality with the tag just built, not just "no CHANGEME left": if
# common/compose.yaml ever ships a real registry reference instead of the
# placeholder, the select("CHANGEME") above matches nothing, no CHANGEME
# string remains either, and the stack would come up on a *pulled* image
# while the one just built is discarded — a green run proving nothing.
assert_image_is_built_tag() {
  local service="$1" actual
  actual="$(yq ".services.${service}.image" "${PROJECT_DIR}/compose.yaml")"
  [ "$actual" = "$IMAGE_TAG" ] \
    || die "compose.yaml's ${service} image is ${actual}, not the image just built (${IMAGE_TAG})"
}
assert_image_is_built_tag app
yq -e '.services.migrate' "${PROJECT_DIR}/compose.yaml" >/dev/null 2>&1 \
  && assert_image_is_built_tag migrate

# common/install.sh's own generate_service_passwords, not a second copy of
# the substitution: a gate that leaves every password at the literal
# "changeme" runs a sequence no real deploy ever runs, and proves nothing
# about the password loop, the APP_KEY branch, or anything downstream that
# depends on either.
cp "${PROJECT_DIR}/example.env" "${PROJECT_DIR}/.env"
# shellcheck source=/dev/null # path is this toolbox's own common/install.sh
source "${ROOT}/common/install.sh"
generate_service_passwords "${PROJECT_DIR}/.env" \
  || die "could not generate service passwords for ${ADAPTER}"

cd "$PROJECT_DIR"

log "starting the stack..."
docker compose up -d || die "docker compose up failed for ${ADAPTER}"

log "waiting for the app container to become healthy (up to ${HEALTH_TIMEOUT_SECONDS}s)..."
health=""
elapsed=0
while [ "$elapsed" -lt "$HEALTH_TIMEOUT_SECONDS" ]; do
  # `docker inspect` on the container itself, not `docker compose ps
  # --format json`: that format's shape is compose-version-dependent — a
  # version emitting an array instead of one object per line makes `jq -r
  # '.Health'` error, which the `|| true` this needs anyway would swallow
  # into a false "unknown", producing a full 120s red on an actually-healthy
  # stack. `docker inspect` on one container id has one shape.
  health="$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -q app)" 2>/dev/null || true)"
  [ "$health" = "healthy" ] && break
  [ "$health" = "unhealthy" ] \
    && die "app container reported unhealthy — its HEALTHCHECK against ${LIVENESS_PATH} is failing (see: docker compose logs app)"
  sleep "$HEALTH_POLL_INTERVAL_SECONDS"
  elapsed=$((elapsed + HEALTH_POLL_INTERVAL_SECONDS))
done
[ "$health" = "healthy" ] \
  || die "app container did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s (last status: ${health:-unknown})"

# The readiness probe is `select 1` — it proves connectivity, not schema, and
# returns 200 against an empty database. Asserting the migration's own exit
# code, separately, is what stops a deploy whose migration silently failed
# from going green anyway.
#
# A missing migrate service used to just log a skip and exit 0 — which means
# renaming the service, breaking `config` under the migrate profile, or a
# driver returning an empty command all look identical to "this adapter has
# no database" from here, and the check that exists to catch exactly that
# regression turns itself off. ROLE and DB_SERVICE are already known, so
# absence is only ever a skip when no database was actually requested.
if docker compose --profile migrate config --services 2>/dev/null | grep -qx migrate; then
  log "running migrations..."
  docker compose --profile migrate run --rm migrate \
    || die "migrate service exited non-zero — schema was not applied"
elif [ "$ROLE" != "web" ] && [ "$DB_SERVICE" != "none" ]; then
  die "expected a migrate service for ${ADAPTER} (role=${ROLE}, db=${DB_SERVICE:-default}) but compose has none — a service, profile, or driver may have silently vanished"
else
  log "no migrate service for ${ADAPTER} — skipping migration"
fi

# `|| true`: under pipefail, a .env with no APP_PORT line makes grep exit 1
# and, unguarded, that kills the script here — silently, before the
# `${PORT:-8080}` fallback below ever gets a chance to run.
PORT="$(grep '^APP_PORT=' .env | cut -d= -f2 || true)"
PORT="${PORT:-8080}"
BASE_URL="http://localhost:${PORT}"

check_path() {
  local label="$1" path="$2" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE_URL}${path}")" \
    || die "${label} check failed: could not reach ${BASE_URL}${path}"
  [ "$code" = "200" ] \
    || die "${label} check failed: ${BASE_URL}${path} returned ${code}, not 200"
  log "${label} (${path}): ${code}"
}

check_path liveness "$LIVENESS_PATH"

if [ -n "$READINESS_PATH" ]; then
  check_path readiness "$READINESS_PATH"
elif [ "$DB_SERVICE" = none ]; then
  log "--db none — skipping readiness check"
else
  log "${ADAPTER} declares no readiness path — skipping readiness check"
fi

log "${ADAPTER} stack serves HTTP and reaches its database"
