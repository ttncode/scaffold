# shellcheck shell=bash

# The account owning the generated workflows' `uses:` and image refs. Dies
# rather than shipping `you/`, which fails only on the first push. Detection is
# announced on stderr for the same reason: a wrong account produces workflows
# that look fine until GitHub rejects them.
#
# `gh api user`, not `gh auth status`: the former reports who the token belongs
# to, the latter reports what login recorded and goes stale after a rename.
# Observed disagreeing here — status said `ttndevfullstack`, the token
# resolved to `ttncode`.
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

# PROJECT_NAME_RULE — what a usable project name has to satisfy, in the
# user's terms. Shared by init_project's die() and the wizard's prompt
# (lib/tui.sh) so a rejected name gets the same sentence either way.
PROJECT_NAME_RULE="a project name must start with a lowercase letter or digit, and may contain only lowercase letters, digits, '.', '_' and '-'"

# project_name_is_usable <name>
# The name is substituted into `sed s|@PROJECT_NAME@|...|` and into the image
# reference in the generated workflows. A `|` would close the sed expression
# early and a `&` would expand to the whole match, so an unchecked name can
# rewrite the file it is being written into. The same characters are illegal
# in an OCI image name, so one rule covers both: lowercase, digits, and
# separators, starting alphanumeric. Called from init_project (the flags and
# `scaffold add`) and from the wizard's name prompt, so the two cannot drift.
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
#
# `git describe` against this checkout rather than a VERSION file: every
# install of this toolbox is a clone, and a file is a second copy of the same
# fact that goes stale the first time someone forgets to bump it. `--dirty`
# is the point as much as the tag is — a project generated from uncommitted
# edits cannot be reproduced from any commit, and the string has to say so.
# Printed without a trailing newline so a caller that records it into a file
# decides its own framing.
scaffold_version() {
  local version
  version="$(git -C "$SCAFFOLD_ROOT" describe --tags --always --dirty 2>/dev/null)" \
    || version="unknown"
  printf '%s' "$version"
}

# SCAFFOLD_MANIFEST — the file a generated project records its own origin in.
# A file of its own rather than another `[vars]` entry in mise.toml: the apps
# table is a mapping, and mise's vars are flat strings.
SCAFFOLD_MANIFEST=".scaffold.toml"

