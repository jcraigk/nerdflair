#!/bin/bash
# Audio/visual notifications for Claude Code hook events.
# Called with event name as $1: Notification, PermissionRequest, PreCompact,
# SessionEnd, SessionStart, Stop, UserPromptSubmit.
#
# Reads settings from ~/.claude/nerdflair/state.json:
#   terminal_bell: on | off        (BEL char — hard-coded to Notification, PermissionRequest, Stop)
#   chime_sound:   macOS system sound name (fallback when no chime style)
#   chime_style:   style folder name from audio/ (or "random")
#   chime_events:  comma-separated list of enabled events for chimes
#   chime_volume:  0.0–1.0 (0 = muted, no audio plays)

set -euo pipefail

EVENT="${1:-Stop}"

# Read stdin payload (Claude Code passes JSON with session context)
_stdin_data=""
if ! [ -t 0 ]; then
  _stdin_data=$(cat)
fi

# Resolve plugin root (hooks/ is one level down from plugin root)
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDIO_DIR="$PLUGIN_ROOT/assets/audio"

# shellcheck source=../scripts/lib.sh
source "$PLUGIN_ROOT/scripts/lib.sh"
_nf_require_jq

# Read state (populates NF_CUR_* with legacy migration)
_nf_read_state

# If no state file exists, nerdflair is not installed — exit silently
if [[ ! -f "$NF_STATE_FILE" ]]; then
  exit 0
fi

terminal_bell="$NF_CUR_TERMINAL_BELL"
chime_sound="$NF_CUR_CHIME_SOUND"
chime_style="$NF_CUR_CHIME_STYLE"
chime_events="$NF_CUR_CHIME_EVENTS"
chime_volume="$NF_CUR_CHIME_VOLUME"

# Hard-coded events that trigger the terminal bell (BEL character)
TERMINAL_BELL_EVENTS="Notification,PermissionRequest,Stop"

# Extract session_id from stdin payload
_session_id=""
if [[ -n "$_stdin_data" ]]; then
  _session_id=$(echo "$_stdin_data" | jq -r '.session_id // empty' 2>/dev/null || true)
fi

# Suppress SessionStart for resumed sessions and post-compaction restarts.
# Three checks:
#   1. source == "resume" (explicit /resume command)
#   2. session_id == last_session (same session already seen by statusline)
#   3. PreCompact marker file exists (compaction just happened, SessionStart is a restart)
_COMPACT_MARKER="$HOME/.claude/nerdflair/.pre-compact"
if [[ "$EVENT" == "SessionStart" ]]; then
  _source=""
  if [[ -n "$_stdin_data" ]]; then
    _source=$(echo "$_stdin_data" | jq -r '.source // empty' 2>/dev/null || true)
  fi
  if [[ "$_source" == "resume" ]]; then
    exit 0
  fi
  if [[ -n "$_session_id" && -n "$NF_CUR_LAST_SESSION" ]]; then
    if [[ "$_session_id" == "$NF_CUR_LAST_SESSION" ]]; then
      exit 0
    fi
  fi
  # Check PreCompact marker: if it exists, this SessionStart follows compaction
  if [[ -f "$_COMPACT_MARKER" ]]; then
    rm -f "$_COMPACT_MARKER"
    exit 0
  fi
fi

# On PreCompact, write a marker file so the subsequent SessionStart is suppressed
if [[ "$EVENT" == "PreCompact" ]]; then
  mkdir -p "$(dirname "$_COMPACT_MARKER")"
  printf '%s' "$(date +%s)" > "$_COMPACT_MARKER"
fi

# ── Resolve chime style (per-session) ──
# Each session gets a JSON file: ~/.claude/nerdflair/sessions/<session_id>
#   {"chime":"StyleName"}
# The global chime_recent_styles list in the shared state file prevents
# repeats across sessions. The statusline reads the per-session file.
mkdir -p "$NF_SESSION_DIR"
_session_file=""
if [[ -n "$_session_id" ]]; then
  _session_file="$NF_SESSION_DIR/${_session_id}"
fi

