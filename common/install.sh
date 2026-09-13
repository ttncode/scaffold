#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# Script      : install.sh
# Description : Download the latest release's compose files and start the stack.
# Author      : ttncode
#
# Usage:
#   ./install.sh
#
# Example:
#   curl -fsSL https://github.com/you/@PROJECT_NAME@/releases/latest/download/install.sh | bash
# ═══════════════════════════════════════════════════════════════════════════
#
# Adapted from immich's install.sh; unlike immich, never overwrites an existing
# .env (see download_release_assets).

set -o nounset
set -o pipefail

# Substituted at generation time; assumes the repo is named after the project
# directory.
RepoUrl='https://github.com/you/@PROJECT_NAME@/releases/latest/download'
TargetDir='./app'

RepoSlug="${RepoUrl#https://github.com/}"
RepoSlug="${RepoSlug%/releases/latest/download}"

# Matched on the placeholder value, not a *_PASSWORD name pattern, so a
# differently-named variable (e.g. RABBITMQ_DEFAULT_PASS) still gets a real value.
PasswordPlaceholder='changeme'
PasswordBytes=32
PasswordLength=24

# ─── downloading the release ───────────────────────────────────────────────

# release_asset_id <name> — reads a release's JSON on stdin.
#
# jq, not grep: an asset's own id precedes its name while the uploader's
# follows it, so "find the name, take the next id" returns the uploader's id —
# and that request succeeds, fetching a different valid object.
release_asset_id() {
  local -r name="$1"
  local id
  id="$(jq -r --arg name "$name" \
    'first(.assets[] | select(.name == $name) | .id) // empty')" || return 1
  if [ -z "$id" ]; then
    echo "the latest release has no asset named ${name}; the release may be incomplete" >&2
    return 1
  fi
  printf '%s' "$id"
}

# fetch_release_asset <name> <dest>
#
# Two endpoints: a private release's browser URL returns 404 both anonymously
# and with a Bearer token, while the API asset endpoint returns 200.
fetch_release_asset() {
  local -r name="$1" dest="$2"
  local id

  if [ -z "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL "${RepoUrl}/${name}" -o "$dest" && return 0
    echo "could not download ${name}; if this project is private, set GITHUB_TOKEN to a token with repo and read:packages" >&2
    return 1
  fi

  id="$(curl -fsSL \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/${RepoSlug}/releases/latest" \
    | release_asset_id "$name")" || return 1

  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H 'Accept: application/octet-stream' \
    "https://api.github.com/repos/${RepoSlug}/releases/assets/${id}" -o "$dest" && return 0
  echo "could not download ${name} with the token given; it needs repo and read:packages" >&2
  return 1
}

# Checked separately from main's other checks, so a public install never needs jq.
require_private_tools() {
  [ -n "${GITHUB_TOKEN:-}" ] || return 0
  command -v jq >/dev/null || {
    echo 'jq is required when GITHUB_TOKEN is set: installing from a private project reads the release json' >&2
    return 1
  }
}

create_directory() {
  if [[ -e $TargetDir ]]; then
    echo "found existing ${TargetDir}, will overwrite compose.yaml"
  else
    mkdir "$TargetDir" || return 1
  fi
  cd "$TargetDir" || return 1
}

# compose.yaml is always overwritten; a kept .env is only checked for a
# password left at the placeholder.
#
# Two cleanup mechanisms, both needed so no temp file is left holding a
# plaintext password: the explicit `rm -f` before each `return 1`, since an EXIT
# trap fires only at the end of the script; and the trap, for a signal landing
# mid-download.
download_release_assets() {
  echo "downloading compose.yaml..."
  fetch_release_asset compose.yaml ./compose.yaml || return 1

  if [[ -f .env ]]; then
    echo "found existing .env, leaving it alone"
    if grep -qE "^[A-Za-z_][A-Za-z0-9_]*=${PasswordPlaceholder}\$" .env; then
      echo ".env still has a password set to ${PasswordPlaceholder}; set real values in .env before running this again"
      return 1
    fi
    return 0
  fi

  echo "downloading example.env..."
  local tmp_env
  tmp_env="$(mktemp ./.env.XXXXXX)" || return 1
  # Two changes from the obvious `trap 'rm -f "$tmp_env"' EXIT`, or a Ctrl-C
  # leaves the generated password on disk: the path is baked in with printf %q,
  # because bash unwinds function locals before running the trap; and the
  # signals are named, because a plain EXIT trap does not run on a kill.
  # shellcheck disable=SC2064 # expanding now is the point
  trap "rm -f $(printf '%q' "$tmp_env")" EXIT INT TERM HUP
  if ! fetch_release_asset example.env "$tmp_env"; then
    trap - EXIT INT TERM HUP
    rm -f "$tmp_env"
    return 1
  fi
  if ! generate_service_passwords "$tmp_env"; then
    trap - EXIT INT TERM HUP
    rm -f "$tmp_env"
    return 1
  fi
  if ! mv "$tmp_env" ./.env; then
    rm -f "$tmp_env"
    trap - EXIT INT TERM HUP
    echo "could not write .env" >&2
    return 1
  fi
  trap - EXIT INT TERM HUP
}

