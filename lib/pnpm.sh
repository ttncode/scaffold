# shellcheck shell=bash
#
# The pnpm workspace, and the supply-chain policy that governs what may be
# installed into it (ADR-0017).
#
# Split out of lib/project.sh, which had grown to carry this, the config_roots
# manifest, the GitHub account, the project name rule and the git commit — five
# subjects whose only relation was being needed by `scaffold new`.

# enable_typescript_workspace <project>
# only called when every application in the project is typescript; sharing
# types across a language boundary is a different problem, solved by openapi.
enable_typescript_workspace() {
  local project="$1"

  mkdir -p "${project}/packages"
  mv "${project}/packages-types" "${project}/packages/types"
  register_config_root "$project" "packages/types"
}
# Not every generator notices the pnpm-workspace.yaml init_project already
# wrote. create-next-app writes its own apps/web/pnpm-lock.yaml and
# pnpm-workspace.yaml, and pnpm's upward search finds the nested one first —
# so the app never resolves as part of the outer workspace, which is fatal for
# a multi-app project and harmless for a standalone one. Drop the strays and
# rebuild one root lockfile. The minimum-release-age relaxation covers this
# pass only; resolve_minimum_release_age still enforces the real default.
sync_workspace_lockfile() {
  local project="$1"

  find "$project" -mindepth 3 -maxdepth 3 \
    \( -name pnpm-lock.yaml -o -name pnpm-workspace.yaml \) -delete

  pnpm_install "$project" "reconciling the workspace lockfile"
}
# sync_standalone_build_policy <app-dir> <project-root>
# An app that stands alone rather than joining the workspace (mixed-language)
# resolves its own generator's pnpm-workspace.yaml, if any — the root one,
# carrying ADR-0017's allowBuilds, is never reached: pnpm's upward search
# stops at the first workspace file it finds, and so does the docker build
# context (apps/<role> only, never the root). Without this, common's baseline
# (unrs-resolver, esbuild, @parcel/watcher) is simply absent for this app, and
# any of it this app needs fails ERR_PNPM_IGNORED_BUILDS the moment nothing
# outside apps/<role> is there to answer for it. Merge: common wins on a key
# both name, the app's own generator (e.g. create-next-app denying sharp)
# keeps any key only it names.
sync_standalone_build_policy() {
  local app="$1" project="$2"
  local file="${app}/pnpm-workspace.yaml"

  [ -f "$file" ] || printf '{}\n' > "$file"

  yq eval-all --inplace \
    'select(fileIndex==0).allowBuilds = ((select(fileIndex==0).allowBuilds // {}) * select(fileIndex==1).allowBuilds) | select(fileIndex==0)' \
    "$file" "${project}/pnpm-workspace.yaml"
}
# pnpm_install <dir> <what-for>
# pnpm reports its failures on stdout, so silencing the install leaves a `die`
# that names the step and proves nothing — a CI failure here was unreadable
# until this kept the output. Shown only on failure; a successful install is
# still quiet.
pnpm_install() {
  local dir="$1" what="$2" log status=0
  step "$what"
  log="$(mktemp)"

  (
    cd "$dir"
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
# pnpm re-checks minimum-release-age on every frozen install, not just the
# first, so relaxing it for one call would not hold. Record the too-fresh
# entries in the project's own file instead, leaving the policy live for
# everything it adds later. Excluding one batch can reveal another, so this
# loops — capped, so a different failure cannot spin forever.
# resolve_minimum_release_age <install-dir> [settings-dir]
# Runs the frozen install from <install-dir> and records the exclusions in
# <settings-dir>'s pnpm-workspace.yaml, defaulting to the same place.
#
# The two differ for an app outside a workspace: its contract tasks install
# from the app, which is the only place pnpm resolves its dependencies — the
# project root holds the lockfile but its own package.json names none of them,
# so running there found no violation and the app still could not install.
resolve_minimum_release_age() {
  local project="$1"
  local settings="${2:-$1}"
  step "checking $(basename "$project")'s lockfile against the supply-chain policy"
  local workspace_file="${settings}/pnpm-workspace.yaml"

  # Keyed on the lockfile pnpm will actually verify — which for an app outside
  # a workspace is the root's, found by walking up.
  [ -f "${project}/pnpm-lock.yaml" ] || [ -f "${settings}/pnpm-lock.yaml" ] || return 0

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
    [ -f "$workspace_file" ] || : > "$workspace_file"
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
# app_is_workspace_member <project> <rel> — true when rel falls inside
# pnpm-workspace.yaml's packages: globs, i.e. rel resolves through the shared
# root install rather than owning a package.json/lockfile of its own. This is
# what actually decides which Dockerfile variant an app needs (finalize_app_
# dockerfile) and what its build context has to be — not whether the command
# generating it was `new` or `add`, and not whether every adapter requested
# at `new` time happened to be typescript (cmd_new's all_typescript is just
# how that project arrived at this same state).
app_is_workspace_member() {
  local project="$1" rel="$2"
  local workspace_file="${project}/pnpm-workspace.yaml" glob

  [ -f "$workspace_file" ] || return 1

  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    # shellcheck disable=SC2254 # glob is a pattern by design, not a literal
    case "$rel" in $glob) return 0 ;; esac
  done < <(yq -r '.packages[]? // ""' "$workspace_file")

  return 1
}
# finalize_app_dockerfile <project> <rel> — apply_adapter's flat copy lands
# both Dockerfile and Dockerfile.workspace for any adapter that ships one
# (nestjs, nextjs); exactly one may survive, whichever matches
# app_is_workspace_member, since that's what the standalone Dockerfile's
# assumption of its own lockfile actually depends on.
finalize_app_dockerfile() {
  local project="$1" rel="$2"
  local dir="${project}/${rel}"

  [ -f "${dir}/Dockerfile.workspace" ] || return 0

  if app_is_workspace_member "$project" "$rel"; then
    mv -f "${dir}/Dockerfile.workspace" "${dir}/Dockerfile"
  else
    rm -f "${dir}/Dockerfile.workspace"
  fi
}

# join_typescript_workspace <project> <rel>:<adapter>...
# Every application is TypeScript, so they share one lockfile and one
# node_modules at the project root, and a packages/types can exist between
# them. Lifted out of cmd_new, where it was one arm of an if/else long enough
# that the condition and the consequence never appeared on screen together.
join_typescript_workspace() {
  local project="$1"; shift

  enable_typescript_workspace "$project"

  # docs ships its own standalone pnpm-workspace.yaml/pnpm-lock.yaml for a
  # project with no typescript adapter; here it joins the real workspace
  # instead, so its own copies would only sit there unused at best, and shadow
  # the root pnpm-workspace.yaml for docs' own tasks at worst.
  rm -f "${project}/docs/pnpm-workspace.yaml" "${project}/docs/pnpm-lock.yaml"

  sync_workspace_lockfile "$project"
  resolve_minimum_release_age "$project"

  # Every application just lost its own package.json and lockfile to the
  # workspace above, and apply_adapter's standalone Dockerfile assumed it had
  # one. finalize_app_dockerfile swaps in the workspace-flavored Dockerfile
  # each typescript adapter ships beside it.
  local pair
  for pair in "$@"; do
    finalize_app_dockerfile "$project" "${pair%%:*}"
  done
}

# keep_apps_standalone <project> <rel>:<adapter>...
# Not every application is TypeScript — or there are none — so each owns its
# manifests and its own lockfile, and there is no shared workspace to join.
keep_apps_standalone() {
  local project="$1"; shift

  rm -rf "${project}/packages-types"

  # The packages list goes, but the file stays either way: it carries
  # ADR-0017's allowBuilds, which applies to any node install here, including
  # the root package.json a php-only project still needs for commitlint.
  # Deleting it left that project with no recorded build-script decision.
  yq --inplace 'del(.packages)' "${project}/pnpm-workspace.yaml"

  # The root package.json still needs installing on its own — commitlint backs
  # lefthook's commit-msg hook, which must work in a php-only project
  # (docs/decisions/0007).
  pnpm_install "$project" "installing the project root's own tooling dependencies"
  # That install ran at full strength (minimum-release-age=0), so a violation
  # among commitlint's own dependencies never surfaced — the loop below
  # resolves each application's lockfile but never the root's, and the root's
  # is the one the commit-msg hook installs from.
  resolve_minimum_release_age "$project"

  # The adapter travels with the path because this branch asks about it: only
  # a typescript application resolves through a pnpm workspace file, and
  # "does it have a package.json" is a different question with a different
  # answer (laravel-inertia has one, for vite, and is not typescript).
  local pair app
  for pair in "$@"; do
    app="${pair%%:*}"
    # Each application here stands alone, so each owns a lockfile the policy
    # will re-check forever.
    adapter_is_typescript "${pair#*:}" \
      && sync_standalone_build_policy "${project}/${app}" "$project"
    # The standalone Dockerfile is the one this shape builds from; a
    # typescript adapter's workspace-flavored sibling never applies here and
    # would otherwise ship unused.
    finalize_app_dockerfile "$project" "$app"
    resolve_minimum_release_age "${project}/${app}"
  done
}
