# ═══════════════════════════════════════════════════════════════════════════
# Script      : lib/project.sh
# Description : Create a project's skeleton and record what generated it.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck shell=bash

# Its own file rather than a `[vars]` entry: the apps table is a mapping, and
# mise's vars are flat strings.
SCAFFOLD_MANIFEST=".scaffold.toml"

# Shared by init_project's die() and the wizard's prompt, so a rejected name
# gets the same sentence either way.
PROJECT_NAME_RULE="a project name must start with a lowercase letter or digit, and may contain only lowercase letters, digits, '.', '_' and '-'"

# init_project writes this; mise.toml alone is not proof, since any repository
# can carry one.
PROJECT_MARKER="monorepo_root = true"

# Not an ambient git config, which a CI runner does not have.
PROJECT_COMMIT_NAME="scaffold"
PROJECT_COMMIT_EMAIL="scaffold@scaffold.invalid"

# Files carrying the `you/` placeholder, alongside every workflow; mise.root.toml
# carries the registry path and must be substituted before it becomes mise.toml.
PROJECT_OWNER_FILES=(compose.yaml install.sh README.md mise.root.toml)

# Files carrying @PROJECT_NAME@; the image build.yml pushes to and the image
# compose.yaml pulls have to be one string.
PROJECT_NAME_FILES=(
  .github/workflows/build.yml .github/workflows/release.yml
  docs/.vitepress/config.ts docs/index.md compose.yaml install.sh README.md
)

# The one place the name is read rather than resolved: a browser tab and a page
# heading, which want the capital project_name_is_usable forbids.
PROJECT_TITLE_FILES=(docs/.vitepress/config.ts docs/index.md README.md)

# `gh api user`, not `gh auth status`: the former reports who the token belongs
# to, the latter what login recorded — seen disagreeing after a rename.
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

  # Interpolated into `sed s|you/|...|`; GNU sed's s///e flag runs the pattern
  # space as a shell command, so an owner containing `|` is remote code execution.
  case "$owner" in
    *[!A-Za-z0-9-]* | -* | *-)
      die "not a usable GitHub account name: ${owner}"
      ;;
  esac
  [ -z "$source" ] || warn "using GitHub owner '${owner}' (detected from ${source}) — set SCAFFOLD_GITHUB_OWNER to override"
  printf '%s' "$owner"
}

# The name goes into `sed s|@PROJECT_NAME@|...|`, where `|` closes the
# expression early and `&` expands to the whole match; the same characters are
# illegal in an OCI image name, so one rule covers both.
project_name_is_usable() {
  local -r name="$1"

  case "$name" in
    [a-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$name" in
    *[!a-z0-9._-]*) return 1 ;;
  esac
}

# `git describe`, not a VERSION file: a file goes stale the first time someone
# forgets to bump it. `--dirty` matters as much as the tag — a project generated
# from uncommitted edits cannot be reproduced from any commit.
scaffold_version() {
  local version
  version="$(git -C "$SCAFFOLD_ROOT" describe --tags --always --dirty 2>/dev/null)" ||
    version="unknown"
  printf '%s' "$version"
}

is_scaffold_project() {
  [ -f "${1}/mise.toml" ] && grep -q "^${PROJECT_MARKER}\$" "${1}/mise.toml"
}

init_scaffold_manifest() {
  local -r project="$1"

  # A heredoc, not printf: the prose is full of backticks, which shellcheck
  # reads inside single quotes as an unescaped command substitution.
  cat >"${project}/${SCAFFOLD_MANIFEST}" <<EOF
# Written by scaffold. \`scaffold update\` reads this to work out what changed
# in the toolbox since this project was generated.
#
# version is \`git describe\` from the toolbox checkout. A \`-dirty\` suffix means
# it was generated from uncommitted edits, so there is no commit to diff
# against and \`scaffold update\` will say so.
version = "$(scaffold_version)"

# Which adapter produced each application, so an update knows whose files to
# bring across. Added by \`scaffold new\` and \`scaffold add\`.
[apps]
EOF
}

