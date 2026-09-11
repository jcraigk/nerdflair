#!/bin/bash
set -euo pipefail
# nerdflair — Configure Claude Code statusline layout and width.
#
# Usage:
#   nerdflair                      # cycle layout to next mode
#   nerdflair layout               # cycle layout: full → compact → minimal → full
#   nerdflair layout full          # set layout directly
#   nerdflair chime-events         # show/edit which events play chimes
#   nerdflair chime-style          # cycle chime style: random → BalladPiano → ... → random
#   nerdflair chime-style random   # set chime style directly
#   nerdflair chime-volume 50      # set chime volume to 50% (0 = muted)
#   nerdflair color-palette        # cycle color palette: vibrant → muted → mono → vibrant
#   nerdflair color-palette mono   # set color palette directly
#   nerdflair terminal-bell        # toggle terminal bell on/off (BEL char on Notification/PermissionRequest/Stop)
#   nerdflair width 60             # set layout width to 60
#   nerdflair width auto           # reset to auto (terminal width)
#   nerdflair spinner-verbs         # toggle nerdflair spinner verbs on/off
#   nerdflair spinner-verbs enable  # enable nerdflair spinner verbs
#   nerdflair spinner-verbs disable # disable (restore Claude Code defaults)
#   nerdflair info                 # show current settings without changing anything
#
# State is persisted in ~/.claude/nerdflair/state.json
# Spinner verbs are written directly to ~/.claude/settings.json (spinnerVerbs field).
# The statusline script reads this file on every render.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
_nf_require_jq

# Ensure the directory exists
mkdir -p "$(dirname "$NF_STATE_FILE")"

# Read current state (populates NF_CUR_* variables with legacy migration)
_nf_read_state

# Alias NF_CUR_* to current_* for readability in this script
current_mode="$NF_CUR_MODE"
current_width="$NF_CUR_WIDTH"
current_color="$NF_CUR_COLOR"
current_terminal_bell="$NF_CUR_TERMINAL_BELL"
current_chime_sound="$NF_CUR_CHIME_SOUND"
current_chime_style="$NF_CUR_CHIME_STYLE"
current_chime_events="$NF_CUR_CHIME_EVENTS"
current_chime_volume="$NF_CUR_CHIME_VOLUME"

