#!/bin/bash
# lib.sh — Shared constants, helpers, and state management for nerdflair.
# Sourced by nerdflair.sh, statusline.sh, and bell.sh.

# ── Paths ────────────────────────────────────────────────────────
NF_STATE_FILE="$HOME/.claude/nerdflair/state.json"
NF_SESSION_DIR="$HOME/.claude/nerdflair/sessions"
NF_CACHE_DIR="$HOME/.claude/nerdflair/cache"
NF_SETTINGS_FILE="$HOME/.claude/settings.json"

# ── Defaults ─────────────────────────────────────────────────────
NF_DEFAULT_MODE="full"
NF_DEFAULT_WIDTH="auto"
NF_DEFAULT_COLOR="vibrant"
NF_DEFAULT_TERMINAL_BELL="on"
NF_DEFAULT_CHIME_SOUND="Glass"
NF_DEFAULT_CHIME_STYLE="random"
NF_DEFAULT_CHIME_EVENTS="Notification,PermissionRequest,PreCompact,SessionEnd,SessionStart,Stop"
NF_DEFAULT_CHIME_VOLUME="1"

NF_ALL_CHIME_EVENTS="Notification PermissionRequest PreCompact SessionEnd SessionStart Stop UserPromptSubmit"
NF_VALID_MODES="full compact minimal"

# Exact-match check against NF_VALID_MODES (never treat user input as a regex).
_nf_valid_mode() {
  local m
  for m in $NF_VALID_MODES; do [[ "$1" == "$m" ]] && return 0; done
  return 1
}

# Lowercase without ${var,,}, which bash 3.2 (macOS /bin/bash) lacks.
_nf_lower() { printf "%s" "$1" | tr "[:upper:]" "[:lower:]"; }

# Session ids become filenames under NF_SESSION_DIR; allow only safe characters.
_nf_valid_session_id() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# ── ANSI colors (shared across scripts) ──────────────────────────
NF_CYAN='\033[38;2;86;182;194m'
NF_GREEN='\033[38;2;152;195;121m'
NF_DIM='\033[38;2;120;135;155m'
NF_RED='\033[38;2;224;108;117m'
NF_RST='\033[0m'

# ── jq check ─────────────────────────────────────────────────────
_nf_require_jq() {
  if ! command -v jq &>/dev/null; then
    printf '%b✗ jq not found — nerdflair requires jq.%b\n' "$NF_RED" "$NF_RST" >&2
    printf '  Install with: %bbrew install jq%b (macOS) or %bsudo apt install jq%b (Debian/Ubuntu)\n' \
      "$NF_CYAN" "$NF_RST" "$NF_CYAN" "$NF_RST" >&2
    exit 1
  fi
}

# ── Read a single field from the state file ──────────────────────
# Usage: _nf_read_field <field_name> [default_value]
# Returns the value via stdout. Handles missing file/field gracefully.
_nf_read_field() {
  local field="$1" default="${2:-}"
  if [[ -f "$NF_STATE_FILE" ]]; then
    local val
    val=$(jq -r ".$field // empty" "$NF_STATE_FILE" 2>/dev/null)
    if [[ -n "$val" ]]; then
      printf '%s' "$val"
      return
    fi
  fi
  printf '%s' "$default"
}

# ── Read the chime_recent_styles array as comma-separated ────────
_nf_read_recent_styles() {
  if [[ -f "$NF_STATE_FILE" ]]; then
    jq -r '.chime_recent_styles // [] | join(",")' "$NF_STATE_FILE" 2>/dev/null
  fi
}

