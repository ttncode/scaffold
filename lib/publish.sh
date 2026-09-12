# ═══════════════════════════════════════════════════════════════════════════
# Script      : lib/publish.sh
# Description : Create the GitHub repository a generated project assumes.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck shell=bash
#
# Each step was a hand step in docs/runbook/first-project-walkthrough.md, and
# two of them fail in ways that point somewhere else:
#
#   - `gh repo create --push` pushes whatever branch is checked out and makes it
#     the default, so from a feature branch `main` never reaches the remote and
#     CI's `changes` job fails fetching a branch that is not there.
#   - Without `can_approve_pull_request_reviews`, Release Please cannot open its
#     pull request: "GitHub Actions is not permitted to create or approve pull
#     requests", several steps away from the setting that caused it.
#
# Not here: GitHub Pages. `app-docs.yml` builds the site and does not deploy it.

# A repository setting this account's plan does not allow is not a failed
# publish — the caller says what is missing and carries on.
PUBLISH_UNSUPPORTED=2

# repo_slug <project> — `<owner>/<name>`, taken from the registry path the
# project already publishes under. compose.yaml's image, install.sh's RepoUrl
# and the build workflows all carry that same pair, so deriving the repository
# from it is what makes their assumption true rather than hopeful.
repo_slug() {
  local image; image="$(project_image_base "$1")"
  printf '%s' "${image#ghcr.io/}"
}

gh_repo_exists() {
  gh repo view "$1" --json name >/dev/null 2>&1
}

create_repo() {
  local project="$1" slug="$2" visibility="$3"

  # One `gh` call doing three things — create, add the remote, push — so a
  # failure in the second or third leaves the first behind. Everything here is
  # idempotent, but the message has to say what may already be out there.
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

main_is_protected() {
  local rulesets
  rulesets="$(gh api "repos/${1}/rulesets" --jq '.[].name' 2>/dev/null)" || return 1
  grep -qx main <<<"$rulesets"
}

# protect_main <slug> — ADR-0004's fourth guardrail, and the only one that is a
# repository setting rather than a file: without it the other three turn red
# without blocking anything. Returns PUBLISH_UNSUPPORTED on a free account's
# private repository, which answers 403 "Upgrade to GitHub Pro".
#
# No required status checks. A ruleset names them literally, and this project's
# are `ci (apps/api)`, one per config root — a list that differs per project and
# changes whenever an application is added. Requiring a pull request and
# refusing force-pushes is the part that generalises.
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
    *"Upgrade to GitHub Pro"*) return "$PUBLISH_UNSUPPORTED" ;;
  esac
  printf '%s\n' "$response" >&2
  return 1
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
    *"Advanced Security"*|*"not available"*|*"upgrade"*|*"Upgrade"*) return "$PUBLISH_UNSUPPORTED" ;;
  esac
  printf '%s\n' "$response" >&2
  return 1
}

# set_release_secrets <slug>
# Optional on both sides: the release workflow declares them optional and falls
# back to GITHUB_TOKEN. What the fallback costs is a release pull request whose
# checks sit at "Action required" and then expire red.
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
