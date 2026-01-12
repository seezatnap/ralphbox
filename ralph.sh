#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Claude <-> Codex alternating loop runner + split-pane TUI
#
# Usage:
#   ./loop.sh [options] [prompt_file] [iteration_count]
#
# Alternation (default START_ENGINE=claude):
#   Iter 1: Claude
#   Iter 2: Codex
#   Iter 3: Claude
#   ...
#
# Env overrides:
#   ITERATION_COUNT=50
#   PROMPT_FILE=loop/prompt.md
#   LOG_FILE=loop/loop.log
#   ROTATE_LOG=1                 # rotate existing log instead of truncating
#   CONTINUE_ON_ERROR=1          # set to 0 to stop on a failed iteration (default: continue)
#   NO_FIGLET=0                  # set to 1 to disable figlet banners
#   NO_UI=0                      # set to 1 to disable the TUI panes
#   START_ENGINE=claude          # set to "claude" or "codex"
#   ENGINES=claude,codex         # which engines to run: "claude", "codex", or "claude,codex"
#
# Codex:
#   CODEX_MODEL=gpt-5.2-codex
#   CODEX_CMD=codex
#
# Claude:
#   CLAUDE_CMD=claude
#   # If you want to change Claude args, edit run_claude_once()
# ------------------------------------------------------------------------------

# --- helpers -----------------------------------------------------------------

die() { printf "Error: %s\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

show_help() {
  cat <<'EOF'
Usage: ./ralph.sh [OPTIONS] [prompt_file] [iteration_count]

Alternating Claude <-> Codex loop runner with split-pane TUI.

Arguments:
  prompt_file       Path to prompt file (default: loop/prompt.md)
  iteration_count   Number of iterations to run (default: 50)

Options:
  -h, --help        Show this help message and exit
  --init            Create loop/ directory and starter prompt.md file
  --start ENGINE    Start with engine: "claude" or "codex"
  --models MODELS   Which models to run: "claude", "codex", or "claude,codex" (default)
  --disable-danger  Disable dangerous CLI flags for Claude/Codex (for local debug)

Environment variables:
  ITERATION_COUNT=50           Number of iterations
  PROMPT_FILE=loop/prompt.md   Path to prompt file
  LOG_FILE=loop/loop.log       Path to log file
  ROTATE_LOG=1                 Rotate existing log instead of truncating
  CONTINUE_ON_ERROR=1          Set to 0 to stop on failed iteration (default: continue)
  NO_FIGLET=0                  Set to 1 to disable figlet banners
  NO_UI=0                      Set to 1 to disable the TUI panes
  START_ENGINE=claude          Starting engine: "claude" or "codex"
  ENGINES=claude,codex         Which engines to run: "claude", "codex", or "claude,codex"
  CODEX_MODEL=gpt-5.2-codex    Model for Codex
  CODEX_CMD=codex              Codex command
  DISABLE_DANGER=0             Set to 1 or use --disable-danger to skip dangerous flags
  CLAUDE_CMD=claude            Claude command

Examples:
  ./ralph.sh                           # Use defaults (alternates claude/codex)
  ./ralph.sh --models claude           # Only run Claude
  ./ralph.sh --models codex            # Only run Codex
  ./ralph.sh --start codex             # Start with Codex (alternating)
  ./ralph.sh my-prompt.md              # Custom prompt file
  ./ralph.sh my-prompt.md 10           # Custom prompt, 10 iterations
  CONTINUE_ON_ERROR=0 ./ralph.sh       # Stop on first failure
EOF
  exit 0
}

do_init() {
  local dir="loop"
  local prompt_file="$dir/prompt.md"

  # Initialize git repo if not already one
  if [[ -d ".git" ]]; then
    printf "Git repository already initialized.\n"
  else
    git init
    printf "Initialized git repository.\n"
  fi

  if [[ -d "$dir" ]]; then
    printf "Directory '%s' already exists.\n" "$dir"
  else
    mkdir -p "$dir"
    printf "Created directory: %s\n" "$dir"
  fi

  if [[ -f "$prompt_file" ]]; then
    printf "Prompt file '%s' already exists, skipping.\n" "$prompt_file"
  else
    cat > "$prompt_file" <<'PROMPT'
# Task

Describe what you want Claude and Codex to work on here.

## Context

- Add any relevant context
- File paths, requirements, constraints

## Goals

1. First goal
2. Second goal
3. ...
PROMPT
    printf "Created starter prompt: %s\n" "$prompt_file"
  fi

  printf "\nReady! Edit %s and run: ./ralph.sh\n" "$prompt_file"
  exit 0
}

# --- args / config ------------------------------------------------------------

SHOW_HELP=0
SHOW_INIT=0
START_ENGINE="${START_ENGINE:-claude}"
ENGINES="${ENGINES:-claude,codex}"
DISABLE_DANGER="${DISABLE_DANGER:-0}"
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      SHOW_HELP=1
      shift
      ;;
    --init)
      SHOW_INIT=1
      shift
      ;;
    --start)
      [[ $# -ge 2 ]] || die "Missing value for --start (expected 'claude' or 'codex')"
      START_ENGINE="$2"
      shift 2
      ;;
    --start=*)
      START_ENGINE="${1#*=}"
      shift
      ;;
    --models)
      [[ $# -ge 2 ]] || die "Missing value for --models (expected 'claude', 'codex', or 'claude,codex')"
      ENGINES="$2"
      shift 2
      ;;
    --models=*)
      ENGINES="${1#*=}"
      shift
      ;;
    --disable-danger)
      DISABLE_DANGER=1
      shift
      ;;
    --)
      shift
      POSITIONAL_ARGS+=("$@")
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

