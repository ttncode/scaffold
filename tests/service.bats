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