_resolved_style="$chime_style"
if [[ "$_resolved_style" == "random" ]]; then
  if [[ "$EVENT" == "SessionStart" && -d "$AUDIO_DIR" ]]; then
    # New session: pick a fresh random style, avoiding recently used ones
    _styles=()
    while IFS= read -r d; do
      _styles+=("$(basename "$d")")
    done < <(find "$AUDIO_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
    if [[ ${#_styles[@]} -gt 0 ]]; then
      _recent_csv=$(_nf_read_recent_styles)
      _recent=()
      if [[ -n "$_recent_csv" ]]; then
        IFS=',' read -ra _recent <<< "$_recent_csv"
      fi
      _candidates=()
      for s in "${_styles[@]}"; do
        _is_recent=false
        if [[ ${#_recent[@]} -gt 0 ]]; then
          for r in "${_recent[@]}"; do
            if [[ "$s" == "$r" ]]; then _is_recent=true; break; fi
          done
        fi
        if [[ "$_is_recent" == "false" ]]; then
          _candidates+=("$s")
        fi
      done
      if [[ ${#_candidates[@]} -eq 0 ]]; then
        _candidates=("${_styles[@]}")
      fi
      _resolved_style="${_candidates[$((RANDOM % ${#_candidates[@]}))]}"
      # Update global recent history (keep last 10)
      _recent+=("$_resolved_style")
      while [[ ${#_recent[@]} -gt 10 ]]; do
        _recent=("${_recent[@]:1}")
      done
      _recent_joined=$(IFS=','; printf '%s' "${_recent[*]}")
      _nf_update_recent_styles "$_recent_joined"
    fi
  elif [[ -n "$_session_file" && -f "$_session_file" ]]; then
    # Non-SessionStart: reuse this session's resolved style from session JSON
    _prev=$(jq -r '.chime // empty' "$_session_file" 2>/dev/null || true)
    if [[ -n "$_prev" && "$_prev" != "random" ]]; then
      _resolved_style="$_prev"
    fi
  fi
else
  # Non-random global style: check for per-session override (set by chime-session)
  if [[ "$EVENT" != "SessionStart" && -n "$_session_file" && -f "$_session_file" ]]; then
    _prev=$(jq -r '.chime // empty' "$_session_file" 2>/dev/null || true)
    if [[ -n "$_prev" && "$_prev" != "$_resolved_style" ]]; then
      _resolved_style="$_prev"
    fi
  fi
fi

# Write session file as JSON
if [[ -n "$_session_file" ]]; then
  if [[ "$EVENT" == "SessionStart" ]]; then
    printf '{"chime":"%s"}\n' "$_resolved_style" > "$_session_file"
  elif [[ "$_resolved_style" != "random" && ! -f "$_session_file" ]]; then
    printf '{"chime":"%s"}\n' "$_resolved_style" > "$_session_file"
  fi
fi

# Clean up per-session file on SessionEnd
if [[ "$EVENT" == "SessionEnd" && -n "$_session_file" && -f "$_session_file" ]]; then
  rm -f "$_session_file"
fi

# On SessionStart, prune stale session files older than 7 days
if [[ "$EVENT" == "SessionStart" ]]; then
  find "$NF_SESSION_DIR" -type f -mtime +7 -delete 2>/dev/null || true
fi

# Exit early if terminal bell is off and chime volume is 0
_chime_muted=$(awk -v v="$chime_volume" 'BEGIN {print (v+0 <= 0) ? 1 : 0}')
if [[ "$terminal_bell" == "off" && "$_chime_muted" == "1" ]]; then
  exit 0
fi

# Hooks run without a controlling TTY, so /dev/tty won't work.
# Walk up the process tree to find the TTY of the parent Claude process.
_find_tty() {
  local pid=$$
  while [ "$pid" -gt 1 ]; do
    local tty
    tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    # "no controlling terminal" is spelled "??" by BSD/macOS ps but "?" by
    # procps on Linux. Accepting "?" builds the path /dev/? , and writing to it
    # fails with EACCES -- which, under this script's `set -e`, aborted the
    # whole hook BEFORE the chime played. Net effect on Linux: Stop,
    # Notification and PermissionRequest never chimed at all.
    case "$tty" in
      ''|'?'|'??'|'-') ;;
      *)
        # Only accept something that is really a writable character device.
        if [ -c "/dev/$tty" ] && [ -w "/dev/$tty" ]; then
          echo "/dev/$tty"
          return 0
        fi
        ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  return 1
}

# Send terminal bell (BEL character) — hard-coded to attention-seeking events only
if [[ "$terminal_bell" == "on" ]] && echo ",$TERMINAL_BELL_EVENTS," | grep -q ",$EVENT,"; then
  if tty_path=$(_find_tty); then
    # Never let an unwritable tty abort the hook and swallow the chime below.
    printf '\a' > "$tty_path" 2>/dev/null || true
  fi
fi

# Play chime — user-configurable events, skip if volume is 0 or no audio player
if [[ "$_chime_muted" != "1" ]] && echo ",$chime_events," | grep -q ",$EVENT,"; then
  _audio_file="$AUDIO_DIR/$_resolved_style/$_resolved_style-$EVENT.mp3"
  if [[ -f "$_audio_file" ]]; then
    _nf_play_audio "$_audio_file" "$chime_volume"
  else
    # Fallback to macOS system sound
    _sys_sound="/System/Library/Sounds/${chime_sound}.aiff"
    if [[ -f "$_sys_sound" ]]; then
      _nf_play_audio "$_sys_sound" "$chime_volume"
    fi
  fi
fi
