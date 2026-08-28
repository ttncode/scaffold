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
# docs/decisions/0014-deployment-deferred-with-seams.md in the scaffold
# toolbox repository).
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
# example.env is fetched to a temporary file first and only moved into place
# once the download and password substitution both succeed, so a curl that
# dies partway through cannot leave a partial or unedited .env behind for
# the next run's `[ -f .env ]` check to mistake for a real configuration.
download_release_assets() {
  echo "downloading compose.yaml..."
  curl -fsSL "${RepoUrl}/compose.yaml" -o ./compose.yaml || return 1

  if [[ -f .env ]]; then
    echo "found existing .env, leaving it alone"
    return 0
  fi

  echo "downloading example.env..."
  local tmp_env
  tmp_env="$(mktemp ./.env.XXXXXX)" || return 1
  if ! curl -fsSL "${RepoUrl}/example.env" -o "$tmp_env"; then
    rm -f "$tmp_env"
    return 1
  fi
  if ! generate_database_password "$tmp_env"; then
    rm -f "$tmp_env"
    return 1
  fi
  mv "$tmp_env" ./.env
}

# generate_database_password <file> — fails hard, instead of reporting
# success, if the substitution does not land: a client's real database
# password quietly staying "changeme" because example.env's literal text
# drifted is a credential silently defaulting to a known value, which must
# be loud, not swallowed.
generate_database_password() {
  local file="$1" password
  password="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  sed -i.bak "s/DB_PASSWORD=changeme/DB_PASSWORD=${password}/" "$file"
  rm -f "${file}.bak"
  grep -qF "DB_PASSWORD=${password}" "$file" || {
    echo "could not set the database password in ${file} (DB_PASSWORD=changeme not found); refusing to start with an unconfirmed password"
    return 1
  }
}

# check_image_configured — an unedited placeholder image already fails
# `docker compose up` on its own (docker itself rejects the uppercase
# CHANGEME with "invalid reference format"), but catching it here first,
# with a message that says what to actually do, means an operator doesn't
# have to translate a generic docker error into "go edit compose.yaml".
# matches a bare CHANGEME anywhere on the image line, not the exact
# placeholder string, so a half-edit (e.g. ghcr.io/myorg/CHANGEME) still
# trips it instead of sailing through into the same failure this guard
# exists to prevent.
check_image_configured() {
  if grep 'image:' compose.yaml | grep -q 'CHANGEME'; then
    echo "compose.yaml's image line still has a CHANGEME placeholder; edit it to this project's real registry path, then re-run this script"
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