# ── Parse arguments ──────────────────────────────────────────────
next_mode=""
next_width=""
cycle_color=false
set_color=""
toggle_terminal_bell=false
set_chime_style=""
cycle_chime_style=false
toggle_chime_event=""
set_volume=""
show_info=false
cycle_layout=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    info)
      show_info=true
      shift
      ;;
    layout)
      if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
        if ! _nf_valid_mode "$2"; then
          printf '%b✗ Unknown layout "%s"%b\n' "$NF_RED" "$2" "$NF_RST"
          printf '  Valid layouts: %s\n' "$NF_VALID_MODES"
          exit 1
        fi
        next_mode="$2"
        shift 2
      else
        cycle_layout=true
        shift
      fi
      ;;
    width|--width|-w)
      if [[ -z "${2:-}" ]]; then
        printf '%b✗ width requires a value (number or "auto")%b\n' "$NF_RED" "$NF_RST"
        exit 1
      fi
      if [[ "$2" == "auto" ]]; then
        next_width="auto"
      elif [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 50 && $2 <= 150 )); then
        next_width="$2"
      else
        printf '%b✗ Width must be 50-150 or "auto"%b\n' "$NF_RED" "$NF_RST"
        exit 1
      fi
      shift 2
      ;;
    flair)
      # Legacy: flair is always on (texture always shown)
      printf '%bFlair is always on — texture is always shown.%b\n' "$NF_DIM" "$NF_RST"
      exit 0
      ;;
    terminal-bell|bell)
      toggle_terminal_bell=true
      shift
      ;;
    chimes)
      # Legacy: treat as alias for chime-volume toggle (not documented)
      # If chimes are muted, set to 100%; otherwise mute
      _cur_muted=$(awk -v v="$current_chime_volume" 'BEGIN {print (v+0 <= 0) ? 1 : 0}')
      if [[ "$_cur_muted" == "1" ]]; then
        set_volume="1"
      else
        set_volume="0"
      fi
      shift
      ;;
    chime-session)
      # Set the chime style for the current session only (does not change global setting)
      # Uses last_session from state to find the active session file
      _cs_session="$NF_CUR_LAST_SESSION"
      _nf_valid_session_id "$_cs_session" || _cs_session=""
      if [[ -z "$_cs_session" ]]; then
        printf '%b✗ No active session found%b\n' "$NF_RED" "$NF_RST"
        exit 1
      fi
      _cs_session_file="$NF_SESSION_DIR/${_cs_session}"

      AUDIO_DIR="$(cd "$SCRIPT_DIR/../assets/audio" 2>/dev/null && pwd)" || AUDIO_DIR=""
      _cs_styles=()
      if [[ -n "$AUDIO_DIR" && -d "$AUDIO_DIR" ]]; then
        while IFS= read -r d; do
          _cs_styles+=("$(basename "$d")")
        done < <(find "$AUDIO_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
      fi

      if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
        # Set directly
        _cs_target="$2"
        shift 2
      else
        # No argument: list available styles with numbers and current marker
        _cs_current=""
        if [[ -f "$_cs_session_file" ]]; then
          _cs_current=$(jq -r '.chime // empty' "$_cs_session_file" 2>/dev/null || true)
        fi
        printf '%bSession chime styles:%b\n' "$NF_CYAN" "$NF_RST"
        for i in "${!_cs_styles[@]}"; do
          _num=$((i + 1))
          if [[ "${_cs_styles[$i]}" == "$_cs_current" ]]; then
            printf '  %b%2d. %s  ◄%b\n' "$NF_GREEN" "$_num" "${_cs_styles[$i]}" "$NF_RST"
          else
            printf '  %2d. %s\n' "$_num" "${_cs_styles[$i]}"
          fi
        done
        printf '\n%bSet with: nerdflair chime-session <name|number>%b\n' "$NF_DIM" "$NF_RST"
        exit 0
      fi

      # If target is a number, resolve to style name
      if [[ "$_cs_target" =~ ^[0-9]+$ ]]; then
        _cs_idx=$((_cs_target - 1))
        if (( _cs_idx >= 0 && _cs_idx < ${#_cs_styles[@]} )); then
          _cs_target="${_cs_styles[$_cs_idx]}"
        else
          printf '%b✗ Invalid number "%s" (1-%d)%b\n' "$NF_RED" "$_cs_target" "${#_cs_styles[@]}" "$NF_RST"
          exit 1
        fi
      fi

      # Validate style name
      _cs_matched=""
      for s in "${_cs_styles[@]}"; do
        if [[ "$(_nf_lower "$s")" == "$(_nf_lower "$_cs_target")" ]]; then
          _cs_matched="$s"
          break
        fi
      done
      if [[ -z "$_cs_matched" ]]; then
        printf '%b✗ Unknown chime style "%s"%b\n' "$NF_RED" "$_cs_target" "$NF_RST"
        printf '  Available: %s\n' "${_cs_styles[*]}"
        exit 1
      fi

      # Create session file if it doesn't exist (e.g. session started before plugin was installed)
      if [[ ! -f "$_cs_session_file" ]]; then
        mkdir -p "$NF_SESSION_DIR"
        printf '{"chime":"%s"}\n' "$_cs_matched" > "$_cs_session_file"
      else
        # Update session file: overwrite chime
        _cs_tmp="$_cs_session_file.tmp.$$"
        jq --arg chime "$_cs_matched" '.chime = $chime' "$_cs_session_file" > "$_cs_tmp" && mv "$_cs_tmp" "$_cs_session_file"
      fi

      printf '%b✓ Session chime → %s%b (this session only)\n' "$NF_GREEN" "$_cs_matched" "$NF_RST"

      # Play the SessionStart sound for the new style
      _cs_audio="$AUDIO_DIR/$_cs_matched/$_cs_matched-SessionStart.mp3"
      _nf_play_audio "$_cs_audio" "$NF_CUR_CHIME_VOLUME"
      exit 0
      ;;
    chime-style)
      if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
        set_chime_style="$2"
        shift 2
      else
        cycle_chime_style=true
        shift
      fi
      ;;
    bell-sound|audio-style)
      # Legacy aliases
      if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
        set_chime_style="$2"
        shift 2
      else
        cycle_chime_style=true
        shift
      fi
      ;;
    chime-events|audio-events)
      if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
        toggle_chime_event="$2"
        shift 2
      else
        toggle_chime_event="__show__"
        shift
      fi
      ;;
    chime-volume|volume)
      if [[ -z "${2:-}" ]]; then
        printf '%b✗ chime-volume requires a value (0-100)%b\n' "$NF_RED" "$NF_RST"
        exit 1
      fi
      _vol="$2"
      if [[ "$_vol" =~ ^[0-9]+%?$ ]]; then
        _vol="${_vol%\%}"
        if (( _vol < 0 || _vol > 100 )); then
          printf '%b✗ Volume must be 0-100%b\n' "$NF_RED" "$NF_RST"
          exit 1
        fi
        set_volume=$(awk -v v="$_vol" 'BEGIN {printf "%.2f", v / 100}')
      else
        printf '%b✗ Volume must be 0-100 (integer)%b\n' "$NF_RED" "$NF_RST"
        exit 1
      fi
      shift 2
      ;;
    spinner-verbs|spinner)
      # Toggle nerdflair spinner verbs in ~/.claude/settings.json
      # Reads verbs from assets/text/spinners.txt (one per line)
      _verbs_file="$(cd "$SCRIPT_DIR/../assets/text" 2>/dev/null && pwd)/spinners.txt"
      _sv_action="${2:-__toggle__}"
      shift
      [[ "$_sv_action" != "__toggle__" ]] && shift

      # Check if nerdflair verbs are currently enabled
      _sv_enabled=false
      if [[ -f "$NF_SETTINGS_FILE" ]] && jq -e '.spinnerVerbs' "$NF_SETTINGS_FILE" &>/dev/null; then
        _sv_enabled=true
      fi

      if [[ "$_sv_action" == "__toggle__" || "$_sv_action" == "enable" || "$_sv_action" == "disable" ]]; then
        # Determine target state
        if [[ "$_sv_action" == "enable" ]]; then
          _target="on"
        elif [[ "$_sv_action" == "disable" ]]; then
          _target="off"
        elif [[ "$_sv_enabled" == "true" ]]; then
          _target="off"
        else
          _target="on"
        fi

        _backup_file="$HOME/.claude/nerdflair/spinnerVerbs.backup.json"

        if [[ "$_target" == "on" ]]; then
          # Read verbs from file
          if [[ ! -f "$_verbs_file" ]]; then
            printf '%b✗ Verbs file not found: %s%b\n' "$NF_RED" "$_verbs_file" "$NF_RST"
            exit 1
          fi
          _verbs_json=$(jq -R -s '[split("\n")[] | select(length > 0)]' < "$_verbs_file")
          _count=$(echo "$_verbs_json" | jq 'length')
          if [[ "$_count" -eq 0 ]]; then
            printf '%b✗ No verbs found in %s%b\n' "$NF_RED" "$_verbs_file" "$NF_RST"
            exit 1
          fi
          # Back up existing spinnerVerbs if they exist and aren't nerdflair's
          if [[ -f "$NF_SETTINGS_FILE" ]] && jq -e '.spinnerVerbs' "$NF_SETTINGS_FILE" &>/dev/null; then
            # Check for a known nerdflair verb as fingerprint
            _is_nerdflair=$(jq '.spinnerVerbs.verbs // [] | map(select(contains("Chugging an estus flask"))) | length > 0' "$NF_SETTINGS_FILE")
            if [[ "$_is_nerdflair" != "true" ]]; then
              mkdir -p "$(dirname "$_backup_file")"
              jq '.spinnerVerbs' "$NF_SETTINGS_FILE" > "$_backup_file"
              printf '%b↗ Backed up existing spinner verbs to %s%b\n' "$NF_CYAN" "$_backup_file" "$NF_RST"
            fi
          fi
          # Write to settings.json
          if [[ ! -f "$NF_SETTINGS_FILE" ]]; then
            echo '{}' > "$NF_SETTINGS_FILE"
          fi
          _tmp="$NF_SETTINGS_FILE.tmp.$$"
          jq --argjson verbs "$_verbs_json" '.spinnerVerbs = {"mode": "replace", "verbs": $verbs}' "$NF_SETTINGS_FILE" > "$_tmp" && mv "$_tmp" "$NF_SETTINGS_FILE"
          printf '%b✓ Spinner verbs: on%b (%s verbs loaded). Restart Claude Code to apply.\n' "$NF_GREEN" "$NF_RST" "$_count"
        else
          # Restore backed-up spinnerVerbs, or remove entirely
          if [[ -f "$_backup_file" ]]; then
            _backup_json=$(cat "$_backup_file")
            _tmp="$NF_SETTINGS_FILE.tmp.$$"
            jq --argjson sv "$_backup_json" '.spinnerVerbs = $sv' "$NF_SETTINGS_FILE" > "$_tmp" && mv "$_tmp" "$NF_SETTINGS_FILE"
            rm "$_backup_file"
            printf '%b✓ Spinner verbs: restored%b (previous verbs recovered from backup). Restart Claude Code to apply.\n' "$NF_GREEN" "$NF_RST"
          else
            if [[ -f "$NF_SETTINGS_FILE" ]] && jq -e '.spinnerVerbs' "$NF_SETTINGS_FILE" &>/dev/null; then
              _tmp="$NF_SETTINGS_FILE.tmp.$$"
              jq 'del(.spinnerVerbs)' "$NF_SETTINGS_FILE" > "$_tmp" && mv "$_tmp" "$NF_SETTINGS_FILE"
            fi
            printf '%b✓ Spinner verbs: off%b (back to defaults). Restart Claude Code to apply.\n' "$NF_GREEN" "$NF_RST"
          fi
        fi
        exit 0

      else
        printf '%b✗ Unknown spinner-verbs action "%s"%b\n' "$NF_RED" "$_sv_action" "$NF_RST"
        printf '  Usage: nerdflair spinner-verbs [enable|disable]\n'
        exit 1
      fi
      ;;
    context-bar)
      # Legacy: silently ignore
      shift
      ;;
    color-palette|color)
      if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
        case "$2" in
          vibrant|muted|mono) set_color="$2"; shift 2 ;;
          *) printf '%b✗ Unknown palette "%s"%b\n' "$NF_RED" "$2" "$NF_RST"
             printf '  Valid palettes: vibrant, muted, mono\n'
             exit 1 ;;
        esac
      else
        cycle_color=true
        shift
      fi
      ;;
    install)
      # Idempotent install / upgrade: preserve user settings, refresh plugin state.
      if [[ ! -f "$NF_STATE_FILE" ]]; then
        NF_CUR_MODE="$NF_DEFAULT_MODE"
        NF_CUR_WIDTH="$NF_DEFAULT_WIDTH"
        NF_CUR_FLAIR="true"
        NF_CUR_COLOR="$NF_DEFAULT_COLOR"
        NF_CUR_TERMINAL_BELL="$NF_DEFAULT_TERMINAL_BELL"
        NF_CUR_CHIME_SOUND="$NF_DEFAULT_CHIME_SOUND"
        NF_CUR_CHIME_STYLE="$NF_DEFAULT_CHIME_STYLE"
        NF_CUR_CHIME_EVENTS="$NF_DEFAULT_CHIME_EVENTS"
        NF_CUR_CHIME_VOLUME="$NF_DEFAULT_CHIME_VOLUME"
        NF_CUR_LAST_SESSION=""
        _nf_write_state
        printf '%b✓ Settings initialized to defaults%b\n' "$NF_GREEN" "$NF_RST"
      else
        # Re-write state to apply migrations and clean up legacy fields
        _nf_write_state
        printf '%b✓ Existing settings preserved%b\n' "$NF_GREEN" "$NF_RST"
      fi

      # Configure statusLine
      _sl_cmd="bash ${SCRIPT_DIR}/statusline.sh"
      if [[ ! -f "$NF_SETTINGS_FILE" ]]; then
        echo '{}' > "$NF_SETTINGS_FILE"
      fi
      _tmp="$NF_SETTINGS_FILE.tmp.$$"
      jq --arg cmd "$_sl_cmd" '.statusLine = {"type": "command", "command": $cmd}' "$NF_SETTINGS_FILE" > "$_tmp" && mv "$_tmp" "$NF_SETTINGS_FILE"
      printf '%b✓ statusLine configured in settings.json%b\n' "$NF_GREEN" "$NF_RST"

      # Refresh spinnerVerbs if nerdflair spinners were previously enabled
      if [[ -f "$NF_SETTINGS_FILE" ]] && jq -e '.spinnerVerbs' "$NF_SETTINGS_FILE" &>/dev/null; then
        _is_nerdflair=$(jq '.spinnerVerbs.verbs // [] | map(select(contains("Chugging an estus flask"))) | length > 0' "$NF_SETTINGS_FILE")
        if [[ "$_is_nerdflair" == "true" ]]; then
          _verbs_file="$(cd "$SCRIPT_DIR/../assets/text" 2>/dev/null && pwd)/spinners.txt"
          if [[ -f "$_verbs_file" ]]; then
            _verbs_json=$(jq -R -s '[split("\n")[] | select(length > 0)]' < "$_verbs_file")
            _count=$(echo "$_verbs_json" | jq 'length')
            _tmp="$NF_SETTINGS_FILE.tmp.$$"
            jq --argjson verbs "$_verbs_json" '.spinnerVerbs = {"mode": "replace", "verbs": $verbs}' "$NF_SETTINGS_FILE" > "$_tmp" && mv "$_tmp" "$NF_SETTINGS_FILE"
            printf '%b✓ Spinner verbs refreshed%b (%s verbs)\n' "$NF_GREEN" "$NF_RST" "$_count"
          fi
        fi
      fi

      exit 0
      ;;
    uninstall)
      # Remove all nerdflair traces from ~/.claude
      _nerdflair_dir="$HOME/.claude/nerdflair"

      printf '%bUninstalling nerdflair...%b\n' "$NF_DIM" "$NF_RST"

      # Restore or remove spinnerVerbs from settings.json
      _backup_file="$_nerdflair_dir/spinnerVerbs.backup.json"
      if [[ -f "$_backup_file" ]]; then
        _backup_json=$(cat "$_backup_file")
        _tmp="$NF_SETTINGS_FILE.tmp.$$"
        jq --argjson sv "$_backup_json" '.spinnerVerbs = $sv' "$NF_SETTINGS_FILE" > "$_tmp" && mv "$_tmp" "$NF_SETTINGS_FILE"
        printf '  %b✓%b Restored previous spinnerVerbs from backup\n' "$NF_GREEN" "$NF_RST"
      elif [[ -f "$NF_SETTINGS_FILE" ]] && jq -e '.spinnerVerbs' "$NF_SETTINGS_FILE" &>/dev/null; then
        _tmp="$NF_SETTINGS_FILE.tmp.$$"
        jq 'del(.spinnerVerbs)' "$NF_SETTINGS_FILE" > "$_tmp" && mv "$_tmp" "$NF_SETTINGS_FILE"
        printf '  %b✓%b Removed spinnerVerbs from settings.json\n' "$NF_GREEN" "$NF_RST"
      else
        printf '  %b· No spinnerVerbs in settings.json%b\n' "$NF_DIM" "$NF_RST"
      fi

      # Remove statusLine from settings.json
      if [[ -f "$NF_SETTINGS_FILE" ]] && jq -e '.statusLine' "$NF_SETTINGS_FILE" &>/dev/null; then
        _tmp="$NF_SETTINGS_FILE.tmp.$$"
        jq 'del(.statusLine)' "$NF_SETTINGS_FILE" > "$_tmp" && mv "$_tmp" "$NF_SETTINGS_FILE"
        printf '  %b✓%b Removed statusLine from settings.json\n' "$NF_GREEN" "$NF_RST"
      else
        printf '  %b· No statusLine in settings.json%b\n' "$NF_DIM" "$NF_RST"
      fi

      # Remove nerdflair data directory
      if [[ -d "$_nerdflair_dir" ]]; then
        rm -rf "$_nerdflair_dir"
        printf '  %b✓%b Removed ~/.claude/nerdflair/\n' "$NF_GREEN" "$NF_RST"
      else
        printf '  %b· No ~/.claude/nerdflair/ directory%b\n' "$NF_DIM" "$NF_RST"
      fi

      printf '\n%b✓ Uninstall complete.%b Restart Claude Code to apply.\n' "$NF_GREEN" "$NF_RST"
      printf '%b  The plugin files themselves remain in place — disable or remove\n' "$NF_DIM"
      printf '  the plugin from Claude Code settings to fully remove.%b\n' "$NF_RST"
      exit 0
      ;;
    *)
      # Treat as layout mode for backwards compat
      if [[ -z "$next_mode" ]]; then
        if ! _nf_valid_mode "$1"; then
          printf '%b✗ Unknown command "%s"%b\n' "$NF_RED" "$1" "$NF_RST"
          printf '  Commands: chime-events, chime-session, chime-style, chime-volume,\n'
          printf '            color-palette, layout, spinner-verbs, terminal-bell, uninstall, width\n'
          exit 1
        fi
        next_mode="$1"
      fi
      shift
      ;;
  esac