ITERATION_COUNT="${ITERATION_COUNT:-50}"
PROMPT_FILE="${PROMPT_FILE:-loop/prompt.md}"
if [[ ${#POSITIONAL_ARGS[@]} -ge 1 ]]; then
  PROMPT_FILE="${POSITIONAL_ARGS[0]}"
fi
if [[ ${#POSITIONAL_ARGS[@]} -ge 2 ]]; then
  ITERATION_COUNT="${POSITIONAL_ARGS[1]}"
fi

LOG_FILE="${LOG_FILE:-loop/loop.log}"
ROTATE_LOG="${ROTATE_LOG:-1}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-1}"
NO_FIGLET="${NO_FIGLET:-0}"
NO_UI="${NO_UI:-0}"

CODEX_CMD="${CODEX_CMD:-codex}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.2-codex}"

CLAUDE_CMD="${CLAUDE_CMD:-claude}"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
SCRIPT_PID="$$"
INTERRUPTED=0

# Cross-platform ISO 8601 timestamp (works on macOS and Linux)
iso_timestamp() {
  if date -Is >/dev/null 2>&1; then
    date -Is
  else
    # macOS/BSD fallback
    date -u +"%Y-%m-%dT%H:%M:%S%z"
  fi
}

# Now that functions are defined, handle --help and --init if requested
[[ "$SHOW_HELP" == "1" ]] && show_help
[[ "$SHOW_INIT" == "1" ]] && do_init

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf "%s" "$s"
}

log_json() {
  # Skip logging if log directory doesn't exist yet (early exit before setup)
  [[ -d "$(dirname "$LOG_FILE")" ]] || return 0

  local type="$1"; shift
  local msg="$1"; shift || true
  local extra="${1:-}"

  local msg_esc; msg_esc="$(json_escape "$msg")"
  if [[ -n "$extra" ]]; then
    printf '{"type":"%s","ts":"%s","run_id":"%s","pid":%s,"message":"%s",%s}\n' \
      "$type" "$(iso_timestamp)" "$RUN_ID" "$SCRIPT_PID" "$msg_esc" "$extra" >>"$LOG_FILE"
  else
    printf '{"type":"%s","ts":"%s","run_id":"%s","pid":%s,"message":"%s"}\n' \
      "$type" "$(iso_timestamp)" "$RUN_ID" "$SCRIPT_PID" "$msg_esc" >>"$LOG_FILE"
  fi
}

fmt_hhmmss() {
  local total="$1"
  local h=$(( total / 3600 ))
  local m=$(( (total % 3600) / 60 ))
  local s=$(( total % 60 ))
  printf "%02d:%02d:%02d" "$h" "$m" "$s"
}

print_big() {
  local text="$1"
  if [[ "$NO_FIGLET" == "1" ]] || ! have figlet; then
    printf "    %s\n" "$text"
    return 0
  fi
  (figlet -f doh "$text" | sed -E '/^[[:space:]]*$/d' | sed 's/^/    /') || true
}

banner_line() {
  printf '\n\n'
  printf '%0.s▄' $(seq 1 80)
  printf '\n\n'
}

# --- UI (split panes) ---------------------------------------------------------
# Layout (top to bottom):
#   Row 0:              Fixed status bar (iteration, engine, status, elapsed time)
#   Rows 1-TOP_END:     Top pane (important status items with colored backgrounds)
#   Row SEPARATOR:      Divider line
#   Rows BOTTOM_START+: Bottom pane (detailed output, scrolling)

UI_ENABLED=0
UI_TTY_FD=3
TERM_COLS=0
TERM_LINES=0

# Row positions
STATUS_BAR_ROW=0
PANE_TOP_START=1
PANE_TOP_END=0
PANE_SEPARATOR=0
PANE_BOTTOM_START=0
PANE_BOTTOM_END=0

# For alternating status line colors
STATUS_ALT=0
# Track how many status lines have been added to top pane (for partial background fill)
TOP_PANE_LINE_COUNT=0

# Color codes
C_RESET=""
C_BOLD=""
C_DIM=""
# Status bar colors
C_STATUSBAR_BG=""
C_STATUSBAR_FG=""
# Top pane alternating colors
UI_BG_A=""
UI_BG_B=""
UI_FG_A=""
UI_FG_B=""
# Separator colors
UI_SEP_BG=""
UI_SEP_FG=""
# Accent colors for emojis/highlights
C_GREEN=""
C_YELLOW=""
C_BLUE=""
C_CYAN=""
C_RED=""

STATE_DIR=""
STATE_FILE=""

# --- State management ---

state_write() {
  local key="$1" val="$2"
  local tmp="${STATE_FILE}.tmp"
  if [[ -f "$STATE_FILE" ]]; then
    awk -v k="$key" -v v="$val" '
      BEGIN { found=0 }
      $0 ~ "^"k"=" { print k"="v; found=1; next }
      { print }
      END { if (!found) print k"="v }
    ' "$STATE_FILE" > "$tmp"
  else
    printf "%s=%s\n" "$key" "$val" > "$tmp"
  fi
  mv "$tmp" "$STATE_FILE"
}

state_get() {
  local key="$1"
  # shellcheck disable=SC1090
  source "$STATE_FILE" 2>/dev/null || true
  eval "printf '%s' \"\${$key:-}\""
}

# --- UI detection and dimensions ---

ui_detect() {
  if [[ "$NO_UI" == "1" ]] || [[ ! -t 1 ]] || ! have tput; then
    UI_ENABLED=0
  else
    UI_ENABLED=1
  fi
}

ui_dims() {
  # Try multiple methods to get terminal size, preferring stty which is more reliable
  local size_info
  if size_info="$(stty size 2>/dev/null </dev/tty)"; then
    TERM_LINES="${size_info%% *}"
    TERM_COLS="${size_info##* }"
  else
    TERM_COLS="$(tput cols 2>/dev/null || echo 0)"
    TERM_LINES="$(tput lines 2>/dev/null || echo 0)"
  fi

  [[ "$TERM_COLS" =~ ^[0-9]+$ ]] || TERM_COLS=0
  [[ "$TERM_LINES" =~ ^[0-9]+$ ]] || TERM_LINES=0

  if (( TERM_LINES < 10 || TERM_COLS < 40 )); then
    UI_ENABLED=0
    return 0
  fi
  ui_layout
}

ui_layout() {
  # Status bar is always row 0
  STATUS_BAR_ROW=0

  # 50/50 split: half for top pane, half for bottom pane (minus status bar and separator)
  local usable_lines=$(( TERM_LINES - 2 ))  # subtract status bar and separator
  local half=$(( usable_lines / 2 ))

  # Ensure minimum sizes
  if (( half < 3 )); then
    UI_ENABLED=0
    return 0
  fi

  PANE_TOP_START=1
  PANE_TOP_END=$(( half ))
  PANE_SEPARATOR=$(( half + 1 ))
  PANE_BOTTOM_START=$(( half + 2 ))
  PANE_BOTTOM_END=$(( TERM_LINES - 1 ))
}

ui_colors_init() {
  local colors=0
  colors="$(tput colors 2>/dev/null || echo 0)"

  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'

  # Check for 256/truecolor support via multiple methods:
  # 1. tput colors >= 256
  # 2. COLORTERM=truecolor or 24bit
  # 3. TERM contains "256color"
  local use_256=0
  if [[ "$colors" =~ ^[0-9]+$ ]] && (( colors >= 256 )); then
    use_256=1
  elif [[ "${COLORTERM:-}" == "truecolor" ]] || [[ "${COLORTERM:-}" == "24bit" ]]; then
    use_256=1
  elif [[ "${TERM:-}" == *"256color"* ]]; then
    use_256=1
  fi

  if (( use_256 == 1 )); then
    # 256 color mode - rich colors
    C_STATUSBAR_BG=$'\033[48;5;24m'   # Deep blue background
    C_STATUSBAR_FG=$'\033[38;5;255m'  # Bright white text

    UI_BG_A=$'\033[48;5;236m'         # Dark gray
    UI_BG_B=$'\033[48;5;238m'         # Slightly lighter gray
    UI_FG_A=$'\033[38;5;252m'         # Light gray text
    UI_FG_B=$'\033[38;5;250m'         # Slightly dimmer text

    UI_SEP_BG=$'\033[48;5;240m'       # Medium gray
    UI_SEP_FG=$'\033[38;5;245m'       # Gray text

    C_GREEN=$'\033[38;5;82m'
    C_YELLOW=$'\033[38;5;220m'
    C_BLUE=$'\033[38;5;39m'
    C_CYAN=$'\033[38;5;87m'
    C_RED=$'\033[38;5;196m'
  else
    # Basic 16 color fallback
    # Use more distinct colors that work across terminals
    C_STATUSBAR_BG=$'\033[44m'
    C_STATUSBAR_FG=$'\033[97m'

    # Use 100m (bright black) and 40m (black) with bold/dim to increase contrast
    # Also using reverse video on alternating rows for better visibility
    UI_BG_A=$'\033[48;5;239m'        # Try 256 anyway - most modern terms support it even if tput says otherwise
    UI_BG_B=$'\033[48;5;235m'
    UI_FG_A=$'\033[97m'
    UI_FG_B=$'\033[37m'

    # If the 256 escape didn't work, terminal will ignore it - no harm done
    # But we also set a fallback using ANSI dim/bold for visual differentiation
    if [[ "${TERM:-dumb}" == "dumb" ]] || [[ -z "${TERM:-}" ]]; then
      # True fallback for very basic terminals - use reverse video alternation
      UI_BG_A=$'\033[7m'    # Reverse video (swap fg/bg)
      UI_BG_B=$'\033[0m'    # Normal
      UI_FG_A=$'\033[0m'    # Reset after reverse
      UI_FG_B=$'\033[0m'    # Normal
    fi

    UI_SEP_BG=$'\033[47m'
    UI_SEP_FG=$'\033[30m'

    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
    C_RED=$'\033[31m'
  fi
}

# --- Low-level UI helpers ---

ui_tput() { tput "$@" >&$UI_TTY_FD 2>/dev/null || true; }
ui_write() { printf "%s" "$*" >&$UI_TTY_FD; }
ui_writeln() { printf "%s\n" "$*" >&$UI_TTY_FD; }

ui_move_to() {
  local row="$1" col="${2:-0}"
  ui_write $'\033['"$((row + 1));$((col + 1))H"
}

ui_clear_line() {
  ui_write $'\033[2K'
}

ui_hide_cursor() { ui_write $'\033[?25l'; }
ui_show_cursor() { ui_write $'\033[?25h'; }
ui_save_cursor() { ui_write $'\033[s'; }
ui_restore_cursor() { ui_write $'\033[u'; }

# Alternate screen buffer - prevents scroll-back issues
# This is what vim, htop, less use
ui_enter_alt_screen() { ui_write $'\033[?1049h'; }
ui_exit_alt_screen() { ui_write $'\033[?1049l'; }

ui_set_scroll_region() {
  local top="$1" bottom="$2"
  ui_write $'\033['"$((top + 1));$((bottom + 1))r"
}

ui_reset_scroll_region() {
  ui_write $'\033[r'
}

ui_fill_spaces() {
  local count="$1"
  printf '%*s' "$count" ''
}

ui_pad_line() {
  local text="$1" width="$2"
  local text_len=${#text}
  if (( text_len >= width )); then
    printf "%s" "${text:0:$width}"
  else
    printf "%s%*s" "$text" "$((width - text_len))" ''
  fi
}

trim_whitespace() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

# --- Status bar (fixed row 0) ---

ui_draw_status_bar() {
  (( UI_ENABLED == 1 )) || return 0

  # Refresh terminal dimensions in case of resize
  local size_info
  if size_info="$(stty size 2>/dev/null </dev/tty)"; then
    TERM_LINES="${size_info%% *}"
    TERM_COLS="${size_info##* }"
  fi
  ui_layout

  local iter total engine status elapsed
  iter="$(state_get ITER)"
  total="$(state_get TOTAL)"
  engine="$(state_get ENGINE)"
  status="$(state_get LAST_STATUS)"

  local start_epoch iter_start now_epoch
  start_epoch="$(state_get START_EPOCH)"
  iter_start="$(state_get ITER_START)"
  now_epoch="$(date +%s)"

  # Calculate elapsed times
  local total_elapsed=0 iter_elapsed=0
  if [[ -n "$start_epoch" ]]; then
    total_elapsed=$(( now_epoch - start_epoch ))
  fi
  if [[ -n "$iter_start" ]]; then
    iter_elapsed=$(( now_epoch - iter_start ))
  fi

  # Format elapsed time
  local total_time iter_time
  total_time="$(fmt_hhmmss "$total_elapsed")"
  iter_time="$(fmt_hhmmss "$iter_elapsed")"

  # Status emoji
  local status_icon
  case "$status" in
    running)  status_icon="🔄" ;;
    ok)       status_icon="✅" ;;
    fail)     status_icon="❌" ;;
    starting) status_icon="🚀" ;;
    *)        status_icon="⏳" ;;
  esac

  # Engine emoji
  local engine_icon engine_display
  case "$engine" in
    claude) engine_icon="🟣" engine_display="Claude" ;;
    codex)  engine_icon="🟢" engine_display="Codex" ;;
    *)      engine_icon="⚪" engine_display="$engine" ;;
  esac

  # Build status bar content
  local bar_content
  bar_content=" ${status_icon} Iter ${iter:-0}/${total:-0} │ ${engine_icon} ${engine_display:-?} │ ⏱  Total: ${total_time} │ This: ${iter_time} "

  # Draw status bar, empty top pane rows, and separator
  ui_save_cursor
  ui_reset_scroll_region

  # Status bar at row 0
  ui_move_to "$STATUS_BAR_ROW" 0
  ui_write "${C_STATUSBAR_BG}${C_STATUSBAR_FG}${C_BOLD}${bar_content}"
  ui_write $'\033[K'
  ui_write "${C_RESET}"

  # Fill only EMPTY rows in top pane (rows that haven't received content yet)
  local pane_height=$(( PANE_TOP_END - PANE_TOP_START + 1 ))
  local empty_rows=$(( pane_height - TOP_PANE_LINE_COUNT ))
  if (( empty_rows > 0 )); then
    local row
    for (( row = PANE_TOP_START; row < PANE_TOP_START + empty_rows; row++ )); do
      local bg
      if (( (row - PANE_TOP_START) % 2 == 0 )); then
        bg="$UI_BG_A"
      else
        bg="$UI_BG_B"
      fi
      ui_move_to "$row" 0
      ui_write "${bg}"
      ui_write $'\033[K'
      ui_write "${C_RESET}"
    done
  fi

  # Separator line - green background with = characters
  ui_move_to "$PANE_SEPARATOR" 0
  ui_write $'\033[42m'"="
  ui_write $'\033[K'
  ui_write "${C_RESET}"

  # Restore bottom pane scroll region and cursor
  ui_set_scroll_region "$PANE_BOTTOM_START" "$PANE_BOTTOM_END"
  ui_restore_cursor
}