# ── Read all state fields into NF_CUR_* variables ────────────────
# Applies legacy migrations inline.
_nf_read_state() {
  if [[ -f "$NF_STATE_FILE" ]]; then
    # Read all fields in a single jq call
    local _json
    _json=$(jq -r '[
      .mode // "",
      .width // "",
      .flair // "",
      .color // "",
      .terminal_bell // "",
      .chime_sound // "",
      .chime_style // "",
      .chime_events // "",
      .chime_volume // "",
      .last_session // "",
      .bell // "",
      .audio_style // "",
      .audio_events // "",
      .bell_volume // ""
    ] | map(tostring) | join("\u001f")' "$NF_STATE_FILE" 2>/dev/null) || {
      printf "nerdflair: %s is not valid JSON; using defaults\n" "$NF_STATE_FILE" >&2
      _json=""
    }

    # Unit separator, not tab: tab is IFS whitespace and collapses empty fields.
    IFS=$'\x1f' read -r \
      NF_CUR_MODE NF_CUR_WIDTH NF_CUR_FLAIR NF_CUR_COLOR \
      NF_CUR_TERMINAL_BELL NF_CUR_CHIME_SOUND NF_CUR_CHIME_STYLE \
      NF_CUR_CHIME_EVENTS NF_CUR_CHIME_VOLUME NF_CUR_LAST_SESSION \
      _old_bell _old_audio_style _old_audio_events _old_bell_volume \
      <<< "$_json"
  fi

  # Apply defaults
  NF_CUR_MODE="${NF_CUR_MODE:-$NF_DEFAULT_MODE}"
  NF_CUR_WIDTH="${NF_CUR_WIDTH:-$NF_DEFAULT_WIDTH}"
  NF_CUR_FLAIR="${NF_CUR_FLAIR:-true}"
  NF_CUR_COLOR="${NF_CUR_COLOR:-$NF_DEFAULT_COLOR}"
  NF_CUR_TERMINAL_BELL="${NF_CUR_TERMINAL_BELL:-}"
  NF_CUR_CHIME_SOUND="${NF_CUR_CHIME_SOUND:-$NF_DEFAULT_CHIME_SOUND}"
  NF_CUR_CHIME_STYLE="${NF_CUR_CHIME_STYLE:-}"
  NF_CUR_CHIME_EVENTS="${NF_CUR_CHIME_EVENTS:-}"
  NF_CUR_CHIME_VOLUME="${NF_CUR_CHIME_VOLUME:-}"
  NF_CUR_LAST_SESSION="${NF_CUR_LAST_SESSION:-}"

  # Legacy migration: "default" color → "vibrant"
  if [[ "$NF_CUR_COLOR" == "default" ]]; then
    NF_CUR_COLOR="vibrant"
  fi

  # Legacy migration: old "bell" field → terminal_bell + chime_volume
  if [[ -z "$NF_CUR_TERMINAL_BELL" && -n "${_old_bell:-}" ]]; then
    case "$_old_bell" in
      both)   NF_CUR_TERMINAL_BELL="on" ;;
      visual) NF_CUR_TERMINAL_BELL="on"; NF_CUR_CHIME_VOLUME="0" ;;
      audio)  NF_CUR_TERMINAL_BELL="off" ;;
      off)    NF_CUR_TERMINAL_BELL="off"; NF_CUR_CHIME_VOLUME="0" ;;
    esac
  fi
  NF_CUR_TERMINAL_BELL="${NF_CUR_TERMINAL_BELL:-$NF_DEFAULT_TERMINAL_BELL}"

  # Legacy migration: audio_style → chime_style
  if [[ -z "$NF_CUR_CHIME_STYLE" && -n "${_old_audio_style:-}" ]]; then
    NF_CUR_CHIME_STYLE="$_old_audio_style"
  fi
  NF_CUR_CHIME_STYLE="${NF_CUR_CHIME_STYLE:-$NF_DEFAULT_CHIME_STYLE}"

  # Legacy migration: audio_events → chime_events
  if [[ -z "$NF_CUR_CHIME_EVENTS" && -n "${_old_audio_events:-}" ]]; then
    NF_CUR_CHIME_EVENTS="$_old_audio_events"
  fi
  NF_CUR_CHIME_EVENTS="${NF_CUR_CHIME_EVENTS:-$NF_DEFAULT_CHIME_EVENTS}"

  # Legacy migration: bell_volume → chime_volume
  if [[ -z "$NF_CUR_CHIME_VOLUME" && -n "${_old_bell_volume:-}" ]]; then
    NF_CUR_CHIME_VOLUME="$_old_bell_volume"
  fi
  NF_CUR_CHIME_VOLUME="${NF_CUR_CHIME_VOLUME:-$NF_DEFAULT_CHIME_VOLUME}"
}

