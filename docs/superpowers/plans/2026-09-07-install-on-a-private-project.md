# Installing a Private Project Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `common/install.sh` work against a private repository and a
private ghcr package, using one token the operator already needs, without
changing anything on the public path.

**Architecture:** `install.sh` reads `GITHUB_TOKEN` from the environment. With
it, asset downloads go through the API endpoint that actually serves a private
release, and `docker login ghcr.io` runs before the pull. Without it, every
line behaves exactly as it does today. The release JSON is parsed with `jq`,
required only on the token path.

**Tech Stack:** bash, `curl`, `jq`, GitHub REST API, Docker Compose, bats.

**Spec:** `docs/superpowers/specs/2026-09-07-install-on-a-private-project-design.md`

## Global Constraints

- Chat is Vietnamese; **every file, comment and commit message is English**.
- Comments explain **why**, never **what**, matching the register already in
  `common/install.sh` — read `download_release_assets`' existing comments and
  match them. No comment asserts a mechanism does something unless a check
  enforces it.
- **The public path must not change.** Same commands, same output, no `jq`, no
  token. Every task that touches a shared line proves this.
- `install.sh` runs with `set -o nounset` and `set -o pipefail` (lines 8-9), so
  every environment read is `${VAR:-}`.
- `install.sh` is documented as curl-piped (`curl … | bash`), so it may not
  assume `$0` is a file — the `BASH_SOURCE[0]:-$0` guard at the bottom exists
  for that and stays.
- Tests source one function at a time:
  `bash -c "source ./install.sh 2>/dev/null; <function> <args>"`. Follow that
  shape; it is how `generate_service_passwords` is already tested.
- **Run only the suites you touch**: `mise exec -- bats tests/compose.bats`.
  Redirect to a file and read it rather than running twice to count.
- `mise run lint` (shellcheck) covers `common/*.sh`; it must pass before every
  commit.
- Work on branch `feat/install-private`, cut from `spec/install-private`.

## File Structure

**Modified:**

| Path | Change |
| --- | --- |
| `common/install.sh` | `RepoSlug`, `release_asset_id`, `fetch_release_asset`, a login step, the messages |
| `tests/compose.bats` | five assertions, per spec section 8 |
| `docs/runbook/first-project-walkthrough.md` | step 10 says what a private project needs |
| `docs/decisions/0014-deployment-deferred-with-seams.md` | amend the "one deploy mechanism" claim |

**Created:** none. This is one file plus its tests and docs.

---

### Task 0: Branch

- [ ] **Step 1: Cut the branch**

```bash
cd /home/ttndev/workspace/personal/scaffold
git checkout spec/install-private
git checkout -b feat/install-private
```

- [ ] **Step 2: Confirm the tree is clean**

Run: `git status --porcelain`
Expected: no output.

---

### Task 1: Read an asset id out of a release, without picking the uploader's

This is the task the spec exists for. Inside a release's JSON the asset's own
id **precedes** its name and an uploader id **follows** it, so the obvious
hand-rolled parse returns a valid-but-wrong id, and the request for it
succeeds against a different object.

**Files:**
- Modify: `common/install.sh`
- Test: `tests/compose.bats`

**Interfaces:**
- Produces: `release_asset_id <name>` — reads a release's JSON on stdin,
  prints that asset's numeric id, returns 1 with a message when the asset is
  not in the release. Task 2 consumes it.

- [ ] **Step 1: Write the failing test**

Append to `tests/compose.bats`. The fixture is the real document order,
measured from a live release on 2026-09-07 — the asset id before the name, an
uploader id after it:

```bash
@test "release_asset_id picks the asset's own id, not the uploader's" {
  # Measured document order: "id" (the asset's) precedes "name", and a second
  # "id" (the uploader's) follows it. A grep for the name that then takes the
  # next id yields 41898282 for every asset — a valid object that downloads
  # something else entirely, with no error anywhere.
  cd "$PROJECT"
  cat > release.fixture.json <<'INNER_EOF'
{
  "tag_name": "v0.2.1",
  "assets": [
    { "id": 548466515, "name": "compose.yaml",
      "uploader": { "id": 41898282, "login": "github-actions[bot]" } },
    { "id": 548466513, "name": "example.env",
      "uploader": { "id": 41898282, "login": "github-actions[bot]" } }
  ]
}
INNER_EOF
  run bash -c "source ./install.sh 2>/dev/null; release_asset_id example.env < release.fixture.json"
  assert_ok
  [ "$output" = "548466513" ]
}

@test "release_asset_id fails when the release has no such asset" {
  cd "$PROJECT"
  cat > release.empty.json <<'INNER_EOF'
{ "tag_name": "v0.2.1", "assets": [] }
INNER_EOF
  run bash -c "source ./install.sh 2>/dev/null; release_asset_id compose.yaml < release.empty.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"compose.yaml"* ]]
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mise exec -- bats --filter 'release_asset_id' tests/compose.bats`
Expected: both FAIL with `release_asset_id: command not found`.

