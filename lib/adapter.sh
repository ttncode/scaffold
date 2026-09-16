# Load an adapter and install the application it generates.
# shellcheck shell=bash

APPS_DIR="apps"

# Sourced or merged by name, so never copied verbatim into the application.
ADAPTER_INTERNAL_FILES=(adapter.env lefthook.fragment.yml)

# Cleared on every load, or a stale value is read as the next adapter's own.
ADAPTER_OPTIONAL_VARS=(
  ADAPTER_POST_GENERATE ADAPTER_LANGUAGE ADAPTER_ROLE ADAPTER_TIER
  ADAPTER_FAMILY ADAPTER_LIVENESS_PATH ADAPTER_READINESS_PATH
)

# Runs a command in a directory through the app's pinned toolchain. composer
# stays ambient on purpose (ADR-0016).
# shellcheck disable=SC2016 # $1 and $2 are the child's to expand
ADAPTER_TOOLCHAIN_SCRIPT='cd "$1" && mise exec -- bash -c "$2"'

load_adapter() {
  local -r name="$1"

  # `source` below executes what it reads, so the name must not leave adapters/.
  case "$name" in
    '' | *[!a-z0-9-]* | -*) die "not a usable adapter name: ${name} (run: scaffold list)" ;;
  esac

  local -r dir="${SCAFFOLD_ROOT}/adapters/${name}"
  [[ -d "$dir" ]] || die "unknown adapter: ${name} (run: scaffold list)"

  ADAPTER_DIR="$dir"
  unset -v "${ADAPTER_OPTIONAL_VARS[@]}"

  # shellcheck source=/dev/null
  source "${dir}/adapter.env" || return 1

  # Left to the linter, so a fixture missing them still loads.
  : "${ADAPTER_TIER:=}"
  : "${ADAPTER_FAMILY:=}"

  # Under `set -u` the caller would die mid-loop reading an unset name, hiding
  # every good adapter after it.
  [[ -n "${ADAPTER_NAME:-}" ]] && [[ -n "${ADAPTER_ROLE:-}" ]] || return 1
}

adapter_is_typescript() {
  (
    load_adapter "$1"
    [[ "${ADAPTER_LANGUAGE:-}" == "typescript" ]]
  )
}

role_path() {
  local -r role="$1"

  case "$role" in
    web | api | app) printf '%s/%s\n' "$APPS_DIR" "$role" ;;
    *) die "unknown adapter role: ${role}" ;;
  esac
}

merge_lefthook_fragment() {
  local -r fragment="$1" project="$2" rel="$3"
  local rendered

  [[ -f "$fragment" ]] || return 0

  rendered="$(mktemp)"
  sed "s|@APP_ROOT@|${rel}/|g" "$fragment" >"$rendered"

  # The merge is key-wise: without the suffix, two laravel apps' `pint` collapse
  # into one and the other app goes unformatted.
  yq --inplace "(.. | select(has(\"commands\")) | .commands) |=
      with_entries(.key |= . + \"-${rel//\//-}\")" "$rendered"

  # -P: yq propagates the fragment's style, and an empty `{}` fragment would
  # collapse lefthook.yml onto one line and drop its comments.
  if ! yq eval-all --inplace -P 'select(fileIndex==0) * select(fileIndex==1)' \
    "${project}/lefthook.yml" "$rendered"; then
    rm -f "$rendered"
    die "failed to merge the lefthook fragment for ${rel}"
  fi
  rm -f "$rendered"
}

# pnpm exits 0 on a --filter that matches nothing, so a misnamed package.json
# would surface steps later as a COPY of a node_modules never created.
assert_workspace_filter_name() {
  local -r dest="$1"

  [[ -f "${ADAPTER_DIR}/Dockerfile.workspace" ]] || return 0

  local found expected
  found="$(jq -r '.name' "${dest}/package.json")"
  expected="$(basename "$dest")"
  [[ "$found" == "$expected" ]] ||
    die "${dest}/package.json is named '${found}', not '${expected}' — Dockerfile.workspace's 'pnpm --filter ${expected}' would match nothing"
}

substitute_workspace_filter() {
  local -r dest="$1"
  local -r file="${dest}/Dockerfile.workspace"

  [[ -f "$file" ]] || return 0

  sed -i.bak "s|@APP_FILTER@|$(basename "$dest")|g" "$file"
  rm -f "${file}.bak"
}

# Directories merge rather than replace: the generator already created `src/`,
# and `cp -R src dest/src` would nest it.
copy_adapter_files() {
  local -r dest="$1"
  local file base dir had_dotglob=0

  shopt -q dotglob && had_dotglob=1
  shopt -s dotglob
  for file in "${ADAPTER_DIR}"/*; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file")"
    case " ${ADAPTER_INTERNAL_FILES[*]} " in
      *" ${base} "*) continue ;;
    esac
    cp "$file" "${dest}/${base}"
  done
  ((had_dotglob == 1)) || shopt -u dotglob

  for dir in "${ADAPTER_DIR}"/*/; do
    [[ -d "$dir" ]] || continue
    mkdir -p "${dest}/$(basename "$dir")"
    cp -R "${dir}." "${dest}/$(basename "$dir")/"
  done
}

apply_adapter() {
  local -r name="$1" project="$2" rel="$3"

  load_adapter "$name"

  local -r dest="${project}/${rel}"
  generate_adapter_app "$name" "$dest" "$rel"

  assert_workspace_filter_name "$dest"
  copy_adapter_files "$dest"
  substitute_workspace_filter "$dest"
  configure_adapter_app "$dest" "$rel"
  wire_adapter_services "$dest" "$project"

  register_config_root "$project" "$rel"
  merge_lefthook_fragment "${ADAPTER_DIR}/lefthook.fragment.yml" "$project" "$rel"
}

# CI=true stays, so pnpm replaces node_modules without a TTY; its frozen
# lockfile must not, or `pnpm add` reports success and installs nothing.
generate_adapter_app() {
  local -r name="$1" dest="$2" rel="$3"
  local parent
  parent="$(dirname "$dest")"
  mkdir -p "$parent"

  step "generating ${rel} with ${name} (a framework generator, this takes a few minutes)"
  run_quietly "generating ${rel} with ${name}" \
    env APP_DIR="$(basename "$dest")" npm_config_frozen_lockfile=false \
    bash -c "$ADAPTER_TOOLCHAIN_SCRIPT" _ "$parent" "$ADAPTER_GENERATOR"
}

# verify-deps off: node_modules is meant to disagree with the lockfile here,
# and `pnpm exec` would run its own install and fail opaquely.
configure_adapter_app() {
  local -r dest="$1" rel="$2"

  [[ -n "${ADAPTER_POST_GENERATE:-}" ]] || return 0

  step "configuring ${rel}"
  run_quietly "configuring ${rel} after its generator ran" \
    env npm_config_frozen_lockfile=false npm_config_verify_deps_before_run=false \
    bash -c "$ADAPTER_TOOLCHAIN_SCRIPT" _ "$dest" "$ADAPTER_POST_GENERATE"
}

# After post-generate, which copies in the .env.example a driver edits.
wire_adapter_services() {
  local -r dest="$1" project="$2"

  if [[ "${ADAPTER_ROLE}" != "web" ]] && ((${#SCAFFOLD_SERVICES[@]} > 0)); then
    apply_service_drivers "$dest" "$project" "$ADAPTER_FAMILY" "${SCAFFOLD_SERVICES[@]}"
  else
    # Even with no block: a Dockerfile shipping the anchor verbatim fails to build.
    apply_service_dockerfile "$dest" ""
  fi
}