done

# ── Info mode: print current state and exit ─────────────────────
if [[ "$show_info" == "true" ]]; then
  case "$current_mode" in
    full)    mode_desc="3 rows -- folder/branch, progress bar, mcp/cost" ;;
    compact) mode_desc="2 rows -- folder/branch, progress bar (cost in bar)" ;;
    minimal) mode_desc="1 row  -- progress bar only" ;;
    *)       mode_desc="unknown layout" ;;
  esac

  printf '%bStatusline: %s%b (%s)' "$NF_CYAN" "$current_mode" "$NF_RST" "$mode_desc"
  if [[ "$current_width" == "auto" ]]; then
    printf ' %bwidth: auto%b' "$NF_DIM" "$NF_RST"
  else
    printf ' %bwidth: %s%b' "$NF_DIM" "$current_width" "$NF_RST"
  fi
  if [[ "$current_terminal_bell" == "on" ]]; then
    printf ' %bterminal-bell: on%b' "$NF_GREEN" "$NF_RST"
  else
    printf ' %bterminal-bell: off%b' "$NF_DIM" "$NF_RST"
  fi
  _vol_pct=$(awk -v v="$current_chime_volume" 'BEGIN {printf "%g", v * 100}')
  if [[ "$_vol_pct" == "0" ]]; then
    printf ' %bchime-volume: muted%b' "$NF_DIM" "$NF_RST"
  else
    printf ' %bchime-volume: %s%%%b %b(%s)%b' "$NF_GREEN" "$_vol_pct" "$NF_RST" "$NF_DIM" "$current_chime_style" "$NF_RST"
    _evt_count=$(echo "$current_chime_events" | tr ',' '\n' | grep -c . || true)
    printf ' %b(%s events)%b' "$NF_DIM" "$_evt_count" "$NF_RST"
  fi
  if [[ "$current_color" == "vibrant" ]]; then
    printf ' %bcolor-palette: vibrant%b' "$NF_DIM" "$NF_RST"
  elif [[ "$current_color" == "mono" ]]; then
    printf ' %bcolor-palette: mono%b' "$NF_GREEN" "$NF_RST"
  elif [[ "$current_color" == "muted" ]]; then
    printf ' %bcolor-palette: muted%b' "$NF_GREEN" "$NF_RST"
  fi
  if [[ -f "$NF_SETTINGS_FILE" ]] && jq -e '.spinnerVerbs' "$NF_SETTINGS_FILE" &>/dev/null; then
    _sv_count=$(jq '.spinnerVerbs.verbs | length' "$NF_SETTINGS_FILE")
    printf ' %bspinner-verbs: on (%s)%b' "$NF_GREEN" "$_sv_count" "$NF_RST"
  else
    printf ' %bspinner-verbs: off%b' "$NF_DIM" "$NF_RST"
  fi
  printf '\n'
  exit 0
