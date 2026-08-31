# shellcheck shell=bash

# resolve_github_owner — the account or org that owns the shipped workflows'
# `uses: you/.github/...@v1` reusable-workflow references and the
# `ghcr.io/you/...` image ref. Dies rather than shipping a project whose
# workflows reference an account that does not exist — CI cannot resolve
# `you/` on any real one, and that failure mode is invisible until the first
# push.
#
# order: the explicit variable, then gh, then git config. detection is
# announced on stderr rather than applied silently — a wrong account produces
# workflows that look fine and fail only on GitHub, so the one moment a human
# can catch it is while watching the generation.
#
# `gh api user` and not `gh auth status`: the former reports the account the
# stored token actually belongs to, the latter reports what hosts.yml recorded
# at login and goes stale after an account rename. They were observed
# disagreeing on the machine this was written on — auth status said
# `ttndevfullstack`, the token resolved to `ttncode`. Trust the token.
resolve_github_owner() {
  local owner="${SCAFFOLD_GITHUB_OWNER:-}" source=""

  if [ -z "$owner" ] && command -v gh >/dev/null 2>&1; then
    owner="$(timeout 10 gh api user --jq .login 2>/dev/null || true)"
    [ -n "$owner" ] && source="gh"
  fi

  if [ -z "$owner" ]; then
    owner="$(git config --get github.user || true)"
    [ -n "$owner" ] && source="git config github.user"
  fi

  [ -n "$owner" ] || die "no GitHub account to substitute for 'you/' in the generated workflows — set SCAFFOLD_GITHUB_OWNER, sign in with 'gh auth login', or 'git config --global github.user <account>'"
  [ -z "$source" ] || warn "using GitHub owner '${owner}' (detected from ${source}) — set SCAFFOLD_GITHUB_OWNER to override"
  printf '%s' "$owner"
}

# require_git_identity — finalize_project ends in a commit, and git refuses to
# make one without user.name and user.email. Checked before anything is
# generated: without it the failure lands after the generator has run, in git's
# words rather than scaffold's. Kept out of require_tools because that checks
# for commands on PATH, and out of the shared path because only `new` commits —
# `list`, `lint` and `add` do not.
require_git_identity() {
  local field
  for field in user.name user.email; do
    [ -n "$(git config --get "$field" || true)" ] \
      || die "git has no ${field} to commit the new project with — set it with 'git config --global ${field} \"<value>\"'"
  done
}

# init_project <dir> <name>
init_project() {
  local dir="$1" name="$2"

  [ -e "$dir" ] && die "refusing to overwrite existing path: ${dir}"

  local owner
  owner="$(resolve_github_owner)"

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

  # the shipped workflows and image ref point at the placeholder account
  # "you"; substitute it the same way @PROJECT_NAME@ is substituted below,
  # so every generated project's CI resolves against a real account.
  local wf
  for wf in "${dir}/.github/workflows/"*.yml; do
    sed -i.bak "s|you/|${owner}/|g" "$wf"
    rm -f "${wf}.bak"
  done

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

  pnpm_install "$project" "reconciling the workspace lockfile"
}

# pnpm_install <dir> <what-for> [ceiling]
# pnpm reports its failures on stdout, so silencing the install leaves a `die`
# that names the step and proves nothing — a CI failure here was unreadable
# until this kept the output. Shown only on failure; a successful install is
# still quiet.
pnpm_install() {
  local dir="$1" what="$2" ceiling="${3:-}" log status=0
  log="$(mktemp)"

  (
    cd "$dir"
    # exported inside the subshell, not written as a `VAR=x cmd` prefix: the
    # prefix has to be literal, and an expanded one is read as a command name.
    [ -z "$ceiling" ] || export MISE_CEILING_PATHS="$ceiling"
    # --no-frozen-lockfile because pnpm turns frozen on by itself when CI=true,
    # and this install exists precisely to rewrite the lockfile a generator just
    # produced. Without it the step is a contradiction that only fails on a
    # runner: reconcile the lockfile, but you may not change the lockfile.
    mise exec -- pnpm install \
      --no-frozen-lockfile \
      --config.confirm-modules-purge=false \
      --config.minimum-release-age=0
  ) >"$log" 2>&1 || status=$?

  if [ "$status" -ne 0 ]; then
    cat "$log" >&2
    rm -f "$log"
    die "pnpm install failed while ${what}"
  fi
  rm -f "$log"
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

  if ! grep -q "^  \"${root}\",\$" "$file"; then
    awk -v root="$root" '
      { print }
      /^config_roots = \[$/ { printf "  \"%s\",\n", root }
    ' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
  fi

  # the root [tasks.checklist] (pre-push's own gate) must run every config
  # root's own checklist, not just docs' — register_config_root is the one
  # place every config root passes through, so this stays in lockstep with
  # config_roots itself instead of being a second list a later task forgets
  # to update.
  if ! grep -q "\"//${root}:checklist\"" "$file"; then
    awk -v root="$root" '
      /^\[tasks\.checklist\]$/ { in_checklist = 1 }
      in_checklist && /^run = \[/ {
        sub(/\]$/, ", { task = \"//" root ":checklist\" }]")
        in_checklist = 0
      }
      { print }
    ' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
  fi
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
# `mise install` writes a lockfile naming versions but no download URLs when the
# tools were already in the local cache, and CI's `mise install --locked` rejects
# exactly that file. `mise lock` fills in the URLs and checksums. It covers one
# config root, and the root is the only one CI installs from.
lock_toolchains() {
  # a mise.toml above the new project is neither trusted nor necessarily
  # parseable, and mise reads it before ours. That breaks locking but not the
  # project, so say so and leave the environment to whoever owns it.
  mise lock --quiet -C "$1" >/dev/null \
    || warn "could not lock the toolchain — run 'mise lock' before committing mise.lock, or CI's 'mise install --locked' will reject it"
}

finalize_project() {
  local project="$1"
  sync_ci_roots "$project"
  lock_toolchains "$project"
  git -C "$project" add -A
  git -C "$project" commit --quiet -m "chore: scaffold project"
}
