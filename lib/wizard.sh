# What the interactive wizard asks, and the command it builds.
# shellcheck shell=bash

WIZARD_ACTION_PROMPT='What do you want to do?'
WIZARD_VISIBILITY_PROMPT='Repository visibility'
WIZARD_SHAPE_PROMPT='What are you building?'

# Every kind wizard_questions can emit, for wizard_prompt_width.
WIZARD_QUESTION_KINDS=(web api app database cache)

# wizard_actions <inside-a-project:0|1>
# Outside a project, update and publish are not offered: a refusal the user
# cannot walk into beats one they can.
wizard_actions() {
  local -r inside_project="${1:-0}"

  printf 'new\tgenerate a project\n'
  [[ "$inside_project" == "1" ]] || return 0
  printf 'update\tbring this project up to this toolbox\n'
  printf 'publish\tcreate its GitHub repository and apply its settings\n'
}

# Private first: a client's project is the case this toolbox exists for.
wizard_visibilities() {
  printf 'private\tonly people you add can see it\n'
  printf 'public\tanyone can see it\n'
}

# wizard_questions accepts only these, so a shape added to one list and not the
# other fails a test.
wizard_shapes() {
  printf 'web+api\tseparate frontend and backend, one repository\n'
  printf 'app\tone application serving both pages and data\n'
  printf 'api\tbackend only\n'
  printf 'web\tfrontend only\n'
}

# In the order answers constrain each other. `web` asks no database: `scaffold
# new` refuses --db without a backend.
wizard_questions() {
  local -r shape="$1"

  grep -qx "$shape" <<<"$(wizard_shapes | cut -f1)" || die "unknown project shape: ${shape}"

  case "$shape" in
    web+api) printf 'web\napi\ndatabase\ncache\n' ;;
    app) printf 'app\ndatabase\ncache\n' ;;
    api) printf 'api\ndatabase\ncache\n' ;;
    web) printf 'web\n' ;;
    *) die "wizard_shapes lists ${shape} but wizard_questions has no case for it" ;;
  esac
}

wizard_prompt_for() {
  local -r kind="$1"

  case "$kind" in
    web) printf 'Frontend' ;;
    api) printf 'Backend' ;;
    app) printf 'Fullstack framework' ;;
    database) printf 'Database' ;;
    cache) printf 'Cache' ;;
    *) die "unknown question kind: ${kind}" ;;
  esac
}

# Measured, not hand-counted, so a new kind widens the answer column.
wizard_prompt_width() {
  local kind text width=${#WIZARD_SHAPE_PROMPT}

  ((${#WIZARD_ACTION_PROMPT} > width)) && width=${#WIZARD_ACTION_PROMPT}
  ((${#WIZARD_VISIBILITY_PROMPT} > width)) && width=${#WIZARD_VISIBILITY_PROMPT}
  for kind in "${WIZARD_QUESTION_KINDS[@]}"; do
    text="$(wizard_prompt_for "$kind")"
    ((${#text} > width)) && width=${#text}
  done
  printf '%s' "$width"
}

# wizard_options <listing> <kind>
# <listing> is cmd_list's output: the options come from what adapters and
# services declare, not a second copy.
wizard_options() {
  local -r listing="$1" kind="$2"

  case "$kind" in
    web | api | app)
      awk -F'\t' -v role="$kind" \
        '$2 == role { printf "%s\ttier %s\n", $1, $3 }' <<<"$listing"
      # `if`, not `&&`: as the branch's last command, `&&` would return 1
      # whenever kind is not web.
      if [[ "$kind" == "web" ]]; then
        printf 'none\tno frontend\n'
      fi
      ;;
    database)
      awk -F'\t' '$2 == "database" { printf "%s\t\n", $1 }' <<<"$listing"
      printf 'none\tno database service\n'
      ;;
    cache)
      awk -F'\t' '$2 == "cache" { printf "%s\t\n", $1 }' <<<"$listing"
      printf 'none\tno cache service\n'
      ;;
    *) die "unknown question kind: ${kind}" ;;
  esac
}

# cmd_new's unset-flag default moves first, so a plain Enter matches the flags.
wizard_order_options() {
  local -r kind="$1" listing="$2"
  local default="" line

  case "$kind" in
    database) default="$DEFAULT_DATABASE_SERVICE" ;;
    cache) default="none" ;;
  esac

  if [[ -z "$default" ]]; then
    wizard_options "$listing" "$kind"
    return
  fi

  while IFS= read -r line; do
    if [[ "${line%%$'\t'*}" == "$default" ]]; then
      printf '%s\n' "$line"
    fi
  done <<<"$(wizard_options "$listing" "$kind")"
  while IFS= read -r line; do
    if [[ "${line%%$'\t'*}" != "$default" ]]; then
      printf '%s\n' "$line"
    fi
  done <<<"$(wizard_options "$listing" "$kind")"
  # The loop's status is read's EOF failure.
  return 0
}

# wizard_new_args <kind=value>... — cmd_new's argv, one token per line.
wizard_new_args() {
  local pair kind value

  for pair in "$@"; do
    kind="${pair%%=*}"
    value="${pair#*=}"
    case "$kind" in
      web | api | app)
        if [[ "$value" != "none" ]]; then
          printf -- '--%s\n%s\n' "$kind" "$value"
        fi
        ;;
      database) printf -- '--db\n%s\n' "$value" ;;
      cache) printf -- '--cache\n%s\n' "$value" ;;
      *) die "unknown answer: ${pair}" ;;
    esac
  done
}

# Printed before the run, so the second project is scripted rather than clicked.
wizard_command() {
  local -r name="$1"
  shift
  local -a args
  mapfile -t args < <(wizard_new_args "$@")
  local out="scaffold new ${name}"
  ((${#args[@]} == 0)) || out+=" ${args[*]}"
  printf '%s\n' "$out"
}

# `!` in front: how this shell runs a line without leaving the prompt.
wizard_echo_command() {
  local -r command_line="$1"
  local token out="${CYAN}!${RESET}"
  for token in $command_line; do
    case "$token" in
      --* | scaffold) out+=" ${CYAN}${token}${RESET}" ;;
      *) out+=" ${token}" ;;
    esac
  done
  printf '%b\n' "$out" >&2
}
