#!/usr/bin/env bats

setup() {
  load 'helpers/setup'
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  # DRIVEN_ROLES lives here, and add_app_service reads it to decide whether an
  # application waits on the database. Unset, every application looks
  # undriven and the depends_on tests pass for the wrong reason.
  source "${SCAFFOLD_ROOT}/lib/contract.sh"
  source "${SCAFFOLD_ROOT}/lib/service.sh"
}

@test "load_service reads a service manifest" {
  load_service mysql
  [ "$SERVICE_NAME" = "mysql" ]
  [ "$SERVICE_KIND" = "database" ]
  [[ "$SERVICE_IMAGE" == *"@sha256:"* ]]
}

@test "load_service refuses a name that leaves services/" {
  # `source` runs what it reads, so this is the same class of hole
  # load_adapter closes — a relative name would source an arbitrary file.
  run load_service "../../tmp/evil"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a usable service name"* ]]
}

@test "load_service dies on an unknown service" {
  run load_service nonesuch
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown service: nonesuch"* ]]
}

@test "load_service returns 1 on a malformed service.env" {
  # cmd_list calls load_service per service and must treat a missing var as a
  # per-service error rather than a `set -u` crash — the same completeness
  # check load_adapter already has for adapters.
  local dir="${BATS_TEST_TMPDIR}/services/broken"
  mkdir -p "$dir"
  printf 'SERVICE_NAME="broken"\nSERVICE_KIND="database"\n' > "${dir}/service.env"

  SCAFFOLD_ROOT="$BATS_TEST_TMPDIR" run load_service broken
  [ "$status" -eq 1 ]
}

@test "service_compose_key rejects a kind nothing depends on" {
  run service_compose_key storage
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown service kind: storage"* ]]
}

@test "every service pins its image by digest" {
  for service in "${SCAFFOLD_ROOT}"/services/*/; do
    [ -f "${service}service.env" ] || continue
    grep -q '@sha256:' "${service}service.env" \
      || { echo "no digest in ${service}service.env"; false; }
  done
}

@test "no fragment pins its own image" {
  # assemble_compose injects SERVICE_IMAGE from service.env; a fragment
  # carrying its own image: line would silently fight that, and the digest
  # would no longer live in the one place it's supposed to.
  for fragment in "${SCAFFOLD_ROOT}"/services/*/compose*.fragment.yaml; do
    [ -f "$fragment" ] || continue
    if grep -q '^\s*image:' "$fragment"; then
      echo "${fragment} pins its own image"
      false
    fi
  done
}

@test "assemble_compose writes a valid stack for one database" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/compose.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.dev.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.test.yaml" "$project/"

  run assemble_compose "$project" mysql
  assert_ok

  run yq -e '.services.database.image | test("@sha256:")' "${project}/compose.yaml"
  assert_ok
  run yq -e '.volumes | has("database")' "${project}/compose.yaml"
  assert_ok
  run yq -e '.services.database.tmpfs != null' "${project}/compose.test.yaml"
  assert_ok

  run yq -e '.services.database.ports[0] == "127.0.0.1:3306:3306"' \
    "${project}/compose.dev.yaml"
  assert_ok
  run yq -e '.services.database.image | test("@sha256:")' "${project}/compose.dev.yaml"
  assert_ok

  # the prod fragment merges after the shared one, so its changeme default
  # has to win; swapping that order or dropping the override breaks nothing
  # the rest of this test would catch.
  run yq -e '.services.database.environment.MYSQL_PASSWORD == "${DB_PASSWORD:-changeme}"' \
    "${project}/compose.yaml"
  assert_ok
  run yq -e '.services.database.environment.MYSQL_PASSWORD == "${DB_PASSWORD:-app}"' \
    "${project}/compose.dev.yaml"
  assert_ok
  run yq -e '.services.database.environment.MYSQL_PASSWORD == "${DB_PASSWORD:-app}"' \
    "${project}/compose.test.yaml"
  assert_ok
}

@test "a project with no services gets no services" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/compose.yaml" "$project/"

  run assemble_compose "$project"
  assert_ok
  run yq -e '(.services | length) == 0' "${project}/compose.yaml"
  assert_ok
}