- [ ] **Step 3: Implement it**

In `common/install.sh`, after `RepoUrl`/`TargetDir`:

```sh
# The owner/repo pair, taken from RepoUrl so a project still edits one line.
RepoSlug="${RepoUrl#https://github.com/}"
RepoSlug="${RepoSlug%/releases/latest/download}"

# release_asset_id <name> — reads a release's JSON on stdin.
#
# jq, not grep: measured against a real release, an asset's own id precedes
# its name while the uploader's id follows it, so "find the name, take the
# next id" returns the uploader's for every asset. That request does not
# fail — it fetches a different valid object and writes it to the file the
# caller asked for. Only the token path needs this, so jq stays off the
# public path's dependency list.
release_asset_id() {
  local name="$1" id
  id="$(jq -r --arg name "$name" \
    'first(.assets[] | select(.name == $name) | .id) // empty')" || return 1
  if [ -z "$id" ]; then
    echo "the latest release has no asset named ${name}; the release may be incomplete" >&2
    return 1
  fi
  printf '%s' "$id"
}
```

- [ ] **Step 4: Run the tests**

Run: `mise exec -- bats --filter 'release_asset_id' tests/compose.bats`
Expected: both PASS.

- [ ] **Step 5: Prove the test is load-bearing**

Replace the `jq` line with the naive parse the comment warns about:

```sh
  id="$(grep -A1 "\"name\": \"${name}\"" | grep -oE '[0-9]+' | head -1)"
```

Run the first test again. It must FAIL, printing the uploader's id. Restore
the `jq` version and confirm it passes. Put both transcripts in your report —
a test that has never failed is what this whole plan is about.

- [ ] **Step 6: Commit**

```bash
mise run lint
git add common/install.sh tests/compose.bats
git commit -m "feat: read a release asset's id with a parser that cannot pick the uploader's"
```

---

### Task 2: Fetch an asset, token-aware

**Files:**
- Modify: `common/install.sh`
- Test: `tests/compose.bats`

**Interfaces:**
- Consumes: `release_asset_id <name>` from Task 1, `RepoSlug`.
- Produces: `fetch_release_asset <name> <dest>` — downloads one release asset,
  using the browser URL with no token and the API asset endpoint with one.
  Task 3 replaces two `curl` calls with it.

- [ ] **Step 1: Write the failing test**

Append to `tests/compose.bats`. It asserts the URL shape rather than the
network, by shadowing `curl` with a stub on PATH:

```bash
@test "fetch_release_asset uses the browser URL when no token is set" {
  # The public path must not change: no API call, no jq, no token.
  cd "$PROJECT"
  mkdir -p stub && cat > stub/curl <<'INNER_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG}"
INNER_EOF
  chmod +x stub/curl
  CURL_LOG="${PWD}/curl.log" run bash -c \
    "PATH='${PWD}/stub:${PATH}'; source ./install.sh 2>/dev/null; fetch_release_asset compose.yaml ./out"
  assert_ok
  run cat curl.log
  [[ "$output" == *"releases/latest/download/compose.yaml"* ]]
  [[ "$output" != *"api.github.com"* ]]
}

@test "fetch_release_asset uses the api asset endpoint when a token is set" {
  # A Bearer token on the browser URL returns 404 for a private repository —
  # measured 2026-09-07 — so the endpoint has to change, not just the headers.
  cd "$PROJECT"
  mkdir -p stub2 && cat > stub2/curl <<'INNER_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG}"
case "$*" in
  *releases/latest*) printf '{"assets":[{"id":42,"name":"compose.yaml"}]}' ;;
esac
INNER_EOF
  chmod +x stub2/curl
  CURL_LOG="${PWD}/curl2.log" GITHUB_TOKEN=t0ken run bash -c \
    "PATH='${PWD}/stub2:${PATH}'; source ./install.sh 2>/dev/null; fetch_release_asset compose.yaml ./out"
  assert_ok
  run cat curl2.log
  [[ "$output" == *"releases/assets/42"* ]]
  [[ "$output" == *"application/octet-stream"* ]]
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mise exec -- bats --filter 'fetch_release_asset' tests/compose.bats`
Expected: both FAIL with `fetch_release_asset: command not found`.

