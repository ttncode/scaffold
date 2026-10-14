setup() {
  load 'helpers/setup'
  WORKDIR="$(mktemp -d)"
  PROJECT="${WORKDIR}/demo"
}

teardown() {
  remove_workdir "$WORKDIR"
}

@test "vite-react generates an app at apps/web" {
  run scaffold new "$PROJECT" --web vite-react
  assert_ok
  [ -f "${PROJECT}/apps/web/index.html" ]
  [ -f "${PROJECT}/apps/web/Caddyfile" ]
  [ -f "${PROJECT}/apps/web/mise.toml" ]
}

@test "vite-react adds no tool to the project root" {
  scaffold new "$PROJECT" --web vite-react
  [ "$(yq -p toml -oy '.tools' "${PROJECT}/mise.toml")" = \
    "$(yq -p toml -oy '.tools' "${SCAFFOLD_ROOT}/common/mise.root.toml")" ]
}

@test "vite-react lints with eslint, not oxlint" {
  scaffold new "$PROJECT" --web vite-react
  [ -f "${PROJECT}/apps/web/eslint.config.js" ]
  run jq -r '.devDependencies.oxlint // "absent"' "${PROJECT}/apps/web/package.json"
  [ "$output" = "absent" ]
}

@test "the generated web app passes its own checklist" {
  scaffold new "$PROJECT" --web vite-react
  cd "$PROJECT"
  run mise run //apps/web:checklist
  assert_ok
}

@test "the caddy runtime answers health and config without index.html" {
  scaffold new "$PROJECT" --web vite-react
  run grep -c 'handle /health/live\|handle /config.json' "${PROJECT}/apps/web/Caddyfile"
  [ "$output" = "2" ]
  run grep -c '^FROM node' "${PROJECT}/apps/web/Dockerfile"
  [ "$output" = "1" ]
}

@test "vite-react and nestjs share one workspace" {
  scaffold new "$PROJECT" --web vite-react --api nestjs --db none
  [ -f "${PROJECT}/packages/types/package.json" ]
  run find "$PROJECT" -name pnpm-lock.yaml -not -path '*/node_modules/*'
  [ "$output" = "${PROJECT}/pnpm-lock.yaml" ]
  run grep -c -- '--filter web' "${PROJECT}/apps/web/Dockerfile"
  [ "$output" = "1" ]
}

@test "a role mismatch is rejected" {
  run scaffold new "$PROJECT" --api vite-react
  [ "$status" -eq 1 ]
  [[ "$output" == *"adapter vite-react has role web"* ]]
}

@test "the deployed stack's env lists API_URL for the web app" {
  scaffold new "$PROJECT" --web vite-react
  # compose feeds every container from the root .env, which install.sh builds
  # from example.env; apps/web/.env.example reaches no container.
  run grep -c '^API_URL=' "${PROJECT}/example.env"
  [ "$output" = "1" ]
  [ ! -e "${PROJECT}/apps/web/example.env.fragment" ]
}

@test "the caddy runtime keeps a stale index.html out of browser caches" {
  scaffold new "$PROJECT" --web vite-react
  # a heuristically cached index.html asks for hashed assets a later deploy
  # removed, and the SPA fallback answers them with HTML: a blank page.
  run grep -c 'Cache-Control no-cache' "${PROJECT}/apps/web/Caddyfile"
  [ "$output" = "1" ]
}