@test "assemble_example_env appends only the selected services' variables" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/example.env" "$project/"

  run assemble_example_env "$project" mysql
  assert_ok
  run grep -qx 'DB_PASSWORD=changeme' "${project}/example.env"
  assert_ok
  # redis was not selected, so its variable must not appear either
  run grep -q '^REDIS_PASSWORD=' "${project}/example.env"
  [ "$status" -eq 1 ]
}

@test "example.env carries no database variables until a service adds them" {
  run grep -c '^DB_' "${SCAFFOLD_ROOT}/common/example.env"
  [ "$output" = "0" ]
}

@test "every adapter declares a framework family" {
  for adapter in "${SCAFFOLD_ROOT}"/adapters/*/; do
    grep -Eq '^ADAPTER_FAMILY="(laravel|nest|next)"$' "${adapter}adapter.env" \
      || { echo "no ADAPTER_FAMILY in ${adapter}adapter.env"; false; }
  done
}

@test "every adapter Dockerfile carries the service anchor" {
  for adapter in "${SCAFFOLD_ROOT}"/adapters/*/; do
    grep -q '^# @SERVICE_SETUP@$' "${adapter}Dockerfile" \
      || { echo "no @SERVICE_SETUP@ anchor in ${adapter}Dockerfile"; false; }
  done
}

@test "apply_service_dockerfile removes the anchor when nothing was selected" {
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "$app"
  printf 'FROM scratch\n# @SERVICE_SETUP@\nCMD ["true"]\n' > "${app}/Dockerfile"

  run apply_service_dockerfile "$app" ""
  assert_ok
  # exact content, not just "no anchor line" — that proxy would still pass
  # if the anchor were replaced by a blank line instead of removed
  run cat "${app}/Dockerfile"
  assert_ok
  [ "$output" = "$(printf 'FROM scratch\nCMD ["true"]')" ]
}

@test "apply_service_dockerfile splices in every selected service's block" {
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "$app"
  printf 'FROM scratch\n# @SERVICE_SETUP@\nCMD ["true"]\n' > "${app}/Dockerfile"

  run apply_service_dockerfile "$app" "$(printf 'RUN one\nRUN two\n')"
  assert_ok
  run grep -q '^RUN one$' "${app}/Dockerfile"
  assert_ok
  run grep -q '^RUN two$' "${app}/Dockerfile"
  assert_ok
}

@test "apply_service_dockerfile dies when the Dockerfile has no anchor" {
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "$app"
  printf 'FROM scratch\nCMD ["true"]\n' > "${app}/Dockerfile"

  run apply_service_dockerfile "$app" "RUN one"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no @SERVICE_SETUP@ anchor"* ]]
}

@test "apply_service_dockerfile passes a block through without escape processing" {
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "$app"
  printf 'FROM scratch\n# @SERVICE_SETUP@\nCMD ["true"]\n' > "${app}/Dockerfile"

  # a literal backslash-t, two characters — awk's -v assignment does
  # C-style escape processing and would collapse this into a tab
  run apply_service_dockerfile "$app" 'RUN echo \t done'
  assert_ok
  run grep -Fq 'RUN echo \t done' "${app}/Dockerfile"
  assert_ok
}

@test "write_env_lines replaces a key rather than duplicating it" {
  local file="${BATS_TEST_TMPDIR}/.env.example"
  printf 'DB_HOST=localhost\nAPP_ENV=local\n' > "$file"

  run write_env_lines "$file" "DB_HOST=database" "DB_PORT=3306"
  assert_ok
  run grep -c '^DB_HOST=' "$file"
  [ "$output" = "1" ]
  run grep -qx 'DB_HOST=database' "$file"
  assert_ok
  run grep -qx 'DB_PORT=3306' "$file"
  assert_ok
}

@test "write_env_lines survives a value with sed metacharacters on replace" {
  # a MongoDB DATABASE_URL carries both & and | in the wild; sed's own
  # replacement syntax would otherwise mangle them (and $ would need
  # escaping too, so a backslash is thrown in on top).
  local file="${BATS_TEST_TMPDIR}/.env.example"
  local value='mongodb://app:app@localhost/app?authSource=admin&x=1|y\z'
  printf 'DATABASE_URL=placeholder\n' > "$file"

  run write_env_lines "$file" "DATABASE_URL=${value}"
  assert_ok
  run write_env_lines "$file" "DATABASE_URL=${value}"
  assert_ok

  run grep -c '^DATABASE_URL=' "$file"
  [ "$output" = "1" ]
  run grep -Fxq "DATABASE_URL=${value}" "$file"
  assert_ok
}

