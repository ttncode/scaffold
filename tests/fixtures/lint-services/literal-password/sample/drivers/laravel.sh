# shellcheck shell=bash
# Exists only to prove tests/service.bats' literal-password check can fail:
# a check exercised solely by drivers already written to pass it is a check
# that cannot fail, which is the same gap this fixture's sibling
# missing-driver-function closes for the driver-function loop.
service_driver_compose_env() {
  printf 'DB_PASSWORD: hunter2\n'
}