# --- Top pane (important status items) ---

ui_fill_top_pane_background() {
  # Fill the top pane with alternating background colors
  (( UI_ENABLED == 1 )) || return 0

  ui_save_cursor
  ui_reset_scroll_region

  local row
  for (( row = PANE_TOP_START; row <= PANE_TOP_END; row++ )); do
    local bg
    if (( (row - PANE_TOP_START) % 2 == 0 )); then
      bg="$UI_BG_A"
    else
      bg="$UI_BG_B"
    fi
    ui_move_to "$row" 0
    ui_write "${bg}"
    ui_write $'\033[K'
    ui_write "${C_RESET}"
  done

  ui_set_scroll_region "$PANE_BOTTOM_START" "$PANE_BOTTOM_END"
  ui_restore_cursor
}

ui_draw_separator() {
  (( UI_ENABLED == 1 )) || return 0

  ui_save_cursor
  ui_reset_scroll_region
  ui_move_to "$PANE_SEPARATOR" 0
  # Draw separator character and clear to end of line
  ui_write "${UI_SEP_BG}${UI_SEP_FG}─"
  ui_write $'\033[K'  # Clear to end of line (fills with separator background)
  ui_write "${C_RESET}"
  ui_set_scroll_region "$PANE_BOTTOM_START" "$PANE_BOTTOM_END"
  ui_restore_cursor
}