@test "write_env_lines appends onto a file with no trailing newline" {
  local file="${BATS_TEST_TMPDIR}/.env.example"
  printf 'APP_ENV=local' > "$file"

  run write_env_lines "$file" "DB_HOST=database"
  assert_ok
  run grep -qx 'APP_ENV=local' "$file"
  assert_ok
  run grep -qx 'DB_HOST=database' "$file"
  assert_ok
}

@test "apply_service_drivers does not leak one driver's parameters into the next" {
  local toolbox; toolbox="$(copy_toolbox)"
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "$app" \
    "${toolbox}/services/leaky/drivers" "${toolbox}/services/clean/drivers"

  cat > "${toolbox}/services/leaky/service.env" <<'EOF'
SERVICE_NAME="leaky"
SERVICE_KIND="database"
SERVICE_IMAGE="example/leaky@sha256:deadbeef"
EOF
  cat > "${toolbox}/services/leaky/drivers/fixture.sh" <<'EOF'
service_driver_apply() { FIXTURE_PARAM=set; }
service_driver_dockerfile() { :; }
EOF

  cat > "${toolbox}/services/clean/service.env" <<'EOF'
SERVICE_NAME="clean"
SERVICE_KIND="cache"
SERVICE_IMAGE="example/clean@sha256:deadbeef"
EOF
  cat > "${toolbox}/services/clean/drivers/fixture.sh" <<'EOF'
service_driver_apply() {
  [ -z "${FIXTURE_PARAM:-}" ] \
    || { echo "leaky's FIXTURE_PARAM survived into clean's driver" >&2; exit 1; }
}
service_driver_dockerfile() { :; }
EOF

  SCAFFOLD_ROOT="$toolbox" run apply_service_drivers "$app" "$app" fixture leaky clean
  assert_ok
}

@test "apply_service_drivers dies when a driver fails partway through service_driver_apply" {
  local toolbox; toolbox="$(copy_toolbox)"
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "$app" "${toolbox}/services/broken/drivers"

  cat > "${toolbox}/services/broken/service.env" <<'EOF'
SERVICE_NAME="broken"
SERVICE_KIND="database"
SERVICE_IMAGE="example/broken@sha256:deadbeef"
EOF
  # Mirrors the real bug's shape: a fallible command fails, then a later
  # command in the same function would otherwise succeed. `|| return 1` makes
  # the failure visible at the point it happens; apply_service_drivers'
  # process-level `set -e` (below) would also catch a driver that omits it.
  cat > "${toolbox}/services/broken/drivers/fixture.sh" <<'EOF'
service_driver_apply() {
  false || return 1
  touch installed
}
service_driver_dockerfile() { :; }
EOF

  SCAFFOLD_ROOT="$toolbox" run apply_service_drivers "$app" "$app" fixture broken
  [ "$status" -eq 1 ]
  # The service and the family both have to be named: a bare "a driver failed"
  # sends the reader to the wrong one of eight.
  [[ "$output" == *"wiring broken into"* ]] \
    || { echo "the failure does not name the service:"; echo "$output"; false; }
  [[ "$output" == *"fixture driver"* ]] \
    || { echo "the failure does not name the driver family:"; echo "$output"; false; }
  [ ! -e "${app}/installed" ]
}

# The guarantee has to hold even when a driver forgets `|| return 1`
# altogether — that is what makes it structural rather than conventional.
# `( ... ) || die` (the previous shape) makes the subshell the left operand
# of `||`, and bash disables `set -e` inside that; this driver has no
# `|| return 1` anywhere, so it only dies here if apply_service_drivers runs
# it somewhere `set -e` still applies.
@test "apply_service_drivers dies on an unchecked driver failure with no || return 1 anywhere" {
  local toolbox; toolbox="$(copy_toolbox)"
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "$app" "${toolbox}/services/careless/drivers"

  cat > "${toolbox}/services/careless/service.env" <<'EOF'
SERVICE_NAME="careless"
SERVICE_KIND="database"
SERVICE_IMAGE="example/careless@sha256:deadbeef"
EOF
  cat > "${toolbox}/services/careless/drivers/fixture.sh" <<'EOF'
service_driver_apply() { false; touch installed; }
service_driver_dockerfile() { :; }
EOF

  SCAFFOLD_ROOT="$toolbox" run apply_service_drivers "$app" "$app" fixture careless
  [ "$status" -eq 1 ]
  # The service and the family both have to be named: a bare "a driver failed"
  # sends the reader to the wrong one of eight.
  [[ "$output" == *"wiring careless into"* ]] \
    || { echo "the failure does not name the service:"; echo "$output"; false; }
  [[ "$output" == *"fixture driver"* ]] \
    || { echo "the failure does not name the driver family:"; echo "$output"; false; }
  [ ! -e "${app}/installed" ]
}

