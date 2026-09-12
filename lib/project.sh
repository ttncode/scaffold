# ═══════════════════════════════════════════════════════════════════════════
# Script      : lib/project.sh
# Description : Create a project's skeleton and record what generated it.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck shell=bash

# Where a generated project records its own origin. Its own file rather than a
# `[vars]` entry: the apps table is a mapping, and mise's vars are flat strings.
SCAFFOLD_MANIFEST=".scaffold.toml"

# Shared by init_project's die() and the wizard's prompt, so a rejected name
# gets the same sentence either way.
PROJECT_NAME_RULE="a project name must start with a lowercase letter or digit, and may contain only lowercase letters, digits, '.', '_' and '-'"

# init_project writes this and nothing else has a reason to; mise.toml alone is
# not proof, since any repository can carry one.
PROJECT_MARKER="monorepo_root = true"

# The first commit is boilerplate, not authored by a person, so it must not
# depend on an ambient git config a CI runner does not have.
PROJECT_COMMIT_NAME="scaffold"
PROJECT_COMMIT_EMAIL="scaffold@scaffold.invalid"

# Files carrying the `you/` placeholder, alongside every workflow. mise.root.toml
# carries the registry path ([vars] image) and must be substituted before it
# becomes mise.toml.
PROJECT_OWNER_FILES=(compose.yaml install.sh README.md mise.root.toml)

# Files carrying @PROJECT_NAME@. The image build.yml pushes to and the image
# compose.yaml pulls have to be one string. migrate inherits it later, from
# assemble_compose copying the app image across.
PROJECT_NAME_FILES=(
  .github/workflows/build.yml .github/workflows/release.yml
  docs/.vitepress/config.ts docs/index.md compose.yaml install.sh README.md
)

# The one place the name is read rather than resolved: a browser tab and a page
# heading, which want the capital project_name_is_usable forbids.
PROJECT_TITLE_FILES=(docs/.vitepress/config.ts docs/index.md README.md)

# The account owning the generated workflows' `uses:` and image refs. Dies
# rather than shipping `you/`, which fails only on the first push.
#
# `gh api user`, not `gh auth status`: the former reports who the token belongs
# to, the latter what login recorded, which goes stale after a rename. Seen
# disagreeing here.
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

  # This is interpolated into `sed s|you/|...|`, and GNU sed's s///e flag runs
  # the pattern space as a shell command — an owner containing `|` is remote
  # code execution. GitHub's own rule is alphanumerics and single hyphens.
  case "$owner" in
    *[!A-Za-z0-9-]*|-*|*-)
      die "not a usable GitHub account name: ${owner}" ;;
  esac
  [ -z "$source" ] || warn "using GitHub owner '${owner}' (detected from ${source}) — set SCAFFOLD_GITHUB_OWNER to override"
  printf '%s' "$owner"
}

# project_name_is_usable <name>
# The name goes into `sed s|@PROJECT_NAME@|...|`, where a `|` closes the
# expression early and a `&` expands to the whole match — an unchecked name can
# rewrite the file it is written into. The same characters are illegal in an OCI
# image name, so one rule covers both.
project_name_is_usable() {
  local name="$1"

  case "$name" in
    [a-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$name" in
    *[!a-z0-9._-]*) return 1 ;;
  esac
}

# scaffold_version — which toolbox produced a given project, in one string.
# `git describe`, not a VERSION file: every install of this toolbox is a clone,
# and a file goes stale the first time someone forgets to bump it. `--dirty` is
# the point as much as the tag — a project generated from uncommitted edits
# cannot be reproduced from any commit, and the string has to say so.
scaffold_version() {
  local version
  version="$(git -C "$SCAFFOLD_ROOT" describe --tags --always --dirty 2>/dev/null)" \
    || version="unknown"
  printf '%s' "$version"
}

is_scaffold_project() {
  [ -f "${1}/mise.toml" ] && grep -q "^${PROJECT_MARKER}\$" "${1}/mise.toml"
}

