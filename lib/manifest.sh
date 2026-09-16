# The config roots and image targets, each recorded in one place and derived
# everywhere else.
# shellcheck shell=bash

MISE_CONFIG_FILE="mise.toml"
CI_WORKFLOW=".github/workflows/ci.yml"
BUILD_WORKFLOWS=(".github/workflows/build.yml" ".github/workflows/release.yml")

# ADR-0013: `config_roots` in mise.toml is the manifest.
register_config_root() {
  local -r project="$1" root="$2"
  local -r file="${project}/${MISE_CONFIG_FILE}"

  add_config_roots_entry "$file" "$root"
  add_root_checklist_task "$file" "$root"
}

# Anchored on the formatting mise.root.toml ships, and verified afterwards: a
# silent no-op here ships a CI matrix of [] that passes green running nothing.
add_config_roots_entry() {
  local -r file="$1" root="$2"

  grep -q "^  \"${root}\",\$" "$file" && return 0
  awk -v root="$root" '
    { print }
    /^config_roots = \[$/ { printf "  \"%s\",\n", root }
  ' "$file" >"${file}.tmp"
  mv "${file}.tmp" "$file"
  grep -q "^  \"${root}\",\$" "$file" ||
    die "could not register ${root}: no 'config_roots = [' line in ${file} — has it been reformatted?"
}

add_root_checklist_task() {
  local -r file="$1" root="$2"

  grep -q "\"//${root}:checklist\"" "$file" && return 0
  awk -v root="$root" '
    /^\[tasks\.checklist\]$/ { in_checklist = 1 }
    in_checklist && /^run = \[/ {
      sub(/\]$/, ", { task = \"//" root ":checklist\" }]")
      in_checklist = 0
    }
    { print }
  ' "$file" >"${file}.tmp"
  mv "${file}.tmp" "$file"
  grep -q "\"//${root}:checklist\"" "$file" ||
    die "could not add ${root} to the root checklist in ${file} — has [tasks.checklist] been reformatted?"
}

config_roots() {
  local -r project="$1"

  sed -n '/^config_roots = \[$/,/^\]$/p' "${project}/${MISE_CONFIG_FILE}" |
    sed -n 's/^  "\(.*\)",$/\1/p'
}

sync_ci_roots() {
  local -r project="$1"
  local json
  json="$(config_roots "$project" | jq -R . | jq -sc .)"
  sed -i.bak "s|^      roots: .*|      roots: '${json}'|" \
    "${project}/${CI_WORKFLOW}"
  rm -f "${project}/${CI_WORKFLOW}.bak"
}

# ADR-0022. Call once the workspace shape is settled: the build context depends
# on it.
register_image_target() {
  local -r project="$1" rel="$2"
  local name context dockerfile image file

  name="$(app_service_key "$rel")"
  image="$(project_image_base "$project")-${name}"
  dockerfile="${rel}/Dockerfile"

  # A workspace member's manifests live at the root.
  if app_is_workspace_member "$project" "$rel"; then
    context="."
  else
    context="$rel"
  fi

  [[ -f "${project}/${dockerfile}" ]] ||
    die "no Dockerfile at ${dockerfile} to build ${name} from"

  for file in "${BUILD_WORKFLOWS[@]}"; do
    append_image_target "${project}/${file}" "$name" "$image" "$context" "$dockerfile"
  done
}

append_image_target() {
  local -r file="$1" name="$2" image="$3" context="$4" dockerfile="$5"
  local current updated

  current="$(yq -r '[.jobs[] | select(has("with")) | .with.images] | .[0] // "[]"' "$file")"
  updated="$(jq -c --arg image "$image" --arg context "$context" \
    --arg dockerfile "$dockerfile" \
    '. + [{image: $image, context: $context, dockerfile: $dockerfile}]' \
    <<<"$current")" ||
    die "could not read the images array out of ${file}"

  IMAGES="$updated" yq --inplace \
    '(.jobs[] | select(has("with")) | .with.images) = strenv(IMAGES)' "$file" ||
    die "could not record ${name}'s image in ${file}"
}
