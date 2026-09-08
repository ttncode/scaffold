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
  tui_header
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

# tui_header — the wizard's title box, printed once by tui_begin and never
# repainted: this is a transcript, not a screen, so nothing below it may ever
# clear or scroll it away.
#
# Box shape, edge colour and the one-column-short width are banner.sh's,
# reimplemented rather than sourced — scaffold has to run standalone on a
# client machine, the same reason the select loop reimplements menu.sh's.
#
# Collapses to one line under menu.sh's own threshold (TERM_LINES < 23): a
# terminal that short scrolls once the header and a question's screen don't
# both fit, and a scroll breaks tui_select's cursor-up overwrite math.
tui_header() {
  local term_lines; term_lines="$(tput lines 2>/dev/null || echo 24)"
  if (( term_lines < 23 )); then
    echo -e "${BOLD}${GREEN}scaffold — project generator${RESET}"
    return
  fi

  local cols width; cols="$(tput cols 2>/dev/null || echo 80)"
  width=$(( cols - 1 ))

  # Blank row, the wordmark, two-space indent, one hint per line, blank row,
  # then a blank line under the box: banner.sh's own layout, followed exactly
  # rather than approximated, because the two are meant to be recognisably
  # one family.
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

# The wordmark, in menu.sh's font: ANSI Shadow with its duplicated fourth row
# and its trailing shadow row dropped, which is the same four-row compression
# menu.sh applies to DOTFILE. Written out rather than generated — figlet
# does not ship this font, and a client machine has no figlet at all.
#
# _TUI_LOGO_WIDTH is checked before the rows are drawn because this wordmark
# is wider than DOTFILE's. banner.sh guarantees DOTFILE fits its own minimum
# width; nothing guarantees that here, and _tui_fit would otherwise hand back
# four separate ellipsised fragments, which reads as damage rather than as a
# logo. Below the threshold the box simply carries no wordmark.
_TUI_LOGO=(
  '  ███████╗ ██████╗ █████╗ ███████╗███████╗ ██████╗ ██╗     ██████╗ '
  '  ██╔════╝██╔════╝██╔══██╗██╔════╝██╔════╝██╔═══██╗██║     ██╔══██╗'
  '  ███████╗██║     ███████║█████╗  █████╗  ██║   ██║██║     ██║  ██║'
  '  ███████║╚██████╗██║  ██║██║     ██║     ╚██████╔╝███████╗██████╔╝'
)
_TUI_LOGO_WIDTH=${#_TUI_LOGO[0]}

# _tui_header_edge <left-corner> <right-corner> <label> <width> — banner.sh's
# _banner_edge, cut down to the one shape tui_header needs: a label centred
# in a horizontal rule, drawn once so it carries none of banner.sh's
# rebuild-on-resize bookkeeping.
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

# _tui_header_row [dim] <text> <width> — banner.sh's _banner_row, minus the
# plain/bold/blank styles it never uses here.
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

# tui_name_is_usable <name> — project_name_is_usable (lib/project.sh), so
# the prompt can reject a bad name before the rest of the wizard's screens
# are shown, rather than after init_project rejects it during generation.
tui_name_is_usable() {
  project_name_is_usable "$1"
}

# tui_prompt_name — reads a project name, re-asking until it satisfies
# tui_name_is_usable.
#
# Echo stays off, as tui_begin left it: _tui_read_line prints each character
# itself, so letting the tty echo as well would show every keystroke twice.
# The cursor is turned back on, though — tui_begin hides it for the menu
# screens, and a typed field needs a caret to type against.
tui_prompt_name() {
  local name
  # cmd_wizard reads this function back with `name="$(tui_prompt_name)"`,
  # capturing everything written to stdout — so tput's escape sequences go to
  # stderr, the same fd the rest of this prompt already writes to, or they'd
  # land inside $name instead of on the terminal.
  tput cnorm >&2 2>/dev/null || true

  while true; do
    printf '%b' "${BOLD}? Project name: ${RESET}" >&2
    _tui_read_line || { printf '\n' >&2; exit 130; }
    name="$REPLY"
    tui_name_is_usable "$name" && break
    printf '%b\n' "${RED}  ${PROJECT_NAME_RULE}: ${name}${RESET}" >&2
  done

  # A blank line between the name and the questions that follow it, so the
  # answered-question list below reads as its own block rather than as a
  # continuation of the field the user just typed in.
  printf '\n' >&2

  tput civis >&2 2>/dev/null || true
  printf '%s\n' "$name"
}

# _tui_read_line — one line of input into REPLY, byte by byte. Returns 1 on
# Esc or EOF.
#
# `read -r` cannot see Esc: the tty hands it a whole line, and Esc is just a
# byte inside it. Reading a byte at a time is what makes the header's
# "Press Esc to cancel" true on this screen too.
#
# The cost is real: this is not readline. Ctrl-W, Ctrl-U and the left/right
# arrows do nothing, and Backspace is handled below because nothing else
# would.
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
        # which the printable filter below would silently discard, leaving
        # the prompt spinning. tests/wizard.bats has asserted this exit since
        # before the byte-at-a-time read existed, and caught it immediately.
        return 1
        ;;
      $'\x1b')
        # An escape sequence (an arrow key) arrives as Esc plus more bytes.
        # Draining them distinguishes a real Esc, which arrives alone, from
        # an arrow — the same 50ms window and the same reason as tui_select.
        if read -rsn2 -t 0.05 key; then
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
        # land in the name, where project_name_is_usable would reject it with
        # a message about a character the user cannot see.
        case "$key" in
          [[:print:]]) REPLY+="$key"; printf '%s' "$key" >&2 ;;
        esac
        ;;
    esac
  done
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