# init_scaffold_manifest <project>
# Without this a generated project has no record of what produced it, and
# `scaffold update` has no "since when" to diff against.
init_scaffold_manifest() {
  local project="$1"

  # A heredoc, not printf: the prose is full of backticks, which shellcheck
  # reads inside single quotes as an unescaped command substitution.
  cat > "${project}/${SCAFFOLD_MANIFEST}" <<EOF
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
  local project="$1" rel="$2" adapter="$3"
  local file="${project}/${SCAFFOLD_MANIFEST}"

  [ -f "$file" ] \
    || die "no ${SCAFFOLD_MANIFEST} in ${project} — this project predates it; see 'scaffold update'"

  grep -q "^\"${rel}\" = " "$file" \
    && die "${rel} is already recorded in ${SCAFFOLD_MANIFEST}"

  printf '"%s" = "%s"\n' "$rel" "$adapter" >> "$file"
}

substitute_in_files() {
  local expression="$1"; shift
  local file

  for file in "$@"; do
    sed -i.bak "$expression" "$file"
    rm -f "${file}.bak"
  done
}

init_project() {
  local dir="$1" name="$2"

  project_name_is_usable "$name" || die "${PROJECT_NAME_RULE}: ${name}"

  [ -e "$dir" ] && die "refusing to overwrite existing path: ${dir}"

  local owner
  owner="$(resolve_github_owner)"

  mkdir -p "$dir"
  # From here on this run owns $dir; a later step failing must remove it, not
  # leave debris behind the overwrite guard above. $dir is baked into the trap
  # command so it survives this function's locals going away; $? stays deferred.
  # shellcheck disable=SC2064 # $dir expanding now is intentional; $? is escaped and still deferred
  trap "cmd_new_cleanup $(printf '%q' "$dir") \"\$?\"" EXIT

  git -C "$dir" init --initial-branch=main --quiet
  cp -R "${SCAFFOLD_ROOT}/common/." "${dir}/"
  # cp -R preserves the committed executable bit, but that depends on the
  # source checkout's own mode surviving clone/checkout (e.g. core.fileMode).
  chmod +x "${dir}/install.sh"

  local -a owner_files=("${dir}/.github/workflows/"*.yml)
  owner_files+=("${PROJECT_OWNER_FILES[@]/#/${dir}/}")
  substitute_in_files "s|you/|${owner}/|g" "${owner_files[@]}"

  # CODEOWNERS carries the placeholder as `@you`, which the pattern above does
  # not match. SECURITY.md points vulnerability reports at whoever CODEOWNERS
  # names, and GitHub treats an unresolvable owner as a syntax error — an
  # untouched file here makes the security contact unreachable.
  substitute_in_files "s|@you\b|@${owner}|g" "${dir}/CODEOWNERS"

  sed "s|@PROJECT_NAME@|${name}|g" "${dir}/mise.root.toml" > "${dir}/mise.toml"
  rm -f "${dir}/mise.root.toml"

  substitute_in_files "s|@PROJECT_NAME@|${name}|g" "${PROJECT_NAME_FILES[@]/#/${dir}/}"
  substitute_in_files "s|@PROJECT_TITLE@|${name^}|g" "${PROJECT_TITLE_FILES[@]/#/${dir}/}"

  # a config not yet trusted makes mise prompt or refuse instead of working.
  mise trust -y --quiet -C "$dir"
}

# lock_toolchains <project>
# `mise install` writes a lockfile naming versions but no download URLs when
# the tools were already in the local cache, and CI's `mise install --locked`
# rejects exactly that file. `mise lock` fills in the URLs and checksums.
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

  # `feat:`, not `chore:`. Release Please hides chore from the changelog and
  # cuts nothing for it, so a new project's first push ran the release
  # workflow, found no releasable commit and finished green with no release —
  # leaving install.sh with nothing to download. This commit really is the
  # project's first feature, and the release it cuts from 0.0.0 is v1.0.0.
  #
  # GIT_AUTHOR_*/GIT_COMMITTER_* rather than `-c user.name=`: these env vars
  # outrank `-c` config in git's own precedence, so a caller that exports one
  # would otherwise still leak through.
  GIT_AUTHOR_NAME="$PROJECT_COMMIT_NAME" GIT_AUTHOR_EMAIL="$PROJECT_COMMIT_EMAIL" \
    GIT_COMMITTER_NAME="$PROJECT_COMMIT_NAME" GIT_COMMITTER_EMAIL="$PROJECT_COMMIT_EMAIL" \
    git -C "$project" commit --quiet -m "feat: scaffold project"
}
