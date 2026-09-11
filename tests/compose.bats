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

@test "compose.yaml, install.sh and the build workflows name one registry path" {
  # build.yml pushes the image compose.yaml pulls, and install.sh downloads
  # the release that publishes compose.yaml. Three files, one path — written
  # from the same owner and project name at generation time.
  #
  # They used to disagree by construction: the workflows were substituted and
  # compose.yaml/install.sh shipped `CHANGEME/CHANGEME`, so a project's first
  # release named an image nothing had pushed and needed a hand-edit plus a
  # second release before install.sh worked at all.
  # One entry per application now (ADR-0022), so this asks the question of
  # every one of them rather than of a single `app` service.
  local images want_repo
  images="$(yq -r '[.jobs[] | select(has("with")) | .with.images] | .[0]' \
    "${PROJECT}/.github/workflows/build.yml")"
  [ "$(jq 'length' <<<"$images")" -gt 0 ] \
    || { echo "build.yml publishes no image at all"; false; }

  local want_image service actual
  while IFS= read -r want_image; do
    service="${want_image##*-}"
    actual="$(yq ".services.\"${service}\".image // \"\"" "${PROJECT}/compose.yaml")"
    [ -n "$actual" ] && [ "$actual" != null ] || {
      echo "build.yml pushes ${want_image} but compose.yaml has no ${service} service to run it"
      false
    }
    [[ "$actual" == "${want_image}:"* ]] || {
      echo "compose.yaml's ${service} image is ${actual}, not ${want_image} as build.yml pushes"
      false
    }
  done < <(jq -r '.[].image' <<<"$images")

  # The migrate service inherits a driven application's image rather than
  # naming one of its own.
  actual="$(yq '.services.migrate.image // ""' "${PROJECT}/compose.yaml")"
  if [ -n "$actual" ] && [ "$actual" != null ]; then
    jq -e --arg image "${actual%%:*}" 'any(.[]; .image == $image)' <<<"$images" >/dev/null \
      || { echo "migrate runs ${actual}, which no build target publishes"; false; }
  fi

  want_repo="$(jq -r '.[0].image' <<<"$images")"
  want_repo="${want_repo#ghcr.io/}"
  want_repo="${want_repo%-*}"
  run grep -qF "github.com/${want_repo}/releases" "${PROJECT}/install.sh"
  [ "$status" -eq 0 ] || {
    echo "install.sh's RepoUrl does not name ${want_repo}:"
    grep -n '^RepoUrl=' "${PROJECT}/install.sh"
    false
  }

  # A placeholder anywhere in either file means the substitution was skipped.
  run bash -c "grep -l 'CHANGEME\|@PROJECT_NAME@\|ghcr.io/you/' '${PROJECT}/compose.yaml'"
  [ -z "$output" ] || { echo "compose.yaml still carries a placeholder"; false; }
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

  # Both applications, not just the one that happened to be applied last:
  # that single-target shape is exactly the defect ADR-0022 removed.
  local images
  images="$(yq -r '[.jobs[] | select(has("with")) | .with.images] | .[0]' \
    "${ts}/.github/workflows/build.yml")"
  [ "$(jq 'length' <<<"$images")" -eq 2 ] \
    || { echo "expected two build targets, got: ${images}"; false; }

  local context dockerfile manifest
  while IFS=$'\t' read -r context dockerfile; do
    [ "$context" = "." ] || { echo "${dockerfile} builds from '${context}', not the workspace root"; false; }
    [ -f "${ts}/${dockerfile}" ] || { echo "no Dockerfile at ${dockerfile}"; false; }
    for manifest in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
      [ -f "${ts}/${context}/${manifest}" ] \
        || { echo "missing ${manifest} at context '${context}', named by ${dockerfile}"; false; }
    done
  done < <(jq -r '.[] | [.context, .dockerfile] | @tsv' <<<"$images")
}

