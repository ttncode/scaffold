# shellcheck shell=bash
#
# Creating the GitHub repository a generated project already assumes it has.
#
# Everything here was a step in docs/runbook/first-project-walkthrough.md that
# a person had to get right by hand, and two of them fail in ways that point
# somewhere else:
#
#   - `gh repo create --push` pushes whatever branch is checked out and makes
#     it the default. Run from a feature branch, `main` never reaches the
#     remote, `gh pr create` then refuses with "head branch is the same as the
#     base branch", and CI's `changes` job fails fetching a `main` that is not
#     there. Two red runs, none of it about the project.
#   - Without `can_approve_pull_request_reviews`, Release Please cannot open
#     its pull request. Measured on a real repository: the release job failed
#     with "GitHub Actions is not permitted to create or approve pull
#     requests" — several steps away from the setting that caused it. The
#     runbook calls this one "required, not optional".
#
# Not here: GitHub Pages. `app-docs.yml` builds the site and does not deploy
# it, so there is nothing for a Pages setting to serve.

# repo_slug <project> — `<owner>/<name>`, taken from the registry path the
# project already publishes under. The whole project assumes its repository is
# named after its own directory: compose.yaml's image, install.sh's RepoUrl and
# the build workflows all carry that pair. Deriving the repository from the same
# value is what makes that assumption true instead of hopeful.
repo_slug() {
  local image; image="$(project_image_base "$1")"
  printf '%s' "${image#ghcr.io/}"
}

# gh_repo_exists <slug>
gh_repo_exists() {
  gh repo view "$1" --json name >/dev/null 2>&1
}

# create_repo <project> <slug> <visibility>
create_repo() {
  local project="$1" slug="$2" visibility="$3"

  # One `gh` call doing three things — create, add the remote, push — and a
  # failure in the second or third leaves the first behind. Observed: adding
  # the remote failed and the repository existed anyway, so the next run
  # reported "already exists" about a repository this command had just made.
  # That path is now idempotent rather than surprising, but the message has to
  # say what may be out there.
  gh repo create "$slug" "--${visibility}" --source "$project" \
    --remote origin --push >/dev/null \
    || die "could not finish creating ${slug} — it may exist on GitHub already, with no remote or no branch pushed. Check it, then run this again: everything here is idempotent."
}

# allow_actions_to_open_pull_requests <slug>
# `default_workflow_permissions=read` alongside it, deliberately: the reusable
# workflows each request exactly what they need at the job level, so the
# repository default has no reason to be write.
allow_actions_to_open_pull_requests() {
  gh api -X PUT "repos/${1}/actions/permissions/workflow" \
    -f default_workflow_permissions=read \
    -F can_approve_pull_request_reviews=true >/dev/null \
    || die "could not allow Actions to open pull requests on ${1} — Release Please will not be able to open its release pull request"
}

# protect_main <slug>
# ADR-0004's fourth guardrail, and the only one that is a repository setting
# rather than a file: without it the other three turn red without blocking
# anything.
#
# No required status checks. A ruleset names them literally, and this
# project's are `ci (apps/api)`, one per config root — a list that differs per
# project and changes whenever an application is added. Requiring a pull
# request and refusing force-pushes is the part that generalises; naming
# checks is left to whoever knows the project.
#
# Three outcomes, not two. Measured against a real repository: a private
# repository on a free account answers 403 "Upgrade to GitHub Pro or make this
# repository public to enable this feature". Treating that as fatal would make
# the whole command unusable for exactly the accounts that most need the steps
# before it, so it comes back as 2 and the caller says what is missing and
# carries on. Anything else is a real failure.
protect_main() {
  local slug="$1" response status=0

  response="$(gh api -X POST "repos/${slug}/rulesets" --input - 2>&1 <<'EOF'
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["merge", "squash", "rebase"]
      }
    }
  ]
}
EOF
)" || status=$?

  [ "$status" -eq 0 ] && return 0
  case "$response" in
    *"Upgrade to GitHub Pro"*) return 2 ;;
  esac
  printf '%s\n' "$response" >&2
  return 1
}

# main_is_protected <slug>
main_is_protected() {
  gh api "repos/${1}/rulesets" --jq '.[].name' 2>/dev/null | grep -qx main
}

# enable_secret_scanning <slug>
# GitHub scans and blocks the push itself. Free on a public repository; on a
# private one it needs Advanced Security, which answers 422 — the same shape
# protect_main handles, and reported the same way.
enable_secret_scanning() {
  local response status=0

  response="$(gh api -X PATCH "repos/${1}" --input - 2>&1 <<'EOF'
{
  "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" }
  }
}
EOF
)" || status=$?

  [ "$status" -eq 0 ] && return 0
  case "$response" in
    *"Advanced Security"*|*"not available"*|*"upgrade"*|*"Upgrade"*) return 2 ;;
  esac
  printf '%s\n' "$response" >&2
  return 1
}

# set_release_secrets <slug>
# Optional on both sides: the release workflow declares them optional and falls
# back to GITHUB_TOKEN. What the fallback costs is a release pull request whose
# checks sit at "Action required" and then expire red — three runs in the
# history that say nothing true about the project.
set_release_secrets() {
  local slug="$1"

  [ -n "${RELEASE_APP_ID:-}" ] && [ -n "${RELEASE_APP_PRIVATE_KEY:-}" ] || return 1

  # --body reads from the environment rather than argv: a private key in a
  # process's arguments is readable by every other user on the host.
  gh secret set RELEASE_APP_ID --repo "$slug" --body "$RELEASE_APP_ID" >/dev/null \
    || die "could not set RELEASE_APP_ID on ${slug}"
  gh secret set RELEASE_APP_PRIVATE_KEY --repo "$slug" --body "$RELEASE_APP_PRIVATE_KEY" >/dev/null \
    || die "could not set RELEASE_APP_PRIVATE_KEY on ${slug}"
}
