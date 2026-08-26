# shellcheck shell=bash

# load_adapter <name> — read one adapter's metadata into the current shell.
load_adapter() {
  local name="$1"
  local dir="${SCAFFOLD_ROOT}/adapters/${name}"

  [ -d "$dir" ] || die "unknown adapter: ${name} (run: scaffold list)"

  ADAPTER_DIR="$dir"
  # shellcheck source=/dev/null
  source "${dir}/adapter.env"
}

# role_path <role> — where an adapter of this role is installed.
role_path() {
  case "$1" in
    web) printf 'apps/web\n' ;;
    api) printf 'apps/api\n' ;;
    app) printf 'apps/app\n' ;;
    *) die "unknown adapter role: ${1}" ;;
  esac
}

# merge_lefthook_fragment <fragment> <project> <relative-path>
merge_lefthook_fragment() {
  local fragment="$1" project="$2" rel="$3" rendered

  [ -f "$fragment" ] || return 0

  rendered="$(mktemp)"
  sed "s|@APP_ROOT@|${rel}/|g" "$fragment" > "$rendered"
  yq eval-all --inplace 'select(fileIndex==0) * select(fileIndex==1)' \
    "${project}/lefthook.yml" "$rendered"
  rm -f "$rendered"
}

# apply_adapter <name> <project> <relative-path>
apply_adapter() {
  local name="$1" project="$2" rel="$3"

  load_adapter "$name"

  local dest="${project}/${rel}"
  local parent; parent="$(dirname "$dest")"
  mkdir -p "$parent"

  ( cd "$parent" && APP_DIR="$(basename "$dest")" eval "$ADAPTER_GENERATOR" )

  cp "${ADAPTER_DIR}/mise.toml"    "${dest}/mise.toml"
  cp "${ADAPTER_DIR}/Dockerfile"   "${dest}/Dockerfile"
  cp "${ADAPTER_DIR}/.env.example" "${dest}/.env.example"

  register_config_root "$project" "$rel"
  merge_lefthook_fragment "${ADAPTER_DIR}/lefthook.fragment.yml" "$project" "$rel"
}