record_scaffold_app() {
  local -r project="$1" rel="$2" adapter="$3"
  local -r file="${project}/${SCAFFOLD_MANIFEST}"

  [ -f "$file" ] ||
    die "no ${SCAFFOLD_MANIFEST} in ${project} — this project predates it; see 'scaffold update'"

  grep -q "^\"${rel}\" = " "$file" &&
    die "${rel} is already recorded in ${SCAFFOLD_MANIFEST}"

  printf '"%s" = "%s"\n' "$rel" "$adapter" >>"$file"
}

substitute_in_files() {
  local -r expression="$1"
  shift
  local file

  for file in "$@"; do
    sed -i.bak "$expression" "$file"
    rm -f "${file}.bak"
  done
}

init_project() {
  local -r dir="$1" name="$2"

  project_name_is_usable "$name" || die "${PROJECT_NAME_RULE}: ${name}"

  [ -e "$dir" ] && die "refusing to overwrite existing path: ${dir}"

  local owner
  owner="$(resolve_github_owner)"

  mkdir -p "$dir"
  # $dir is baked into the trap command with printf %q so it survives this
  # function's locals going away; a later step failing must clean up $dir.
  # shellcheck disable=SC2064 # $dir expanding now is intentional; $? is escaped and still deferred
  trap "cmd_new_cleanup $(printf '%q' "$dir") \"\$?\"" EXIT

  git -C "$dir" init --initial-branch=main --quiet
  cp -R "${SCAFFOLD_ROOT}/common/." "${dir}/"
  # cp -R's preserved executable bit depends on the source checkout's own mode
  # surviving clone/checkout (e.g. core.fileMode).
  chmod +x "${dir}/install.sh"

  local -a owner_files=("${dir}/.github/workflows/"*.yml)
  owner_files+=("${PROJECT_OWNER_FILES[@]/#/${dir}/}")
  substitute_in_files "s|you/|${owner}/|g" "${owner_files[@]}"

  # CODEOWNERS carries the placeholder as `@you`, which the pattern above does
  # not match; GitHub treats an unresolvable owner in it as a syntax error.
  substitute_in_files "s|@you\b|@${owner}|g" "${dir}/CODEOWNERS"

  sed "s|@PROJECT_NAME@|${name}|g" "${dir}/mise.root.toml" >"${dir}/mise.toml"
  rm -f "${dir}/mise.root.toml"

  substitute_in_files "s|@PROJECT_NAME@|${name}|g" "${PROJECT_NAME_FILES[@]/#/${dir}/}"
  substitute_in_files "s|@PROJECT_TITLE@|${name^}|g" "${PROJECT_TITLE_FILES[@]/#/${dir}/}"

  # a config not yet trusted makes mise prompt or refuse instead of working.
  mise trust -y --quiet -C "$dir"
}

# `mise install` writes a lockfile naming versions but no download URLs when
# the tools were already in the local cache, and CI's `mise install --locked`
# rejects exactly that file. `mise lock` fills in the URLs and checksums.
lock_toolchains() {
  # A mise.toml above the new project, read before ours, can make this fail
  # without breaking the project — so warn and leave it to whoever owns it.
  mise lock --quiet -C "$1" >/dev/null ||
    warn "could not lock the toolchain — run 'mise lock' before committing mise.lock, or CI's 'mise install --locked' will reject it"
}

finalize_project() {
  local -r project="$1"

  sync_ci_roots "$project"
  lock_toolchains "$project"
  git -C "$project" add -A

  # `feat:`, not `chore:`: Release Please hides chore from the changelog and
  # cuts nothing for it, leaving install.sh with no release to download.
  #
  # GIT_AUTHOR_*/GIT_COMMITTER_* rather than `-c user.name=`: these env vars
  # outrank `-c` config, so a caller that exports one would otherwise leak through.
  GIT_AUTHOR_NAME="$PROJECT_COMMIT_NAME" GIT_AUTHOR_EMAIL="$PROJECT_COMMIT_EMAIL" \
    GIT_COMMITTER_NAME="$PROJECT_COMMIT_NAME" GIT_COMMITTER_EMAIL="$PROJECT_COMMIT_EMAIL" \
    git -C "$project" commit --quiet -m "feat: scaffold project"
}
