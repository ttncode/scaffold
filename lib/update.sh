# shellcheck shell=bash
#
# Bringing a toolbox change to a project that already exists.
#
# ADR-0005 wrote the problem down on its first line: a project generated in
# January carries January's tooling forever, because nothing revisits it. That
# ADR solved it for the workflow bodies by moving them into a second
# repository behind a moving tag. Everything else — every Dockerfile,
# lefthook.yml, renovate.json, install.sh, every file an adapter overlays —
# was still frozen at generation time.
#
# The whole approach rests on one fact: the files scaffold owns in a generated
# project came from `common/` and `adapters/<name>/` in this checkout, at a
# commit .scaffold.toml records. So `git diff <that commit>..HEAD` over those
# paths is exactly the set of changes the project never received. Rewriting
# that patch onto the project's own layout is all "update" has to mean.

# manifest_version <project> — the toolbox commit a project was generated from.
manifest_version() {
  local file="${1}/${SCAFFOLD_MANIFEST}" version

  [ -f "$file" ] || return 1
  version="$(yq -p toml -oy -r '.version // ""' "$file" 2>/dev/null || true)"
  [ -n "$version" ] && [ "$version" != "null" ] || return 1
  printf '%s' "$version"
}

# manifest_apps <project> — one `<rel><tab><adapter>` line per application.
manifest_apps() {
  yq -p toml -oy -r '.apps // {} | to_entries | .[] | [.key, .value] | @tsv' \
    "${1}/${SCAFFOLD_MANIFEST}" 2>/dev/null || true
}

# rewrite_patch_paths <from-prefix> <to-prefix>
# Reads a patch on stdin and moves every path in its headers from one prefix
# to another, so a diff of `common/lefthook.yml` applies to the project's own
# `lefthook.yml`. Anchored per header line rather than a blind global
# substitution: a path-shaped string in a context line is file content, not a
# header, and rewriting it would corrupt the very hunk it appears in.
#
# `#` as the delimiter, not `|`: the last rule alternates on `rename|copy`, and
# with `|` delimiting the expression sed reads that alternation as the end of
# the pattern — "unknown option to `s'", against a patch that looked fine.
rewrite_patch_paths() {
  local from="$1" to="$2"
  sed -E \
    -e "s#^diff --git a/${from}#diff --git a/${to}#" \
    -e "s#^(diff --git a/[^ ]+) b/${from}#\1 b/${to}#" \
    -e "s#^--- a/${from}#--- a/${to}#" \
    -e "s#^\+\+\+ b/${from}#+++ b/${to}#" \
    -e "s#^(rename|copy) (from|to) ${from}#\1 \2 ${to}#"
}

# project_owner <project> / project_name <project>
# Read back out of the project rather than recomputed from `gh` or from the
# directory name, which would answer for this machine today rather than for
# the project as it was generated.
project_owner() {
  local image; image="$(project_image_base "$1")"
  image="${image#ghcr.io/}"
  printf '%s' "${image%%/*}"
}

project_name() {
  local image; image="$(project_image_base "$1")"
  printf '%s' "${image##*/}"
}

# substitute_placeholders <project> [app-rel]
# The patch is cut from template files, so it carries their placeholders. Both
# sides of it need the project's real values — the `+` lines because they are
# about to become the project's content, and the context lines because
# otherwise no hunk matches anything.
substitute_placeholders() {
  local project="$1" rel="${2:-}"
  local owner name filter
  owner="$(project_owner "$project")"
  name="$(project_name "$project")"

  local -a rules=(
    -e "s|you/|${owner}/|g"
    -e "s|@PROJECT_NAME@|${name}|g"
    -e "s|@PROJECT_TITLE@|${name^}|g"
  )
  if [ -n "$rel" ]; then
    filter="$(app_service_key "$rel")"
    rules+=(-e "s|@APP_ROOT@|${rel}/|g" -e "s|@APP_FILTER@|${filter}|g")
  fi

  sed "${rules[@]}"
}

