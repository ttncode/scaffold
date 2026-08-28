setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
  scaffold new "$PROJECT" --api nestjs
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "the project ships five workflows" {
  run bash -c "ls '${PROJECT}/.github/workflows' | wc -l"
  [ "$output" = "5" ]
}

@test "every workflow starts from a closed permission set" {
  for f in "${PROJECT}"/.github/workflows/*.yml; do
    run yq '.permissions' "$f"
    [ "$output" = "{}" ]
  done
}

@test "every workflow only calls into the shared repository" {
  run bash -c "yq -r '.jobs[].uses' '${PROJECT}'/.github/workflows/*.yml | sort -u"
  [[ "$output" != *"null"* ]]
  [[ "$output" == *"you/.github/.github/workflows/"* ]]
}

@test "every reusable workflow pins its actions by sha" {
  run bash -c "grep -rhoE 'uses: [^ ]+@[^ ]+' /home/ttndev/workspace/personal/dot-github/.github/workflows/ | grep -vE '@[0-9a-f]{40}$' || true"
  [ -z "$output" ]
}

@test "every checkout disables credential persistence" {
  run bash -c "grep -c 'persist-credentials: false' /home/ttndev/workspace/personal/dot-github/.github/workflows/app-ci.yml"
  [ "$output" -ge 1 ]
}