ui_print_status_line() {
  local text="$1" icon="${2:-💬}"
  (( UI_ENABLED == 1 )) || return 0

  local bg fg
  if (( STATUS_ALT % 2 == 0 )); then
    bg="$UI_BG_A"
    fg="$UI_FG_A"
  else
    bg="$UI_BG_B"
    fg="$UI_FG_B"
  fi
  STATUS_ALT=$(( STATUS_ALT + 1 ))

  # Track how many lines we've added (cap at pane height)
  local pane_height=$(( PANE_TOP_END - PANE_TOP_START + 1 ))
  if (( TOP_PANE_LINE_COUNT < pane_height )); then
    TOP_PANE_LINE_COUNT=$(( TOP_PANE_LINE_COUNT + 1 ))
  fi

  local content=" ${icon} ${text}"

  # Save cursor, set scroll region for top pane only, scroll up, draw line
  ui_save_cursor
  ui_set_scroll_region "$PANE_TOP_START" "$PANE_TOP_END"
  ui_move_to "$PANE_TOP_END" 0

  # Clear line and fill with background color, then write content
  ui_write "${bg}${fg}${content}"
  ui_write $'\033[K'
  ui_write "${C_RESET}"
  ui_writeln ""

  # Restore bottom pane scroll region
  ui_set_scroll_region "$PANE_BOTTOM_START" "$PANE_BOTTOM_END"
  ui_restore_cursor

  # Redraw status bar (it might get overwritten)
  ui_draw_status_bar
}

