# ═══════════════════════════════════════════════════════════════════════════
# Script      : lib/tui.sh
# Description : The interactive wizard's terminal layer: header, prompt, menu.
# Author      : ttncode
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck shell=bash
#
# Adapted from ~/.dotfiles/scripts/lib/menu.sh (the select loop, the
# echo/cursor handling) and lib/banner.sh (the one-column-short row width),
# with that menu's boolean-per-row selection removed: this is one choice per
# screen, so SELECTED[] becomes a single cursor index and space is not a key.

BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
CYAN="\033[36m"
RED="\033[31m"
RESET="\033[0m"

DEFAULT_TERM_COLS=80
DEFAULT_TERM_LINES=24

# Below this the header collapses to one line: a terminal that short scrolls
# once the header and a question's screen don't both fit, and a scroll breaks
# _tui_render's cursor-up overwrite math. menu.sh's own threshold.
MIN_TERM_LINES_FOR_HEADER=23

# An escape sequence (an arrow key) arrives as Esc plus more bytes; a bare Esc
# arrives alone. 50ms, not 10: under autorepeat the rest of a sequence can
# arrive late, and a truncated read reads as a bare Esc — which would cancel
# the wizard mid-scroll.
ESC_SEQUENCE_TIMEOUT=0.05

# Autorepeat outruns the redraw loop, so a held key can leave a backlog.
KEY_DRAIN_TIMEOUT=0.001

# ─── the terminal session ──────────────────────────────────────────────────

# tui_begin / tui_end take and restore the terminal for the wizard's whole run,
# not per screen: `read -s` only silences the one read it wraps, and a key held
# down keeps sending bytes while a redraw is in flight, which the tty echoes
# into the middle of the menu.
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
  tui_header
}

tui_end() {
  [ -t 0 ] || return 0
  # Drained here rather than left to spill into whatever the caller reads or
  # prints next.
  local junk
  # shellcheck disable=SC2034 # junk is the read target, not read back
  while read -rsn1 -t "$KEY_DRAIN_TIMEOUT" junk 2>/dev/null; do :; done
  if [ -n "$_TUI_STTY_SAVED" ]; then
    stty "$_TUI_STTY_SAVED" 2>/dev/null || true
    _TUI_STTY_SAVED=""
  fi
  tput cnorm 2>/dev/null || true
}

# ─── the header ────────────────────────────────────────────────────────────

