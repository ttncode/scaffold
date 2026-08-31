setup() {
  load 'helpers/setup'
}

@test "every tour page has the four required headings" {
  local missing=""
  for page in "${SCAFFOLD_ROOT}"/docs/tour/*.md; do
    for heading in "## What it does" "## Read this" "## Delete test" "## Try it"; do
      grep -q "$heading" "$page" || missing="${missing}${page}: ${heading}"$'\n'
    done
  done
  [ -z "$missing" ]
}

@test "every path named in the tour and runbooks exists" {
  run bash -c "
    grep -rhoE '\`((\w|[.-])+/)+(\w|[.-])+\`' \
      '${SCAFFOLD_ROOT}/docs/tour' '${SCAFFOLD_ROOT}/docs/runbook' \
    | tr -d '\`' | sort -u \
    | while read -r p; do
        # apps/* names a path inside a *generated* project, which this
        # repository has no copy of and cannot verify — the walkthrough has to
        # name them to be followable. Everything else must exist here.
        case \"\$p\" in apps/*) continue ;; esac
        [ -e \"${SCAFFOLD_ROOT}/\$p\" ] || echo \"missing: \$p\"
      done"
  [ -z "$output" ]
}

@test "add-an-adapter fits on one page" {
  run wc -l < "${SCAFFOLD_ROOT}/docs/runbook/add-an-adapter.md"
  [ "$output" -le 120 ]
}

@test "every adr referenced by the tour exists" {
  run bash -c "
    grep -rhoE 'ADR-[0-9]{4}' '${SCAFFOLD_ROOT}/docs' | sort -u \
    | while read -r adr; do
        n=\${adr#ADR-}
        ls '${SCAFFOLD_ROOT}'/docs/decisions/\${n}-*.md >/dev/null 2>&1 \
          || echo \"missing: \$adr\"
      done"
  [ -z "$output" ]
}
