#!/usr/bin/env bats

setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
  GH_LOG="${WORKDIR}/gh.log"
  export GH_LOG
}

teardown() {
  rm -rf "$WORKDIR"
}

# _stub_gh — a `gh` that records what it was asked to do and answers from
# GH_SCENARIO, so every branch of this command can be exercised without
# creating a repository on anybody's account. Same technique as the curl and
# docker stubs in tests/install.bats.
#
# GH_SCENARIO: `absent` (no such repository), `exists`, `plan-limit` (an
# account whose plan refuses rulesets), or `no-advanced-security`.
_stub_gh() {
  local bin="${WORKDIR}/stub"
  mkdir -p "$bin"
  cat > "${bin}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"

case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view")
    [ "${GH_SCENARIO}" = absent ] && exit 1
    printf '{"name":"demo"}\n'; exit 0 ;;
  "repo create") exit 0 ;;
  "secret set") exit 0 ;;
esac

# `gh api repos/<slug>/rulesets` with no -X is the listing; with -X POST it is
# the create.
case "$*" in
  *"-X PATCH"*)
    if [ "${GH_SCENARIO}" = no-advanced-security ]; then
      echo 'gh: Advanced Security is not available for this repository (HTTP 422)' >&2
      exit 1
    fi
    exit 0 ;;
  *"-X POST"*rulesets*)
    if [ "${GH_SCENARIO}" = plan-limit ]; then
      echo 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)' >&2
      exit 1
    fi
    exit 0 ;;
  *rulesets*) exit 0 ;;          # listing: no ruleset named main
  *actions/permissions/workflow*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "${bin}/gh"
  PATH="${bin}:${PATH}"
  export PATH
}

# _project [branch] — the least a project needs to be one publish will act on.
_project() {
  mkdir -p "$PROJECT"
  printf 'monorepo_root = true\n\n[vars]\nimage = "ghcr.io/acme/demo"\n' \
    > "${PROJECT}/mise.toml"
  git -C "$PROJECT" init -q -b "${1:-main}"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" -c user.email=t@scaffold.invalid -c user.name=t commit -q -m one
}

@test "publish refuses a directory that is not a scaffold project" {
  _stub_gh
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q -b main

  GH_SCENARIO=absent run scaffold publish "$PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a scaffold project"* ]]
}

@test "publish refuses to create a repository from a branch that is not main" {
  # `gh repo create --push` pushes the checked-out branch and makes it the
  # default. From a feature branch that leaves the project with no main, after
  # which `gh pr create` refuses and CI's changes job fails fetching a main
  # that is not there — two red runs, none of it about the project.
  _stub_gh
  _project feat/something

  GH_SCENARIO=absent run scaffold publish "$PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"check out main first"* ]]
  run grep -c 'repo create' "$GH_LOG"
  [ "$output" = 0 ]
}

@test "publish refuses to create a repository from a dirty tree" {
  _stub_gh
  _project
  printf 'work in progress\n' > "${PROJECT}/scratch"

  GH_SCENARIO=absent run scaffold publish "$PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted changes"* ]]
}

@test "publish refuses to create a second repository beside an existing origin" {
  # `gh repo create --remote origin` fails on this anyway, with "Unable to add
  # remote" — a message about git that says nothing about the project pointing
  # at two different repositories.
  _stub_gh
  _project
  git -C "$PROJECT" remote add origin https://github.com/acme/somewhere-else.git

  GH_SCENARIO=absent run scaffold publish "$PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already pushes to"* ]]
  [[ "$output" == *"acme/demo"* ]]
  run grep -c 'repo create' "$GH_LOG"
  [ "$output" = 0 ]
}

@test "a dry run asks nothing of GitHub but whether the repository exists" {
  _stub_gh
  _project

  GH_SCENARIO=absent run scaffold publish "$PROJECT" --dry-run
  assert_ok
  [[ "$output" == *"would create acme/demo (private)"* ]]
  [[ "$output" == *"would allow Actions to open pull requests"* ]]
  [[ "$output" == *"would protect main"* ]]

  run grep -cE 'repo create|-X PUT|-X POST|-X PATCH|secret set' "$GH_LOG"
  [ "$output" = 0 ] || { echo "a dry run called:"; cat "$GH_LOG"; false; }
}

