# ═══════════════════════════════════════════════════════════════════════════
# Script      : lib/manifest.sh
# Description : One list of config roots and image targets, derived not copied.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck shell=bash
#
# `config_roots` in mise.toml is the manifest (ADR-0013): register_config_root is
# the single place a root enters it, and sync_ci_roots copies it into the CI
# workflow. register_image_target does the same for images (ADR-0022).

MISE_CONFIG_FILE="mise.toml"
CI_WORKFLOW=".github/workflows/ci.yml"
BUILD_WORKFLOWS=(".github/workflows/build.yml" ".github/workflows/release.yml")

register_config_root() {
  local project="$1" root="$2"
  local file="${project}/${MISE_CONFIG_FILE}"

  # Anchored on the exact formatting mise.root.toml ships, and verified: an
  # inline `config_roots = ["docs"]` matches neither awk, and a silent no-op
  # here ships a CI matrix of [] that passes green while running nothing.
  if ! grep -q "^  \"${root}\",\$" "$file"; then
    awk -v root="$root" '
      { print }
      /^config_roots = \[$/ { printf "  \"%s\",\n", root }
    ' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    grep -q "^  \"${root}\",\$" "$file" \
      || die "could not register ${root}: no 'config_roots = [' line in ${file} — has it been reformatted?"
  fi

  # The root [tasks.checklist] must run every config root's checklist. Kept
  # here, the one place every root passes through, not as a second list.
  if ! grep -q "\"//${root}:checklist\"" "$file"; then
    awk -v root="$root" '
      /^\[tasks\.checklist\]$/ { in_checklist = 1 }
      in_checklist && /^run = \[/ {
        sub(/\]$/, ", { task = \"//" root ":checklist\" }]")
        in_checklist = 0
      }
      { print }
    ' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    grep -q "\"//${root}:checklist\"" "$file" \
      || die "could not add ${root} to the root checklist in ${file} — has [tasks.checklist] been reformatted?"
  fi
}

config_roots() {
  sed -n '/^config_roots = \[$/,/^\]$/p' "${1}/${MISE_CONFIG_FILE}" \
    | sed -n 's/^  "\(.*\)",$/\1/p'
}

sync_ci_roots() {
  local project="$1" json
  json="$(config_roots "$project" | jq -R . | jq -sc .)"
  sed -i.bak "s|^      roots: .*|      roots: '${json}'|" \
    "${project}/${CI_WORKFLOW}"
  rm -f "${project}/${CI_WORKFLOW}.bak"
}

# register_image_target <project> <rel> — one entry in the `images` array the
# build workflows pass on (ADR-0022). Called after the workspace decision is
# settled, since the build context depends on it.
register_image_target() {
  local project="$1" rel="$2"
  local name context dockerfile image file current updated

  name="$(app_service_key "$rel")"
  image="$(project_image_base "$project")-${name}"
  dockerfile="${rel}/Dockerfile"

  # A workspace member has no package.json or lockfile of its own — they live
  # at the root — so its Dockerfile's first COPY only resolves from there.
  if app_is_workspace_member "$project" "$rel"; then
    context="."
  else
    context="$rel"
  fi

  [ -f "${project}/${dockerfile}" ] \
    || die "no Dockerfile at ${dockerfile} to build ${name} from"

  for file in "${BUILD_WORKFLOWS[@]}"; do
    file="${project}/${file}"
    current="$(yq -r '[.jobs[] | select(has("with")) | .with.images] | .[0] // "[]"' "$file")"
    updated="$(jq -c --arg image "$image" --arg context "$context" \
      --arg dockerfile "$dockerfile" \
      '. + [{image: $image, context: $context, dockerfile: $dockerfile}]' \
      <<<"$current")" \
      || die "could not read the images array out of ${file}"

    IMAGES="$updated" yq --inplace \
      '(.jobs[] | select(has("with")) | .with.images) = strenv(IMAGES)' "$file" \
      || die "could not record ${name}'s image in ${file}"
  done
}
