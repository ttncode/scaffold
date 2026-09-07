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