fi

# Handle flair toggle
next_flair="true"  # flair is always on

# Handle terminal-bell toggle: on → off → on
next_terminal_bell="$current_terminal_bell"
if [[ "$toggle_terminal_bell" == "true" ]]; then
  if [[ "$current_terminal_bell" == "on" ]]; then
    next_terminal_bell="off"
  else
    next_terminal_bell="on"
  fi
fi

next_chime_sound="$current_chime_sound"

# Handle chime-style: cycle or set directly
AUDIO_DIR="$(cd "$SCRIPT_DIR/../assets/audio" 2>/dev/null && pwd)" || AUDIO_DIR=""
_available_styles=("random")
if [[ -n "$AUDIO_DIR" && -d "$AUDIO_DIR" ]]; then
  while IFS= read -r d; do
    _available_styles+=("$(basename "$d")")
  done < <(find "$AUDIO_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
fi

next_chime_style="$current_chime_style"
if [[ -n "$set_chime_style" ]]; then
  _matched=""
  for s in "${_available_styles[@]}"; do
    if [[ "$(_nf_lower "$s")" == "$(_nf_lower "$set_chime_style")" ]]; then
      _matched="$s"
      break
    fi
  done
  if [[ -n "$_matched" ]]; then
    next_chime_style="$_matched"
  else
    printf '%b✗ Unknown chime style "%s"%b\n' "$NF_RED" "$set_chime_style" "$NF_RST"
    printf '  Available: %s\n' "${_available_styles[*]}"
    exit 1
  fi
elif [[ "$cycle_chime_style" == "true" ]]; then
  _found=false
  for i in "${!_available_styles[@]}"; do
    if [[ "${_available_styles[$i]}" == "$current_chime_style" ]]; then
      _next_idx=$(( (i + 1) % ${#_available_styles[@]} ))
      next_chime_style="${_available_styles[$_next_idx]}"
      _found=true
      break
    fi
  done
  if [[ "$_found" == "false" ]]; then
    next_chime_style="random"
  fi
fi

# Handle chime-events: toggle individual events or show current
next_chime_events="$current_chime_events"
if [[ "$toggle_chime_event" == "__show__" ]]; then
  printf '%bChime events:%b\n' "$NF_CYAN" "$NF_RST"
  for evt in $NF_ALL_CHIME_EVENTS; do
    if echo ",$current_chime_events," | grep -q ",$evt,"; then
      printf '  %b✓ %s%b\n' "$NF_GREEN" "$evt" "$NF_RST"
    else
      printf '  %b✗ %s%b\n' "$NF_DIM" "$evt" "$NF_RST"
    fi
  done
  printf '\n%bToggle with: nerdflair chime-events <EventName>%b\n' "$NF_DIM" "$NF_RST"
  exit 0
elif [[ -n "$toggle_chime_event" ]]; then
  _valid_event=false
  for evt in $NF_ALL_CHIME_EVENTS; do
    if [[ "$evt" == "$toggle_chime_event" ]]; then
      _valid_event=true
      break
    fi
  done
  if [[ "$_valid_event" == "false" ]]; then
    printf '%b✗ Unknown event "%s"%b\n' "$NF_RED" "$toggle_chime_event" "$NF_RST"
    printf '  Valid events: %s\n' "$NF_ALL_CHIME_EVENTS"
    exit 1
  fi
  if echo ",$current_chime_events," | grep -q ",$toggle_chime_event,"; then
    # Remove event from comma-separated list using exact-match sandwich to avoid
    # substring corruption (e.g. removing "Stop" must not damage "UserPromptSubmit")
    next_chime_events=$(printf ',%s,' "$current_chime_events" | sed "s/,$toggle_chime_event,/,/" | sed 's/^,//;s/,$//')
  else
    if [[ -z "$current_chime_events" ]]; then
      next_chime_events="$toggle_chime_event"
    else
      next_chime_events="$current_chime_events,$toggle_chime_event"
    fi
  fi
fi

# Handle color-palette: set directly or cycle
next_color="$current_color"
if [[ -n "$set_color" ]]; then
  next_color="$set_color"
elif [[ "$cycle_color" == "true" ]]; then
  case "$current_color" in
    vibrant) next_color="muted" ;;
    muted)   next_color="mono" ;;
    mono)    next_color="vibrant" ;;
    *)       next_color="vibrant" ;;
  esac
