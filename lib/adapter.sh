# ═══════════════════════════════════════════════════════════════════════════
# Script      : lib/adapter.sh
# Description : Load an adapter and install the application it generates.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck shell=bash

APPS_DIR="apps"

# Sourced or merged by name, so never copied verbatim into the application.
ADAPTER_INTERNAL_FILES=(adapter.env lefthook.fragment.yml)

# Cleared on every load, or a stale value is read as the next adapter's own.
ADAPTER_OPTIONAL_VARS=(
  ADAPTER_POST_GENERATE ADAPTER_LANGUAGE ADAPTER_ROLE ADAPTER_TIER
  ADAPTER_FAMILY ADAPTER_LIVENESS_PATH ADAPTER_READINESS_PATH
)

load_adapter() {
  local name="$1"

  # `source` below executes whatever it reads, so the name must not leave
  # adapters/ — `--api ../../../tmp/evil` runs an arbitrary file. Checked before
  # the path is built.
  case "$name" in
    ''|*[!a-z0-9-]*|-*) die "not a usable adapter name: ${name} (run: scaffold list)" ;;
  esac

  local dir="${SCAFFOLD_ROOT}/adapters/${name}"
  [ -d "$dir" ] || die "unknown adapter: ${name} (run: scaffold list)"

  ADAPTER_DIR="$dir"
  unset -v "${ADAPTER_OPTIONAL_VARS[@]}"

  # shellcheck source=/dev/null
  # `|| return 1` so an unreadable adapter.env fails here rather than letting
  # the defaults below become this function's always-successful last command.
  source "${dir}/adapter.env" || return 1

  # The linter is the gate for both, so a fixture adapter missing them still
  # loads and assert_known_tiers reports a bad tier by name.
  : "${ADAPTER_TIER:=}"
  : "${ADAPTER_FAMILY:=}"

  # An adapter.env that parses but omits a name would reach the caller, where
  # reading $ADAPTER_NAME under `set -u` kills the shell mid-loop — one
  # incomplete adapter suppressing the listing of every good one.
  [ -n "${ADAPTER_NAME:-}" ] && [ -n "${ADAPTER_ROLE:-}" ] || return 1
}

adapter_is_typescript() {
  ( load_adapter "$1"; [ "${ADAPTER_LANGUAGE:-}" = "typescript" ] )
}

role_path() {
  case "$1" in
    web|api|app) printf '%s/%s\n' "$APPS_DIR" "$1" ;;
    *) die "unknown adapter role: ${1}" ;;
  esac
}