@test "a mixed-language project's build context and dockerfile still see their own manifests" {
  # same check as the all-typescript case above, on the shape that must not
  # regress: apps/web stays its own pnpm root here, so context and dockerfile
  # both stay scoped to apps/web instead of moving to the workspace root.
  local mixed="${WORKDIR}/mixed-context"
  scaffold new "$mixed" --api laravel-api --web nextjs

  local images context dockerfile manifest
  images="$(yq -r '[.jobs[] | select(has("with")) | .with.images] | .[0]' \
    "${mixed}/.github/workflows/build.yml")"
  context="$(jq -r '.[] | select(.dockerfile == "apps/web/Dockerfile") | .context' <<<"$images")"
  dockerfile="apps/web/Dockerfile"
  [ "$context" = "apps/web" ] \
    || { echo "apps/web builds from '${context}', not its own directory"; false; }
  [ -f "${mixed}/${dockerfile}" ]

  for manifest in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
    [ -f "${mixed}/${context}/${manifest}" ] \
      || { echo "missing ${manifest} at context '${context}', named by ${dockerfile}"; false; }
  done
}

@test "every adapter Dockerfile serves the port compose publishes" {
  # add_app_service publishes ${<NAME>_PORT:-<allocated>}:8080 for every
  # application, so an adapter exposing anything else publishes a dead port.
  run bash -c "grep -L '^EXPOSE 8080\$' '${SCAFFOLD_ROOT}'/adapters/*/Dockerfile*"
  [ -z "$output" ] || { echo "not exposing 8080:"; echo "$output"; false; }

  # The container side of every published port, asserted against a real
  # project rather than the template it came from.
  run bash -c "yq -r '.services[].ports[]? | select(test(\":8080\$\") | not)' '${PROJECT}/compose.yaml'"
  [ -z "$output" ] || { echo "publishing to a port no adapter serves:"; echo "$output"; false; }
}

@test "every adapter Dockerfile probes the liveness path its adapter declares" {
  # nestjs probed /health for months while the generator produced only `/`.
  # The Dockerfile's idea of the route and the adapter's must be one value.
  local wrong=""
  for dir in "${SCAFFOLD_ROOT}"/adapters/*/; do
    path="$(grep '^ADAPTER_LIVENESS_PATH=' "${dir}adapter.env" | cut -d'"' -f2)"
    for file in "${dir}"Dockerfile "${dir}"Dockerfile.workspace; do
      [ -f "$file" ] || continue
      grep -q '^HEALTHCHECK' "$file" \
        || { wrong="${wrong}${file}: no HEALTHCHECK"$'\n'; continue; }
      # localhost or 127.0.0.1: nextjs's HEALTHCHECK dials 127.0.0.1 because
      # this image's resolver hands "localhost" the IPv6 ::1 first and the
      # IPv4-only listener (forced by ENV HOSTNAME="0.0.0.0", the fix for
      # standalone server.js otherwise binding to the container's own id)
      # refuses it — see adapters/nextjs/Dockerfile. Either host still
      # proves the adapter's declared path is the one actually probed.
      grep -Eq "(localhost|127\.0\.0\.1):8080${path}" "$file" \
        || wrong="${wrong}${file}: does not probe ${path} on 8080"$'\n'
    done
  done
  [ -z "$wrong" ] || { echo "$wrong"; false; }
}

@test "install.sh generates an APP_KEY laravel will accept" {
  # generate_service_passwords' generic 24-character value is rejected with
  # "Unsupported cipher or incorrect key length" — laravel needs base64: and
  # exactly 32 bytes.
  local env_file="${BATS_TEST_TMPDIR}/.env"
  printf 'DB_PASSWORD=changeme\nAPP_KEY=changeme\n' > "$env_file"
  . "${SCAFFOLD_ROOT}/common/install.sh"
  run generate_service_passwords "$env_file"
  assert_ok
  run grep '^APP_KEY=' "$env_file"
  [[ "$output" =~ ^APP_KEY=base64:[A-Za-z0-9+/]{43}=$ ]] \
    || { echo "not a laravel key: ${output}"; false; }
}
