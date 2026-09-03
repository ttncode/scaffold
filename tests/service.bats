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
  run yq -e '.volumes.database != null' "${project}/compose.yaml"
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

  SCAFFOLD_ROOT="$toolbox" run apply_service_drivers "$app" fixture leaky clean
  assert_ok
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