@test "apply_service_drivers dies clearly when services are selected but no driver family is set" {
  # Same blank-interpolation shape lint_services once had: an empty family
  # reaching the loop below produces "no driver for  — run 'scaffold lint'"
  # (two spaces, no name). Guarded before the loop instead, so this never
  # even reaches load_service.
  local app="${BATS_TEST_TMPDIR}/no-family-app"
  mkdir -p "$app"

  run apply_service_drivers "$app" "$app" "" nonexistent-service
  [ "$status" -eq 1 ]
  [[ "$output" == *"no driver family"* ]]
  [[ "$output" != *"has no driver for  "* ]]
}

@test "apply_service_drivers points a driver at the real project root, not the app's own ancestor" {
  # scaffold add creates its app one directory below the project root
  # ("worker", not "apps/worker"); a driver that assumed the fixed
  # apps/<role> depth would land two directories above the app instead —
  # reproduced directly against the pre-fix nest.sh, which mutated this
  # decoy file with exit 0 and never noticed the real root had no
  # pnpm-workspace.yaml of its own.
  local root="${BATS_TEST_TMPDIR}/rootcheck/project"
  local decoy="${BATS_TEST_TMPDIR}/rootcheck"
  local app="${root}/worker"
  local fakebin="${BATS_TEST_TMPDIR}/rootcheck/fakebin"
  mkdir -p "$app" "$fakebin"
  printf 'allowBuilds: {}\n' > "${decoy}/pnpm-workspace.yaml"

  # stands in for pnpm add/pnpm add -D, both network calls nest.sh's driver
  # makes before the yq guard this test exercises
  cat > "${fakebin}/pnpm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${fakebin}/pnpm"

  PATH="${fakebin}:${PATH}" run apply_service_drivers "$app" "$root" nest mysql
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not set allowBuilds for prisma in pnpm-workspace.yaml"* ]]
  [ ! -f "${root}/pnpm-workspace.yaml" ]
  run cat "${decoy}/pnpm-workspace.yaml"
  [ "$output" = "allowBuilds: {}" ]
}

@test "apply_service_drivers skips a driver's empty dockerfile output instead of splicing a blank line" {
  local toolbox; toolbox="$(copy_toolbox)"
  local app="${BATS_TEST_TMPDIR}/blank-line-app"
  mkdir -p "$app" "${toolbox}/services/quiet/drivers" "${toolbox}/services/loud/drivers"
  printf 'FROM scratch\n# @SERVICE_SETUP@\nCMD ["true"]\n' > "${app}/Dockerfile"

  cat > "${toolbox}/services/quiet/service.env" <<'EOF'
SERVICE_NAME="quiet"
SERVICE_KIND="cache"
SERVICE_IMAGE="example/quiet@sha256:deadbeef"
EOF
  cat > "${toolbox}/services/quiet/drivers/fixture.sh" <<'EOF'
service_driver_apply() { :; }
service_driver_dockerfile() { :; }
EOF

  cat > "${toolbox}/services/loud/service.env" <<'EOF'
SERVICE_NAME="loud"
SERVICE_KIND="database"
SERVICE_IMAGE="example/loud@sha256:deadbeef"
EOF
  cat > "${toolbox}/services/loud/drivers/fixture.sh" <<'EOF'
service_driver_apply() { :; }
service_driver_dockerfile() { printf 'RUN loud-setup\n'; }
EOF

  SCAFFOLD_ROOT="$toolbox" run apply_service_drivers "$app" "$app" fixture loud quiet
  assert_ok
  run cat "${app}/Dockerfile"
  assert_ok
  [ "$output" = "$(printf 'FROM scratch\nRUN loud-setup\nCMD ["true"]')" ]
}

