setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
  scaffold new "$PROJECT" --api nestjs
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "add installs an adapter at an arbitrary path" {
  cd "$PROJECT"
  run scaffold add apps/worker --adapter nestjs
  [ "$status" -eq 0 ]
  [ -f "${PROJECT}/apps/worker/mise.toml" ]
}

@test "add registers the new config root" {
  cd "$PROJECT"
  scaffold add apps/worker --adapter nestjs
  run grep -c '"apps/worker",' "${PROJECT}/mise.toml"
  [ "$output" = "1" ]
}

@test "add updates the ci roots input" {
  cd "$PROJECT"
  scaffold add apps/worker --adapter nestjs
  run grep 'roots:' "${PROJECT}/.github/workflows/ci.yml"
  [[ "$output" == *'apps/worker'* ]]
}

@test "add touches exactly one line of the ci workflow" {
  cd "$PROJECT"
  scaffold add apps/worker --adapter nestjs
  run bash -c "git -C '${PROJECT}' diff --numstat -- .github/workflows/ci.yml"
  [[ "$output" == "1"$'\t'"1"* ]]
}

@test "add refuses a path that already exists" {
  cd "$PROJECT"
  run scaffold add apps/api --adapter nestjs
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
}
