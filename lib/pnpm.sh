# ═══════════════════════════════════════════════════════════════════════════
# Script      : lib/pnpm.sh
# Description : The pnpm workspace and the supply-chain policy over it.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck shell=bash
#
# ADR-0017 governs what may be installed into the workspace.

WORKSPACE_FILE="pnpm-workspace.yaml"
LOCKFILE="pnpm-lock.yaml"

# Excluding one batch of too-fresh dependencies can reveal another, so
# record_release_age_exceptions loops — capped, so a different failure cannot
# spin forever.
MAX_RELEASE_AGE_ROUNDS=10

RELEASE_AGE_BLOCK_START="# too fresh at generation time"
RELEASE_AGE_BLOCK_END="# end minimumReleaseAgeExclude"

# What a generator needs relaxed while it runs inside a workspace that is
# already installed, and that cmd_add must strip again on both the success and
# the failure path — a relaxation left behind is the caller's file, permanently
# weakened.
#
#   confirmModulesPurge  linking a new member makes pnpm purge and relink the
#                        shared node_modules, which it refuses without a TTY.
#   frozenLockfile       the generator's own `pnpm install` sees dependencies
#                        the workspace lockfile has never heard of, and CI=true
#                        turns frozen on by itself.
#   minimumReleaseAge    the generator verifies the lockfile it is extending,
#                        and a dependency published in the last day fails that
#                        check before scaffold can record it.
#
# In the workspace file rather than the environment because a generator spawns
# pnpm through several processes and npm_config_* does not survive the trip.
PNPM_RELAXATIONS=('confirmModulesPurge: false' 'frozenLockfile: false' 'minimumReleaseAge: 0')

# relax_pnpm_workspace <workspace-file> / restore_pnpm_workspace <file>
# Whenever the file exists, not only when a shared workspace does: a generator
# writes into the root lockfile either way.
relax_pnpm_workspace() {
  [ -f "$1" ] || return 0
  printf '%s\n' "${PNPM_RELAXATIONS[@]}" >> "$1"
}

restore_pnpm_workspace() {
  local line
  [ -f "$1" ] || return 0
  for line in "${PNPM_RELAXATIONS[@]}"; do
    sed -i "/^${line}\$/d" "$1"
  done
}

# app_is_workspace_member <project> <rel> — true when rel resolves through the
# shared root install rather than owning a package.json/lockfile. This, not
# whether the command was `new` or `add`, decides which Dockerfile variant an
# app needs and what its build context has to be.
app_is_workspace_member() {
  local project="$1" rel="$2"
  local workspace_file="${project}/${WORKSPACE_FILE}" glob

  [ -f "$workspace_file" ] || return 1

  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    # shellcheck disable=SC2254 # glob is a pattern by design, not a literal
    case "$rel" in $glob) return 0 ;; esac
  done < <(yq -r '.packages[]? // ""' "$workspace_file")

  return 1
}

