# shellcheck shell=bash

load_adapter() {
  local name="$1"

  # `source` below executes whatever it reads, so the name must not be able to
  # leave adapters/ — `--api ../../../tmp/evil` would otherwise run an
  # arbitrary file. Checked before the path is built, not after.
  case "$name" in
    ''|*[!a-z0-9-]*|-*) die "not a usable adapter name: ${name} (run: scaffold list)" ;;
  esac

  local dir="${SCAFFOLD_ROOT}/adapters/${name}"

  [ -d "$dir" ] || die "unknown adapter: ${name} (run: scaffold list)"

  ADAPTER_DIR="$dir"
  # every optional value, not just one: a stale ADAPTER_LANGUAGE or ROLE from
  # the previous load would otherwise be read as this adapter's own
  unset -v ADAPTER_POST_GENERATE ADAPTER_LANGUAGE ADAPTER_ROLE ADAPTER_TIER ADAPTER_FAMILY
  # shellcheck source=/dev/null
  # `|| return 1` so an unreadable adapter.env fails here, rather than letting
  # the default below become this function's last, always-successful command
  source "${dir}/adapter.env" || return 1
  # not contract-required yet, and validate_tiers reports a bad value better
  # than `set -u` reports an unbound one
  : "${ADAPTER_TIER:=}"
  # not contract-required yet either — the linter is the gate — so a fixture
  # adapter with no family still loads
  : "${ADAPTER_FAMILY:=}"

  # An adapter.env that parses but omits a name used to reach the caller, where
  # reading $ADAPTER_NAME under `set -u` killed the shell mid-loop — so one
  # incomplete adapter suppressed the listing of every good one. Failing here
  # keeps that a per-adapter error, which is what cmd_list already handles.
  [ -n "${ADAPTER_NAME:-}" ] && [ -n "${ADAPTER_ROLE:-}" ] || return 1
}

adapter_is_typescript() {
  ( load_adapter "$1"; [ "${ADAPTER_LANGUAGE:-}" = "typescript" ] )
}

role_path() {
  case "$1" in
    web) printf 'apps/web\n' ;;
    api) printf 'apps/api\n' ;;
    app) printf 'apps/app\n' ;;
    *) die "unknown adapter role: ${1}" ;;
  esac
}

merge_lefthook_fragment() {
  local fragment="$1" project="$2" rel="$3" rendered

  [ -f "$fragment" ] || return 0

  rendered="$(mktemp)"
  sed "s|@APP_ROOT@|${rel}/|g" "$fragment" > "$rendered"

  # Suffix every command name with the app it came from. The merge below is
  # key-wise, so two apps of the same language — both laravel adapters define
  # `pint` — would otherwise leave one hook scoped to whichever was applied
  # last, and the other app's code unformatted on commit, silently.
  yq --inplace "(.. | select(has(\"commands\")) | .commands) |=
      with_entries(.key |= . + \"-${rel//\//-}\")" "$rendered"

  # cleaned up on both paths: under `set -e` a yq failure leaves immediately
  # and the file survives the run. Not a RETURN trap — that fires again in
  # callers, where $rendered is out of scope and the shell aborts.
  if ! yq eval-all --inplace 'select(fileIndex==0) * select(fileIndex==1)' \
    "${project}/lefthook.yml" "$rendered"; then
    rm -f "$rendered"
    die "failed to merge the lefthook fragment for ${rel}"
  fi
  rm -f "$rendered"
}

apply_adapter() {
  local name="$1" project="$2" rel="$3"

  load_adapter "$name"

  local dest="${project}/${rel}"
  local parent; parent="$(dirname "$dest")"
  mkdir -p "$parent"

  # CI=true stays — it is what lets pnpm replace node_modules with no TTY to
  # confirm on. The frozen lockfile it also switches on must not: a generator
  # cannot install what it is adding, so `pnpm add -D prettier` reports
  # success, leaves no binary, and the next `pnpm exec prettier` is not found.
  ( cd "$parent" && APP_DIR="$(basename "$dest")" \
      npm_config_frozen_lockfile=false eval "$ADAPTER_GENERATOR" )

  # everything the adapter ships except adapter.env (sourced) and
  # lefthook.fragment.yml (merged). dotglob so .env.example is not skipped.
  local file base had_dotglob=0
  shopt -q dotglob && had_dotglob=1
  shopt -s dotglob
  for file in "${ADAPTER_DIR}"/*; do
    [ -f "$file" ] || continue
    base="$(basename "$file")"
    case "$base" in
      adapter.env|lefthook.fragment.yml) continue ;;
    esac
    cp "$file" "${dest}/${base}"
  done
  [ "$had_dotglob" -eq 1 ] || shopt -u dotglob

  # the flat loop above skips directories
  [ -d "${ADAPTER_DIR}/docker" ] && cp -R "${ADAPTER_DIR}/docker" "${dest}/docker"

  if [ -n "${ADAPTER_POST_GENERATE:-}" ]; then
    # verify-deps off too: this runs between the generator and
    # sync_workspace_lockfile, the one window where node_modules is meant to
    # disagree with the lockfile. Left on, `pnpm exec` runs its own install
    # first and reports only `Command failed with exit code 1` when it fails.
    ( cd "$dest" \
        && npm_config_frozen_lockfile=false \
           npm_config_verify_deps_before_run=false \
           eval "$ADAPTER_POST_GENERATE" )
  fi

  register_config_root "$project" "$rel"
  merge_lefthook_fragment "${ADAPTER_DIR}/lefthook.fragment.yml" "$project" "$rel"
}
