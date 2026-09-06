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
LIVENESS_PATH="$ADAPTER_LIVENESS_PATH"
READINESS_PATH="${ADAPTER_READINESS_PATH:-}"

TMP_DIR="$(mktemp -d)"
PROJECT_DIR="${TMP_DIR}/demo"
IMAGE_TAG="deploy-check/${ADAPTER}:local"

# A trap, not a trailing cleanup line: every die() below is a plain `exit 1`,
# and only a trap runs on that path too.
cleanup() {
  if [ -f "${PROJECT_DIR}/compose.yaml" ]; then
    ( cd "$PROJECT_DIR" && docker compose down -v --remove-orphans ) || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

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
grep -Eq '^\s*image:.*CHANGEME' "${PROJECT_DIR}/compose.yaml" \
  && die "compose.yaml still names the CHANGEME placeholder after rewriting it"

cp "${PROJECT_DIR}/example.env" "${PROJECT_DIR}/.env"

cd "$PROJECT_DIR"

log "starting the stack..."
docker compose up -d || die "docker compose up failed for ${ADAPTER}"

log "waiting for the app container to become healthy (up to ${HEALTH_TIMEOUT_SECONDS}s)..."
health=""
elapsed=0
while [ "$elapsed" -lt "$HEALTH_TIMEOUT_SECONDS" ]; do
  health="$(docker compose ps app --format json 2>/dev/null | jq -r '.Health // empty' || true)"
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
if docker compose --profile migrate config --services 2>/dev/null | grep -qx migrate; then
  log "running migrations..."
  docker compose --profile migrate run --rm migrate \
    || die "migrate service exited non-zero — schema was not applied"
else
  log "no migrate service for ${ADAPTER} — skipping migration"
fi

PORT="$(grep '^APP_PORT=' .env | cut -d= -f2)"
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
else
  log "${ADAPTER} declares no readiness path — skipping readiness check"
fi

log "${ADAPTER} stack serves HTTP and reaches its database"