fi

# If no action specified at all — cycle layout
if [[ -z "$next_mode" && "$cycle_layout" == "false" && "$toggle_terminal_bell" == "false" && "$cycle_chime_style" == "false" && -z "$set_chime_style" && -z "$toggle_chime_event" && -z "$set_volume" && "$cycle_color" == "false" && -z "$set_color" && -z "$next_width" ]]; then
  cycle_layout=true
fi

if [[ "$cycle_layout" == "true" && -z "$next_mode" ]]; then
  case "$current_mode" in
    full)    next_mode="compact" ;;
    compact) next_mode="minimal" ;;
    *)       next_mode="full" ;;
  esac
fi

# Apply: keep current values for anything not explicitly changed
next_mode="${next_mode:-$current_mode}"
next_width="${next_width:-$current_width}"
next_chime_volume="${set_volume:-$current_chime_volume}"

# Write new state using jq (preserves chime_recent_styles automatically)
NF_CUR_MODE="$next_mode"
NF_CUR_WIDTH="$next_width"
NF_CUR_FLAIR="$next_flair"
NF_CUR_TERMINAL_BELL="$next_terminal_bell"
NF_CUR_CHIME_SOUND="$next_chime_sound"
NF_CUR_CHIME_VOLUME="$next_chime_volume"
NF_CUR_CHIME_STYLE="$next_chime_style"
NF_CUR_CHIME_EVENTS="$next_chime_events"
NF_CUR_COLOR="$next_color"
_nf_write_state

