#!/bin/bash
# screenshot.sh — Generate deterministic nerdflair screenshots for docs.
#
# Renders multiple statusline variations by calling the real
# statusline.sh with controlled inputs:
#   (1) Full layout × 3 color modes (vibrant, muted, mono)
#   (2) Compact layout (vibrant)
#   (3) Minimal layout (vibrant)
#
# The model segment includes the xhigh effort label, the thinking glyph,
# the explanatory style icon, and the fast-mode glyph so the gallery
# exercises all of the model-state suffixes.
#
# Usage:
#   ./scripts/screenshot.sh              # render to terminal
#   ./scripts/screenshot.sh > out.txt    # capture with ANSI codes (out.txt is gitignored)
#
# The script creates a throwaway git repo in /tmp so the real renderer
# picks up the folder name, branch, and diff stats we want.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDERER="$SCRIPT_DIR/statusline.sh"

# ── Configurable dummy values ────────────────────────────────────
FOLDER="todos-app"
BRANCH="feature/reminders"
MODEL_ID="us.anthropic.claude-fable-5-1-v1"
OUTPUT_STYLE="explanatory"
SESSION_ID="screenshot-session-fixed-id-0001"
COST_USD="12.83"
API_DURATION_MS="1560000"  # 26 minutes
CONTEXT_USED_PCT="83"
INPUT_TOKENS="60000"
OUTPUT_TOKENS="24000"
CTX_WINDOW_SIZE="200000"
# Edit stats: 3 dirty files, +153 / -14 lines
DIRTY_FILE_COUNT=3
LINES_ADDED=153
LINES_REMOVED=14

# ── Build sandboxed environment ──────────────────────────────────
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

FAKE_HOME="$TMPDIR_ROOT/home"
mkdir -p "$FAKE_HOME/.claude/nerdflair"

FAKE_CWD="$TMPDIR_ROOT/workspace/$FOLDER"
mkdir -p "$FAKE_CWD"

# Create a git repo with the right branch and dirty state
(
  cd "$FAKE_CWD"
  git init -q
  git checkout -q -b main

  # Initial commit: put LINES_REMOVED lines in file1 only (will be erased)
  for j in $(seq 1 "$LINES_REMOVED"); do
    echo "original line $j" >> "file1.txt"
  done
  # file2 and file3 start empty (they only gain lines, so pure additions)
  touch file2.txt file3.txt
  git add -A
  git commit -q -m "initial"

  # Switch to feature branch
  git checkout -q -b "$BRANCH"

  # Dirty state: erase file1 so all LINES_REMOVED count as removals
  > file1.txt
  # Spread LINES_ADDED across all 3 files
  lines_per_file=$(( LINES_ADDED / DIRTY_FILE_COUNT ))
  remainder=$(( LINES_ADDED % DIRTY_FILE_COUNT ))
  for i in $(seq 1 "$DIRTY_FILE_COUNT"); do
    count=$lines_per_file
    (( i <= remainder )) && (( count++ ))
    for j in $(seq 1 "$count"); do
      echo "new line $j in file $i" >> "file${i}.txt"
    done
  done
) >/dev/null 2>&1

# Write MCP config (Glean, Gmail, Slack)
cat > "$FAKE_HOME/.claude.json" << 'MCPEOF'
{"mcpServers":{"Glean":{},"Gmail":{},"Slack":{}}}
MCPEOF


# ── Helper: write state file and render ──────────────────────────
render_variation() {
  local mode="$1"
  local color="$2"
  local pct_override="${3:-}"
  local label="$4"

  # Section header: centered label
  if [[ -n "$label" ]]; then
    local LABEL_COLOR='\033[1;38;2;35;38;42m'
    local HEADER_RESET='\033[0m'
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    local label_len=${#label}
    local pad=$(( (cols - label_len) / 2 ))
    (( pad < 0 )) && pad=0
    local spaces
    spaces=$(printf '%*s' "$pad" '')
    printf '\n\n%s%b%s%b\n' "$spaces" "$LABEL_COLOR" "$label" "$HEADER_RESET"
  else
    printf '\n\n'
  fi

  # Write state file into the sandboxed HOME
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" << STATEEOF
{"mode": "$mode", "width": "auto", "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "$color", "last_session": "$SESSION_ID"}
STATEEOF

  # Write session file as JSON (chime style)
  mkdir -p "$FAKE_HOME/.claude/nerdflair/sessions"
  printf '{"chime":"TestStyle"}\n' > "$FAKE_HOME/.claude/nerdflair/sessions/$SESSION_ID"

  # Build JSON payload
  local json_input json_pct json_tokens json_cost json_api_ms
  json_pct="${pct_override:-$CONTEXT_USED_PCT}"
  json_tokens=$(( CTX_WINDOW_SIZE * json_pct / 100 ))
  json_cost="$COST_USD"
  json_api_ms="$API_DURATION_MS"
  json_input=$(cat << JSONEOF
{
  "workspace": {
    "current_dir": "$FAKE_CWD",
    "project_dir": "$FAKE_CWD"
  },
  "model": {
    "id": "$MODEL_ID"
  },
  "effort": {
    "level": "xhigh"
  },
  "thinking": {
    "enabled": true
  },
  "fast_mode": true,
  "cost": {
    "total_cost_usd": $json_cost,
    "total_duration_ms": $json_api_ms,
    "total_api_duration_ms": $json_api_ms
  },
  "output_style": {
    "name": "$OUTPUT_STYLE"
  },
  "session_id": "$SESSION_ID",
  "context_window": {
    "used_percentage": $json_pct,
    "total_input_tokens": $json_tokens,
    "total_output_tokens": $json_tokens,
    "context_window_size": $CTX_WINDOW_SIZE
  }
}
JSONEOF
  )

  # Run the renderer with an overridden HOME so it reads our state file
  printf '%s' "$json_input" | HOME="$FAKE_HOME" bash "$RENDERER"
}

# ── (1) Full layout × 3 color modes ─────────────────────────────
render_variation "full" "vibrant" "" "Color: vibrant"

render_variation "full" "muted"   "" "Color: muted"

render_variation "full" "mono"    "" "Color: mono"

# ── (2) Compact layout ───────────────────────────────────────────
render_variation "compact" "vibrant" "" "Layout: compact"

# ── (3) Minimal layout ──────────────────────────────────────────
render_variation "minimal" "vibrant" "" "Layout: minimal"

printf '\n\n'
