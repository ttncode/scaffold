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
  # tomorrow. Nothing enforced the second half.
  run bash -c "grep -h '^FROM' '${SCAFFOLD_ROOT}'/adapters/*/Dockerfile | grep -v '@sha256:'"
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
