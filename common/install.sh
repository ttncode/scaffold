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
# scaffold generates this file before either exists (see the scaffold
# toolbox's ADR-0014, not shipped here).
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

# compose.yaml is always overwritten so it never drifts from the image it
# names. .env never is: it holds this installation's real password and the
# operator's edits, and re-running to pick up a release must not lose either.
# A kept .env is still checked for any password left at changeme, so an
# upgrade cannot leave a production service on the literal default.
#
# Two cleanup mechanisms, both needed: the explicit `rm -f` before each
# `return 1`, since an EXIT trap would not fire until the script ends; and the
# trap itself, for a signal landing mid-download. Neither leaves a temp file
# holding a plaintext password.
download_release_assets() {
  echo "downloading compose.yaml..."
  curl -fsSL "${RepoUrl}/compose.yaml" -o ./compose.yaml || return 1

  if [[ -f .env ]]; then
    echo "found existing .env, leaving it alone"
    if grep -qE '^[A-Z_]*_PASSWORD=changeme$' .env; then
      echo ".env still has a password set to changeme; set real values in .env before running this again"
      return 1
    fi
    return 0
  fi

  echo "downloading example.env..."
  local tmp_env
  tmp_env="$(mktemp ./.env.XXXXXX)" || return 1
  # Two changes from the obvious `trap 'rm -f "$tmp_env"' EXIT`, both needed
  # before a Ctrl-C stopped leaving the generated password on disk: the path is
  # baked in with printf %q, because bash unwinds function locals before
  # running the trap; and the signals are named, because a plain EXIT trap does
  # not run when one kills the shell.
  # shellcheck disable=SC2064 # expanding now is the point
  trap "rm -f $(printf '%q' "$tmp_env")" EXIT INT TERM HUP
  if ! curl -fsSL "${RepoUrl}/example.env" -o "$tmp_env"; then
    trap - EXIT INT TERM HUP
    rm -f "$tmp_env"
    return 1
  fi
  if ! generate_service_passwords "$tmp_env"; then
    trap - EXIT INT TERM HUP
    rm -f "$tmp_env"
    return 1
  fi
  # checked, like every other step here: an unchecked mv returns 0 through the
  # trap below, so a failure reported success and left the password file behind.
  if ! mv "$tmp_env" ./.env; then
    rm -f "$tmp_env"
    trap - EXIT INT TERM HUP
    echo "could not write .env" >&2
    return 1
  fi
  trap - EXIT INT TERM HUP
}

# Every *_PASSWORD the assembled .env carries, not one hardcoded name: a
# project may have a database, a cache, both or neither, and a name that was
# right when this was written stops being generated the moment the set
# changes — silently, because nothing reads back what it did not expect.
#
# Fails hard if a substitution misses: a password staying "changeme" because
# example.env's text drifted is a credential defaulting to a known value.
#
# Known, not fixed: each password is briefly visible in sed's argv to other
# local users. Pre-existing in the immich script this came from.
generate_service_passwords() {
  local file="$1" name password
  while IFS= read -r name; do
    password="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
    sed -i.bak "s/^${name}=changeme\$/${name}=${password}/" "$file"
    rm -f "${file}.bak"
    grep -qF "${name}=${password}" "$file" || {
      echo "could not set ${name} in ${file}; refusing to start with an unconfirmed password"
      return 1
    }
  done < <(sed -n 's/^\([A-Z_]*_PASSWORD\)=changeme$/\1/p' "$file")
}

# docker rejects the placeholder on its own, but with "invalid reference
# format" rather than anything actionable. Matched case-insensitively so a
# half-edit — ghcr.io/myorg/changeme — trips it too.
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

# sourced by the toolbox's tests to exercise one function at a time; running
# main on source would try to download a release from a CHANGEME url.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main
fi
