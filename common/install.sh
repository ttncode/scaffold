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

# The owner/repo pair, taken from RepoUrl so a project still edits one line.
RepoSlug="${RepoUrl#https://github.com/}"
RepoSlug="${RepoSlug%/releases/latest/download}"

# release_asset_id <name> — reads a release's JSON on stdin.
#
# jq, not grep: measured against a real release, an asset's own id precedes
# its name while the uploader's id follows it, so "find the name, take the
# next id" returns the uploader's for every asset. That request does not
# fail — it fetches a different valid object and writes it to the file the
# caller asked for. Only the token path needs this, so jq stays off the
# public path's dependency list.
release_asset_id() {
  local name="$1" id
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
# Two endpoints, because a private release is not reachable from the public
# one: measured against a real private repository, the browser URL returns
# 404 both anonymously and with a Bearer token, while the API asset endpoint
# returns 200. So a token alone does not fix the public URL — the URL is what
# has to change.
fetch_release_asset() {
  local name="$1" dest="$2" id

  if [ -z "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL "${RepoUrl}/${name}" -o "$dest" && return 0
    # A private release answers 404 to an anonymous request, which reads as
    # "no such release" rather than "you are not signed in".
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
  # A token given but rejected by this endpoint is the token's problem, not
  # its absence — this message must not repeat the no-token hint above.
  echo "could not download ${name} with the token given; it needs repo and read:packages" >&2
  return 1
}

# jq is needed only to read a release's JSON, which only the token path does.
# Checked separately from main's curl/docker checks so a public install never
# learns about a dependency it does not use.
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
  fetch_release_asset compose.yaml ./compose.yaml || return 1

  if [[ -f .env ]]; then
    echo "found existing .env, leaving it alone"
    if grep -qE '^[A-Za-z_][A-Za-z0-9_]*=changeme$' .env; then
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

# Every variable still at the literal `changeme` the assembled .env carries,
# not a *_PASSWORD name match: example.env's own header names the literal as
# the contract, and a service naming its variable differently (e.g.
# RABBITMQ_DEFAULT_PASS) still needs a real value generated for it — a name
# pattern is a convention nothing enforces, the literal is what's actually
# checked below.
#
# Fails hard if a substitution misses: a password staying "changeme" because
# example.env's text drifted is a credential defaulting to a known value.
#
# Known, not fixed: each password is briefly visible in sed's argv to other
# local users. Pre-existing in the immich script this came from.
generate_service_passwords() {
  local file="$1" name password
  while IFS= read -r name; do
    # APP_KEY is not a password: laravel decrypts with it and rejects anything
    # that is not base64: plus exactly 32 bytes. Handled inside this loop
    # rather than beside it so example.env keeps one placeholder, and the
    # existing-.env guard that greps for a remaining `=changeme` still covers
    # it.
    if [ "$name" = APP_KEY ]; then
      password="base64:$(head -c 32 /dev/urandom | base64)"
    else
      password="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
    fi
    # `|`, not `/`: a base64 value can itself contain `/`, which would end
    # sed's s/// early and leave the line unmatched instead of substituted.
    sed -i.bak "s|^${name}=changeme\$|${name}=${password}|" "$file"
    rm -f "${file}.bak"
    grep -qF "${name}=${password}" "$file" || {
      echo "could not set ${name} in ${file}; refusing to start with an unconfirmed password"
      return 1
    }
  done < <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=changeme$/\1/p' "$file")
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
  # A package's ghcr visibility is separate from its repository's, and a
  # private package refuses an anonymous pull with `unauthorized` — measured
  # 2026-09-07. The username is not checked for a token login; RepoSlug's
  # owner just makes a failure name something the operator recognises.
  #
  # --password-stdin, not an argument: an argument would put the token in
  # this process's argv, visible to every other user on the host through the
  # process list — the same exposure generate_service_passwords already
  # carries for sed's argv, and this must not add a second instance of it.
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    printf '%s' "${GITHUB_TOKEN}" \
      | docker login ghcr.io -u "${RepoSlug%%/*}" --password-stdin >/dev/null || {
        echo 'could not sign in to ghcr.io; the token needs read:packages' >&2
        return 1
      }
  fi
  docker compose up --remove-orphans -d || return 1
}

# ADR-0014 seam 5 forbids migrations from an *entrypoint* — a container that
# migrates every time it starts cannot be scaled or rolled back. This is a
# human running one command on the target host, which is what that ADR calls
# the one deploy mechanism that exists today. A project with no database
# ships no migrate service, and `--profile` on a service that is not there
# is not an error.
run_migrations() {
  # `docker compose config --services` (no --profile) never lists a service
  # gated behind a profile, so that guard alone always skipped the migration
  # silently — measured: plain `config --services` prints only `app`, and
  # `--profile migrate config --services` prints `migrate app`.
  if docker compose --profile migrate config --services | grep -qx migrate; then
    echo "running migrations..."
    docker compose --profile migrate run --rm migrate
    return
  fi
  # A database service with no migrate service beside it is not "nothing to
  # migrate" — every database driver ships a migrate command, so this
  # combination only happens if the service, its profile, or the command
  # itself silently vanished. Returning 0 here is exactly the hole that let
  # a stack go green with unapplied schema; a project with no database at
  # all is the only case this falls through to.
  if docker compose config --services | grep -qx database; then
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
  check_image_configured || return 1
  start_stack || { echo 'could not start the stack; check the output above'; return 1; }
  run_migrations || { echo 'could not run migrations; check the output above'; return 1; }

  local port
  port="$(grep '^APP_PORT=' .env | cut -d= -f2)"
  echo "the application is running on http://localhost:${port:-8080}"
}

# sourced by the toolbox's tests to exercise one function at a time; running
# main on source would try to download a release from a CHANGEME url.
# `${BASH_SOURCE[0]:-$0}`, not a bare `${BASH_SOURCE[0]}`: this is documented
# as curl-piped (`curl ... | bash`, same as the immich script it's adapted
# from), and piped in there is no BASH_SOURCE at all — `set -o nounset` above
# killed the script before this line under the bare form, silently, in the
# one way this project is actually run.
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  main
fi