- [ ] **Step 3: Implement it**

In `common/install.sh`, below `release_asset_id`:

```sh
# fetch_release_asset <name> <dest>
#
# Two endpoints, because a private release is not reachable from the public
# one: measured against a real private repository, the browser URL returns
# 404 both anonymously and with a Bearer token, while the API asset endpoint
# returns 200. So a token alone does not fix the public URL — the URL is what
# has to change.
fetch_release_asset() {
  local name="$1" dest="$2" id

  if [ -z "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL "${RepoUrl}/${name}" -o "$dest"
    return
  fi

  id="$(curl -fsSL \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/${RepoSlug}/releases/latest" \
    | release_asset_id "$name")" || return 1

  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H 'Accept: application/octet-stream' \
    "https://api.github.com/repos/${RepoSlug}/releases/assets/${id}" -o "$dest"
}
```

- [ ] **Step 4: Run the tests**

Run: `mise exec -- bats --filter 'fetch_release_asset' tests/compose.bats`
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
mise run lint
git add common/install.sh tests/compose.bats
git commit -m "feat: fetch a release asset through the endpoint a private release answers"
```

---

### Task 3: Route both downloads through it, and require jq only on the token path

**Files:**
- Modify: `common/install.sh`
- Test: `tests/compose.bats`

**Interfaces:**
- Consumes: `fetch_release_asset <name> <dest>` from Task 2.

- [ ] **Step 1: Write the failing test**

```bash
@test "install.sh requires jq only when a token is set" {
  # jq lands on a client's production host, so the public path must not
  # acquire a dependency it never needed.
  cd "$PROJECT"
  mkdir -p nojq && cat > nojq/jq <<'INNER_EOF'
#!/usr/bin/env bash
exit 127
INNER_EOF
  chmod +x nojq/jq

  run bash -c "source ./install.sh 2>/dev/null; require_private_tools"
  assert_ok

  GITHUB_TOKEN=t0ken PATH_WITHOUT_JQ=1 run bash -c \
    "source ./install.sh 2>/dev/null
     command() { [ \"\$2\" = jq ] && return 1; builtin command \"\$@\"; }
     require_private_tools"
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq"* ]]
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- bats --filter 'requires jq only' tests/compose.bats`
Expected: FAIL with `require_private_tools: command not found`.

- [ ] **Step 3: Implement**

Replace the two `curl` calls in `download_release_assets` — the one fetching
`compose.yaml` and the one fetching `example.env` into `$tmp_env` — with
`fetch_release_asset`, leaving every surrounding line, trap and check exactly
as it is:

```sh
  fetch_release_asset compose.yaml ./compose.yaml || return 1
```

```sh
  if ! fetch_release_asset example.env "$tmp_env"; then
```

Add beside the other preflight helpers:

```sh
# jq is needed only to read a release's JSON, which only the token path does.
# Checked separately from main's curl/docker checks so a public install never
# learns about a dependency it does not use.
require_private_tools() {
  [ -n "${GITHUB_TOKEN:-}" ] || return 0
  command -v jq >/dev/null || {
    echo 'jq is required when GITHUB_TOKEN is set: installing from a private project reads the release json' >&2
    return 1
  }
}
```

Call it from `main`, immediately after the existing `docker compose` check:

```sh
  require_private_tools || return 1
```

- [ ] **Step 4: Run the whole file's suite**

Run: `mise exec -- bats tests/compose.bats > /tmp/t3.log 2>&1; tail -5 /tmp/t3.log; grep -A4 '^not ok' /tmp/t3.log`
Expected: all PASS. The pre-existing `install.sh is executable and passes
shellcheck` test covers the edited file.

- [ ] **Step 5: Commit**

```bash
mise run lint
git add common/install.sh tests/compose.bats
git commit -m "feat: route release downloads through the token-aware fetch"
```

---

### Task 4: Log in to ghcr before pulling

A package's ghcr visibility is separate from its repository's. Measured
2026-09-07: `docker pull` of a private package while logged out returns
`unauthorized`. Fixing only the download moves the failure here.

**Files:**
- Modify: `common/install.sh`
- Test: `tests/compose.bats`

**Interfaces:**
- Consumes: `RepoSlug` from Task 1.

- [ ] **Step 1: Write the failing test**

```bash
@test "start_stack logs in to ghcr only when a token is set" {
  cd "$PROJECT"
  mkdir -p stub3 && cat > stub3/docker <<'INNER_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG}"
INNER_EOF
  chmod +x stub3/docker

  DOCKER_LOG="${PWD}/d1.log" run bash -c \
    "PATH='${PWD}/stub3:${PATH}'; source ./install.sh 2>/dev/null; start_stack"
  assert_ok
  run cat d1.log
  [[ "$output" != *"login"* ]]

  DOCKER_LOG="${PWD}/d2.log" GITHUB_TOKEN=t0ken run bash -c \
    "PATH='${PWD}/stub3:${PATH}'; source ./install.sh 2>/dev/null; start_stack"
  assert_ok
  run cat d2.log
  [[ "$output" == *"login ghcr.io"* ]]
  [[ "$output" == *"--password-stdin"* ]]
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- bats --filter 'logs in to ghcr' tests/compose.bats`
Expected: FAIL — the second half finds no `login`.

- [ ] **Step 3: Implement**

Replace `start_stack`:

```sh
start_stack() {
  # A package's ghcr visibility is separate from its repository's, and a
  # private package refuses an anonymous pull with `unauthorized`. The
  # username is not checked for a token login; RepoSlug's owner makes a
  # failure name something the operator recognises.
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    printf '%s' "${GITHUB_TOKEN}" \
      | docker login ghcr.io -u "${RepoSlug%%/*}" --password-stdin >/dev/null || {
        echo 'could not sign in to ghcr.io; the token needs read:packages' >&2
        return 1
      }
  fi
  docker compose up --remove-orphans -d || return 1
}
```

`--password-stdin` rather than an argument: the token would otherwise be
visible to other local users in the process list.

- [ ] **Step 4: Run the suite**

Run: `mise exec -- bats tests/compose.bats > /tmp/t4.log 2>&1; tail -5 /tmp/t4.log; grep -A4 '^not ok' /tmp/t4.log`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
mise run lint
git add common/install.sh tests/compose.bats
git commit -m "feat: sign in to ghcr when a token is set"
```

---

### Task 5: Say what to do when it fails

The operator is on their own host with no access to this repository, so
curl's own text is not enough.

**Files:**
- Modify: `common/install.sh`
- Test: `tests/compose.bats`

- [ ] **Step 1: Write the failing test**

```bash
@test "a failed download with no token names GITHUB_TOKEN" {
  # Without this the operator sees only `curl: (22) ... 404`, which does not
  # say that a private project needs a token, or which scopes.
  cd "$PROJECT"
  mkdir -p stub4 && cat > stub4/curl <<'INNER_EOF'
#!/usr/bin/env bash
exit 22
INNER_EOF
  chmod +x stub4/curl
  run bash -c "PATH='${PWD}/stub4:${PATH}'; source ./install.sh 2>/dev/null; fetch_release_asset compose.yaml ./out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GITHUB_TOKEN"* ]]
  [[ "$output" == *"read:packages"* ]]
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- bats --filter 'names GITHUB_TOKEN' tests/compose.bats`
Expected: FAIL — no output mentioning the token.

- [ ] **Step 3: Implement**

In `fetch_release_asset`'s no-token branch:

```sh
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL "${RepoUrl}/${name}" -o "$dest" && return 0
    # A private release answers 404 to an anonymous request, which reads as
    # "no such release" rather than "you are not signed in".
    echo "could not download ${name}; if this project is private, set GITHUB_TOKEN to a token with repo and read:packages" >&2
    return 1
  fi
```

And in the token branch, after the id lookup:

```sh
  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H 'Accept: application/octet-stream' \
    "https://api.github.com/repos/${RepoSlug}/releases/assets/${id}" -o "$dest" && return 0
  echo "could not download ${name} with the token given; it needs repo and read:packages" >&2
  return 1
```

- [ ] **Step 4: Run the suite**

Run: `mise exec -- bats tests/compose.bats > /tmp/t5.log 2>&1; tail -5 /tmp/t5.log; grep -A4 '^not ok' /tmp/t5.log`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
mise run lint
git add common/install.sh tests/compose.bats
git commit -m "feat: say a private project needs a token, rather than showing curl's 404"
```

---

### Task 6: Documentation

**Files:**
- Modify: `docs/runbook/first-project-walkthrough.md`,
  `docs/decisions/0014-deployment-deferred-with-seams.md`
- Test: `tests/documentation.bats`

- [ ] **Step 1: Amend the runbook's step 10**

Say that a private project needs `GITHUB_TOKEN` with `repo` and
`read:packages`, that `jq` is required on that path, and give the command:

```sh
GITHUB_TOKEN=ghp_... bash install.sh
```

State the measured reason in one sentence — a private release's browser URL
returns 404 even with a token, so the script uses the API endpoint — because
an operator who hits it otherwise assumes their token is wrong.

- [ ] **Step 2: Amend ADR-0014**

Its "one deploy mechanism that exists today" was true only for a public
project until now. Append a dated note saying so and naming this change. Do
not edit the original text — an ADR is a history.

- [ ] **Step 3: Run the docs suite**

Run: `mise exec -- bats tests/documentation.bats`
Expected: 4/4 PASS. Note test 2 treats any backticked string containing `/` as
a path that must exist, exempting `apps/*` — write `read:packages` and
`repo` without slashes, or outside backticks.

- [ ] **Step 4: Commit**

```bash
git add docs
git commit -m "docs: say what a private project needs to install"
```

---

### Task 7: End to end, against the real repositories

The unit tests stub `curl` and assert URL shapes. They cannot prove the
endpoint is right — proving that is the whole reason this plan exists, and the
previous round established that reasoning about an endpoint is not enough.

Two real repositories from the 2026-09-07 acceptance run are still in place:

| Repository | State | Expectation |
| --- | --- | --- |
| `ttncode/scaffold-real-mongo` | private repo, private package | works only with `GITHUB_TOKEN` |
| `ttncode/scaffold-real-nest` | public repo | works with no token, unchanged |

- [ ] **Step 1: The public path is unchanged**

```bash
cd "$(mktemp -d)"
gh release download --repo ttncode/scaffold-real-nest --pattern install.sh
bash install.sh
```

Expected: exits 0, no `jq` needed, output identical in shape to the
2026-09-07 run — downloads, generates passwords, starts the stack, runs
migrations, prints the URL. Then fetch the liveness and readiness paths the
adapter declares and require 200 from both. `curl` and `wget` are denied on
this host: use `python3 -c 'urllib.request…'` or the container's own `wget`
via `docker compose exec`, and say which.

- [ ] **Step 2: The private path works**

```bash
cd "$(mktemp -d)"
gh release download --repo ttncode/scaffold-real-mongo --pattern install.sh
GITHUB_TOKEN="$(gh auth token)" bash install.sh
```

Expected: exits 0. Both health paths return 200 against the private image.

- [ ] **Step 3: The private path without a token fails usefully**

```bash
bash install.sh
```

Expected: non-zero, and the message names `GITHUB_TOKEN` and the two scopes —
not curl's `(22) ... 404`.

- [ ] **Step 4: Tear down**

```bash
docker compose -f app/compose.yaml down -v
```

Run this for both stacks. Report what each step printed.

- [ ] **Step 5: The full lane**

```bash
mise run lint
mise run test-runner > /tmp/runner.log 2>&1
echo "ok=$(grep -c '^ok ' /tmp/runner.log) notok=$(grep -c '^not ok' /tmp/runner.log)"
grep -A6 '^not ok' /tmp/runner.log | head -40
```

Expected: `notok=0`. Note that `test-runner` does **not** run
`tests/new-*.bats` — those per-adapter suites are CI's `smoke` jobs only, so a
green lane says nothing about them. This plan touches no adapter, so that gap
does not apply here, but do not report the number as wider than it is.

---

## Self-Review

**Spec coverage.** Section 4's two halves → Tasks 2 and 4. Section 5's parser
and its trap → Task 1. Section 6's message table → Tasks 1, 3, 4 and 5; the
401/403 case is covered by Task 5's token-branch message, and the missing-asset
case by Task 1's. Section 7's file list → Tasks 3-6. Section 8's five
assertions → Tasks 1-5, plus Task 7 for the end-to-end pair it demands.
Section 9's limits are stated, not implemented.

**Placeholders.** None. Every step carries the code or the command it needs.

**Type consistency.** `release_asset_id <name>` reading stdin is defined in
Task 1 and consumed in Task 2. `fetch_release_asset <name> <dest>` is defined
in Task 2, consumed in Task 3, and extended in Task 5. `RepoSlug` is defined
in Task 1 and used in Tasks 2 and 4. `require_private_tools` is defined and
called in Task 3.

**One gap I am naming rather than closing.** Task 5's test proves the no-token
message; the token-branch message is written but only exercised by Task 7's
step 3, which runs it for real. A unit test for it would need a stub that
fails only the second `curl` call, and the real run covers it better.