@test "publish creates the repository the project already names" {
  # Not a name passed on the command line: compose.yaml's image, install.sh's
  # RepoUrl and the build workflows all carry one owner/name pair, and the
  # repository has to be that one or none of them resolve.
  _stub_gh
  _project

  GH_SCENARIO=absent run scaffold publish "$PROJECT"
  assert_ok
  run grep -c 'repo create acme/demo --private' "$GH_LOG"
  [ "$output" = 1 ] || { echo "$(cat "$GH_LOG")"; false; }
}

@test "publish on a repository that exists changes no code, only settings" {
  _stub_gh
  _project

  GH_SCENARIO=exists run scaffold publish "$PROJECT"
  assert_ok
  [[ "$output" == *"already exists — applying settings only"* ]]
  run grep -c 'repo create' "$GH_LOG"
  [ "$output" = 0 ]
  run grep -c 'actions/permissions/workflow' "$GH_LOG"
  [ "$output" = 1 ]
}

@test "publish always allows Actions to open pull requests" {
  # The runbook calls this one required, not optional: without it Release
  # Please cannot open its release pull request, and the failure surfaces
  # several steps from the setting that caused it.
  _stub_gh
  _project

  GH_SCENARIO=absent run scaffold publish "$PROJECT"
  assert_ok
  run grep -c 'can_approve_pull_request_reviews=true' "$GH_LOG"
  [ "$output" = 1 ]
  run grep -c 'default_workflow_permissions=read' "$GH_LOG"
  [ "$output" = 1 ]
}

@test "publish turns on GitHub's own secret scanning" {
  # The control that blocks a secret at push time, before it lands. Free on a
  # public repository; the CI scan covers the private case.
  _stub_gh
  _project

  GH_SCENARIO=exists run scaffold publish "$PROJECT"
  assert_ok
  [[ "$output" == *"secret scanning and push protection are on"* ]]
  run grep -c -- '-X PATCH repos/acme/demo' "$GH_LOG"
  [ "$output" = 1 ]

  # The payload travels on stdin, so it is checked where it is written.
  run bash -c "sed -n '/\"security_and_analysis\"/,/^EOF\$/p' '${SCAFFOLD_ROOT}/lib/publish.sh' \
    | grep -c 'secret_scanning_push_protection'"
  [ "$output" = 1 ]
}

@test "a plan without Advanced Security is a warning, not a failed publish" {
  _stub_gh
  _project

  GH_SCENARIO=no-advanced-security run scaffold publish "$PROJECT"
  assert_ok
  [[ "$output" == *"no secret scanning"* ]]
}

@test "a plan that refuses rulesets is a warning, not a failed publish" {
  # Measured against a real repository: a private repository on a free account
  # answers 403 "Upgrade to GitHub Pro". Everything before it succeeded, and
  # failing the command would take those steps away from exactly the accounts
  # that need them.
  _stub_gh
  _project

  GH_SCENARIO=plan-limit run scaffold publish "$PROJECT"
  assert_ok
  [[ "$output" == *"main is unprotected"* ]]
  [[ "$output" == *"ADR-0004"* ]]
}

@test "--no-protect asks nothing about rulesets" {
  _stub_gh
  _project

  GH_SCENARIO=exists run scaffold publish "$PROJECT" --no-protect
  assert_ok
  run grep -c rulesets "$GH_LOG"
  [ "$output" = 0 ]
}

@test "the release app secrets are set only when both are in the environment" {
  _stub_gh
  _project

  GH_SCENARIO=exists run scaffold publish "$PROJECT"
  assert_ok
  [[ "$output" == *"no RELEASE_APP_ID/RELEASE_APP_PRIVATE_KEY"* ]]
  run grep -c 'secret set' "$GH_LOG"
  [ "$output" = 0 ]

  : > "$GH_LOG"
  GH_SCENARIO=exists RELEASE_APP_ID=1 RELEASE_APP_PRIVATE_KEY=key \
    run scaffold publish "$PROJECT"
  assert_ok
  run grep -c 'secret set' "$GH_LOG"
  [ "$output" = 2 ]
}

@test "the ruleset it posts is valid json and carries the three rules" {
  # The payload is a heredoc, so a typo in it reaches GitHub as a 422 on
  # somebody's real repository rather than as a failure here.
  run bash -c "awk '/^\{\$/{f=1} f{print} /^\}\$/{if(f) exit}' '${SCAFFOLD_ROOT}/lib/publish.sh' \
    | jq -r '[.rules[].type] | sort | join(\",\")'"
  assert_ok
  [ "$output" = "deletion,non_fast_forward,pull_request" ] \
    || { echo "rules are: ${output}"; false; }
}
