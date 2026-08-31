# shellcheck shell=bash

# load_adapter <name> — read one adapter's metadata into the current shell.
load_adapter() {
  local name="$1"
  local dir="${SCAFFOLD_ROOT}/adapters/${name}"

  [ -d "$dir" ] || die "unknown adapter: ${name} (run: scaffold list)"

  ADAPTER_DIR="$dir"
  # optional; a stale value from a previously loaded adapter must not leak
  # into one that does not define it.
  unset -v ADAPTER_POST_GENERATE
  # shellcheck source=/dev/null
  # explicit `|| return 1`: a missing/unreadable adapter.env must still
  # make load_adapter fail (so cmd_list's malformed-adapter branch fires)
  # rather than let the ADAPTER_TIER default below silently become this
  # function's last, always-successful command.
  source "${dir}/adapter.env" || return 1
  # ADAPTER_TIER is not (yet) contract-required the way NAME/ROLE are, so an
  # adapter.env that omits it must not crash every `scaffold list` under
  # set -u — an empty string still reaches validate_tiers() (see
  # scripts/adapter-matrix.sh), which names the adapter and the bad value,
  # instead of a bare "unbound variable" naming neither.
  : "${ADAPTER_TIER:=}"
}

# adapter_is_typescript <name>
adapter_is_typescript() {
  ( load_adapter "$1"; [ "${ADAPTER_LANGUAGE:-}" = "typescript" ] )
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

  # CI=true has to stay: it is what lets pnpm replace a node_modules without a
  # TTY to confirm on (ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY otherwise).
  # What must not carry over is the frozen lockfile it also switches on —
  # a generator cannot install what it is in the middle of adding, so
  # `pnpm add -D prettier` reports success, leaves no binary, and the next
  # `pnpm exec prettier` dies with "Command not found". Generating an app is
  # the one moment the lockfile is meant to change.
  ( cd "$parent" && APP_DIR="$(basename "$dest")" \
      npm_config_frozen_lockfile=false eval "$ADAPTER_GENERATOR" )

  # overlay everything the adapter ships except adapter.env (sourced, not
  # copied) and lefthook.fragment.yml (merged, not copied verbatim) — the
  # file list is adapter-dependent; lib/lint.sh still requires the four.
  # dotglob so dotfiles like .env.example are not silently skipped.
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

  # a docker/ subdirectory (e.g. php-fpm's opcache.ini) is not covered by the
  # flat-file loop above; copy it wholesale when an adapter ships one.
  [ -d "${ADAPTER_DIR}/docker" ] && cp -R "${ADAPTER_DIR}/docker" "${dest}/docker"

  if [ -n "${ADAPTER_POST_GENERATE:-}" ]; then
    # same reason as the generator above: post-generate steps install the tools
    # the contract needs and then immediately run them.
    #
    # verify-deps-before-run off as well: this runs between the generator and
    # sync_workspace_lockfile, the one window where node_modules is meant to
    # disagree with the lockfile. Left on, `pnpm exec` sees the mismatch and
    # silently runs its own install first — one that reports nothing but
    # `Command failed with exit code 1` when it fails, which is what a CI
    # failure here looked like.
    ( cd "$dest" \
        && npm_config_frozen_lockfile=false \
           npm_config_verify_deps_before_run=false \
           eval "$ADAPTER_POST_GENERATE" )
  fi

  register_config_root "$project" "$rel"
  merge_lefthook_fragment "${ADAPTER_DIR}/lefthook.fragment.yml" "$project" "$rel"
}
