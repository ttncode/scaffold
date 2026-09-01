setup() {
  load 'helpers/setup'
}

@test "every verbatim row points at a file that exists locally" {
  run bash -c "
    awk -F'|' '/^\| \`/ && /verbatim/ { gsub(/[ \`]/, \"\", \$2); print \$2 }' \
      '${SCAFFOLD_ROOT}/docs/PROVENANCE.md' \
    | while read -r f; do [ -f \"${SCAFFOLD_ROOT}/\$f\" ] || echo \"missing: \$f\"; done"
  [ -z "$output" ]
}

@test "UPSTREAM pins a commit" {
  run grep -Eq '^immich-app/immich@[0-9a-f]{7,40}$' "${SCAFFOLD_ROOT}/UPSTREAM"
  assert_ok
}

@test "check-provenance reports no drift" {
  run "${SCAFFOLD_ROOT}/scripts/check-provenance.sh"
  assert_ok
  [[ "$output" == *"0 drifted"* ]]
}

@test "check-provenance detects a modified verbatim file" {
  local toolbox; toolbox="$(copy_toolbox)"
  echo "# drift" >> "${toolbox}/common/.editorconfig"
  run "${toolbox}/scripts/check-provenance.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFTED"* ]]
}