ui_emit_status_line() {
  local engine="$1" line="$2"
  (( UI_ENABLED == 1 )) || return 0

  line="$(trim_whitespace "$line")"
  [[ -n "$line" ]] || return 0

  # Strip leading emoji if present (emoji + optional space)
  local stripped_line="$line"
  stripped_line="${stripped_line#💬 }"
  stripped_line="${stripped_line#💬}"
  stripped_line="${stripped_line#🛠  }"
  stripped_line="${stripped_line#🛠 }"
  stripped_line="${stripped_line#🛠}"
  stripped_line="${stripped_line#✅ }"
  stripped_line="${stripped_line#❌ }"
  stripped_line="${stripped_line#📝 }"
  stripped_line="${stripped_line#⚡ }"
  stripped_line="${stripped_line#🔍 }"
  stripped_line="$(trim_whitespace "$stripped_line")"

  # Skip empty lines
  [[ -n "$stripped_line" ]] || return 0

  # FILTER: Only show important status lines, not every line of output
  # Show: Tool uses, markdown headers (**...**), "thinking", errors, completions
  local dominated=0
  local icon=""

  if [[ "$stripped_line" == "Tool:"* ]] || [[ "$stripped_line" == *"Tool: "* ]]; then
    icon="🛠 "
    show=1
  elif [[ "$stripped_line" == "**"* ]]; then
    # Markdown bold header (like **Checking for instructions**)
    icon="📋"
    show=1
  elif [[ "$stripped_line" == "thinking"* ]] || [[ "$stripped_line" == "Thinking"* ]]; then
    icon="🧠"
    show=1
  elif [[ "$stripped_line" == *"error"* ]] || [[ "$stripped_line" == *"Error"* ]] || [[ "$stripped_line" == *"failed"* ]] || [[ "$stripped_line" == *"Failed"* ]]; then
    icon="❌"
    show=1
  elif [[ "$stripped_line" == *"success"* ]] || [[ "$stripped_line" == *"Success"* ]] || [[ "$stripped_line" == *"completed"* ]] || [[ "$stripped_line" == *"Completed"* ]]; then
    icon="✅"
    show=1
  elif [[ "$stripped_line" == *"Starting"* ]] || [[ "$stripped_line" == *"starting"* ]]; then
    icon="🚀"
    show=1
  elif [[ "$stripped_line" == *"Running"* ]] || [[ "$stripped_line" == *"Executing"* ]]; then
    icon="⚡"
    show=1
  else
    # Skip regular output lines - they're already in the bottom pane
    return 0
  fi

  local iter
  iter="$(state_get ITER)"
  local prefix
  if [[ -n "$iter" ]]; then
    prefix="[${engine} #${iter}] "
  else
    prefix="[${engine}] "
  fi

  ui_print_status_line "${prefix}${stripped_line}" "$icon"
}

# --- Bottom pane (detailed output) ---

ui_setup_bottom_pane() {
  (( UI_ENABLED == 1 )) || return 0
  ui_set_scroll_region "$PANE_BOTTOM_START" "$PANE_BOTTOM_END"
  ui_move_to "$PANE_BOTTOM_START" 0
}

ui_pipe_main() {
  local engine="$1"
  if (( UI_ENABLED == 1 )); then
    ui_pipe_main_impl "$engine"
  else
    cat
  fi
}

# Track if we've positioned the cursor in the bottom pane this "session"
BOTTOM_PANE_CURSOR_SET=0

