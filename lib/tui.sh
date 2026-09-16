# The interactive wizard's terminal layer: header, prompt, menu.
# shellcheck shell=bash
#
# Adapted from ~/.dotfiles/scripts/lib/menu.sh and lib/banner.sh, cut down to
# one choice per screen.

BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
CYAN="\033[36m"
RED="\033[31m"
RESET="\033[0m"

DEFAULT_TERM_COLS=80
DEFAULT_TERM_LINES=24

# Shorter than this, the header scrolls away and breaks _tui_render's
# cursor-up overwrite, so it collapses to one line.
MIN_TERM_LINES_FOR_HEADER=23

# 50ms, not 10: under autorepeat an arrow key's tail can arrive late, and a
# truncated sequence reads as a bare Esc that cancels the wizard.
ESC_SEQUENCE_TIMEOUT=0.05

# Autorepeat outruns the redraw loop, so a held key can leave a backlog.
KEY_DRAIN_TIMEOUT=0.001

# The terminal is taken for the whole run, not per screen: `read -s` silences
# only its own read, and keys held during a redraw would echo into the menu.
_TUI_STTY_SAVED=""

tui_begin() {
  [[ -t 0 ]] || return 0
  _TUI_STTY_SAVED="$(stty -g 2>/dev/null || true)"
  stty -echo 2>/dev/null || true
  tput civis 2>/dev/null || true
  trap 'tui_end' EXIT
  trap 'tui_end; exit 130' INT TERM
  tui_header
}

tui_end() {
  [[ -t 0 ]] || return 0
  local junk
  # shellcheck disable=SC2034 # junk is the read target, not read back
  while read -rsn1 -t "$KEY_DRAIN_TIMEOUT" junk 2>/dev/null; do :; done
  if [[ -n "$_TUI_STTY_SAVED" ]]; then
    stty "$_TUI_STTY_SAVED" 2>/dev/null || true
    _TUI_STTY_SAVED=""
  fi
  tput cnorm 2>/dev/null || true
}

