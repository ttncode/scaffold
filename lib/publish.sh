# Create the GitHub repository a generated project assumes, with the settings
# no file in the project records (ADR-0024).
# shellcheck shell=bash

# A setting this account's plan does not allow: the caller warns and carries on.
PUBLISH_UNSUPPORTED=2

# Derived from the registry path compose.yaml, install.sh and the build
# workflows already carry, so their assumption about the repository holds.
repo_slug() {
  local -r project="$1"
  local image
  image="$(project_image_base "$project")"
  printf '%s' "${image#ghcr.io/}"
}

gh_repo_exists() {
  gh repo view "$1" --json name >/dev/null 2>&1
}

create_repo() {
  local -r project="$1" slug="$2" visibility="$3"

  gh repo create "$slug" "--${visibility}" --source "$project" \
    --remote origin --push >/dev/null ||
    die "could not finish creating ${slug} — it may exist on GitHub already, with no remote or no branch pushed. Check it, then run this again: everything here is idempotent."
}

# Without this, Release Please fails far from the cause: "GitHub Actions is not
# permitted to create or approve pull requests". The default stays read: each
# reusable workflow requests its own permissions.
allow_actions_to_open_pull_requests() {
  local -r slug="$1"

  gh api -X PUT "repos/${slug}/actions/permissions/workflow" \
    -f default_workflow_permissions=read \
    -F can_approve_pull_request_reviews=true >/dev/null ||
    die "could not allow Actions to open pull requests on ${slug} — Release Please will not be able to open its release pull request"
}

main_is_protected() {
  local -r slug="$1"
  local rulesets
  rulesets="$(gh api "repos/${slug}/rulesets" --jq '.[].name' 2>/dev/null)" || return 1
  grep -qx main <<<"$rulesets"
}

# ADR-0004. No required status checks: their names (`ci (apps/api)`) differ per
# project and change with every application added. A free account's private
# repository answers 403 "Upgrade to GitHub Pro".
protect_main() {
  local -r slug="$1"
  local response status=0

  response="$(
    gh api -X POST "repos/${slug}/rulesets" --input - 2>&1 <<'EOF'
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

  ((status == 0)) && return 0
  case "$response" in
    *"Upgrade to GitHub Pro"*) return "$PUBLISH_UNSUPPORTED" ;;
  esac
  printf '%s\n' "$response" >&2
  return 1
}

# A private repository without Advanced Security answers 422.
enable_secret_scanning() {
  local -r slug="$1"
  local response status=0

  response="$(
    gh api -X PATCH "repos/${slug}" --input - 2>&1 <<'EOF'
{
  "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" }
  }
}
EOF
  )" || status=$?

  ((status == 0)) && return 0
  case "$response" in
    *"Advanced Security"* | *"not available"* | *"upgrade"* | *"Upgrade"*) return "$PUBLISH_UNSUPPORTED" ;;
  esac
  printf '%s\n' "$response" >&2
  return 1
}

# Optional: the release workflow falls back to GITHUB_TOKEN.
set_release_secrets() {
  local -r slug="$1"

  [[ -n "${RELEASE_APP_ID:-}" ]] && [[ -n "${RELEASE_APP_PRIVATE_KEY:-}" ]] || return 1

  gh secret set RELEASE_APP_ID --repo "$slug" --body "$RELEASE_APP_ID" >/dev/null ||
    die "could not set RELEASE_APP_ID on ${slug}"
  # On stdin: argv is visible to every user on the host.
  printf '%s' "$RELEASE_APP_PRIVATE_KEY" |
    gh secret set RELEASE_APP_PRIVATE_KEY --repo "$slug" >/dev/null ||
    die "could not set RELEASE_APP_PRIVATE_KEY on ${slug}"
}