ui_bottom_writeln() {
  # Write a line to the bottom pane, ensuring scroll region is correct
  local line="$1"

  # Re-establish scroll region (defensive against clears)
  ui_set_scroll_region "$PANE_BOTTOM_START" "$PANE_BOTTOM_END"

  # Move cursor to bottom of scroll region - new content appears here and scrolls up
  # Using "move to row within scroll region" ensures we're in the right place
  ui_move_to "$PANE_BOTTOM_END" 0

  ui_writeln "$line"
}

ui_pipe_main_impl() {
  local engine="$1"
  local line_buf=""
  local line=""
  local line_count=0

  local emit_cols=$(( TERM_COLS - 10 ))
  (( emit_cols < 30 )) && emit_cols=30

  # Initial setup
  ui_set_scroll_region "$PANE_BOTTOM_START" "$PANE_BOTTOM_END"
  ui_move_to "$PANE_BOTTOM_START" 0

  # Read line by line
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Output the line to the bottom pane
    ui_bottom_writeln "$line"

    line_count=$((line_count + 1))

    # Every 10 lines, do a full repaint of fixed elements
    if (( line_count % 10 == 0 )); then
      ui_draw_status_bar
    fi

    # Strip ANSI escape codes for status line processing
    local clean_line
    clean_line="$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')"
    clean_line="$(trim_whitespace "$clean_line")"

    # Skip empty lines for status updates
    if [[ -n "$clean_line" ]]; then
      # Emit to top pane
      ui_emit_status_line "$engine" "$clean_line"
    fi
  done

  # Final status bar update
  ui_draw_status_bar
}

# --- UI lifecycle ---

ui_draw_layout() {
  (( UI_ENABLED == 1 )) || return 0

  # Reset the top pane line counter (full redraw)
  TOP_PANE_LINE_COUNT=0
  STATUS_ALT=0

  # Clear screen
  ui_tput clear

  # Draw status bar (this also fills empty top pane rows and separator)
  ui_draw_status_bar

  # Position cursor in bottom pane
  ui_setup_bottom_pane
}

ui_init() {
  ui_detect
  (( UI_ENABLED == 1 )) || return 0

  ui_dims
  (( UI_ENABLED == 1 )) || return 0

  # Open TTY for direct terminal control
  if ! exec 3>/dev/tty 2>/dev/null; then
    UI_ENABLED=0
    return 0
  fi

  ui_colors_init
  STATUS_ALT=0

  # Enter alternate screen buffer - prevents scroll-back/clear issues
  ui_enter_alt_screen
  ui_hide_cursor
  ui_draw_layout
}

ui_stop() {
  (( UI_ENABLED == 1 )) || return 0

  ui_reset_scroll_region
  ui_show_cursor
  # Exit alternate screen buffer - restores original terminal content
  ui_exit_alt_screen

  exec 3>&- 2>/dev/null || true
}

ui_repaint() {
  # Repaint all fixed UI elements (status bar, separator, top pane background)
  (( UI_ENABLED == 1 )) || return 0

  ui_save_cursor
  ui_reset_scroll_region

  # Redraw status bar
  ui_draw_status_bar

  # Redraw separator
  ui_draw_separator

  # Restore scroll region and cursor
  ui_set_scroll_region "$PANE_BOTTOM_START" "$PANE_BOTTOM_END"
  ui_restore_cursor
}

on_winch() {
  (( UI_ENABLED == 1 )) || return 0

  # Recalculate dimensions using stty for accuracy
  ui_dims || true

  if (( UI_ENABLED == 1 )); then
    # Full redraw on resize
    ui_tput clear
    ui_draw_layout
  else
    ui_reset_scroll_region
    ui_show_cursor
  fi
}

on_cont() {
  # Called when process resumes after being suspended (Ctrl+Z then fg)
  (( UI_ENABLED == 1 )) || return 0

  # Recalculate dimensions
  ui_dims || true

  if (( UI_ENABLED == 1 )); then
    ui_hide_cursor
    ui_tput clear
    ui_draw_layout
  fi
}

trap on_winch WINCH
trap on_cont CONT

# --- traps / cleanup ----------------------------------------------------------

cleanup() {
  local exit_code="$1"

  ui_stop

  if [[ "$INTERRUPTED" == "1" ]]; then
    log_json "loop_terminated" "Interrupted (SIGINT)." "\"exit_code\":$exit_code"
  else
    log_json "loop_exited" "Exiting." "\"exit_code\":$exit_code"
  fi

  [[ -n "${STATE_DIR:-}" ]] && rm -rf "$STATE_DIR" 2>/dev/null || true
}

on_int() { INTERRUPTED=1; exit 130; }
on_exit() { cleanup "$?"; }

trap on_int INT
trap on_exit EXIT

# --- preflight ----------------------------------------------------------------

[[ -f "$PROMPT_FILE" ]] || die "Prompt file not found: $PROMPT_FILE"
[[ "$ITERATION_COUNT" =~ ^[0-9]+$ ]] || die "Iteration count must be an integer (got: $ITERATION_COUNT)"
[[ "$START_ENGINE" == "claude" || "$START_ENGINE" == "codex" ]] || die "START_ENGINE must be 'claude' or 'codex' (got: $START_ENGINE)"

# Validate ENGINES and parse into array
USE_CLAUDE=0
USE_CODEX=0
IFS=',' read -ra ENGINE_ARRAY <<< "$ENGINES"
for eng in "${ENGINE_ARRAY[@]}"; do
  case "$eng" in
    claude) USE_CLAUDE=1 ;;
    codex)  USE_CODEX=1 ;;
    *)      die "Invalid engine in ENGINES: '$eng' (expected 'claude' or 'codex')" ;;
  esac
