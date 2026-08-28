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
# note: that overwrite happens before the .env check below, so a refusal
# there (or any failure after it) leaves a new compose.yaml on disk while
# the running containers are still on the old release — a mid-upgrade
# directory, not a lie: the exit code is still 1 and nothing claims success.
# .env is never overwritten once it exists: it holds this installation's
# real database password and any edits an operator made, and running this
# script again (to pick up a new release) must not be able to lose either.
# a *kept* .env is still checked for the one thing this script itself would
# have put there — an unset DB_PASSWORD=changeme — so an upgrade from a
# pre-patch install, or a hand-written .env, cannot run production postgres
# on the literal default forever with no warning; nothing else in it is
# validated, since the rest is the operator's own configuration to own.
# example.env is fetched to a temporary file first and only moved into place
# once the download and password substitution both succeed. two mechanisms,
# not one, cover every way out of this function: the explicit `rm -f`
# before each `return 1` covers the two ordinary failures (by then $tmp_env
# is a live local, and the trap alone would not fire until the whole script
# exits, long after $tmp_env has gone out of scope); the EXIT trap covers a
# SIGINT/SIGTERM landing mid-download, which no explicit `rm -f` in this
# function's own body can reach. neither leaves a partial file for the next
# run's `[ -f .env ]` check to mistake for real configuration, and neither
# leaves an orphaned temp file holding a plaintext password behind.
download_release_assets() {
  echo "downloading compose.yaml..."
  curl -fsSL "${RepoUrl}/compose.yaml" -o ./compose.yaml || return 1

  if [[ -f .env ]]; then
    echo "found existing .env, leaving it alone"
    if grep -qx 'DB_PASSWORD=changeme' .env; then
      echo ".env has DB_PASSWORD=changeme; set a real password in .env before running this again"
      return 1
    fi
    return 0
  fi

  echo "downloading example.env..."
  local tmp_env
  tmp_env="$(mktemp ./.env.XXXXXX)" || return 1
  trap 'rm -f "$tmp_env"' EXIT
  if ! curl -fsSL "${RepoUrl}/example.env" -o "$tmp_env"; then
    trap - EXIT
    rm -f "$tmp_env"
    return 1
  fi
  if ! generate_database_password "$tmp_env"; then
    trap - EXIT
    rm -f "$tmp_env"
    return 1
  fi
  mv "$tmp_env" ./.env
  trap - EXIT
}

# generate_database_password <file> — fails hard, instead of reporting
# success, if the substitution does not land: a client's real database
# password quietly staying "changeme" because example.env's literal text
# drifted is a credential silently defaulting to a known value, which must
# be loud, not swallowed.
#
# known, not fixed: the password is briefly visible in this process's own
# argv (sed's own command-line argument) to other local users on the same
# machine for the instant sed runs. pre-existing in the immich script this
# was adapted from, local-only, and fixing it properly means restructuring
# how the substitution happens (e.g. piping it in rather than passing it as
# an argument) — not done here.
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
# matches CHANGEME case-insensitively, anywhere on the image line, not the
# exact placeholder string: a half-edit (e.g. ghcr.io/myorg/CHANGEME, or
# ghcr.io/myorg/changeme — the likelier of the two, since docker requires a
# lowercase repository name and a half-edit naturally lowercases it) still
# trips the guard instead of sailing through into the same failure it
# exists to prevent.
check_image_configured() {
  if grep 'image:' compose.yaml | grep -qi 'CHANGEME'; then
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
