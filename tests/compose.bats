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
  [ "$status" -eq 0 ]
  run docker compose -f compose.dev.yaml config --quiet
  [ "$status" -eq 0 ]
}

@test "the application image tag is parameterised" {
  run grep 'image:.*\${IMAGE_TAG' "${PROJECT}/compose.yaml"
  [ "$status" -eq 0 ]
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
  [ "$status" -eq 0 ]
}