# common_patch <project>
# mise.root.toml is excluded: it is not copied but rendered into mise.toml,
# which scaffold then rewrites further (config_roots, the checklist, the
# recorded services). A patch against the template cannot describe the
# result, and `scaffold update` reporting a conflict on every project's
# mise.toml forever would train people to ignore its output.
common_patch() {
  local project="$1"

  git -C "$SCAFFOLD_ROOT" diff "${SCAFFOLD_UPDATE_FROM}..HEAD" -- \
    common/ ':(exclude)common/mise.root.toml' \
    | rewrite_patch_paths 'common/' '' \
    | substitute_placeholders "$project"
}

# adapter_patch <project> <rel> <adapter>
# adapter.env never ships, and lefthook.fragment.yml is merged into the
# project's own lefthook.yml rather than copied, so neither has a path in the
# project for a patch to name.
#
# Of Dockerfile and Dockerfile.workspace exactly one survives generation, as
# the app's `Dockerfile` (finalize_app_dockerfile). Which one depends on
# whether the app resolves through the shared pnpm workspace — so the surviving
# variant is mapped onto `Dockerfile` and the other is dropped, rather than
# emitting a patch against a path that is not there.
adapter_patch() {
  local project="$1" rel="$2" adapter="$3"
  local dir="adapters/${adapter}"
  local kept dropped

  if [ -f "${SCAFFOLD_ROOT}/${dir}/Dockerfile.workspace" ] \
    && app_is_workspace_member "$project" "$rel"; then
    kept="Dockerfile.workspace"
    dropped="Dockerfile"
  else
    kept="Dockerfile"
    dropped="Dockerfile.workspace"
  fi

  {
    git -C "$SCAFFOLD_ROOT" diff "${SCAFFOLD_UPDATE_FROM}..HEAD" -- \
      "${dir}/" \
      ":(exclude)${dir}/adapter.env" \
      ":(exclude)${dir}/lefthook.fragment.yml" \
      ":(exclude)${dir}/${dropped}" \
      ":(exclude)${dir}/${kept}"
    # The surviving Dockerfile, mapped onto the one name the app actually has.
    git -C "$SCAFFOLD_ROOT" diff "${SCAFFOLD_UPDATE_FROM}..HEAD" -- "${dir}/${kept}" \
      | rewrite_patch_paths "${dir}/${kept}" "${dir}/Dockerfile"
  } \
    | rewrite_patch_paths "${dir}/" "${rel}/" \
    | substitute_placeholders "$project" "$rel"
}

# SCAFFOLD_UPDATE_FROM — the commit this run is diffing from. A global rather
# than a fourth parameter on adapter_patch: it is one value for the whole run,
# the same reason SCAFFOLD_SERVICES is one. Set by cmd_update.
SCAFFOLD_UPDATE_FROM=""

# update_patch <project> — everything the project has not received, as one
# patch against its own paths.
update_patch() {
  local project="$1" rel adapter

  common_patch "$project"
  while IFS=$'\t' read -r rel adapter; do
    [ -n "$rel" ] || continue
    [ -d "${SCAFFOLD_ROOT}/adapters/${adapter}" ] \
      || { warn "${rel} was generated by '${adapter}', which this toolbox no longer has — skipping it"; continue; }
    adapter_patch "$project" "$rel" "$adapter"
  done < <(manifest_apps "$project")
}

# resync_derived <project>
# Some of what scaffold owns in a project is computed, not copied: the CI
# matrix from config_roots, and the build targets from the applications. A
# patch cut from the templates carries their uncomputed form — `roots: '[]'`,
# `images: "[]"` — and applying it would quietly leave the project building
# nothing at all, which reads as a comment change in `git diff`.
#
# Re-derived rather than excluded from the patch: excluding those files would
# also throw away every change to the parts of them nobody computes, which is
# most of both files.
#
# Only when the value actually came back empty. A project whose array survived
# the patch is left alone, so this can never reorder or rewrite targets that
# were already right.
resync_derived() {
  local project="$1" rel

  sync_ci_roots "$project"

  local images
  images="$(yq -r '[.jobs[] | select(has("with")) | .with.images] | .[0] // ""' \
    "${project}/.github/workflows/build.yml" 2>/dev/null || true)"
  [ "$images" = "[]" ] || return 0

  while IFS=$'\t' read -r rel _; do
    [ -n "$rel" ] || continue
    register_image_target "$project" "$rel"
  done < <(manifest_apps "$project")
}
