# shellcheck shell=bash

# init_project <dir> <name>
init_project() {
  local dir="$1" name="$2"

  [ -e "$dir" ] && die "refusing to overwrite existing path: ${dir}"

  mkdir -p "$dir"
  # from here on this run owns $dir; a later step failing must remove it, not
  # leave debris behind the overwrite guard above. $dir's value is fixed now
  # and baked into the trap command so it survives after this function
  # returns and its own local goes away; $? stays deferred to fire time.
  # shellcheck disable=SC2064 # $dir expanding now is intentional; $? is escaped and still deferred
  trap "cmd_new_cleanup $(printf '%q' "$dir") \"\$?\"" EXIT

  git -C "$dir" init --initial-branch=main --quiet
  cp -R "${SCAFFOLD_ROOT}/common/." "${dir}/"
  # cp -R preserves common/install.sh's committed executable bit, but that
  # depends on the source checkout's own mode surviving clone/checkout
  # (e.g. core.fileMode); set it explicitly so a generated project's
  # install.sh runs regardless of how this toolbox itself was checked out.
  chmod +x "${dir}/install.sh"

  sed "s|@PROJECT_NAME@|${name}|g" "${dir}/mise.root.toml" > "${dir}/mise.toml"
  rm -f "${dir}/mise.root.toml"

  local file
  for file in "${dir}/.github/workflows/build.yml" "${dir}/.github/workflows/release.yml" \
              "${dir}/docs/.vitepress/config.ts" "${dir}/docs/index.md"; do
    sed -i.bak "s|@PROJECT_NAME@|${name}|g" "$file"
    rm -f "${file}.bak"
  done

  # a config not yet trusted makes mise prompt or refuse instead of working.
  mise trust -y --quiet -C "$dir"
}

# set_image_context <project> <relative-path> — build.yml and release.yml
# default to apps/api; rewrite both to the role's actual path when the
# requested adapter builds a deployable image somewhere else.
set_image_context() {
  local project="$1" rel="$2" file
  for file in "${project}/.github/workflows/build.yml" \
              "${project}/.github/workflows/release.yml"; do
    sed -i.bak "s|^      context: .*|      context: ${rel}|" "$file"
    rm -f "${file}.bak"
  done
}

# enable_typescript_workspace <project>
# only called when every application in the project is typescript; sharing
# types across a language boundary is a different problem, solved by openapi.
enable_typescript_workspace() {
  local project="$1"

  mkdir -p "${project}/packages"
  mv "${project}/packages-types" "${project}/packages/types"
  register_config_root "$project" "packages/types"
}

# sync_workspace_lockfile <project>
# not every adapter's own generator notices the ambient pnpm-workspace.yaml
# that init_project already wrote before it ran. nestjs's generator installs
# straight into the shared root lockfile; nextjs's writes its own, orphaned
# apps/web/pnpm-lock.yaml instead (leaving that app entirely absent from the
# root one) and its own nested apps/web/pnpm-workspace.yaml (which pnpm's
# upward search from inside apps/web finds before the real root one,
# shadowing it — the app never resolves as part of the outer workspace when
# a task's cwd is the app itself, as every contract task's is). both are
# harmless for a standalone nextjs project; both break a multi-app workspace
# outright. drop any stray per-app copy of either file and let one ordinary
# install rebuild a single, correct, root-level lockfile covering every
# member. minimum-release-age is relaxed only for this one resolution pass
# so it does not error out on a version pnpm has not verified before; it is
# not persisted, and resolve_minimum_release_age below still enforces the
# real default against the result.
sync_workspace_lockfile() {
  local project="$1"

  find "$project" -mindepth 3 -maxdepth 3 \
    \( -name pnpm-lock.yaml -o -name pnpm-workspace.yaml \) -delete

  ( cd "$project" && mise exec -- pnpm install \
      --config.confirm-modules-purge=false \
      --config.minimum-release-age=0 >/dev/null ) \
    || die "pnpm install failed while reconciling the workspace lockfile"
}

# resolve_minimum_release_age <project>
# packages/types joins the workspace only after each app's own generator has
# already installed once, so the contract's own frozen install is always the
# first one to re-verify the lockfile the generator just wrote, against
# pnpm's default minimum-release-age policy — verified by hand that this
# check re-applies on every future frozen install of the same lockfile, not
# just this first one, so relaxing it only for this call would not hold.
# record the exact entries pnpm reports as too fresh, once, in the
# generated project's own file, so the guard stays live for every
# dependency this project adds from here on. a bigger workspace (more apps,
# more transitive deps) can reveal a second batch of violations only once
# the first batch is excluded, so this loops until pnpm has nothing left to
# flag, capped so a genuinely different failure cannot loop forever.
resolve_minimum_release_age() {
  local project="$1"
  local workspace_file="${project}/pnpm-workspace.yaml"
  [ -f "$workspace_file" ] || return 0

  local max_rounds=10 round=0 log entries all_entries=""
  log="$(mktemp)"

  while true; do
    if ( cd "$project" && mise exec -- pnpm install --frozen-lockfile --config.confirm-modules-purge=false >"$log" 2>&1 ); then
      rm -f "$log"
      return 0
    fi

    grep -q ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION "$log" || {
      cat "$log" >&2
      rm -f "$log"
      die "pnpm install failed for a reason other than minimum-release-age (see above)"
    }

    round=$((round + 1))
    [ "$round" -le "$max_rounds" ] || {
      cat "$log" >&2
      rm -f "$log"
      die "pnpm install still hits new minimum-release-age violations after ${max_rounds} rounds of recording exceptions"
    }

    entries="$(sed -E 's/\x1b\[[0-9;]*m//g' "$log" | sed -n 's/^  \(.*\) was published.*/\1/p')"
    [ -n "$entries" ] || {
      cat "$log" >&2
      rm -f "$log"
      die "pnpm reported a minimum-release-age failure but no entries could be parsed from it (see above)"
    }

    all_entries="$(printf '%s\n%s\n' "$all_entries" "$entries" | sed '/^$/d' | sort -u)"

    # bounded by an explicit start AND end marker, not a delete-to-eof: a
    # range open on the end (,$d) would silently swallow anything appended
    # after this block by a later step or caller, with nothing printed.
    # both markers are always written together below, so the range is
    # always well-formed by the time this runs a second time.
    sed -i '/^# too fresh at generation time/,/^# end minimumReleaseAgeExclude$/d' "$workspace_file"
    {
      printf '# too fresh at generation time; pnpm re-checks this on every frozen\n'
      printf '# install forever, not just this one, so it is recorded once here\n'
      printf '# instead of turned off for every dependency this project adds later.\n'
      printf 'minimumReleaseAgeExclude:\n'
      printf '%s\n' "$all_entries" | while IFS= read -r entry; do printf '  - "%s"\n' "$entry"; done
      printf '# end minimumReleaseAgeExclude\n'
    } >> "$workspace_file"
  done
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
