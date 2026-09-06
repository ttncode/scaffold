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
  # -P (block style) because yq propagates the *fragment's* style to the whole
  # merged document, and an adapter contributing no hook ships `{}` — one flow
  # mapping is enough to collapse all 26 lines of lefthook.yml onto a single
  # line and replace every comment in it. The hooks still run; the file a
  # human has to read and review does not survive.
  if ! yq eval-all --inplace -P 'select(fileIndex==0) * select(fileIndex==1)' \
    "${project}/lefthook.yml" "$rendered"; then
    rm -f "$rendered"
    die "failed to merge the lefthook fragment for ${rel}"
  fi
  rm -f "$rendered"
}

# verify_workspace_filter_name <dest> — only for an adapter shipping
# Dockerfile.workspace, whose deps stage runs `pnpm --filter <dest's own
# directory name> install` (resolve_workspace_filter_name bakes that value
# in below): a name create-next-app/@nestjs/cli choose by convention, not one
# this toolbox enforces upstream. A filter matching no project does not fail
# there — pnpm reports "No projects matched the filters" and exits 0 — so the
# build proceeds with nothing installed and dies steps later on a COPY of a
# node_modules that was never created, several layers from the real cause.
# Skipped for the Laravel adapters: composer has no --filter to miss.
verify_workspace_filter_name() {
  local dest="$1"

  [ -f "${ADAPTER_DIR}/Dockerfile.workspace" ] || return 0

  local found expected
  found="$(jq -r '.name' "${dest}/package.json")"
  expected="$(basename "$dest")"
  [ "$found" = "$expected" ] \
    || die "${dest}/package.json is named '${found}', not '${expected}' — Dockerfile.workspace's 'pnpm --filter ${expected}' would match nothing"
}

# resolve_workspace_filter_name <dest> — Dockerfile.workspace ships
# @APP_FILTER@ where it needs the app's own directory name: `scaffold add`
# can place an adapter at any path (apps/worker, not just apps/<role>), so
# the filter can't be baked to the role at adapter-authoring time the way
# role_path's apps/<role> can. verify_workspace_filter_name already proved
# package.json carries this same value.
resolve_workspace_filter_name() {
  local dest="$1"
  local file="${dest}/Dockerfile.workspace"

  [ -f "$file" ] || return 0

  sed -i.bak "s|@APP_FILTER@|$(basename "$dest")|g" "$file"
  rm -f "${file}.bak"
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
  #
  # Through mise exec, not a bare eval: without it, node and pnpm resolve from
  # whatever is ambient on the caller's PATH instead of the project's own
  # pin — composer stays ambient too, on purpose (docs/decisions/0016).
  ( cd "$parent" && APP_DIR="$(basename "$dest")" \
      npm_config_frozen_lockfile=false \
      mise exec -- bash -c "$ADAPTER_GENERATOR" )

  verify_workspace_filter_name "$dest"

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

  resolve_workspace_filter_name "$dest"

  if [ -n "${ADAPTER_POST_GENERATE:-}" ]; then
    # verify-deps off too: this runs between the generator and
    # sync_workspace_lockfile, the one window where node_modules is meant to
    # disagree with the lockfile. Left on, `pnpm exec` runs its own install
    # first and reports only `Command failed with exit code 1` when it fails.
    ( cd "$dest" \
        && npm_config_frozen_lockfile=false \
           npm_config_verify_deps_before_run=false \
           mise exec -- bash -c "$ADAPTER_POST_GENERATE" )
  fi

  # After post-generate: the generator and its own follow-up have settled the
  # package manager's state by here, and .env.example has been copied in from
  # the adapter, which is the file the driver edits.
  if [ "${ADAPTER_ROLE}" != "web" ] && [ "${#SCAFFOLD_SERVICES[@]}" -gt 0 ]; then
    apply_service_drivers "$dest" "$project" "$ADAPTER_FAMILY" "${SCAFFOLD_SERVICES[@]}"
  else
    # The anchor is not optional: a Dockerfile shipping it verbatim would fail
    # to build.
    apply_service_setup "$dest" ""
  fi

  register_config_root "$project" "$rel"
  merge_lefthook_fragment "${ADAPTER_DIR}/lefthook.fragment.yml" "$project" "$rel"
}
