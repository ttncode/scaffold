# The pnpm workspace and the supply-chain policy over it (ADR-0017).
# shellcheck shell=bash

WORKSPACE_FILE="pnpm-workspace.yaml"
LOCKFILE="pnpm-lock.yaml"

# Recording one batch of too-fresh dependencies can reveal another; the cap
# stops a different failure spinning forever.
MAX_RELEASE_AGE_ROUNDS=10

RELEASE_AGE_BLOCK_START="# too fresh at generation time"
RELEASE_AGE_BLOCK_END="# end minimumReleaseAgeExclude"

# Relaxed while a generator runs inside an installed workspace, and stripped on
# both of cmd_add's exit paths. In the file, not the environment: npm_config_*
# does not survive a generator's nested pnpm processes.
#   confirmModulesPurge  relinking the shared node_modules otherwise wants a TTY
#   frozenLockfile       CI=true turns it on, and the generator adds dependencies
#   minimumReleaseAge    a day-old dependency fails before scaffold can record it
PNPM_RELAXATIONS=('confirmModulesPurge: false' 'frozenLockfile: false' 'minimumReleaseAge: 0')

# Whenever the file exists, not only for a shared workspace: a generator writes
# the root lockfile either way.
relax_pnpm_workspace() {
  local -r file="$1"

  [[ -f "$file" ]] || return 0
  printf '%s\n' "${PNPM_RELAXATIONS[@]}" >>"$file"
}

restore_pnpm_workspace() {
  local -r file="$1"
  local line

  [[ -f "$file" ]] || return 0
  for line in "${PNPM_RELAXATIONS[@]}"; do
    sed -i "/^${line}\$/d" "$file"
  done
}

# Membership, not whether the command was `new` or `add`, decides an app's
# Dockerfile variant and build context.
app_is_workspace_member() {
  local -r project="$1" rel="$2"
  local -r workspace_file="${project}/${WORKSPACE_FILE}"
  local glob

  [[ -f "$workspace_file" ]] || return 1

  while IFS= read -r glob; do
    [[ -n "$glob" ]] || continue
    # shellcheck disable=SC2254 # glob is a pattern by design, not a literal
    case "$rel" in $glob) return 0 ;; esac
  done < <(yq -r '.packages[]? // ""' "$workspace_file")

  return 1
}

# pnpm reports failures on stdout, so the captured log is shown on failure.
pnpm_install() {
  local -r dir="$1" what="$2"
  local log status=0
  step "$what"
  log="$(mktemp)"

  (
    cd "$dir"
    # This install exists to rewrite the lockfile a generator just produced.
    mise exec -- pnpm install \
      --no-frozen-lockfile \
      --config.confirm-modules-purge=false \
      --config.minimum-release-age=0
  ) >"$log" 2>&1 || status=$?

  ((status == 0)) || die_with_log "$log" "pnpm install failed while ${what}"
  rm -f "$log"
}

# create-next-app writes its own nested pair, which pnpm's upward search finds
# before the outer workspace.
sync_workspace_lockfile() {
  local -r project="$1"

  find "$project" -mindepth 3 -maxdepth 3 \
    \( -name "$LOCKFILE" -o -name "$WORKSPACE_FILE" \) -delete

  pnpm_install "$project" "reconciling the workspace lockfile"
}

# record_release_age_exceptions <install-dir> [settings-dir]
# An app outside a workspace installs from its own directory, the only place
# pnpm resolves its dependencies, and records into the root's workspace file.
#
# Recorded rather than relaxed: pnpm re-checks minimum-release-age on every
# frozen install, and the policy stays live for everything added later.
record_release_age_exceptions() {
  local -r project="$1"
  local -r settings="${2:-$1}"
  step "checking $(basename "$project")'s lockfile against the supply-chain policy"
  local -r workspace_file="${settings}/${WORKSPACE_FILE}"

  [[ -f "${project}/${LOCKFILE}" ]] || [[ -f "${settings}/${LOCKFILE}" ]] || return 0

  local round=0 log entries all_entries=""
  log="$(mktemp)"

  while true; do
    if (cd "$project" && mise exec -- pnpm install --frozen-lockfile --config.confirm-modules-purge=false >"$log" 2>&1); then
      rm -f "$log"
      return 0
    fi

    grep -q ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION "$log" ||
      die_with_log "$log" "pnpm install failed for a reason other than minimum-release-age (see above)"

    round=$((round + 1))
    ((round <= MAX_RELEASE_AGE_ROUNDS)) ||
      die_with_log "$log" "pnpm install still hits new minimum-release-age violations after ${MAX_RELEASE_AGE_ROUNDS} rounds of recording exceptions"

    entries="$(sed -E 's/\x1b\[[0-9;]*m//g' "$log" | sed -n 's/^  \(.*\) was published.*/\1/p')"
    [[ -n "$entries" ]] ||
      die_with_log "$log" "pnpm reported a minimum-release-age failure but no entries could be parsed from it (see above)"

    all_entries="$(printf '%s\n%s\n' "$all_entries" "$entries" | sed '/^$/d' | sort -u)"
    write_release_age_block "$workspace_file" "$all_entries"
  done
}

