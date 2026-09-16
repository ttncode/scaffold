#!/usr/bin/env bash
# Download the latest release's compose files and start the stack. Adapted from
# immich's install.sh, but never overwrites an existing .env.
#
# Usage:   ./install.sh
# Example: curl -fsSL https://github.com/you/@PROJECT_NAME@/releases/latest/download/install.sh | bash
set -euo pipefail

# Substituted at generation time; assumes the repo is named after the project.
RepoUrl='https://github.com/you/@PROJECT_NAME@/releases/latest/download'
TargetDir='./app'

RepoSlug="${RepoUrl#https://github.com/}"
RepoSlug="${RepoSlug%/releases/latest/download}"

# Matched on the value, not a *_PASSWORD name, so RABBITMQ_DEFAULT_PASS counts.
PasswordPlaceholder='changeme'
PasswordBytes=32
PasswordLength=24

# jq, not grep: the uploader's id follows the asset's name, so "the next id
# after the name" fetches a different, valid object.
release_asset_id() {
  local -r name="$1"
  local id
  id="$(jq -r --arg name "$name" \
    'first(.assets[] | select(.name == $name) | .id) // empty')" || return 1
  if [[ -z "$id" ]]; then
    printf '%s\n' "the latest release has no asset named ${name}; the release may be incomplete" >&2
    return 1
  fi
  printf '%s' "$id"
}

# A private release's browser URL is 404 even with a token; only the API asset
# endpoint serves it.
fetch_release_asset() {
  local -r name="$1" dest="$2"
  local id

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL "${RepoUrl}/${name}" -o "$dest" && return 0
    printf '%s\n' "could not download ${name}; if this project is private, set GITHUB_TOKEN to a token with repo and read:packages" >&2
    return 1
  fi

  id="$(curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${RepoSlug}/releases/latest" |
    release_asset_id "$name")" || return 1

  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H 'Accept: application/octet-stream' \
    "https://api.github.com/repos/${RepoSlug}/releases/assets/${id}" -o "$dest" && return 0
  printf '%s\n' "could not download ${name} with the token given; it needs repo and read:packages" >&2
  return 1
}

# Separate from main's checks, so a public install never needs jq.
require_private_tools() {
  [[ -n "${GITHUB_TOKEN:-}" ]] || return 0
  command -v jq >/dev/null || {
    echo 'jq is required when GITHUB_TOKEN is set: installing from a private project reads the release json' >&2
    return 1
  }
}

create_directory() {
  if [[ -e $TargetDir ]]; then
    printf '%s\n' "found existing ${TargetDir}, will overwrite compose.yaml"
  else
    mkdir "$TargetDir" || return 1
  fi
  cd "$TargetDir" || return 1
}

# compose.yaml is always overwritten; a kept .env is only checked for a password
# left at the placeholder.
download_release_assets() {
  echo "downloading compose.yaml..."
  fetch_release_asset compose.yaml ./compose.yaml || return 1

  if [[ -f .env ]]; then
    echo "found existing .env, leaving it alone"
    if grep -qE "^[A-Za-z_][A-Za-z0-9_]*=${PasswordPlaceholder}\$" .env; then
      printf '%s\n' ".env still has a password set to ${PasswordPlaceholder}; set real values in .env before running this again"
      return 1
    fi
    return 0
  fi

  echo "downloading example.env..."
  write_env_from_release
}

# No temp file may outlive this holding a plaintext password: each failure
# removes it before returning, since EXIT fires only when the script ends, and
# the trap covers a signal mid-download. The path is baked in with %q because
# the local is gone when the trap runs; the signals are named because EXIT
# alone does not fire on a kill.
write_env_from_release() {
  local tmp_env
  tmp_env="$(mktemp ./.env.XXXXXX)" || return 1
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

# Known, not fixed: each password is briefly visible in sed's argv.
generate_service_passwords() {
  local -r file="$1"
  local name password
  while IFS= read -r name; do
    # Laravel rejects an APP_KEY that is not `base64:` plus exactly 32 bytes.
    if [[ "$name" == "APP_KEY" ]]; then
      password="base64:$(head -c "$PasswordBytes" /dev/urandom | base64)"
    else
      password="$(head -c "$PasswordBytes" /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$PasswordLength")"
    fi
    # `|`: a base64 value can contain `/`.
    sed -i.bak "s|^${name}=${PasswordPlaceholder}\$|${name}=${password}|" "$file"
    rm -f "${file}.bak"
    grep -qF "${name}=${password}" "$file" || {
      printf '%s\n' "could not set ${name} in ${file}; refusing to start with an unconfirmed password"
      return 1
    }
  done < <(sed -n "s/^\([A-Za-z_][A-Za-z0-9_]*\)=${PasswordPlaceholder}\$/\1/p" "$file")
}

# docker itself would only say "invalid reference format".
require_configured_image() {
  if grep -i 'image:.*CHANGEME' compose.yaml >/dev/null; then
    echo "compose.yaml's image line still has a CHANGEME placeholder; edit it to this project's real registry path, then re-run this script"
    return 1
  fi
}

# A ghcr package's visibility is separate from its repository's. The token goes
# on stdin: argv is visible to every user on the host.
start_stack() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf '%s' "${GITHUB_TOKEN}" |
      docker login ghcr.io -u "${RepoSlug%%/*}" --password-stdin >/dev/null || {
      echo 'could not sign in to ghcr.io; the token needs read:packages' >&2
      return 1
    }
  fi
  docker compose up --remove-orphans -d || return 1
}

# Captured, never piped into `grep -q`: grep exits on its first match, compose
# dies of SIGPIPE, and pipefail fails the check about one run in seven.
compose_has_service() {
  local -r service="$1"
  shift
  local services

  services="$(docker compose "$@" config --services)" || return 1
  grep -qx "$service" <<<"$services"
}

# ADR-0014 forbids migrations from an entrypoint, so they run here.
run_migrations() {
  # `config --services` omits a profiled service unless the profile is named.
  if compose_has_service migrate --profile migrate; then
    echo "running migrations..."
    docker compose --profile migrate run --rm migrate
    return
  fi
  # Every database driver ships a migrate command, so its absence is a fault.
  if compose_has_service database; then
    echo "a database service exists but no migrate service was found — refusing to start with unapplied schema" >&2
    return 1
  fi
}

# ADR-0022: one line per application, from .env, so a changed port shows.
print_running_apps() {
  local name port
  while IFS='=' read -r name port; do
    [[ -n "$port" ]] || continue
    name="${name%_PORT}"
    printf '%s\n' "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]') is running on http://localhost:${port}"
  done < <(grep -E '^[A-Z][A-Z0-9_]*_PORT=' .env || true)
}

main() {
  command -v curl >/dev/null || {
    echo 'curl is required'
    return 1
  }
  docker compose version >/dev/null 2>&1 || {
    echo 'docker compose is required'
    return 1
  }
  require_private_tools || return 1

  create_directory || {
    echo 'could not create the target directory'
    return 1
  }
  download_release_assets || {
    echo 'could not download the release assets'
    return 1
  }
  require_configured_image || return 1
  start_stack || {
    echo 'could not start the stack; check the output above'
    return 1
  }
  run_migrations || {
    echo 'could not run migrations; check the output above'
    return 1
  }

  print_running_apps
}

# Sourced by the toolbox's tests. `:-$0`: piped through curl there is no
# BASH_SOURCE, and nounset would kill the script here.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main
fi
