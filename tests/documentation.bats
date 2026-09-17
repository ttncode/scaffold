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

@test "every path named in the docs exists" {
  run bash -c "
    cd '${SCAFFOLD_ROOT}'
    grep -rhoE '\`((\w|[.-])+/)+(\w|[.-])+\`' \
      docs/tour docs/runbook README.md CONTRIBUTING.md \
      \$(git ls-files docs/README.md) \
    | tr -d '\`' | sort -u \
    | while read -r p; do
        # apps/* names a path inside a *generated* project, which this
        # repository has no copy of and cannot verify.
        case \"\$p\" in apps/*) continue ;; esac
        [ -e \"\$p\" ] || echo \"missing: \$p\"
      done"
  [ -z "$output" ]
}

@test "every relative link and image in the docs resolves" {
  run bash -c "
    cd '${SCAFFOLD_ROOT}'
    for page in README.md CONTRIBUTING.md \$(git ls-files 'docs/*.md'); do
      grep -oE '\]\([^)#[:space:]]+' \"\$page\" | cut -c3- \
        | grep -vE '^(https?:|mailto:)' \
        | while read -r target; do
            [ -e \"\$(dirname \"\$page\")/\$target\" ] || echo \"\$page: \$target\"
          done
    done"
  [ -z "$output" ]
}

@test "add-an-adapter fits on one page" {
  run wc -l <"${SCAFFOLD_ROOT}/docs/runbook/add-an-adapter.md"
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