done
(( USE_CLAUDE == 1 || USE_CODEX == 1 )) || die "ENGINES must include at least one of 'claude' or 'codex' (got: $ENGINES)"

# Only check for commands that will be used
(( USE_CLAUDE == 0 )) || have "$CLAUDE_CMD" || die "Missing required command: $CLAUDE_CMD"
(( USE_CODEX == 0 ))  || have "$CODEX_CMD"  || die "Missing required command: $CODEX_CMD"
have jq            || die "Missing required command: jq"
have tee           || die "Missing required command: tee"

mkdir -p "$(dirname "$LOG_FILE")"

if [[ -f "$LOG_FILE" && "$ROTATE_LOG" == "1" ]]; then
  mv "$LOG_FILE" "${LOG_FILE%.log}.${RUN_ID}.log" 2>/dev/null || mv "$LOG_FILE" "${LOG_FILE}.${RUN_ID}"
fi
: >"$LOG_FILE"

STATE_DIR="$(mktemp -d)"
STATE_FILE="${STATE_DIR}/state.env"
START_EPOCH="$(date +%s)"

state_write TOTAL "$ITERATION_COUNT"
state_write ITER "1"
state_write START_EPOCH "$START_EPOCH"
state_write ITER_START "$START_EPOCH"
state_write LAST_STATUS "starting"
state_write PHASE "init"
state_write ENGINE "?"

log_json "loop_started" "Starting loop." \
  "\"prompt_file\":\"$(json_escape "$PROMPT_FILE")\",\"iteration_count\":$ITERATION_COUNT,\"codex_model\":\"$(json_escape "$CODEX_MODEL")\",\"start_engine\":\"$(json_escape "$START_ENGINE")\""

clear

ui_init

# --- runners ------------------------------------------------------------------

run_claude_once() {
  # Claude: stream-json -> tee raw to log -> jq pretty to terminal
  local claude_args=(
    -p
    --verbose
    --include-partial-messages
    --output-format=stream-json
  )
  if [[ "$DISABLE_DANGER" != "1" ]]; then
    claude_args+=(--dangerously-skip-permissions)
  fi

  # Capture output for error checking
  local tmp_output
  tmp_output="$(mktemp)"

  # Disable errexit so we can check for errors ourselves
  set +e
  cat "$PROMPT_FILE" \
    | "$CLAUDE_CMD" "${claude_args[@]}" \
    | tee -a "$LOG_FILE" \
    | tee "$tmp_output" \
    | jq -rj --unbuffered '
        if (.type=="stream_event" and .event.type=="content_block_delta" and .event.delta.type=="text_delta") then
          (.event.delta.text | gsub("\\r?\\n"; "\n"))
        elif (.type=="stream_event" and .event.type=="message_start") then
          "\n\n💬 "
        elif (.type=="stream_event" and .event.type=="content_block_start" and .event.content_block.type=="tool_use") then
          "\n\n\u001b[33m🛠  Tool: " + .event.content_block.name + " \u001b[0m"
        else
          empty
        end
      ' \
    | ui_pipe_main "claude"
  local pipeline_exit=$?
  set -e
  printf '\n\n'

  # Check for authentication errors
  if grep -q '"error":"authentication_failed"' "$tmp_output" 2>/dev/null; then
    rm -f "$tmp_output"
    ui_print_status_line "AUTH FAILED: Run 'claude /login' to re-authenticate" "🔐"
    printf "\n\033[31mError: Authentication failed. Run 'claude /login' to re-authenticate.\033[0m\n" >&2
    return 1
  fi

  # Check for rate limit / quota errors
  if grep -q '"error":"rate_limit"' "$tmp_output" 2>/dev/null || \
     grep -q '"error":"quota_exceeded"' "$tmp_output" 2>/dev/null; then
    rm -f "$tmp_output"
    ui_print_status_line "RATE LIMIT / QUOTA EXCEEDED" "🚫"
    printf "\n\033[31mError: Rate limit or quota exceeded.\033[0m\n" >&2
    return 1
  fi

  # Check for other fatal errors (is_error:true in result)
  if grep -q '"is_error":true' "$tmp_output" 2>/dev/null; then
    local error_msg
    error_msg="$(jq -r 'select(.type=="result" and .is_error==true) | .result // empty' "$tmp_output" 2>/dev/null | head -1)"
    rm -f "$tmp_output"
    if [[ -n "$error_msg" ]]; then
      ui_print_status_line "ERROR: $error_msg" "❌"
      printf "\n\033[31mError: %s\033[0m\n" "$error_msg" >&2
    fi
    return 1
  fi

  rm -f "$tmp_output"
  return 0
}