# _tui_render <prompt> <cursor> <option>...
# Every row is cut one column short of the terminal width: a row that reaches
# the last column leaves the cursor in the terminal's pending-wrap state, and
# resolving that costs a second screen row.
#
# No `clear`: this is a transcript now, not a screen, and a `clear` here
# would take the header above it with it. The first paint of a question has
# no block above it yet to preserve, so it prints in place; every later paint
# (an arrow key moving the cursor) backs up over its own last block with
# \033[<n>A and overwrites it — never touching a line outside that block.
_TUI_RENDER_HEIGHT=0

_tui_render() {
  local prompt="$1" cursor="$2"; shift 2
  local -a options=("$@")
  local cols limit
  cols="$(tput cols 2>/dev/null || echo 80)"
  limit=$(( cols - 1 ))

  (( _TUI_RENDER_HEIGHT > 0 )) && printf '\033[%dA' "$_TUI_RENDER_HEIGHT"

  _tui_fit "$prompt" "$limit"
  echo -e "${BOLD}? ${REPLY}${RESET}\033[K"
  echo -e "\033[K"
  local height=2

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
    height=$(( height + 1 ))
  done

  echo -e "\033[K"
  _TUI_RENDER_HEIGHT=$(( height + 1 ))
}

# tui_select <prompt> <option>...
# One single-select screen. Each <option> is value<TAB>meta. Leaves the chosen
# value in TUI_CHOICE; returns 1 on Esc rather than dying, so the caller
# decides what cancelling the wizard means.
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
        # Collapse the block _tui_render just painted into the one line a
        # normal transcript would have — the next question then prints
        # straight underneath it instead of onto a screen it has to clear.
        printf '\033[%dA' "$_TUI_RENDER_HEIGHT"
        tput ed 2>/dev/null || true
        echo -e "${GREEN}✔${RESET}  ${prompt}  ${TUI_CHOICE}"
        return 0
        ;;
      *)
        # Type-to-jump: the walkthrough tells a first-time reader to answer
        # "postgres", and typing that word used to be silently discarded
        # keystroke by keystroke, Enter then accepting whatever was already
        # highlighted — no error, nothing on screen. One keystroke moves the
        # cursor to the first option starting with it, so typing does what
        # the document already led the reader to expect.
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