# ─── configuring it ────────────────────────────────────────────────────────

# Known, not fixed: each password is briefly visible in sed's argv to other
# local users.
generate_service_passwords() {
  local -r file="$1"
  local name password
  while IFS= read -r name; do
    # APP_KEY is not a password: laravel decrypts with it and rejects anything
    # that is not `base64:` plus exactly 32 bytes.
    if [ "$name" = APP_KEY ]; then
      password="base64:$(head -c "$PasswordBytes" /dev/urandom | base64)"
    else
      password="$(head -c "$PasswordBytes" /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$PasswordLength")"
    fi
    # `|`, not `/`: a base64 value can itself contain `/`, which would end sed's
    # s/// early and leave the line unmatched instead of substituted.
    sed -i.bak "s|^${name}=${PasswordPlaceholder}\$|${name}=${password}|" "$file"
    rm -f "${file}.bak"
    grep -qF "${name}=${password}" "$file" || {
      echo "could not set ${name} in ${file}; refusing to start with an unconfirmed password"
      return 1
    }
  done < <(sed -n "s/^\([A-Za-z_][A-Za-z0-9_]*\)=${PasswordPlaceholder}\$/\1/p" "$file")
}

# Catches a copy hand-edited back to the placeholder; docker itself would only
# report an unhelpful "invalid reference format".
require_configured_image() {
  if grep -i 'image:.*CHANGEME' compose.yaml >/dev/null; then
    echo "compose.yaml's image line still has a CHANGEME placeholder; edit it to this project's real registry path, then re-run this script"
    return 1
  fi
}

# ─── running it ────────────────────────────────────────────────────────────

start_stack() {
  # ghcr package visibility is separate from repository visibility; a private
  # package refuses an anonymous pull with `unauthorized`.
  # --password-stdin, not an argument: argv is visible to every other user on the host.
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    printf '%s' "${GITHUB_TOKEN}" \
      | docker login ghcr.io -u "${RepoSlug%%/*}" --password-stdin >/dev/null || {
        echo 'could not sign in to ghcr.io; the token needs read:packages' >&2
        return 1
      }
  fi
  docker compose up --remove-orphans -d || return 1
}

# Captured, never piped into `grep -q`: grep closes the pipe on its first match,
# `docker compose` then dies of SIGPIPE, and `set -o pipefail` reports the whole
# pipeline as failed. Measured at roughly one run in seven — a stack that
# refused to migrate, at random, with a message about a service that was there.
compose_has_service() {
  local -r service="$1"; shift
  local services

  services="$(docker compose "$@" config --services)" || return 1
  grep -qx "$service" <<<"$services"
}

# ADR-0014 seam 5 forbids migrations from an entrypoint, so this is a human
# running one command on the target host.
run_migrations() {
  # `config --services` with no --profile never lists a service gated behind one.
  if compose_has_service migrate --profile migrate; then
    echo "running migrations..."
    docker compose --profile migrate run --rm migrate
    return
  fi
  # Every database driver ships a migrate command, so a database with none means
  # the service, its profile or the command vanished — not "nothing to migrate".
  if compose_has_service database; then
    echo "a database service exists but no migrate service was found — refusing to start with unapplied schema" >&2
    return 1
  fi
}

main() {
  command -v curl >/dev/null || { echo 'curl is required'; return 1; }
  docker compose version >/dev/null 2>&1 || { echo 'docker compose is required'; return 1; }
  require_private_tools || return 1

  create_directory || { echo 'could not create the target directory'; return 1; }
  download_release_assets || { echo 'could not download the release assets'; return 1; }
  require_configured_image || return 1
  start_stack || { echo 'could not start the stack; check the output above'; return 1; }
  run_migrations || { echo 'could not run migrations; check the output above'; return 1; }

  # One line per application (ADR-0022), read out of .env so it reflects any
  # port the operator changed.
  local name port
  while IFS='=' read -r name port; do
    [ -n "$port" ] || continue
    name="${name%_PORT}"
    echo "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]') is running on http://localhost:${port}"
  done < <(grep -E '^[A-Z][A-Z0-9_]*_PORT=' .env || true)
}

# Sourced by the toolbox's tests to exercise one function at a time.
#
# `${BASH_SOURCE[0]:-$0}`, not a bare `${BASH_SOURCE[0]}`: piped through curl
# there is no BASH_SOURCE at all, and `set -o nounset` above kills the script
# right here — silently, in the one way this project is actually run.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  main
fi
