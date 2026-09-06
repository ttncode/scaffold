# shellcheck shell=bash
# Deliberately incomplete: this driver exists and sources cleanly, but omits
# service_driver_compose_migrate — the fixture for the "a driver exists and
# does not define a required function" gap in lint_services' function loop.
service_driver_apply() { :; }
service_driver_dockerfile() { :; }
service_driver_compose_env() { :; }
