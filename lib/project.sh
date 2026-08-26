# shellcheck shell=bash

# init_project <dir> <name>
init_project() {
  local dir="$1" name="$2"

  [ -e "$dir" ] && die "refusing to overwrite existing path: ${dir}"

  mkdir -p "$dir"
  git -C "$dir" init --initial-branch=main --quiet
  cp -R "${SCAFFOLD_ROOT}/common/." "${dir}/"

  sed "s|@PROJECT_NAME@|${name}|g" "${dir}/mise.root.toml" > "${dir}/mise.toml"
  rm -f "${dir}/mise.root.toml"

  # a config not yet trusted makes mise prompt or refuse instead of working.
  mise trust -a -y --quiet -C "$dir"
}

# register_config_root <project> <relative-path>
register_config_root() {
  local project="$1" root="$2"
  local file="${project}/mise.toml"

  grep -q "^  \"${root}\",\$" "$file" && return 0

  awk -v root="$root" '
    { print }
    /^config_roots = \[$/ { printf "  \"%s\",\n", root }
  ' "$file" > "${file}.tmp"
  mv "${file}.tmp" "$file"
}

# collect_config_roots <project>
collect_config_roots() {
  sed -n '/^config_roots = \[$/,/^\]$/p' "${1}/mise.toml" \
    | sed -n 's/^  "\(.*\)",$/\1/p'
}

# sync_ci_roots <project> — the ci workflow's matrix input is derived from the
# manifest so the two can never disagree.
sync_ci_roots() {
  local project="$1" json
  json="$(collect_config_roots "$project" | jq -R . | jq -sc .)"
  sed -i.bak "s|^      roots: .*|      roots: '${json}'|" \
    "${project}/.github/workflows/ci.yml"
  rm -f "${project}/.github/workflows/ci.yml.bak"
}

# finalize_project <project>
finalize_project() {
  local project="$1"
  sync_ci_roots "$project"
  git -C "$project" add -A
  git -C "$project" commit --quiet -m "chore: scaffold project"
}
