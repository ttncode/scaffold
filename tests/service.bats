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