merge_lefthook_fragment() {
  local fragment="$1" project="$2" rel="$3" rendered

  [ -f "$fragment" ] || return 0

  rendered="$(mktemp)"
  sed "s|@APP_ROOT@|${rel}/|g" "$fragment" > "$rendered"

  # Suffix every command with the app it came from: the merge below is key-wise,
  # so two apps of the same language — both laravel adapters define `pint` —
  # leave one app's code unformatted on commit, silently.
  yq --inplace "(.. | select(has(\"commands\")) | .commands) |=
      with_entries(.key |= . + \"-${rel//\//-}\")" "$rendered"

  # -P (block style) because yq propagates the *fragment's* style to the whole
  # document, and an adapter contributing no hook ships `{}` — one flow mapping
  # collapses lefthook.yml onto a single line and drops every comment in it.
  #
  # Cleaned up on both paths, and not by a RETURN trap: that fires again in
  # callers, where $rendered is out of scope.
  if ! yq eval-all --inplace -P 'select(fileIndex==0) * select(fileIndex==1)' \
    "${project}/lefthook.yml" "$rendered"; then
    rm -f "$rendered"
    die "failed to merge the lefthook fragment for ${rel}"
  fi
  rm -f "$rendered"
}

# Dockerfile.workspace's deps stage runs `pnpm --filter <dest's directory name>
# install`, and a filter matching no project does not fail: pnpm reports "No
# projects matched the filters" and exits 0, so the build proceeds with nothing
# installed and dies steps later on a COPY of a node_modules that was never
# created. Skipped for Laravel: composer has no --filter to miss.
assert_workspace_filter_name() {
  local dest="$1"

  [ -f "${ADAPTER_DIR}/Dockerfile.workspace" ] || return 0

  local found expected
  found="$(jq -r '.name' "${dest}/package.json")"
  expected="$(basename "$dest")"
  [ "$found" = "$expected" ] \
    || die "${dest}/package.json is named '${found}', not '${expected}' — Dockerfile.workspace's 'pnpm --filter ${expected}' would match nothing"
}

# Dockerfile.workspace ships @APP_FILTER@ where it needs the app's own directory
# name: `scaffold add` can place an adapter at any path, so the filter cannot be
# baked to the role at adapter-authoring time.
substitute_workspace_filter() {
  local dest="$1"
  local file="${dest}/Dockerfile.workspace"

  [ -f "$file" ] || return 0

  sed -i.bak "s|@APP_FILTER@|$(basename "$dest")|g" "$file"
  rm -f "${file}.bak"
}

# Everything the adapter ships except the files it keeps to itself. dotglob so
# .env.example is not skipped; directories merge rather than replace, since
# `src/` exists after the generator ran and `cp -R src dest/src` nests it.
copy_adapter_files() {
  local dest="$1"
  local file base dir had_dotglob=0

  shopt -q dotglob && had_dotglob=1
  shopt -s dotglob
  for file in "${ADAPTER_DIR}"/*; do
    [ -f "$file" ] || continue
    base="$(basename "$file")"
    case " ${ADAPTER_INTERNAL_FILES[*]} " in
      *" ${base} "*) continue ;;
    esac
    cp "$file" "${dest}/${base}"
  done
  [ "$had_dotglob" -eq 1 ] || shopt -u dotglob

  for dir in "${ADAPTER_DIR}"/*/; do
    [ -d "$dir" ] || continue
    mkdir -p "${dest}/$(basename "$dir")"
    cp -R "${dir}." "${dest}/$(basename "$dir")/"
  done
}

apply_adapter() {
  local name="$1" project="$2" rel="$3"

  load_adapter "$name"

  local dest="${project}/${rel}"
  local parent; parent="$(dirname "$dest")"
  mkdir -p "$parent"

  # CI=true stays — it lets pnpm replace node_modules with no TTY to confirm on.
  # The frozen lockfile it also switches on must not: a generator cannot install
  # what it is adding, so `pnpm add -D prettier` reports success, leaves no
  # binary, and the next `pnpm exec prettier` is not found.
  #
  # Through mise exec, not a bare eval, or node and pnpm resolve ambient instead
  # of from the project's pin. composer stays ambient on purpose (ADR-0016).
  # shellcheck disable=SC2016 # $1 and $2 are the child's to expand
  local in_the_app_toolchain='cd "$1" && mise exec -- bash -c "$2"'

  step "generating ${rel} with ${name} (a framework generator, this takes a few minutes)"
  run_quietly "generating ${rel} with ${name}" \
    env APP_DIR="$(basename "$dest")" npm_config_frozen_lockfile=false \
    bash -c "$in_the_app_toolchain" _ "$parent" "$ADAPTER_GENERATOR"

  assert_workspace_filter_name "$dest"
  copy_adapter_files "$dest"
  substitute_workspace_filter "$dest"

  if [ -n "${ADAPTER_POST_GENERATE:-}" ]; then
    # verify-deps off too: this is the one window where node_modules is meant
    # to disagree with the lockfile, and left on `pnpm exec` runs its own
    # install and reports only `Command failed with exit code 1`.
    step "configuring ${rel}"
    run_quietly "configuring ${rel} after its generator ran" \
      env npm_config_frozen_lockfile=false npm_config_verify_deps_before_run=false \
      bash -c "$in_the_app_toolchain" _ "$dest" "$ADAPTER_POST_GENERATE"
  fi

  # After post-generate, which settles the package manager's state and copies in
  # .env.example — the file the driver edits.
  if [ "${ADAPTER_ROLE}" != "web" ] && [ "${#SCAFFOLD_SERVICES[@]}" -gt 0 ]; then
    apply_service_drivers "$dest" "$project" "$ADAPTER_FAMILY" "${SCAFFOLD_SERVICES[@]}"
  else
    # The anchor is not optional: a Dockerfile shipping it verbatim would fail
    # to build.
    apply_service_dockerfile "$dest" ""
  fi

  register_config_root "$project" "$rel"
  merge_lefthook_fragment "${ADAPTER_DIR}/lefthook.fragment.yml" "$project" "$rel"
}
