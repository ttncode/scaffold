#!/usr/bin/env bats

setup() {
  load 'helpers/setup'
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/pnpm.sh"
  WORKDIR="$(mktemp -d)"
}

teardown() {
  remove_workdir "$WORKDIR"
}

@test "pnpm_install fails and never invokes pnpm when the target directory is missing" {
  local stub_dir="${WORKDIR}/stub"
  local ran_marker="${WORKDIR}/pnpm-ran"
  mkdir -p "$stub_dir"
  cat >"${stub_dir}/pnpm" <<EOF
#!/usr/bin/env bash
touch "${ran_marker}"
exit 0
EOF
  chmod +x "${stub_dir}/pnpm"

  PATH="${stub_dir}:${PATH}" run pnpm_install "${WORKDIR}/missing" "a missing target directory"

  [ "$status" -ne 0 ]
  [ ! -e "$ran_marker" ]
}