# ANSI Shadow, written out: figlet does not ship the font, and a client machine
# has no figlet at all.
_TUI_LOGO=(
  '  ███████╗ ██████╗ █████╗ ███████╗███████╗ ██████╗ ██╗     ██████╗ '
  '  ██╔════╝██╔════╝██╔══██╗██╔════╝██╔════╝██╔═══██╗██║     ██╔══██╗'
  '  ███████╗██║     ███████║█████╗  █████╗  ██║   ██║██║     ██║  ██║'
  '  ███████║╚██████╗██║  ██║██║     ██║     ╚██████╔╝███████╗██████╔╝'
)
_TUI_LOGO_WIDTH=${#_TUI_LOGO[0]}

# Printed once and never repainted: nothing below may clear it. The wordmark is
# dropped rather than drawn as four ellipsised fragments when it does not fit.
tui_header() {
  local term_lines
  term_lines="$(tput lines 2>/dev/null || printf '%s\n' "$DEFAULT_TERM_LINES")"
  if ((term_lines < MIN_TERM_LINES_FOR_HEADER)); then
    printf '%b\n' "${BOLD}${GREEN}scaffold — project generator${RESET}"
    return
  fi

  local cols width
  cols="$(tput cols 2>/dev/null || printf '%s\n' "$DEFAULT_TERM_COLS")"
  width=$((cols - 1))

  _tui_header_edge '╭' '╮' 'Scaffold' "$width"
  _tui_header_row '' '' "$width"
  if ((width - 2 >= _TUI_LOGO_WIDTH)); then
    local line
    for line in "${_TUI_LOGO[@]}"; do
      _tui_header_row bold "$line" "$width"
    done
    _tui_header_row '' '' "$width"
  fi
  _tui_header_row '' '  Pick a stack — CI, containers and a release you can install' "$width"
  _tui_header_row '' '' "$width"
  _tui_header_row dim '  Up/down or type a letter to move' "$width"
  _tui_header_row dim '  Press Enter to select' "$width"
  _tui_header_row dim '  Press Esc to cancel' "$width"
  _tui_header_row '' '' "$width"
  _tui_header_edge '╰' '╯' 'Project generator' "$width"
  echo
}

_tui_header_edge() {
  local -r left="$1" right="$2" width="$4"
  local label="$3"
  local -r inner=$((width - 2))

  _tui_fit " ${label} " "$inner"
  label="$REPLY"
  local -r side=$(((inner - ${#label}) / 2))
  local -r extra=$((inner - ${#label} - side * 2))
  local l r
  printf -v l '%*s' "$side" ''
  l="${l// /─}"
  printf -v r '%*s' "$((side + extra))" ''
  r="${r// /─}"

  printf '%b\n' "${BOLD}${GREEN}${left}${l}${label}${r}${right}${RESET}"
}

# _tui_header_row [dim|bold] <text> <width>
_tui_header_row() {
  local -r style="$1" width="$3"
  local text="$2"
  local -r inner=$((width - 2))

  _tui_fit "$text" "$inner"
  text="$REPLY"
  local pad
  printf -v pad '%*s' "$((inner - ${#text}))" ''
  local styled="$text"
  [[ "$style" == "dim" ]] && styled="${DIM}${text}${RESET}"
  [[ "$style" == "bold" ]] && styled="${BOLD}${text}${RESET}"

  printf '%b\n' "${BOLD}${GREEN}│${RESET}${styled}${pad}${BOLD}${GREEN}│${RESET}"
}

tui_name_is_usable() {
  project_name_is_usable "$1"
}

# Echo stays off, as tui_begin left it: _tui_read_line prints each character.
tui_prompt_name() {
  local name
  # stdout is captured by the caller, so tput must write to stderr.
  tput cnorm >&2 2>/dev/null || true

  while true; do
    # Cyan closes on every exit from the read, Esc included.
    printf '%b' "${BOLD}? Project name: ${RESET}${CYAN}" >&2
    _tui_read_line || {
      printf '%b\n' "$RESET" >&2
      exit 130
    }
    printf '%b' "$RESET" >&2
    name="$REPLY"
    tui_name_is_usable "$name" && break
    printf '%b\n' "${RED}  ${PROJECT_NAME_RULE}: ${name}${RESET}" >&2
  done

  printf '\n' >&2

  tput civis >&2 2>/dev/null || true
  printf '%s\n' "$name"
}

# One line into REPLY, byte by byte, because `read -r` cannot see Esc. Returns 1
# on Esc or EOF. Not readline: Ctrl-W, Ctrl-U and left/right do nothing.
_tui_read_line() {
  local key
  REPLY=""
  while true; do
    IFS= read -rsn1 key || return 1
    case "$key" in
      "")
        printf '\n' >&2
        return 0
        ;;
      $'\x04')
        # Ctrl-D: byte-at-a-time reads never turn it into EOF.
        return 1
        ;;
      $'\x1b')
        if read -rsn2 -t "$ESC_SEQUENCE_TIMEOUT" key; then
          continue
        fi
        return 1
        ;;
      $'\x7f' | $'\b')
        [[ -n "$REPLY" ]] || continue
        REPLY="${REPLY%?}"
        printf '\b \b' >&2
        ;;
      *)
        # A stray control byte would land invisibly in the name.
        case "$key" in
          [[:print:]])
            REPLY+="$key"
            printf '%s' "$key" >&2
            ;;
        esac
        ;;
    esac
  done
}

# tui_select <prompt> <option>...
# Each option is value<TAB>meta. Leaves the value in TUI_CHOICE; returns 1 on
# Esc, so the caller decides what cancelling means.
tui_select() {
  local -r prompt="$1"
  shift
  local -a options=("$@")
  local cursor=0 key i value

  # The line above is the previous answer, which _tui_render must not back over.
  _TUI_RENDER_HEIGHT=0

  while true; do
    _tui_render "$prompt" "$cursor" "${options[@]}"
    IFS= read -rsn1 key || true

    case "$key" in
      $'\x1b')
        if read -rsn2 -t "$ESC_SEQUENCE_TIMEOUT" key; then
          case "$key" in
            "[A") cursor=$(((cursor - 1 + ${#options[@]}) % ${#options[@]})) ;;
            "[B") cursor=$(((cursor + 1) % ${#options[@]})) ;;
          esac
        else
          return 1
        fi
        ;;
      "")
        # shellcheck disable=SC2034 # read by the caller
        TUI_CHOICE="${options[$cursor]%%$'\t'*}"
        _tui_collapse "$prompt"
        return 0
        ;;
      *)
        # Type-to-jump: the walkthrough tells a reader to type "postgres".
        for i in "${!options[@]}"; do
          value="${options[$i]%%$'\t'*}"
          if [[ "${value,,}" == "${key,,}"* ]]; then
            cursor="$i"
            break
          fi
        done
        ;;
    esac
  done
}

# Replaces the rendered block with one answer line, so the next question prints
# beneath it. Padding stays outside the colour escapes, keeping styled
# whitespace out of the clipboard. TUI_ANSWER_COLUMN is set by the caller.
_tui_collapse() {
  local -r prompt="$1"

  printf '\033[%dA' "$_TUI_RENDER_HEIGHT"
  tput ed 2>/dev/null || true
  printf '  %b✔%b  %s%*s  %b%s%b\n' \
    "$GREEN" "$RESET" "$prompt" \
    "$((${TUI_ANSWER_COLUMN:-0} - ${#prompt}))" "" \
    "$CYAN" "$TUI_CHOICE" "$RESET"
}

# Rows stop one column short: reaching the last column costs a second screen row
# to resolve the pending wrap. No `clear`, which would take the header: each
# paint backs up over its own previous block.
_TUI_RENDER_HEIGHT=0

_tui_render() {
  local -r prompt="$1" cursor="$2"
  shift 2
  local -a options=("$@")
  local cols limit
  cols="$(tput cols 2>/dev/null || printf '%s\n' "$DEFAULT_TERM_COLS")"
  limit=$((cols - 1))

  ((_TUI_RENDER_HEIGHT > 0)) && printf '\033[%dA' "$_TUI_RENDER_HEIGHT"

  # The blank is part of the block, so collapsed answers end up contiguous.
  printf '%b\n' "\033[K"
  _tui_fit "$prompt" "$limit"
  printf '%b\n' "${BOLD}? ${REPLY}${RESET}\033[K"

  local i value meta pointer
  for i in "${!options[@]}"; do
    value="${options[$i]%%$'\t'*}"
    meta="${options[$i]#*$'\t'}"
    pointer=" "
    ((i == cursor)) && pointer="»"

    _tui_fit "$value" $((limit - 4))
    value="$REPLY"
    [[ -z "$meta" ]] || meta="${DIM} (${meta})${RESET}"

    if ((i == cursor)); then
      printf '%b\n' "  ${GREEN}${pointer} ${value}${RESET}${meta}\033[K"
    else
      printf '%b\n' "  ${pointer} ${value}${meta}\033[K"
    fi
  done

  printf '%b\n' "\033[K"
  _TUI_RENDER_HEIGHT=$((${#options[@]} + 3))
}

# Sets REPLY rather than printing: it runs per row per keypress, and a subshell
# fork there lags behind a held key.
_tui_fit() {
  local -r text="$1" limit="$2"
  if ((${#text} <= limit)); then
    REPLY="$text"
  elif ((limit <= 1)); then
    REPLY="${text:0:limit}"
  else
    REPLY="${text:0:limit-1}…"
  fi
}
