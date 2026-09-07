#!/usr/bin/env bats
# common/install.sh is the source of truth `scaffold new` copies into a
# generated project — sourcing it here tests the same code sooner and for
# free, with no adapter generation anywhere in this suite.

setup() {
  load 'helpers/setup'
  source "${SCAFFOLD_ROOT}/common/install.sh"
  cd "$BATS_TEST_TMPDIR"
}

@test "release_asset_id picks the asset's own id, not the uploader's" {
  # Measured document order: "id" (the asset's) precedes "name", and a second
  # "id" (the uploader's) follows it. One key per line, like the real API
  # response — a compact "id" and "name" sharing one line would put the
  # asset's own id ahead of "name" in the same grep match, masking the bug
  # this fixture exists to catch. A grep for the name that then takes the
  # next id yields 41898282 for every asset — a valid object that downloads
  # something else entirely, with no error anywhere.
  cat > release.fixture.json <<'INNER_EOF'
{
  "tag_name": "v0.2.1",
  "assets": [
    {
      "id": 548466515,
      "name": "compose.yaml",
      "uploader": { "id": 41898282, "login": "github-actions[bot]" }
    },
    {
      "id": 548466513,
      "name": "example.env",
      "uploader": { "id": 41898282, "login": "github-actions[bot]" }
    }
  ]
}
INNER_EOF
  run release_asset_id example.env < release.fixture.json
  assert_ok
  [ "$output" = "548466513" ]
}

@test "release_asset_id fails when the release has no such asset" {
  cat > release.empty.json <<'INNER_EOF'
{ "tag_name": "v0.2.1", "assets": [] }
INNER_EOF
  run release_asset_id compose.yaml < release.empty.json
  [ "$status" -ne 0 ]
  [[ "$output" == *"compose.yaml"* ]]
}

@test "fetch_release_asset uses the browser URL when no token is set" {
  # The public path must not change: no API call, no jq, no token. Asserting
  # api.github.com is absent, not just that the browser URL is present, is
  # what would catch a fetch that called both and quietly required a token
  # for every public client.
  mkdir -p stub
  cat > stub/curl <<'INNER_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG}"
INNER_EOF
  chmod +x stub/curl
  CURL_LOG="${PWD}/curl.log" PATH="${PWD}/stub:${PATH}" \
    run fetch_release_asset compose.yaml ./out
  assert_ok
  run cat curl.log
  [[ "$output" == *"releases/latest/download/compose.yaml"* ]]
  [[ "$output" != *"api.github.com"* ]]
}

@test "fetch_release_asset uses the api asset endpoint when a token is set" {
  # A Bearer token on the browser URL returns 404 for a private repository —
  # measured 2026-09-07 — so the endpoint has to change, not just the headers.
  mkdir -p stub2
  cat > stub2/curl <<'INNER_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG}"
case "$*" in
  *releases/latest*) printf '{"assets":[{"id":42,"name":"compose.yaml"}]}' ;;
esac
INNER_EOF
  chmod +x stub2/curl
  CURL_LOG="${PWD}/curl2.log" GITHUB_TOKEN=t0ken PATH="${PWD}/stub2:${PATH}" \
    run fetch_release_asset compose.yaml ./out
  assert_ok
  run cat curl2.log
  [[ "$output" == *"releases/assets/42"* ]]
  [[ "$output" == *"application/octet-stream"* ]]
}

@test "require_private_tools requires jq only when a token is set" {
  # jq lands on a client's production host, so the public path must not
  # acquire a dependency it never needed.
  #
  # PATH is replaced with a directory holding no jq for both halves, not left
  # unmodified for this one: jq is always present on this project's own PATH,
  # so an unmodified PATH would stay green here even if the GITHUB_TOKEN gate
  # were deleted outright. Only a PATH where `command -v jq` would genuinely
  # fail proves the no-token case returns before that lookup ever runs.
  mkdir -p nojq
  PATH="${PWD}/nojq" run require_private_tools
  assert_ok

  # An exit-127 stub is still a match for `command -v jq`, and a
  # non-executable one is skipped in favor of whatever real jq sits later in
  # PATH — measured against this file's own dependency. Only replacing PATH
  # outright, with no directory in it holding jq, makes the lookup fail the
  # way a client host without jq installed actually would.
  GITHUB_TOKEN=t0ken PATH="${PWD}/nojq" run require_private_tools
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq"* ]]
}

@test "start_stack logs in to ghcr only when a token is set" {
  # A package's ghcr visibility is separate from its repository's — a
  # private package refuses an anonymous pull with `unauthorized`, measured
  # 2026-09-07. A public client pulling a public image must never be asked
  # to authenticate, so the no-token half here must see no login at all.
  mkdir -p stub3
  cat > stub3/docker <<'INNER_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_LOG}"
INNER_EOF
  chmod +x stub3/docker

  DOCKER_LOG="${PWD}/d1.log" PATH="${PWD}/stub3:${PATH}" run start_stack
  assert_ok
  run cat d1.log
  [[ "$output" != *"login"* ]]

  DOCKER_LOG="${PWD}/d2.log" GITHUB_TOKEN=t0ken PATH="${PWD}/stub3:${PATH}" run start_stack
  assert_ok
  run cat d2.log
  [[ "$output" == *"login ghcr.io"* ]]
  [[ "$output" == *"--password-stdin"* ]]
}