# The wordmark, in menu.sh's font: ANSI Shadow with its duplicated fourth row
# and trailing shadow row dropped. Written out rather than generated — figlet
# does not ship this font, and a client machine has no figlet at all.
_TUI_LOGO=(
  '  ███████╗ ██████╗ █████╗ ███████╗███████╗ ██████╗ ██╗     ██████╗ '
  '  ██╔════╝██╔════╝██╔══██╗██╔════╝██╔════╝██╔═══██╗██║     ██╔══██╗'
  '  ███████╗██║     ███████║█████╗  █████╗  ██║   ██║██║     ██║  ██║'
  '  ███████║╚██████╗██║  ██║██║     ██║     ╚██████╔╝███████╗██████╔╝'
)
_TUI_LOGO_WIDTH=${#_TUI_LOGO[0]}

# tui_header — printed once by tui_begin and never repainted: this is a
# transcript, not a screen, so nothing below it may clear or scroll it away.
# The wordmark is width-checked before it is drawn, because below that _tui_fit
# hands back four ellipsised fragments, which reads as damage, not a logo.
tui_header() {
  local term_lines; term_lines="$(tput lines 2>/dev/null || echo "$DEFAULT_TERM_LINES")"
  if (( term_lines < MIN_TERM_LINES_FOR_HEADER )); then
    echo -e "${BOLD}${GREEN}scaffold — project generator${RESET}"
    return
  fi

  local cols width; cols="$(tput cols 2>/dev/null || echo "$DEFAULT_TERM_COLS")"
  width=$(( cols - 1 ))

  _tui_header_edge '╭' '╮' 'Scaffold' "$width"
  _tui_header_row '' '' "$width"
  if (( width - 2 >= _TUI_LOGO_WIDTH )); then
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

# _tui_header_edge <left-corner> <right-corner> <label> <width>
# banner.sh's _banner_edge, cut down to a label centred in a horizontal rule,
# drawn once so it carries none of that file's rebuild-on-resize bookkeeping.
_tui_header_edge() {
  local left="$1" right="$2" label="$3" width="$4"
  local inner=$(( width - 2 ))

  _tui_fit " ${label} " "$inner"
  label="$REPLY"
  local side=$(( (inner - ${#label}) / 2 ))
  local extra=$(( inner - ${#label} - side * 2 ))
  local l r
  printf -v l '%*s' "$side" ''; l="${l// /─}"
  printf -v r '%*s' "$(( side + extra ))" ''; r="${r// /─}"

  echo -e "${BOLD}${GREEN}${left}${l}${label}${r}${right}${RESET}"
}

# _tui_header_row [dim|bold] <text> <width> — banner.sh's _banner_row, minus
# the styles it never uses here.
_tui_header_row() {
  local style="$1" text="$2" width="$3"
  local inner=$(( width - 2 ))

  _tui_fit "$text" "$inner"
  text="$REPLY"
  local pad; printf -v pad '%*s' "$(( inner - ${#text} ))" ''
  local styled="$text"
  [ "$style" = dim ] && styled="${DIM}${text}${RESET}"
  [ "$style" = bold ] && styled="${BOLD}${text}${RESET}"

  echo -e "${BOLD}${GREEN}│${RESET}${styled}${pad}${BOLD}${GREEN}│${RESET}"
}

# ─── the name prompt ───────────────────────────────────────────────────────

# The same rule init_project enforces, so the prompt rejects a bad name before
# the wizard's remaining screens rather than after generation starts.
tui_name_is_usable() {
  project_name_is_usable "$1"
}

# tui_prompt_name — reads a project name, re-asking until it is usable. Echo
# stays off, as tui_begin left it: _tui_read_line prints each character itself.
tui_prompt_name() {
  local name
  # cmd_wizard captures this function's stdout, so tput's escape sequences go
  # to stderr with the rest of the prompt, or they'd land inside $name.
  tput cnorm >&2 2>/dev/null || true

  while true; do
    # Cyan opens before the read and closes after every exit from it, Esc
    # included: a cancelled wizard must not leave the terminal painted.
    printf '%b' "${BOLD}? Project name: ${RESET}${CYAN}" >&2
    _tui_read_line || { printf '%b\n' "$RESET" >&2; exit 130; }
    printf '%b' "$RESET" >&2
    name="$REPLY"
    tui_name_is_usable "$name" && break
    printf '%b\n' "${RED}  ${PROJECT_NAME_RULE}: ${name}${RESET}" >&2
  done

  # A blank line, so the answered-question list below reads as its own block
  # rather than as a continuation of the field just typed in.
  printf '\n' >&2

  tput civis >&2 2>/dev/null || true
  printf '%s\n' "$name"
}

# _tui_read_line — one line of input into REPLY, byte by byte. Returns 1 on Esc
# or EOF.
#
# `read -r` cannot see Esc: the tty hands it a whole line, and Esc is just a
# byte inside it. The cost is real — this is not readline: Ctrl-W, Ctrl-U and
# the left/right arrows do nothing.
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
        # Ctrl-D. Reading a byte at a time means the tty never turns it into
        # EOF the way a line-mode `read` would — it arrives as a plain 0x04,
        # which the printable filter below would discard, leaving the prompt
        # spinning.
        return 1
        ;;
      $'\x1b')
        if read -rsn2 -t "$ESC_SEQUENCE_TIMEOUT" key; then
          continue
        fi
        return 1
        ;;
      $'\x7f'|$'\b')
        [ -n "$REPLY" ] || continue
        REPLY="${REPLY%?}"
        # Back up, overwrite with a space, back up again: the terminal has
        # already echoed the character being removed.
        printf '\b \b' >&2
        ;;
      *)
        # Printable only. A stray control byte would otherwise be echoed and
        # land in the name, where project_name_is_usable would reject it with a
        # message about a character the user cannot see.
        case "$key" in
          [[:print:]]) REPLY+="$key"; printf '%s' "$key" >&2 ;;
        esac
        ;;
    esac
  done
}

# ─── the select screen ─────────────────────────────────────────────────────

# tui_select <prompt> <option>...
# One single-select screen. Each <option> is value<TAB>meta. Leaves the chosen
# value in TUI_CHOICE; returns 1 on Esc rather than dying, so the caller decides
# what cancelling the wizard means.
tui_select() {
  local prompt="$1"; shift
  local -a options=("$@")
  local cursor=0 key i value

  # A fresh question has no block of its own above it yet — the line right
  # above is the previous question's collapsed answer (or the header), and
  # _tui_render must not back up over that.
  _TUI_RENDER_HEIGHT=0

  while true; do
    _tui_render "$prompt" "$cursor" "${options[@]}"
    IFS= read -rsn1 key || true

    case "$key" in
      $'\x1b')
        if read -rsn2 -t "$ESC_SEQUENCE_TIMEOUT" key; then
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
        # Collapse the block _tui_render just painted into the one line a
        # normal transcript would have — the next question then prints straight
        # underneath it instead of onto a screen it has to clear.
        printf '\033[%dA' "$_TUI_RENDER_HEIGHT"
        tput ed 2>/dev/null || true
        # Padding outside the colour escapes, so no run of styled whitespace
        # lands on the line or in the clipboard. TUI_ANSWER_COLUMN is set by the
        # caller, which is the only thing that knows every question it will ask.
        printf '  %b✔%b  %s%*s  %b%s%b\n' \
          "$GREEN" "$RESET" "$prompt" \
          "$(( ${TUI_ANSWER_COLUMN:-0} - ${#prompt} ))" "" \
          "$CYAN" "$TUI_CHOICE" "$RESET"
        return 0
        ;;
      *)
        # Type-to-jump: the walkthrough tells a first-time reader to answer
        # "postgres", so typing that word has to move the cursor rather than be
        # discarded keystroke by keystroke.
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

# _tui_render <prompt> <cursor> <option>...
# Every row is cut one column short of the terminal width: a row reaching the
# last column leaves the cursor in the pending-wrap state, which costs a second
# screen row to resolve.
#
# No `clear` — it would take the header with it. Every paint after the first
# backs up over its own last block with \033[<n>A and overwrites it.
_TUI_RENDER_HEIGHT=0

_tui_render() {
  local prompt="$1" cursor="$2"; shift 2
  local -a options=("$@")
  local cols limit
  cols="$(tput cols 2>/dev/null || echo "$DEFAULT_TERM_COLS")"
  limit=$(( cols - 1 ))

  (( _TUI_RENDER_HEIGHT > 0 )) && printf '\033[%dA' "$_TUI_RENDER_HEIGHT"

  # The blank belongs to the question, not to the transcript above it: the
  # collapse in tui_select rewinds over everything this function printed, so the
  # answered lines end up contiguous while the live question always has air
  # above it.
  echo -e "\033[K"
  _tui_fit "$prompt" "$limit"
  echo -e "${BOLD}? ${REPLY}${RESET}\033[K"

  local i value meta pointer
  for i in "${!options[@]}"; do
    value="${options[$i]%%$'\t'*}"
    meta="${options[$i]#*$'\t'}"
    pointer=" "
    [ "$i" -eq "$cursor" ] && pointer="»"

    _tui_fit "$value" $(( limit - 4 ))
    value="$REPLY"
    # An empty meta means the caller had nothing to add beyond the value itself
    # — "mysql ()" would say less than plain "mysql". Dim, because it qualifies
    # the choice rather than being part of it.
    [ -z "$meta" ] || meta="${DIM} (${meta})${RESET}"

    if [ "$i" -eq "$cursor" ]; then
      echo -e "  ${GREEN}${pointer} ${value}${RESET}${meta}\033[K"
    else
      echo -e "  ${pointer} ${value}${meta}\033[K"
    fi
  done

  echo -e "\033[K"
  _TUI_RENDER_HEIGHT=$(( ${#options[@]} + 3 ))
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