@test "every database service has a driver for every family that takes one" {
  # A missing file means the combination was never wired. It never means the
  # tier does not need one — the web role is excluded by role, above.
  local service family
  for service in "${SCAFFOLD_ROOT}"/services/*/; do
    [ -f "${service}service.env" ] || continue
    for family in laravel nest; do
      [ -f "${service}drivers/${family}.sh" ] \
        || { echo "no ${family} driver in ${service}"; false; }
    done
  done
}

@test "postgres assembles a valid stack" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/compose.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.dev.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.test.yaml" "$project/"

  run assemble_compose "$project" postgres
  assert_ok
  cd "$project"
  run docker compose -f compose.yaml config --quiet
  assert_ok
}

@test "mongodb assembles a valid stack" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/compose.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.dev.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.test.yaml" "$project/"

  run assemble_compose "$project" mongodb
  assert_ok
  cd "$project"
  run docker compose -f compose.yaml config --quiet
  assert_ok
}

# No generated Laravel skeleton needed — same fixture shape as
# register_config_root's anchor tests in tests/new-project.bats: a file
# carrying just the anchor line is enough to prove the insert.
@test "register_mongodb_connection inserts the mongodb connection at the anchor" {
  local file="${BATS_TEST_TMPDIR}/config/database.php"
  mkdir -p "$(dirname "$file")"
  printf "<?php\n\nreturn [\n    'connections' => [\n    ],\n];\n" > "$file"

  run bash -c "
    source '${SCAFFOLD_ROOT}/lib/log.sh'
    source '${SCAFFOLD_ROOT}/services/mongodb/drivers/laravel.sh'
    register_mongodb_connection '$file'
  "
  assert_ok

  run grep -Fxq "        'mongodb' => [" "$file"
  assert_ok
  run grep -Fq "'dsn' => env('DB_URI', 'mongodb://localhost:27017')," "$file"
  assert_ok
  run grep -Fq "'database' => env('DB_DATABASE', 'app')," "$file"
  assert_ok
}

# The half that matters: an anchor that stops matching (a Laravel skeleton
# upgrade reformats config/database.php) must fail loudly here instead of
# shipping an app whose DB_CONNECTION names a connection nothing defines.
@test "register_mongodb_connection dies when the anchor is missing" {
  local file="${BATS_TEST_TMPDIR}/config/database.php"
  mkdir -p "$(dirname "$file")"
  printf "<?php\n\nreturn [\n    'connections' => [],\n];\n" > "$file"

  run bash -c "
    source '${SCAFFOLD_ROOT}/lib/log.sh'
    source '${SCAFFOLD_ROOT}/services/mongodb/drivers/laravel.sh'
    register_mongodb_connection '$file'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"config/database.php"* ]]
}

@test "a database and a cache assemble side by side" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/compose.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.dev.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.test.yaml" "$project/"

  run assemble_compose "$project" mysql redis
  assert_ok
  run yq -e '.services.database != null and .services.cache != null' \
    "${project}/compose.yaml"
  assert_ok
  # assemble_compose no longer touches an application service — a project has
  # one per application now, and add_app_service is what makes each of them
  # wait on the services it was generated against (ADR-0022).
  # Compared as a joined string: yq's `==` on two sequences returns a
  # sequence of per-element results, not one boolean, so `-e` reads it as no
  # match and the test fails whatever the keys are.
  run yq -e '(.services | keys | sort | join(",")) == "cache,database"' \
    "${project}/compose.yaml"
  assert_ok
  cd "$project"
  run docker compose -f compose.yaml config --quiet
  assert_ok
}

# _app_fixture <project> [database] [cache] — the two files add_app_service
# reads: the manifest carrying the registry path and the recorded services,
# and the compose file it merges into.
_app_fixture() {
  local project="$1" database="${2:-none}" cache="${3:-none}"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/compose.yaml" "${project}/compose.yaml"
  : > "${project}/example.env"
  printf 'monorepo_root = true\n\n[vars]\ndatabase = "%s"\ncache = "%s"\nimage = "ghcr.io/acme/demo"\n' \
    "$database" "$cache" > "${project}/mise.toml"
}

@test "add_app_service names the service and image after the application directory" {
  local project="${BATS_TEST_TMPDIR}/named"
  _app_fixture "$project"

  run add_app_service "$project" apps/web web
  assert_ok
  run yq -r '.services.web.image' "${project}/compose.yaml"
  [ "$output" = 'ghcr.io/acme/demo-web:${IMAGE_TAG:-latest}' ] \
    || { echo "image is ${output}"; false; }
}

@test "add_app_service allocates a port per application, from 8080 up" {
  # Allocated off compose.yaml rather than counted in a variable, so
  # `scaffold add` months later continues the same sequence (ADR-0022).
  local project="${BATS_TEST_TMPDIR}/ports"
  _app_fixture "$project"

  add_app_service "$project" apps/web web
  add_app_service "$project" apps/api api
  add_app_service "$project" apps/admin-ui web

  run yq -r '[.services[].ports[0]] | join(" ")' "${project}/compose.yaml"
  [ "$output" = '${WEB_PORT:-8080}:8080 ${API_PORT:-8081}:8080 ${ADMIN_UI_PORT:-8082}:8080' ] \
    || { echo "ports are: ${output}"; false; }

  # The same variable names, in the file install.sh writes .env from.
  run grep -c -E '^(WEB|API|ADMIN_UI)_PORT=' "${project}/example.env"
  [ "$output" = 3 ]
}

@test "only an application that opens a connection waits for one" {
  # A web application has no driver and no client, so making it wait on the
  # database would only delay it behind a service it never reaches.
  local project="${BATS_TEST_TMPDIR}/depends"
  _app_fixture "$project" postgres redis

  add_app_service "$project" apps/web web
  add_app_service "$project" apps/api api

  run yq -r '.services.web.depends_on // "none"' "${project}/compose.yaml"
  [ "$output" = none ] || { echo "web waits on: ${output}"; false; }

  run yq -r '.services.api.depends_on | keys | sort | join(",")' "${project}/compose.yaml"
  [ "$output" = "cache,database" ] || { echo "api waits on: ${output}"; false; }
}

@test "add_app_service refuses a project with no recorded registry path" {
  # A project generated before [vars] image existed would otherwise get a
  # service whose image is the bare suffix, which docker rejects much later.
  local project="${BATS_TEST_TMPDIR}/old"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/compose.yaml" "${project}/compose.yaml"
  printf 'monorepo_root = true\n\n[vars]\ndatabase = "none"\ncache = "none"\n' > "${project}/mise.toml"

  # Through `bash -e`, the way scaffold itself runs it: die() inside a command
  # substitution exits only the subshell, and it is errexit on the assignment
  # that actually stops the run. bats' own `run` turns errexit off, so calling
  # the function directly here would report success and prove nothing.
  run bash -euo pipefail -c "
    source '${SCAFFOLD_ROOT}/lib/log.sh'
    source '${SCAFFOLD_ROOT}/lib/contract.sh'
    source '${SCAFFOLD_ROOT}/lib/service.sh'
    add_app_service '$project' apps/api api
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"[vars] image"* ]]
}

@test "a cache contributes its own password to example.env" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/example.env" "$project/"

  run assemble_example_env "$project" mysql redis
  assert_ok
  run grep -c '=changeme$' "${project}/example.env"
  [ "$output" = "2" ]
}

@test "redis's production command and healthcheck fully replace the shared ones" {
  # yq's * replaces arrays wholesale rather than merging them index by index;
  # a half-merge would leave the shared "app" password sitting next to the
  # production "--appendonly" flag instead of the "changeme" default.
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/compose.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.dev.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.test.yaml" "$project/"

  run assemble_compose "$project" redis
  assert_ok
  # length pins the count so a half-merge (extra elements left over from the
  # shared array) fails here instead of only in the password check below.
  run yq -e '.services.cache.command | length == 5' "${project}/compose.yaml"
  assert_ok
  run yq -e '.services.cache.command[2] == "${REDIS_PASSWORD:-changeme}"' \
    "${project}/compose.yaml"
  assert_ok
  run yq -e '.services.cache.command[3] == "--appendonly"' "${project}/compose.yaml"
  assert_ok
  run yq -e '.services.cache.command[4] == "yes"' "${project}/compose.yaml"
  assert_ok
  run yq -e '.services.cache.healthcheck.test | length == 5' "${project}/compose.yaml"
  assert_ok
  run yq -e '.services.cache.healthcheck.test[3] == "${REDIS_PASSWORD:-changeme}"' \
    "${project}/compose.yaml"
  assert_ok
}

@test "record_services and project_service round-trip" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  sed 's|@PROJECT_NAME@|demo|g' "${SCAFFOLD_ROOT}/common/mise.root.toml" \
    > "${project}/mise.toml"

  run record_services "$project" mysql none
  assert_ok
  run project_service "$project" database
  assert_ok
  [ "$output" = "mysql" ]
  run project_service "$project" cache
  assert_ok
  [ -z "$output" ]
}

@test "the nest driver decides allowBuilds before it installs anything" {
  # pnpm refuses a package whose build script nobody has decided on, and on a
  # runner — no TTY to prompt at — that refusal is ERR_PNPM_IGNORED_BUILDS
  # rather than a warning. Ordered after the installs this passed every local
  # run and failed on the first push to main, because a warm pnpm store hides
  # it. Asserting the order here costs nothing; reproducing it costs a cold
  # store and a full generation.
  local file="${SCAFFOLD_ROOT}/services/shared/nest.sh"
  local allow_builds first_add

  allow_builds="$(grep -n 'allowBuilds.prisma' "$file" | head -1 | cut -d: -f1)"
  first_add="$(grep -n '^  pnpm add' "$file" | head -1 | cut -d: -f1)"

  [ -n "$allow_builds" ] || { echo "no allowBuilds line in ${file}"; false; }
  [ -n "$first_add" ] || { echo "no pnpm add line in ${file}"; false; }
  [ "$allow_builds" -lt "$first_add" ] \
    || { echo "allowBuilds (line ${allow_builds}) must come before the first pnpm add (line ${first_add})"; false; }
}

# Shared by the two tests below, so a regression in the check itself fails
# both: a copy of this logic kept only in the fixture test could no-op right
# alongside a broken check while still reporting green on its own.
_password_literal_report() {
  local driver="$1" block bad=""
  block="$( . "${SCAFFOLD_ROOT}/lib/service.sh"
            SERVICE_DIR="$(dirname "$(dirname "$driver")")"
            . "$driver"; service_driver_compose_env )"

  # A *_PASSWORD key whose value is not exactly an interpolation. Anchored
  # with optional leading whitespace, not a bare ^, so an indented key still
  # gets selected for the case check below.
  #
  # Only *_PASSWORD, deliberately: PGPASSWORD, DB_PASS, and APP_KEY's own
  # base64 secret would also slip past this, but a name blacklist is never
  # complete, and the services/*/drivers/*.sh files are the only writers of
  # this block and already go through review — widen the blacklist here and
  # the next unlisted name just becomes the new hole.
  while IFS= read -r line; do
    case "$line" in
      *_PASSWORD:\ \$\{*_PASSWORD\}) ;;
      *) bad="${bad}${driver} (${line})"$'\n' ;;
    esac
  done < <(grep -E '^[[:space:]]*[A-Za-z_]*_PASSWORD:' <<<"$block")

  # A DSN's user:password@ slot whose password is not exactly an
  # interpolation — the same shape, embedded in a URL instead of a key.
  while IFS= read -r segment; do
    case "$segment" in
      :\$\{*_PASSWORD\}@) ;;
      *) bad="${bad}${driver} (${segment})"$'\n' ;;
    esac
  done < <(grep -oE ':[^:@]*@' <<<"$block")

  printf '%s' "$bad"
}

@test "a driver's compose environment never bakes a literal password" {
  # The password must exist in exactly one place — .env — so compose composes
  # the URL at `up` time. A literal baked here is the changeme-versus-app
  # mismatch that made the dev stack unable to authenticate.
  #
  # No skip for an empty block: an empty block matches neither grep below,
  # so this loop already treats "emits nothing" as "nothing to flag" without
  # a special case for it.
  #
  # Asserts the absence of a literal, not the presence of an interpolation:
  # a block could carry `${DB_PASSWORD}` somewhere else and a hardcoded
  # value where the credential actually goes, and the old presence-only
  # check could not tell the two apart.
  local bad=""
  for driver in "${SCAFFOLD_ROOT}"/services/*/drivers/*.sh; do
    bad="${bad}$(_password_literal_report "$driver")"
  done
  [ -z "$bad" ] || { echo "embeds a literal password:"; echo "$bad"; false; }
}

@test "the literal-password check reports a driver that bakes one in" {
  # The test above only proves the check accepts what ships today — deleting
  # its loops leaves that test green too, which is the same "gate that
  # cannot fail" shape the missing-driver-function fixture exists to rule
  # out for the driver-function loop. This drives the identical check
  # against a fixture driver that hardcodes a password, so a regression to
  # "matches nothing" fails here even while every real driver still passes.
  local driver="${SCAFFOLD_ROOT}/tests/fixtures/lint-services/literal-password/sample/drivers/laravel.sh"
  local bad
  bad="$(_password_literal_report "$driver")"
  [[ "$bad" == *"DB_PASSWORD: hunter2"* ]] \
    || { echo "expected a literal password to be reported, got:"; echo "$bad"; false; }
}

@test "apply_service_compose_env merges into the application it was given" {
  # Named, not assumed: a project has one service per application now, and a
  # driver's environment belongs to the one whose adapter pulled it in — not
  # to a generic `app` (ADR-0022).
  local project="${BATS_TEST_TMPDIR}/p"
  mkdir -p "$project"
  printf 'services:\n  api:\n    image: x\n  web:\n    image: y\n' > "${project}/compose.yaml"
  . "${SCAFFOLD_ROOT}/lib/service.sh"
  apply_service_compose_env "$project" api 'DATABASE_URL: ${DATABASE_URL:-postgresql://app@database:5432/app}'
  run mise exec -- yq -r '.services.api.environment.DATABASE_URL' "${project}/compose.yaml"
  [[ "$output" == 'postgresql://app@database:5432/app' ]] \
    || [[ "$output" == '${DATABASE_URL:-postgresql://app@database:5432/app}' ]]

  # The application beside it is left alone.
  run mise exec -- yq -r '.services.web.environment // "none"' "${project}/compose.yaml"
  [ "$output" = none ]
}

@test "the laravel drivers name the connection selector laravel actually reads" {
  # config/database.php is `env('DB_CONNECTION', 'sqlite')`. Without that
  # variable laravel does not fail — it silently reads DB_DATABASE as a
  # sqlite filename and never contacts the service at all.
  for service in mysql postgres mongodb; do
    block="$( . "${SCAFFOLD_ROOT}/lib/service.sh"
              . "${SCAFFOLD_ROOT}/services/${service}/drivers/laravel.sh"
              service_driver_compose_env )"
    grep -q '^DB_CONNECTION:' <<<"$block" \
      || { echo "${service}/laravel.sh emits no DB_CONNECTION"; false; }
  done
}

@test "the nest drivers name DATABASE_URL and let an operator override it" {
  for service in mysql postgres mongodb; do
    block="$( . "${SCAFFOLD_ROOT}/lib/service.sh"
              . "${SCAFFOLD_ROOT}/services/${service}/drivers/nest.sh"
              service_driver_compose_env )"
    grep -q '^DATABASE_URL: \${DATABASE_URL:-' <<<"$block" \
      || { echo "${service}/nest.sh does not allow an override"; false; }
  done
}

@test "the nestjs health controller ships without async, and its driver adds it" {
  # A project generated with --db none keeps this file as shipped: nothing
  # splices a probe in, so nothing in ready() awaits. Shipping it `async`
  # made every --db none project fail @typescript-eslint/require-await on
  # its own lint task — green-on-generation is the whole promise (ADR-0021),
  # and two of the sixteen nightly service cells were red on it.
  #
  # Both halves, because either alone is satisfiable by a broken file: the
  # shipped file must not say async, and the driver must be the thing that
  # adds it back for the case that does await.
  local controller="${SCAFFOLD_ROOT}/adapters/nestjs/src/health/health.controller.ts"

  run grep -q 'async ready(' "$controller"
  [ "$status" -ne 0 ] || {
    echo "the shipped controller declares ready() async, so a --db none project"
    echo "fails require-await; services/shared/nest.sh adds the keyword instead."
    false
  }

  run grep -q 'async ready(): Promise<' "${SCAFFOLD_ROOT}/services/shared/nest.sh"
  [ "$status" -eq 0 ] || {
    echo "services/shared/nest.sh no longer restores async ready(), so a project"
    echo "with a database awaits inside a non-async method."
    false
  }
}
