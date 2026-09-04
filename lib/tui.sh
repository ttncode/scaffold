# shellcheck shell=bash
# The interactive wizard's terminal layer. Adapted from
# ~/.dotfiles/scripts/lib/menu.sh (the select loop, the echo/cursor handling)
# and lib/banner.sh (the one-column-short row width), with that menu's
# boolean-per-row selection removed: this is one choice per screen, so
# SELECTED[] becomes a single cursor index and space is not a key.

BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"

# tui_begin / tui_end — take and restore the terminal for the wizard's whole
# run, not per screen.
#
# `read -s` only silences the one read it wraps; a key held down keeps sending
# bytes while a redraw is in flight, and the tty echoes them into the middle
# of the menu. Turning echo off once, for the session, is what menu.sh does
# instead.
_TUI_STTY_SAVED=""

tui_begin() {
  [ -t 0 ] || return 0
  _TUI_STTY_SAVED="$(stty -g 2>/dev/null || true)"
  stty -echo 2>/dev/null || true
  tput civis 2>/dev/null || true
  # Esc and Ctrl-C both have to leave the terminal as they found it; a trap is
  # the only thing that fires on both a normal return and a signal.
  trap 'tui_end' EXIT
  trap 'tui_end; exit 130' INT TERM
}

tui_end() {
  [ -t 0 ] || return 0
  # Autorepeat outruns the redraw loop, so a held key can leave a backlog.
  # Drain it here rather than let it spill into whatever the caller reads or
  # prints next.
  local junk
  # shellcheck disable=SC2034 # junk is the read target, not read back
  while read -rsn1 -t 0.001 junk 2>/dev/null; do :; done
  if [ -n "$_TUI_STTY_SAVED" ]; then
    stty "$_TUI_STTY_SAVED" 2>/dev/null || true
    _TUI_STTY_SAVED=""
  fi
  tput cnorm 2>/dev/null || true
}

# tui_name_is_usable <name> — project_name_is_usable (lib/project.sh), so
# the prompt can reject a bad name before the rest of the wizard's screens
# are shown, rather than after init_project rejects it during generation.
tui_name_is_usable() {
  project_name_is_usable "$1"
}

# tui_prompt_name — reads a project name, re-asking until it satisfies
# tui_name_is_usable. Manages its own echo state rather than relying on
# tui_begin's, because a name is typed and has to be seen, unlike a menu
# selection. Same for the cursor: tui_begin hides it for the menu screens,
# but a name is typed, so this screen needs a caret.
tui_prompt_name() {
  local name saved
  saved="$(stty -g 2>/dev/null || true)"
  stty echo 2>/dev/null || true
  # cmd_wizard reads this function back with `name="$(tui_prompt_name)"`,
  # capturing everything written to stdout — so tput's escape sequences go to
  # stderr, the same fd the rest of this prompt already writes to, or they'd
  # land inside $name instead of on the terminal.
  tput cnorm >&2 2>/dev/null || true

  while true; do
    printf '%b' "${BOLD}? Project name: ${RESET}" >&2
    # EOF (Ctrl-D) leaves $name empty and would otherwise re-prompt forever;
    # exit the way Esc does elsewhere and let the EXIT trap restore the tty.
    IFS= read -r name || { printf '\n' >&2; exit 130; }
    tui_name_is_usable "$name" && break
    printf '%b\n' "${RED}  ${PROJECT_NAME_RULE}: ${name}${RESET}" >&2
  done

  [ -n "$saved" ] && stty "$saved" 2>/dev/null
  tput civis >&2 2>/dev/null || true
  printf '%s\n' "$name"
}

# _tui_fit <text> <limit> — sets REPLY rather than echoing, so it can run once
# per row per keypress without forking a subshell while a held key is still
# sending bytes at the (echo-disabled) tty.
_tui_fit() {
  local text="$1" limit="$2"
  if (( ${#text} <= limit )); then
    REPLY="$text"
  elif (( limit <= 1 )); then
    REPLY="${text:0:limit}"
  else
    REPLY="${text:0:limit-1}…"
  fi
}

# _tui_render <prompt> <footer> <cursor> <option>...
# Every row is cut one column short of the terminal width: a row that reaches
# the last column leaves the cursor in the terminal's pending-wrap state, and
# resolving that costs a second screen row.
_tui_render() {
  local prompt="$1" footer="$2" cursor="$3"; shift 3
  local -a options=("$@")
  local cols limit
  cols="$(tput cols 2>/dev/null || echo 80)"
  limit=$(( cols - 1 ))

  clear
  _tui_fit "$prompt" "$limit"
  echo -e "${BOLD}? ${REPLY}${RESET}\033[K"
  echo -e "\033[K"

  local i value meta pointer label
  for i in "${!options[@]}"; do
    value="${options[$i]%%$'\t'*}"
    meta="${options[$i]#*$'\t'}"
    pointer=" "
    [ "$i" -eq "$cursor" ] && pointer="»"

    # An empty meta means the caller had nothing to add beyond the value
    # itself (wizard_options' database/cache rows) — "mysql ()" would say
    # less than plain "mysql".
    if [ -n "$meta" ]; then
      label="${value} (${meta})"
    else
      label="$value"
    fi
    _tui_fit "$label" $(( limit - 2 ))
    if [ "$i" -eq "$cursor" ]; then
      echo -e " ${GREEN}${pointer} ${REPLY}${RESET}\033[K"
    else
      echo -e " ${pointer} ${REPLY}\033[K"
    fi
  done

  echo -e "\033[K"
  _tui_fit "$footer" "$limit"
  echo -e "${DIM}${REPLY}${RESET}\033[K"
}

# tui_select <prompt> <footer> <option>...
# One single-select screen. Each <option> is value<TAB>meta. Leaves the chosen
# value in TUI_CHOICE; returns 1 on Esc rather than dying, so the caller
# decides what cancelling the wizard means.
tui_select() {
  local prompt="$1" footer="$2"; shift 2
  local -a options=("$@")
  local cursor=0 key

  while true; do
    _tui_render "$prompt" "$footer" "$cursor" "${options[@]}"
    IFS= read -rsn1 key || true

    case "$key" in
      $'\x1b')
        # 50ms, not 10: under autorepeat the rest of an arrow sequence can
        # arrive late, and a truncated read here reads as a bare Esc — which
        # would cancel the wizard mid-scroll.
        if read -rsn2 -t 0.05 key; then
          case "$key" in
            "[A") cursor=$(( (cursor - 1 + ${#options[@]}) % ${#options[@]} )) ;;
            "[B") cursor=$(( (cursor + 1) % ${#options[@]} )) ;;
          esac
        else
          return 1
        fi
        ;;
      "")
        # shellcheck disable=SC2034 # read by the caller
        TUI_CHOICE="${options[$cursor]%%$'\t'*}"
        return 0
        ;;
    esac
  done
}