# pnpm_install <dir> <what-for>
# pnpm reports its failures on stdout, so silencing the install leaves a `die`
# that names the step and proves nothing. Shown only on failure.
pnpm_install() {
  local dir="$1" what="$2" log status=0
  step "$what"
  log="$(mktemp)"

  (
    cd "$dir"
    # --no-frozen-lockfile because pnpm turns frozen on by itself when CI=true,
    # and this install exists precisely to rewrite the lockfile a generator
    # just produced.
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

# Not every generator notices the workspace file init_project already wrote.
# create-next-app writes its own nested pair, and pnpm's upward search finds
# those first — so the app never resolves as part of the outer workspace.
sync_workspace_lockfile() {
  local project="$1"

  find "$project" -mindepth 3 -maxdepth 3 \
    \( -name "$LOCKFILE" -o -name "$WORKSPACE_FILE" \) -delete

  pnpm_install "$project" "reconciling the workspace lockfile"
}

# record_release_age_exceptions <install-dir> [settings-dir]
# Runs the frozen install from <install-dir> and records the exclusions in
# <settings-dir>'s workspace file, defaulting to the same place. The two differ
# for an app outside a workspace: its contract tasks install from the app,
# which is the only place pnpm resolves its dependencies — the project root
# holds the lockfile but its own package.json names none of them.
#
# Recorded rather than relaxed: pnpm re-checks minimum-release-age on every
# frozen install, not just the first, so relaxing it for one call would not
# hold. The policy stays live for everything the project adds later.
record_release_age_exceptions() {
  local project="$1"
  local settings="${2:-$1}"
  step "checking $(basename "$project")'s lockfile against the supply-chain policy"
  local workspace_file="${settings}/${WORKSPACE_FILE}"

  # Keyed on the lockfile pnpm will actually verify — which for an app outside
  # a workspace is the root's, found by walking up.
  [ -f "${project}/${LOCKFILE}" ] || [ -f "${settings}/${LOCKFILE}" ] || return 0

  local round=0 log entries all_entries=""
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
    [ "$round" -le "$MAX_RELEASE_AGE_ROUNDS" ] || {
      cat "$log" >&2
      rm -f "$log"
      die "pnpm install still hits new minimum-release-age violations after ${MAX_RELEASE_AGE_ROUNDS} rounds of recording exceptions"
    }

    entries="$(sed -E 's/\x1b\[[0-9;]*m//g' "$log" | sed -n 's/^  \(.*\) was published.*/\1/p')"
    [ -n "$entries" ] || {
      cat "$log" >&2
      rm -f "$log"
      die "pnpm reported a minimum-release-age failure but no entries could be parsed from it (see above)"
    }

    all_entries="$(printf '%s\n%s\n' "$all_entries" "$entries" | sed '/^$/d' | sort -u)"

    # Bounded by an explicit start AND end marker, not a delete-to-eof: a range
    # open on the end (,$d) would silently swallow anything a later step
    # appended. Both markers are always written together, so the range is
    # always well-formed by the time this runs a second time.
    [ -f "$workspace_file" ] || : > "$workspace_file"
    sed -i "/^${RELEASE_AGE_BLOCK_START}/,/^${RELEASE_AGE_BLOCK_END}\$/d" "$workspace_file"
    {
      printf '%s; pnpm re-checks this on every frozen\n' "$RELEASE_AGE_BLOCK_START"
      printf '# install forever, not just this one, so it is recorded once here\n'
      printf '# instead of turned off for every dependency this project adds later.\n'
      printf 'minimumReleaseAgeExclude:\n'
      printf '%s\n' "$all_entries" | while IFS= read -r entry; do printf '  - "%s"\n' "$entry"; done
      printf '%s\n' "$RELEASE_AGE_BLOCK_END"
    } >> "$workspace_file"
  done
}

# enable_typescript_workspace <project>
# Only called when every application is typescript; sharing types across a
# language boundary is a different problem, solved by openapi.
enable_typescript_workspace() {
  local project="$1"

  mkdir -p "${project}/packages"
  mv "${project}/packages-types" "${project}/packages/types"
  register_config_root "$project" "packages/types"
}

# sync_standalone_build_policy <app-dir> <project-root>
# pnpm's upward search stops at the first workspace file it finds, and so does
# the docker build context — so a standalone app never reaches the root file
# carrying ADR-0017's allowBuilds. Merged, not copied: common wins on a key both
# name, the app's own generator keeps any key only it names.
sync_standalone_build_policy() {
  local app="$1" project="$2"
  local file="${app}/${WORKSPACE_FILE}"

  [ -f "$file" ] || printf '{}\n' > "$file"

  yq eval-all --inplace \
    'select(fileIndex==0).allowBuilds = ((select(fileIndex==0).allowBuilds // {}) * select(fileIndex==1).allowBuilds) | select(fileIndex==0)' \
    "$file" "${project}/${WORKSPACE_FILE}"
}

# finalize_app_dockerfile <project> <rel> — apply_adapter's flat copy lands both
# Dockerfile and Dockerfile.workspace; exactly one may survive, whichever
# app_is_workspace_member matches.
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
# node_modules at the root, and a packages/types can exist between them.
join_typescript_workspace() {
  local project="$1"; shift

  enable_typescript_workspace "$project"

  # docs ships its own standalone pair for a project with no typescript adapter;
  # here they would shadow the root workspace file for docs' own tasks.
  rm -f "${project}/docs/${WORKSPACE_FILE}" "${project}/docs/${LOCKFILE}"

  sync_workspace_lockfile "$project"
  record_release_age_exceptions "$project"

  # Every application just lost its own package.json and lockfile to the
  # workspace, which apply_adapter's standalone Dockerfile assumed it had.
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
  yq --inplace 'del(.packages)' "${project}/${WORKSPACE_FILE}"

  # The root package.json still needs installing on its own — commitlint backs
  # lefthook's commit-msg hook, which must work in a php-only project
  # (ADR-0007). That install runs at minimum-release-age=0, so the root's own
  # violations surface only in the call after it.
  pnpm_install "$project" "installing the project root's own tooling dependencies"
  record_release_age_exceptions "$project"

  # The adapter travels with the path because this branch asks about it. "Does
  # it have a package.json" is a different question with a different answer:
  # laravel-inertia has one, for vite, and is not typescript.
  local pair app
  for pair in "$@"; do
    app="${pair%%:*}"
    adapter_is_typescript "${pair#*:}" \
      && sync_standalone_build_policy "${project}/${app}" "$project"
    finalize_app_dockerfile "$project" "$app"
    # Each application here owns a lockfile the policy will re-check forever.
    record_release_age_exceptions "${project}/${app}"
  done
}
