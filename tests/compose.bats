setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
  scaffold new "$PROJECT" --api laravel-api
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "the compose files are valid" {
  cd "$PROJECT"
  run docker compose -f compose.yaml config --quiet
  assert_ok
  run docker compose -f compose.dev.yaml config --quiet
  assert_ok
}

@test "the application image tag is parameterised" {
  run grep 'image:.*\${IMAGE_TAG' "${PROJECT}/compose.yaml"
  assert_ok
}

@test "third-party images are pinned by digest" {
  run bash -c "grep -E '^\s+image: (docker\.io|ghcr\.io)' '${PROJECT}/compose.yaml' | grep -v '@sha256:' | grep -v IMAGE_TAG"
  [ -z "$output" ]
}

@test "no dockerfile copies a dotenv file" {
  run bash -c "grep -rn 'COPY .*\.env' '${PROJECT}/apps' || true"
  [ -z "$output" ]
}

@test "install.sh is executable and passes shellcheck" {
  [ -x "${PROJECT}/install.sh" ]
  run shellcheck "${PROJECT}/install.sh"
  assert_ok
}

@test "every adapter Dockerfile pins its base images by digest" {
  # The compose files have always pinned by digest; the Dockerfiles used tags,
  # which are mutable — the same base image name can be a different image
  # tomorrow. Nothing enforced the second half. Dockerfile* also catches the
  # typescript adapters' workspace-shape Dockerfile.workspace.
  run bash -c "grep -h '^FROM' '${SCAFFOLD_ROOT}'/adapters/*/Dockerfile* | grep -v '@sha256:'"
  [ -z "$output" ] || { echo "unpinned base images:"; echo "$output"; false; }
}

@test "every adapter ships a dockerignore" {
  # `COPY . .` with no ignore file bakes the app's real .env — APP_KEY, database
  # password — into any image built locally. For nextjs it also lets a host
  # node_modules overwrite the one copied from the pinned build stage.
  for adapter in "${SCAFFOLD_ROOT}"/adapters/*/; do
    [ -f "${adapter}.dockerignore" ] \
      || { echo "no .dockerignore in ${adapter}"; false; }
  done
}

@test "install.sh generates a password for every service that has one" {
  # DB_PASSWORD was a hardcoded name in three places, so a project with a
  # cache as well as a database left REDIS_PASSWORD on the literal default
  # and nothing said so.
  cd "$PROJECT"
  cat > env.fixture <<'INNER_EOF'
DB_PASSWORD=changeme
REDIS_PASSWORD=changeme
APP_PORT=8080
INNER_EOF
  run bash -c "source ./install.sh 2>/dev/null; generate_service_passwords env.fixture"
  assert_ok
  run grep -c '=changeme$' env.fixture
  [ "$output" = "0" ]
}

@test "install.sh generates a password whose name does not end in _PASSWORD" {
  # the real contract is common/example.env's own: the literal `changeme`
  # marks a secret, not a *_PASSWORD suffix. A service naming its variable
  # differently (RABBITMQ_DEFAULT_PASS) got no generated value under the old
  # ^[A-Z_]*_PASSWORD=changeme$ pattern, and tripped no check either.
  cd "$PROJECT"
  cat > env.fixture2 <<'INNER_EOF'
RABBITMQ_DEFAULT_PASS=changeme
APP_PORT=8080
INNER_EOF
  run bash -c "source ./install.sh 2>/dev/null; generate_service_passwords env.fixture2"
  assert_ok
  run grep -c '=changeme$' env.fixture2
  [ "$output" = "0" ]
}

@test "install.sh survives being piped into bash instead of dying on an unbound variable" {
  # documented as curl-piped (`curl ... | bash`), same as the immich script
  # this is adapted from — piped in, BASH_SOURCE[0] is unbound, and
  # `set -o nounset` used to kill the script before the source guard even ran.
  mkdir -p "${WORKDIR}/piped"
  cd "${WORKDIR}/piped"
  run bash < "${PROJECT}/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *"could not download the release assets"* ]]
}

@test "a mixed-language web app's Dockerfile can see ADR-0017's build policy" {
  # apps/web is its own pnpm root here (no shared workspace with the php api),
  # so common/pnpm-workspace.yaml's allowBuilds never reaches it on its own —
  # the app needs its own copy of the decision, and the Dockerfile needs to
  # actually copy it into the build context, same as it already does for the
  # lockfile.
  local mixed="${WORKDIR}/mixed"
  scaffold new "$mixed" --api laravel-api --web nextjs
  run grep -c 'COPY .*pnpm-workspace.yaml' "${mixed}/apps/web/Dockerfile"
  [ "$output" -ge 1 ]
  run yq '.allowBuilds."unrs-resolver"' "${mixed}/apps/web/pnpm-workspace.yaml"
  [ "$output" = "false" ]
}

@test "an all-typescript project's build context and dockerfile actually see the manifests they copy" {
  # the original defect: build.yml named apps/api (the last role applied) with
  # no dockerfile input at all, so the standalone Dockerfile's
  # `COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./` failed outright —
  # enable_typescript_workspace had already deleted apps/api's own lockfile
  # and pnpm-workspace.yaml in favor of the workspace root's. Checking the
  # yq value alone (as tests/workflows.bats already did) never caught this;
  # this resolves the pair against the filesystem the way docker build would.
  local ts="${WORKDIR}/all-ts"
  scaffold new "$ts" --web nextjs --api nestjs

  local context dockerfile
  context="$(yq '.jobs.build.with.context' "${ts}/.github/workflows/build.yml")"
  dockerfile="$(yq '.jobs.build.with.dockerfile' "${ts}/.github/workflows/build.yml")"
  [ "$context" = "." ]
  [ -f "${ts}/${dockerfile}" ]

  local manifest
  for manifest in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
    [ -f "${ts}/${context}/${manifest}" ] \
      || { echo "missing ${manifest} at context '${context}', named by ${dockerfile}"; false; }
  done
}

@test "a mixed-language project's build context and dockerfile still see their own manifests" {
  # same check as the all-typescript case above, on the shape that must not
  # regress: apps/web stays its own pnpm root here, so context and dockerfile
  # both stay scoped to apps/web instead of moving to the workspace root.
  local mixed="${WORKDIR}/mixed-context"
  scaffold new "$mixed" --api laravel-api --web nextjs

  local context dockerfile
  context="$(yq '.jobs.build.with.context' "${mixed}/.github/workflows/build.yml")"
  dockerfile="$(yq '.jobs.build.with.dockerfile' "${mixed}/.github/workflows/build.yml")"
  [ "$context" = "apps/web" ]
  [ -f "${mixed}/${dockerfile}" ]

  local manifest
  for manifest in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
    [ -f "${mixed}/${context}/${manifest}" ] \
      || { echo "missing ${manifest} at context '${context}', named by ${dockerfile}"; false; }
  done
}
