setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "flask generates an app at apps/api" {
  run scaffold new "$PROJECT" --api flask
  assert_ok
  [ -f "${PROJECT}/apps/api/pyproject.toml" ]
  [ -f "${PROJECT}/apps/api/uv.lock" ]
  [ -f "${PROJECT}/apps/api/mise.toml" ]
}

# uv resolves its own managed interpreter, so a mise-pinned python would be
# installed and then ignored; .python-version is the pin uv itself reads. The
# root mise.toml pins uv alone. See adapters/flask/mise.toml.
@test "python is pinned in the app and never at the project root" {
  scaffold new "$PROJECT" --api flask
  run grep -q '3.13' "${PROJECT}/apps/api/.python-version"
  assert_ok
  run grep -q -e 'python' -e 'uv' "${PROJECT}/mise.toml"
  [ "$status" -ne 0 ]
}

@test "the flask lefthook fragment is merged with the common hooks" {
  scaffold new "$PROJECT" --api flask
  run yq '.pre-commit.commands | has("ruff-apps-api")' "${PROJECT}/lefthook.yml"
  [ "$output" = "true" ]
  run yq '.pre-commit.commands | has("gitleaks")' "${PROJECT}/lefthook.yml"
  [ "$output" = "true" ]
}

@test "the fragment resolves the app root" {
  scaffold new "$PROJECT" --api flask
  run yq '.pre-commit.commands.ruff-apps-api.root' "${PROJECT}/lefthook.yml"
  [ "$output" = "apps/api/" ]
}

@test "a mixed-language project has no packages/types" {
  scaffold new "$PROJECT" --api flask --web nextjs
  [ ! -e "${PROJECT}/packages/types" ]
  [ ! -e "${PROJECT}/packages-types" ]
}

@test "a mixed-language project keeps the supply-chain policy" {
  scaffold new "$PROJECT" --api flask --web nextjs
  [ -f "${PROJECT}/pnpm-workspace.yaml" ]
  run yq -r '.allowBuilds | keys | .[]' "${PROJECT}/pnpm-workspace.yaml"
  assert_ok
  [[ "$output" == *"unrs-resolver"* ]]
}
