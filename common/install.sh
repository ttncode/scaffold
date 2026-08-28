#!/usr/bin/env bash
# install.sh — download the latest release's compose.yaml and example.env,
# then start the stack. adapted from immich's install.sh (see
# https://github.com/immich-app/immich/blob/main/install.sh); this project
# has one image, not several, so its compose stack is simpler, and it never
# overwrites an existing .env (see the comment on download_release_assets).

set -o nounset
set -o pipefail

# CHANGEME/CHANGEME: filled in by hand once this project has a real github
# repository and a release has published compose.yaml and example.env —
# scaffold generates this file before either exists (see
# docs/decisions/0014).
RepoUrl='https://github.com/CHANGEME/CHANGEME/releases/latest/download'
TargetDir='./app'

create_directory() {
  if [[ -e $TargetDir ]]; then
    echo "found existing ${TargetDir}, will overwrite compose.yaml"
  else
    mkdir "$TargetDir" || return 1
  fi
  cd "$TargetDir" || return 1
}

# download_release_assets — compose.yaml is always overwritten with the
# release's own copy, so it and the image it references never drift apart.
# .env is never overwritten once it exists: it holds this installation's
# real database password and any edits an operator made, and running this
# script again (to pick up a new release) must not be able to lose either.
download_release_assets() {
  echo "downloading compose.yaml..."
  curl -fsSL "${RepoUrl}/compose.yaml" -o ./compose.yaml || return 1

  if [[ -f .env ]]; then
    echo "found existing .env, leaving it alone"
    return 0
  fi

  echo "downloading example.env..."
  curl -fsSL "${RepoUrl}/example.env" -o ./.env || return 1
  generate_database_password
}

generate_database_password() {
  local password
  password="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  sed -i.bak "s/DB_PASSWORD=changeme/DB_PASSWORD=${password}/" ./.env
  rm -f ./.env.bak
}

# check_image_configured — a compose.yaml still pointing at the
# ghcr.io/CHANGEME/CHANGEME placeholder fails `docker compose up` with a bare
# "pull access denied", which explains nothing; catch it here with a message
# that says what to actually do.
check_image_configured() {
  if grep -q 'ghcr.io/CHANGEME/CHANGEME' compose.yaml; then
    echo "compose.yaml still has the ghcr.io/CHANGEME/CHANGEME placeholder image; edit it to this project's real registry path, then re-run this script"
    return 1
  fi
}

start_stack() {
  local port
  docker compose up --remove-orphans -d || return 1
  port="$(grep '^APP_PORT=' .env | cut -d= -f2)"
  echo "the application is running on http://localhost:${port:-8080}"
}

main() {
  command -v curl >/dev/null || { echo 'curl is required'; return 1; }
  docker compose version >/dev/null 2>&1 || { echo 'docker compose is required'; return 1; }

  create_directory || { echo 'could not create the target directory'; return 1; }
  download_release_assets || { echo 'could not download the release assets'; return 1; }
  check_image_configured || return 1
  start_stack || { echo 'could not start the stack; check the output above'; return 1; }
}

main