# ── Write state file atomically using jq ─────────────────────────
# Usage: _nf_write_state [extra_jq_filter]
# Writes NF_CUR_* variables to state.json, preserving chime_recent_styles
# and last_session. Optional jq filter is applied last (e.g. to set
# additional fields).
_nf_write_state() {
  local extra_filter="${1:-}"
  mkdir -p "$(dirname "$NF_STATE_FILE")"

  # Preserve chime_recent_styles from existing file
  local recent_styles="[]"
  if [[ -f "$NF_STATE_FILE" ]]; then
    recent_styles=$(jq -c '.chime_recent_styles // []' "$NF_STATE_FILE" 2>/dev/null || echo "[]")
  fi

  local _tmp="${NF_STATE_FILE}.tmp.$$"
  jq -n \
    --arg mode "$NF_CUR_MODE" \
    --arg width "$NF_CUR_WIDTH" \
    --argjson flair "${NF_CUR_FLAIR:-true}" \
    --arg terminal_bell "$NF_CUR_TERMINAL_BELL" \
    --arg chime_sound "$NF_CUR_CHIME_SOUND" \
    --arg chime_volume "$NF_CUR_CHIME_VOLUME" \
    --arg chime_style "$NF_CUR_CHIME_STYLE" \
    --arg chime_events "$NF_CUR_CHIME_EVENTS" \
    --arg color "$NF_CUR_COLOR" \
    --arg last_session "$NF_CUR_LAST_SESSION" \
    --argjson recent "$recent_styles" \
    '{
      mode: $mode,
      width: $width,
      flair: $flair,
      terminal_bell: $terminal_bell,
      chime_sound: $chime_sound,
      chime_volume: $chime_volume,
      chime_style: $chime_style,
      chime_events: $chime_events,
      color: $color,
      last_session: $last_session,
      chime_recent_styles: $recent
    }' > "$_tmp" && mv "$_tmp" "$NF_STATE_FILE"
}

# ── Update a single field in state.json atomically ───────────────
# Usage: _nf_update_field <field> <value>
# Creates the file with defaults if it doesn't exist.
_nf_update_field() {
  local field="$1" value="$2"
  mkdir -p "$(dirname "$NF_STATE_FILE")"
  if [[ ! -f "$NF_STATE_FILE" ]]; then
    _nf_read_state  # populate NF_CUR_* with defaults
    _nf_write_state
  fi
  local _tmp="${NF_STATE_FILE}.tmp.$$"
  jq --arg v "$value" ".$field = \$v" "$NF_STATE_FILE" > "$_tmp" && mv "$_tmp" "$NF_STATE_FILE"
}

# ── Play audio file (cross-platform) ──────────────────────────────
# Usage: _nf_play_audio <file> <volume>
# volume: 0.0–1.0 float (afplay scale)
# Supports: afplay (macOS), paplay (PulseAudio/PipeWire on Linux)
_nf_play_audio() {
  local file="$1" volume="${2:-1}"
  [[ ! -f "$file" ]] && return 1
  if command -v afplay &>/dev/null; then
    nohup afplay --volume "$volume" "$file" &>/dev/null &
  elif command -v paplay &>/dev/null; then
    # paplay volume: 0–65536 (65536 = 100%)
    local _pa_vol
    _pa_vol=$(awk -v v="$volume" 'BEGIN {printf "%d", v * 65536}')
    nohup paplay --volume="$_pa_vol" "$file" &>/dev/null &
  fi
}

# ── Update chime_recent_styles array ─────────────────────────────
# Usage: _nf_update_recent_styles <comma_separated_styles>
_nf_update_recent_styles() {
  local styles_csv="$1"
  mkdir -p "$(dirname "$NF_STATE_FILE")"
  if [[ ! -f "$NF_STATE_FILE" ]]; then
    _nf_read_state
    _nf_write_state
  fi
  local _tmp="${NF_STATE_FILE}.tmp.$$"
  jq --arg csv "$styles_csv" '.chime_recent_styles = ($csv | split(","))' "$NF_STATE_FILE" > "$_tmp" && mv "$_tmp" "$NF_STATE_FILE"
}