# ── Visual feedback ──────────────────────────────────────────────
case "$next_mode" in
  full)    mode_desc="3 rows -- folder/branch, progress bar, mcp/cost" ;;
  compact) mode_desc="2 rows -- folder/branch, progress bar (cost in bar)" ;;
  minimal) mode_desc="1 row  -- progress bar only" ;;
  *)       mode_desc="unknown layout" ;;
esac

printf '%b⟳ Statusline → %s%b (%s)' "$NF_CYAN" "$next_mode" "$NF_RST" "$mode_desc"

if [[ "$next_width" == "auto" ]]; then
  printf ' %bwidth: auto%b' "$NF_DIM" "$NF_RST"
else
  printf ' %bwidth: %s%b' "$NF_DIM" "$next_width" "$NF_RST"
fi

if [[ "$next_terminal_bell" == "on" ]]; then
  printf ' %bterminal-bell: on%b' "$NF_GREEN" "$NF_RST"
else
  printf ' %bterminal-bell: off%b' "$NF_DIM" "$NF_RST"
fi
_vol_pct=$(awk -v v="$next_chime_volume" 'BEGIN {printf "%g", v * 100}')
if [[ "$_vol_pct" == "0" ]]; then
  printf ' %bchime-volume: muted%b' "$NF_DIM" "$NF_RST"
else
  printf ' %bchime-volume: %s%%%b %b(%s)%b' "$NF_GREEN" "$_vol_pct" "$NF_RST" "$NF_DIM" "$next_chime_style" "$NF_RST"
  _evt_count=$(echo "$next_chime_events" | tr ',' '\n' | grep -c . || true)
  printf ' %b(%s events)%b' "$NF_DIM" "$_evt_count" "$NF_RST"
fi

if [[ "$next_color" == "vibrant" ]]; then
  printf ' %bcolor-palette: vibrant%b' "$NF_DIM" "$NF_RST"
elif [[ "$next_color" == "mono" ]]; then
  printf ' %bcolor-palette: mono%b' "$NF_GREEN" "$NF_RST"
elif [[ "$next_color" == "muted" ]]; then
  printf ' %bcolor-palette: muted%b' "$NF_GREEN" "$NF_RST"
fi
printf '\n'