run_codex_once() {
  # Codex: read prompt from stdin to avoid argv limits.
  local codex_args=(
    exec
    -c
    "model=$CODEX_MODEL"
    -
  )
  if [[ "$DISABLE_DANGER" != "1" ]]; then
    codex_args=(exec --dangerously-bypass-approvals-and-sandbox "${codex_args[@]:1}")
  fi

  # Mark log position before running
  local log_start_line=1
  [[ -f "$LOG_FILE" ]] && log_start_line=$(( $(wc -l < "$LOG_FILE") + 1 ))

  # Run codex and pipe through UI
  # Include stderr in case of errors
  # Disable errexit so we can check for errors ourselves
  set +e
  cat "$PROMPT_FILE" \
    | "$CODEX_CMD" "${codex_args[@]}" 2>&1 \
    | tee -a "$LOG_FILE" \
    | ui_pipe_main "codex"
  local pipeline_exit=$?
  set -e

  # Check new log lines for errors
  local new_output
  new_output="$(tail -n +"$log_start_line" "$LOG_FILE" 2>/dev/null || true)"

  # Check for authentication errors (401 Unauthorized)
  if printf '%s' "$new_output" | grep -q '401 Unauthorized' || \
     printf '%s' "$new_output" | grep -q 'Missing bearer or basic authentication'; then
    ui_print_status_line "AUTH FAILED: Run 'codex login' to re-authenticate" "🔐"
    printf "\n\033[31mError: Authentication failed. Run 'codex login' to re-authenticate.\033[0m\n" >&2
    return 1
  fi

  # Check for rate limit / quota errors
  if printf '%s' "$new_output" | grep -qi 'rate.limit\|quota\|429\|too many requests'; then
    ui_print_status_line "RATE LIMIT / QUOTA EXCEEDED" "🚫"
    printf "\n\033[31mError: Rate limit or quota exceeded.\033[0m\n" >&2
    return 1
  fi

  # Check for other API errors
  if printf '%s' "$new_output" | grep -q 'invalid_request_error'; then
    local error_msg
    error_msg="$(printf '%s' "$new_output" | grep -o '"message": *"[^"]*"' | head -1 | sed 's/.*"message": *"//' | sed 's/"$//')"
    if [[ -n "$error_msg" ]]; then
      ui_print_status_line "ERROR: $error_msg" "❌"
      printf "\n\033[31mError: %s\033[0m\n" "$error_msg" >&2
    else
      ui_print_status_line "ERROR: Codex API error" "❌"
      printf "\n\033[31mError: Codex API error\033[0m\n" >&2
    fi
    return 1
  fi

  return 0
}

engine_for_iteration() {
  local iteration="$1"

  # If only one engine is enabled, always use it
  if (( USE_CLAUDE == 1 && USE_CODEX == 0 )); then
    printf "claude"
    return
  fi
  if (( USE_CODEX == 1 && USE_CLAUDE == 0 )); then
    printf "codex"
    return
  fi

  # Both engines enabled - alternate based on START_ENGINE
  if [[ "$START_ENGINE" == "claude" ]]; then
    if (( iteration % 2 == 1 )); then
      printf "claude"
    else
      printf "codex"
    fi
  else
    if (( iteration % 2 == 1 )); then
      printf "codex"
    else
      printf "claude"
    fi
  fi
}

run_once_engine() {
  local engine="$1"
  case "$engine" in
    claude) run_claude_once ;;
    codex) run_codex_once ;;
    *) die "Unknown engine: $engine" ;;
  esac
}

# --- loop ---------------------------------------------------------------------

for ((i=1; i<=ITERATION_COUNT; i++)); do
  state_write ITER "$i"
  state_write ITER_START "$(date +%s)"
  state_write LAST_STATUS "running"
  state_write PHASE "iteration"

  engine="$(engine_for_iteration "$i")"
  state_write ENGINE "$engine"

  # Update status bar immediately after state changes
  ui_draw_status_bar

  # Only show banner/figlet in the bottom pane (or when UI disabled)
  if (( UI_ENABLED == 0 )); then
    banner_line
    print_big "$i"
    printf '\n'
  fi

  log_json "loop_start_marker" "==================== New Run $i ====================" \
    "\"iteration\":$i,\"engine\":\"$(json_escape "$engine")\""

  # Emit a status line at the start of each iteration
  case "$engine" in
    claude) ui_print_status_line "Starting iteration $i with Claude" "🚀" ;;
    codex)  ui_print_status_line "Starting iteration $i with Codex" "🚀" ;;
    *)      ui_print_status_line "Starting iteration $i with $engine" "🚀" ;;
  esac

  if run_once_engine "$engine"; then
    state_write LAST_STATUS "ok"
    ui_draw_status_bar
    ui_print_status_line "Iteration $i completed successfully" "✅"
    log_json "loop_iteration_completed" "Run completed." "\"iteration\":$i,\"engine\":\"$(json_escape "$(state_get ENGINE)")\""
  else
    state_write LAST_STATUS "fail"
    ui_draw_status_bar
    ui_print_status_line "Iteration $i failed" "❌"
    log_json "loop_iteration_failed" "Run failed." "\"iteration\":$i,\"engine\":\"$(json_escape "$(state_get ENGINE)")\""

    if [[ "$CONTINUE_ON_ERROR" == "1" ]]; then
      printf "\n\n[Iteration %d (%s) failed; continuing to next iteration]\n" "$i" "$engine" >&2
      continue
    fi
    die "Iteration $i failed (CONTINUE_ON_ERROR=0 set)."
  fi
done

state_write PHASE "done"
state_write LAST_STATUS "ok"
ui_draw_status_bar
ui_print_status_line "All $ITERATION_COUNT iterations completed!" "🎉"
log_json "loop_all_completed" "==================== Loop complete ===================="

if (( UI_ENABLED == 0 )); then
  banner_line
  if have figlet && [[ "$NO_FIGLET" != "1" ]]; then
    (printf '\033[32m'; figlet -f doh "Done" | sed -E '/^[[:space:]]*$/d' | sed 's/^/  /'; printf '\033[0m') || true
  else
    printf "\033[32m  Done\033[0m\n"
  fi
  printf '\n'
else
  # Show completion message in bottom pane
  printf '\n\033[32m✅ All %d iterations completed successfully!\033[0m\n\n' "$ITERATION_COUNT"
fi
