# Create a project's skeleton and record what generated it.
# shellcheck shell=bash

# Its own file, not `[vars]`: the apps table is a mapping, and mise vars are flat.
SCAFFOLD_MANIFEST=".scaffold.toml"

PROJECT_NAME_RULE="a project name must start with a lowercase letter or digit, and may contain only lowercase letters, digits, '.', '_' and '-'"

# mise.toml alone is not proof: any repository can carry one.
PROJECT_MARKER="monorepo_root = true"

# A CI runner has no ambient git identity.
PROJECT_COMMIT_NAME="scaffold"
PROJECT_COMMIT_EMAIL="scaffold@scaffold.invalid"

# Carry the `you/` placeholder, alongside every workflow.
PROJECT_OWNER_FILES=(compose.yaml install.sh README.md mise.root.toml)

PROJECT_NAME_FILES=(
  .github/workflows/build.yml .github/workflows/release.yml
  docs/.vitepress/config.ts docs/index.md compose.yaml install.sh README.md
)

# Display text, which wants the capital project_name_is_usable forbids.
PROJECT_TITLE_FILES=(docs/.vitepress/config.ts docs/index.md README.md)

# `gh api user`, not `gh auth status`: after a rename, only the former reports
# who the token belongs to.
resolve_github_owner() {
  local owner="${SCAFFOLD_GITHUB_OWNER:-}" source=""

  if [[ -z "$owner" ]] && command -v gh >/dev/null 2>&1; then
    owner="$(timeout 10 gh api user --jq .login 2>/dev/null || true)"
    [[ -n "$owner" ]] && source="gh"
  fi

  if [[ -z "$owner" ]]; then
    owner="$(git config --get github.user || true)"
    [[ -n "$owner" ]] && source="git config github.user"
  fi

  [[ -n "$owner" ]] || die "no GitHub account to substitute for 'you/' in the generated workflows — set SCAFFOLD_GITHUB_OWNER, sign in with 'gh auth login', or 'git config --global github.user <account>'"

  # Interpolated into `sed s|you/|...|`, where GNU sed's `e` flag makes a `|` in
  # the owner remote code execution.
  case "$owner" in
    *[!A-Za-z0-9-]* | -* | *-)
      die "not a usable GitHub account name: ${owner}"
      ;;
  esac
  [[ -z "$source" ]] || warn "using GitHub owner '${owner}' (detected from ${source}) — set SCAFFOLD_GITHUB_OWNER to override"
  printf '%s' "$owner"
}

# The name goes into `sed s|@PROJECT_NAME@|...|`, where `|` and `&` are syntax;
# an OCI image name forbids both anyway.
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

# `--dirty`: a project generated from uncommitted edits cannot be reproduced
# from any commit.
scaffold_version() {
  local version
  version="$(git -C "$SCAFFOLD_ROOT" describe --tags --always --dirty 2>/dev/null)" ||
    version="unknown"
  printf '%s' "$version"
}

is_scaffold_project() {
  local -r project="$1"

  [[ -f "${project}/mise.toml" ]] && grep -q "^${PROJECT_MARKER}\$" "${project}/mise.toml"
}

init_scaffold_manifest() {
  local -r project="$1"

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

  [[ -f "$file" ]] ||
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

  [[ -e "$dir" ]] && die "refusing to overwrite existing path: ${dir}"

  local owner
  owner="$(resolve_github_owner)"

  mkdir -p "$dir"
  # Baked in with %q: the locals are gone by the time the trap fires.
  # shellcheck disable=SC2064 # $dir expanding now is intentional; $? is escaped and still deferred
  trap "cmd_new_cleanup $(printf '%q' "$dir") \"\$?\"" EXIT

  git -C "$dir" init --initial-branch=main --quiet
  cp -R "${SCAFFOLD_ROOT}/common/." "${dir}/"
  # cp -R keeps the mode the checkout happened to give it (core.fileMode).
  chmod +x "${dir}/install.sh"

  render_project_templates "$dir" "$name" "$owner"

  mise trust -y --quiet -C "$dir"
}

render_project_templates() {
  local -r dir="$1" name="$2" owner="$3"

  local -a owner_files=("${dir}/.github/workflows/"*.yml)
  owner_files+=("${PROJECT_OWNER_FILES[@]/#/${dir}/}")
  substitute_in_files "s|you/|${owner}/|g" "${owner_files[@]}"

  # GitHub rejects an unresolvable CODEOWNERS owner as a syntax error.
  substitute_in_files "s|@you\b|@${owner}|g" "${dir}/CODEOWNERS"

  sed "s|@PROJECT_NAME@|${name}|g" "${dir}/mise.root.toml" >"${dir}/mise.toml"
  rm -f "${dir}/mise.root.toml"

  substitute_in_files "s|@PROJECT_NAME@|${name}|g" "${PROJECT_NAME_FILES[@]/#/${dir}/}"
  substitute_in_files "s|@PROJECT_TITLE@|${name^}|g" "${PROJECT_TITLE_FILES[@]/#/${dir}/}"
}

# `mise install` from a warm cache writes a lockfile with no URLs, which CI's
# `mise install --locked` rejects. A mise.toml above the project can fail this
# without breaking the project, so it warns.
lock_toolchains() {
  local -r project="$1"

  mise lock --quiet -C "$project" >/dev/null ||
    warn "could not lock the toolchain — run 'mise lock' before committing mise.lock, or CI's 'mise install --locked' will reject it"
}

finalize_project() {
  local -r project="$1"

  sync_ci_roots "$project"
  lock_toolchains "$project"
  git -C "$project" add -A

  # `feat:`: Release Please cuts no release for `chore:`, and install.sh needs
  # one. Env vars, not `-c user.name=`: exported GIT_* would outrank `-c`.
  GIT_AUTHOR_NAME="$PROJECT_COMMIT_NAME" GIT_AUTHOR_EMAIL="$PROJECT_COMMIT_EMAIL" \
    GIT_COMMITTER_NAME="$PROJECT_COMMIT_NAME" GIT_COMMITTER_EMAIL="$PROJECT_COMMIT_EMAIL" \
    git -C "$project" commit --quiet -m "feat: scaffold project"
}
