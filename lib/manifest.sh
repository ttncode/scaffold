# shellcheck shell=bash
#
# What a project publishes and what CI runs over, both derived from one list
# rather than written twice.
#
# `config_roots` in mise.toml is the manifest (ADR-0013): register_config_root
# is the single place a root enters it, and sync_ci_roots copies it into the CI
# workflow so the two cannot disagree. register_image_target does the same job
# for the applications a project builds images from (ADR-0022).

# register_config_root <project> <relative-path>
register_config_root() {
  local project="$1" root="$2"
  local file="${project}/mise.toml"

  # Both halves below are anchored on the exact formatting mise.root.toml
  # ships, and both used to no-op silently when it did not match — an inline
  # `config_roots = ["docs"]` left the roots half untouched while the checklist
  # half succeeded, and the project shipped a CI matrix of [] that passed green
  # while running nothing. Verified rather than assumed, on each half.
  if ! grep -q "^  \"${root}\",\$" "$file"; then
    awk -v root="$root" '
      { print }
      /^config_roots = \[$/ { printf "  \"%s\",\n", root }
    ' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    grep -q "^  \"${root}\",\$" "$file" \
      || die "could not register ${root}: no 'config_roots = [' line in ${file} — has it been reformatted?"
  fi

  # the root [tasks.checklist] (pre-push's own gate) must run every config
  # root's own checklist, not just docs' — register_config_root is the one
  # place every config root passes through, so this stays in lockstep with
  # config_roots itself instead of being a second list a later task forgets
  # to update.
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
# collect_config_roots <project>
collect_config_roots() {
  sed -n '/^config_roots = \[$/,/^\]$/p' "${1}/mise.toml" \
    | sed -n 's/^  "\(.*\)",$/\1/p'
}
# sync_ci_roots <project> — the ci workflow's matrix input is derived from the
# manifest so the two can never disagree.
sync_ci_roots() {
  local project="$1" json
  json="$(collect_config_roots "$project" | jq -R . | jq -sc .)"
  sed -i.bak "s|^      roots: .*|      roots: '${json}'|" \
    "${project}/.github/workflows/ci.yml"
  rm -f "${project}/.github/workflows/ci.yml.bak"
}
# register_image_target <project> <rel> — add one entry to the `images` array
# build.yml and release.yml pass to the reusable workflow (ADR-0022).
#
# This replaced a pair of functions that wrote one context/dockerfile pair per
# project: every applied adapter overwrote the previous one, so a project with
# a web and an api application published only whichever was applied last, and
# the other passed CI and was never built at all.
#
# Called after the workspace decision is settled, not during it: an
# application's build context depends on whether it resolves through the
# shared pnpm workspace or owns its manifests, which cmd_new decides only once
# every adapter has been applied.
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

  for file in "${project}/.github/workflows/build.yml" \
              "${project}/.github/workflows/release.yml"; do
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