# init_scaffold_manifest <project>
# Without this a generated project has no record of what produced it, and
# `scaffold update` has no "since when" to diff against — which is the state
# every project generated before this one is stuck in.
init_scaffold_manifest() {
  local project="$1"

  # A heredoc, not a run of printf: the prose is full of backticks, which the
  # linter reads inside single quotes as a command substitution somebody
  # forgot to escape.
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

# record_scaffold_app <project> <rel> <adapter>
record_scaffold_app() {
  local project="$1" rel="$2" adapter="$3"
  local file="${project}/${SCAFFOLD_MANIFEST}"

  [ -f "$file" ] \
    || die "no ${SCAFFOLD_MANIFEST} in ${project} — this project predates it; see 'scaffold update'"

  grep -q "^\"${rel}\" = " "$file" \
    && die "${rel} is already recorded in ${SCAFFOLD_MANIFEST}"

  printf '"%s" = "%s"\n' "$rel" "$adapter" >> "$file"
}

# is_scaffold_project <dir>
# The marker init_project writes and nothing else has a reason to. mise.toml
# alone is not proof — any repository can carry one. Was written out three
# times in `scaffold` before the wizard needed a fourth.
is_scaffold_project() {
  [ -f "${1}/mise.toml" ] && grep -q '^monorepo_root = true$' "${1}/mise.toml"
}

# init_project <dir> <name>
init_project() {
  local dir="$1" name="$2"

  project_name_is_usable "$name" || die "${PROJECT_NAME_RULE}: ${name}"

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

  # The workflows and image ref carry the placeholder account as `you/`;
  # CODEOWNERS carries it as `@you`, which the first pattern does not match —
  # so it used to ship untouched, and SECURITY.md points vulnerability reports
  # at whoever CODEOWNERS names. GitHub treats an unresolvable owner as a
  # syntax error, making the security contact unreachable.
  # mise.root.toml is in this list because it carries the registry path every
  # application publishes under ([vars] image) — and it has to be substituted
  # here, before it becomes mise.toml a few lines below.
  local wf
  for wf in "${dir}/.github/workflows/"*.yml "${dir}/compose.yaml" "${dir}/install.sh" \
            "${dir}/README.md" "${dir}/mise.root.toml"; do
    sed -i.bak "s|you/|${owner}/|g" "$wf"
    rm -f "${wf}.bak"
  done

  sed -i.bak "s|@you\b|@${owner}|g" "${dir}/CODEOWNERS"
  rm -f "${dir}/CODEOWNERS.bak"

  sed "s|@PROJECT_NAME@|${name}|g" "${dir}/mise.root.toml" > "${dir}/mise.toml"
  rm -f "${dir}/mise.root.toml"

  # compose.yaml and install.sh are in this list for the same reason the
  # workflows are: the image build.yml pushes to and the image compose.yaml
  # pulls have to be one string. They used to ship `CHANGEME/CHANGEME`, which
  # made every project's first release unusable — its compose.yaml named an
  # image nothing had pushed, so install.sh had to be given a second release
  # after a hand-edit. Both values were already known here.
  #
  # assemble_compose runs after this and copies the app image onto the migrate
  # service, so migrate inherits the substitution rather than needing its own.
  local file
  for file in "${dir}/.github/workflows/build.yml" "${dir}/.github/workflows/release.yml" \
              "${dir}/docs/.vitepress/config.ts" "${dir}/docs/index.md" \
              "${dir}/compose.yaml" "${dir}/install.sh" "${dir}/README.md"; do
    sed -i.bak "s|@PROJECT_NAME@|${name}|g" "$file"
    rm -f "${file}.bak"
  done

  # The docs site is the one place the name is read rather than resolved: a
  # browser tab and a page heading. project_name_is_usable forces a lowercase
  # first character, because a registry path and a directory name need one —
  # so a title taken straight from it reads as a shell argument, not a title.
  for file in "${dir}/docs/.vitepress/config.ts" "${dir}/docs/index.md" \
              "${dir}/README.md"; do
    sed -i.bak "s|@PROJECT_TITLE@|${name^}|g" "$file"
    rm -f "${file}.bak"
  done

  # a config not yet trusted makes mise prompt or refuse instead of working.
  mise trust -y --quiet -C "$dir"
}












# lock_toolchains <project>
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
  # `feat:`, not `chore:`. Release Please hides chore from the changelog and
  # cuts nothing for it, so the first push of a new project ran the release
  # workflow, found no releasable commit, and finished green with no release —
  # leaving install.sh with nothing to download until somebody hand-wrote a
  # feat or fix commit. Measured on a real repository: Release succeeded in
  # 10 seconds and published nothing. This commit really is the project's
  # first feature, and common/.release-please-manifest.json starts at 0.0.0
  # because nothing has been released yet — measured on a real repository, the
  # release it then cuts is v1.0.0: release-please treats a feat on a 0.x
  # version as the 1.0.0 it was building towards unless told otherwise, and a
  # client project's first shipped version being 1.0.0 is the right answer
  # anyway.
  #
  # GIT_AUTHOR_*/GIT_COMMITTER_* rather than relying on the caller's git
  # config: this commit is boilerplate, not authored by a person, so it has no
  # business depending on an ambient identity that a developer machine has and
  # a CI runner does not — every caller outside the test suite
  # (deploy-check.sh, the adapters workflow) had to work around that gap on
  # its own, repeatedly. `-c user.name=` alone isn't enough: these env vars
  # outrank `-c` config in git's own precedence, so a caller that happens to
  # export one (as this sandbox's shell does) would otherwise still leak
  # through.
  GIT_AUTHOR_NAME="scaffold" GIT_AUTHOR_EMAIL="scaffold@scaffold.invalid" \
    GIT_COMMITTER_NAME="scaffold" GIT_COMMITTER_EMAIL="scaffold@scaffold.invalid" \
    git -C "$project" commit --quiet -m "feat: scaffold project"
}