# Bounded by both markers, not deleted to EOF, so anything appended after the
# block survives a rewrite.
write_release_age_block() {
  local -r workspace_file="$1" entries="$2"

  [[ -f "$workspace_file" ]] || : >"$workspace_file"
  sed -i "/^${RELEASE_AGE_BLOCK_START}/,/^${RELEASE_AGE_BLOCK_END}\$/d" "$workspace_file"
  {
    printf '%s; pnpm re-checks this on every frozen\n' "$RELEASE_AGE_BLOCK_START"
    printf '# install forever, not just this one, so it is recorded once here\n'
    printf '# instead of turned off for every dependency this project adds later.\n'
    printf 'minimumReleaseAgeExclude:\n'
    printf '%s\n' "$entries" | while IFS= read -r entry; do printf '  - "%s"\n' "$entry"; done
    printf '%s\n' "$RELEASE_AGE_BLOCK_END"
  } >>"$workspace_file"
}

# Types are shared across a language boundary through openapi instead.
enable_typescript_workspace() {
  local -r project="$1"

  mkdir -p "${project}/packages"
  mv "${project}/packages-types" "${project}/packages/types"
  register_config_root "$project" "packages/types"
}

# pnpm's upward search and the docker build context both stop at the app's own
# workspace file, so a standalone app needs allowBuilds merged in. common wins
# on a shared key.
sync_standalone_build_policy() {
  local -r app="$1" project="$2"
  local -r file="${app}/${WORKSPACE_FILE}"

  [[ -f "$file" ]] || printf '{}\n' >"$file"

  yq eval-all --inplace \
    'select(fileIndex==0).allowBuilds = ((select(fileIndex==0).allowBuilds // {}) * select(fileIndex==1).allowBuilds) | select(fileIndex==0)' \
    "$file" "${project}/${WORKSPACE_FILE}"
}

# apply_adapter copies both Dockerfile variants; exactly one survives.
finalize_app_dockerfile() {
  local -r project="$1" rel="$2"
  local -r dir="${project}/${rel}"

  [[ -f "${dir}/Dockerfile.workspace" ]] || return 0

  if app_is_workspace_member "$project" "$rel"; then
    mv -f "${dir}/Dockerfile.workspace" "${dir}/Dockerfile"
  else
    rm -f "${dir}/Dockerfile.workspace"
  fi
}

# join_typescript_workspace <project> <rel>:<adapter>...
join_typescript_workspace() {
  local -r project="$1"
  shift

  enable_typescript_workspace "$project"

  # docs' standalone pair would shadow the root workspace file for its tasks.
  rm -f "${project}/docs/${WORKSPACE_FILE}" "${project}/docs/${LOCKFILE}"

  sync_workspace_lockfile "$project"
  record_release_age_exceptions "$project"

  local pair
  for pair in "$@"; do
    finalize_app_dockerfile "$project" "${pair%%:*}"
  done
}

# keep_apps_standalone <project> <rel>:<adapter>...
keep_apps_standalone() {
  local -r project="$1"
  shift

  rm -rf "${project}/packages-types"

  # The file stays: its allowBuilds covers the root package.json that even a
  # php-only project installs, for commitlint (ADR-0007).
  yq --inplace 'del(.packages)' "${project}/${WORKSPACE_FILE}"

  # That install runs at minimum-release-age=0, so the root's own violations
  # surface only in the check after it.
  pnpm_install "$project" "installing the project root's own tooling dependencies"
  record_release_age_exceptions "$project"

  local pair app
  for pair in "$@"; do
    app="${pair%%:*}"
    # By adapter, not by package.json: laravel-inertia has one and is not typescript.
    adapter_is_typescript "${pair#*:}" &&
      sync_standalone_build_policy "${project}/${app}" "$project"
    finalize_app_dockerfile "$project" "$app"
    record_release_age_exceptions "${project}/${app}"
  done
}
