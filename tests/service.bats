#!/usr/bin/env bats

setup() {
  load 'helpers/setup'
  source "${SCAFFOLD_ROOT}/lib/log.sh"
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
  run yq -e '.services.app.depends_on.database.condition == "service_healthy"' \
    "${project}/compose.yaml"
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

@test "a project with no services has no depends_on" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/compose.yaml" "$project/"

  run assemble_compose "$project"
  assert_ok
  run yq -e '.services.app.depends_on == null' "${project}/compose.yaml"
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

@test "apply_service_setup removes the anchor when nothing was selected" {
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "$app"
  printf 'FROM scratch\n# @SERVICE_SETUP@\nCMD ["true"]\n' > "${app}/Dockerfile"

  run apply_service_setup "$app" ""
  assert_ok
  # exact content, not just "no anchor line" — that proxy would still pass
  # if the anchor were replaced by a blank line instead of removed
  run cat "${app}/Dockerfile"
  assert_ok
  [ "$output" = "$(printf 'FROM scratch\nCMD ["true"]')" ]
}

@test "apply_service_setup splices in every selected service's block" {
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "$app"
  printf 'FROM scratch\n# @SERVICE_SETUP@\nCMD ["true"]\n' > "${app}/Dockerfile"

  run apply_service_setup "$app" "$(printf 'RUN one\nRUN two\n')"
  assert_ok
  run grep -q '^RUN one$' "${app}/Dockerfile"
  assert_ok
  run grep -q '^RUN two$' "${app}/Dockerfile"
  assert_ok
}

@test "apply_service_setup dies when the Dockerfile has no anchor" {
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "$app"
  printf 'FROM scratch\nCMD ["true"]\n' > "${app}/Dockerfile"

  run apply_service_setup "$app" "RUN one"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no @SERVICE_SETUP@ anchor"* ]]
}

@test "apply_service_setup passes a block through without escape processing" {
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "$app"
  printf 'FROM scratch\n# @SERVICE_SETUP@\nCMD ["true"]\n' > "${app}/Dockerfile"

  # a literal backslash-t, two characters — awk's -v assignment does
  # C-style escape processing and would collapse this into a tab
  run apply_service_setup "$app" 'RUN echo \t done'
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
  [[ "$output" == *"the broken driver failed for fixture"* ]]
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
  [[ "$output" == *"the careless driver failed for fixture"* ]]
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
  run yq -e '.services.app.depends_on | keys | length == 2' \
    "${project}/compose.yaml"
  assert_ok
  cd "$project"
  run docker compose -f compose.yaml config --quiet
  assert_ok
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
