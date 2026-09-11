#!/usr/bin/env bash
# Tests for nerdflair plugin scripts.
#
# Usage:
#   ./plugins/nerdflair/tests/test-nerdflair.sh
#   TRACE=1 ./plugins/nerdflair/tests/test-nerdflair.sh

set -euo pipefail
if [[ "${TRACE-0}" == "1" ]]; then
  set -o xtrace
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RENDERER="$PLUGIN_ROOT/scripts/statusline.sh"
CONFIGURATOR="$PLUGIN_ROOT/scripts/nerdflair.sh"
BELL="$PLUGIN_ROOT/hooks/bell.sh"

# ── Test harness ────────────────────────────────────────────────
_pass=0
_fail=0
_errors=()

_setup() {
  TMPDIR_ROOT=$(mktemp -d)
  FAKE_HOME="$TMPDIR_ROOT/home"
  mkdir -p "$FAKE_HOME/.claude/nerdflair"

  FAKE_CWD="$TMPDIR_ROOT/workspace/my-project"
  mkdir -p "$FAKE_CWD"

  # Minimal git repo so renderer can detect branch
  (
    cd "$FAKE_CWD"
    git init -q
    git checkout -q -b main
    echo "hello" > file.txt
    git add -A
    git commit -q -m "init"
    git checkout -q -b feature/test-branch
    echo "change" >> file.txt
  ) >/dev/null 2>&1
}

# Exercise the empty-bar (logo) and full-bar paths, which most tests skip.
test_renderer_bar_at_zero_and_full() {
  _setup
  local state='{"mode": "compact", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  echo "$state" > "$FAKE_HOME/.claude/nerdflair/state.json"
  local err_file="$TMPDIR_ROOT/err" out0 out100
  out0=$(_make_input 0 0.00 | HOME="$FAKE_HOME" bash "$RENDERER" 2>"$err_file" | _strip_ansi)
  assert_equals "no errors at 0%" "" "$(cat "$err_file")"
  assert_contains "logo glyph shown at 0%" "$out0" $'\xf3\xb0\xaf\xb4'
  out100=$(_make_input 100 9.99 | HOME="$FAKE_HOME" bash "$RENDERER" 2>"$err_file" | _strip_ansi)
  assert_equals "no errors at 100%" "" "$(cat "$err_file")"
  assert_contains "label shown at 100%" "$out100" "100%"
  _teardown
}

_teardown() {
  rm -rf "$TMPDIR_ROOT"
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: $label — expected to contain '$needle'")
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: $label — expected NOT to contain '$needle'")
  fi
}

assert_equals() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: $label — expected '$expected', got '$actual'")
  fi
}

assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: $label — expected exit code $expected, got $actual")
  fi
}

# Strip ANSI escape codes for text assertions
_strip_ansi() {
  sed $'s/\033\\[[0-9;]*m//g'
}

# Build a JSON payload for the renderer
_make_input() {
  local pct="${1:-42}" cost="${2:-5.00}" model="${3:-us.anthropic.claude-opus-4-6-v1}" display="${4:-}"
  local tokens=$(( 200000 * pct / 100 ))
  local model_json="{\"id\": \"$model\"}"
  [[ -n "$display" ]] && model_json="{\"id\": \"$model\", \"display_name\": \"$display\"}"
  cat <<EOF
{
  "workspace": {"current_dir": "$FAKE_CWD", "project_dir": "$FAKE_CWD"},
  "model": $model_json,
  "cost": {"total_cost_usd": $cost, "total_duration_ms": 120000, "total_api_duration_ms": 120000},
  "output_style": {"name": "default"},
  "session_id": "test-session-001",
  "context_window": {
    "used_percentage": $pct,
    "total_input_tokens": $tokens,
    "total_output_tokens": 0,
    "context_window_size": 200000
  }
}
EOF
}

# Run the renderer with a given state and input
_render() {
  local state="$1" input="$2"
  echo "$state" > "$FAKE_HOME/.claude/nerdflair/state.json"
  printf '%s' "$input" | HOME="$FAKE_HOME" bash "$RENDERER"
}

# Run the configurator
_configure() {
  HOME="$FAKE_HOME" bash "$CONFIGURATOR" "$@"
}

# Read a field from the state file
_state_field() {
  local field="$1"
  grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$FAKE_HOME/.claude/nerdflair/state.json" \
    | head -1 | sed 's/.*"\([^"]*\)"/\1/'
}

_state_field_raw() {
  local field="$1"
  grep -o "\"$field\"[[:space:]]*:[[:space:]]*[a-z]*" "$FAKE_HOME/.claude/nerdflair/state.json" \
    | head -1 | sed 's/.*:[[:space:]]*//'
}

# ════════════════════════════════════════════════════════════════
# RENDERER TESTS
# ════════════════════════════════════════════════════════════════

test_renderer_full_mode_has_three_rows() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 5.00)")
  # Full mode: row1 (folder/branch), row2 (bar on its own line), row3 (logos/cost)
  local line_count
  line_count=$(echo "$output" | wc -l | tr -d ' ')
  # The bar prints a leading \n, so full mode = row1 + \n + bar + \n + row3 = 3 content lines
  if (( line_count >= 3 )); then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: full mode should have >= 3 lines, got $line_count")
  fi
  _teardown
}

test_renderer_compact_mode_has_two_rows() {
  _setup
  local state='{"mode": "compact", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 5.00)")
  local line_count
  line_count=$(echo "$output" | wc -l | tr -d ' ')
  # Compact: row1 + \n + bar = 2 content lines
  if (( line_count >= 2 && line_count < 4 )); then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: compact mode should have 2-3 lines, got $line_count")
  fi
  _teardown
}

test_renderer_minimal_mode_has_one_row() {
  _setup
  local state='{"mode": "minimal", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 5.00)")
  local line_count
  line_count=$(echo "$output" | wc -l | tr -d ' ')
  assert_equals "minimal mode line count" "$line_count" "1"
  _teardown
}

test_renderer_shows_folder_name() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input)" | _strip_ansi)
  assert_contains "folder name in output" "$output" "my-project"
  _teardown
}

test_renderer_shows_branch() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input)" | _strip_ansi)
  assert_contains "branch in output" "$output" "feature/test-branch"
  _teardown
}

# Regression: with neither workspace.project_dir nor workspace.current_dir set,
# the folder/branch block is skipped, so anything it initializes must still have
# a default. _branch_is_multi used to be set only inside that block, so under
# `set -u` the later multi-repo truncation check aborted the whole render.
test_renderer_no_workspace_dir_does_not_crash() {
  _setup
  local state='{"mode": "full", "width": "94", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local input='{"model": {"display_name": "Opus 4.8"}, "context_window": {"used_percentage": 50, "total_input_tokens": 500000, "context_window_size": 1000000}}'
  echo "$state" > "$FAKE_HOME/.claude/nerdflair/state.json"
  local err_file="$FAKE_HOME/.claude/nerdflair/render.err"
  local output
  output=$(printf '%s' "$input" | HOME="$FAKE_HOME" bash "$RENDERER" 2>"$err_file")
  local status=$?
  assert_exit_code "render without workspace dir exits 0" "0" "$status"
  # No unbound-variable (or any) diagnostics should reach stderr.
  local err
  err=$(cat "$err_file")
  assert_equals "render without workspace dir has empty stderr" "" "$err"
  # Still renders the model + context label.
  assert_contains "renders model without workspace dir" "$(printf '%s' "$output" | _strip_ansi)" "Opus 4.8"
  _teardown
}

test_renderer_shows_model_name() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 5.00 us.anthropic.claude-opus-4-6-v1)" | _strip_ansi)
  assert_contains "model name opus" "$output" "Opus 4.6"
  _teardown
}

test_renderer_shows_sonnet_model() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 5.00 us.anthropic.claude-sonnet-4-6-v1)" | _strip_ansi)
  assert_contains "model name sonnet" "$output" "Sonnet 4.6"
  _teardown
}

test_renderer_prefers_display_name() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 5.00 claude-fable-5 "Fable 5")" | _strip_ansi)
  assert_contains "model display_name fable" "$output" "Fable 5"
  _teardown
}

test_renderer_strips_context_suffix_from_display_name() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 5.00 claude-opus-4-8 "Opus 4.8 (1M context)")" | _strip_ansi)
  assert_contains "model display_name opus" "$output" "Opus 4.8"
  assert_not_contains "context window size hidden" "$output" "1M context"
  _teardown
}

test_renderer_falls_back_to_id_parsing() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 5.00 us.anthropic.claude-haiku-4-5-v1)" | _strip_ansi)
  assert_contains "model id fallback haiku" "$output" "Haiku 4.5"
  _teardown
}

test_renderer_shows_context_percentage() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 65)" | _strip_ansi)
  assert_contains "context percentage" "$output" "65%"
  _teardown
}

test_renderer_shows_cost() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 42 12.50)" | _strip_ansi)
  assert_contains "cost in output" "$output" "12.50"
  _teardown
}

# Claude Code spawns the statusline with a minimal environment (no LANG), so
# number grouping must not depend on the locale. Run these under LC_ALL=C.
test_renderer_cost_has_thousands_separator() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(LC_ALL=C _render "$state" "$(_make_input 42 1224.92)" | _strip_ansi)
  assert_contains "cost with comma" "$output" '1,224.92'
  _teardown
}

test_renderer_lines_added_has_thousands_separator() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  # Fixture already has 1 added line; append 1662 more for 1663 total
  (cd "$FAKE_CWD" && seq 1 1662 >> file.txt)
  local output
  output=$(LC_ALL=C _render "$state" "$(_make_input 42 5.00)" | _strip_ansi)
  assert_contains "lines added with comma" "$output" '+1,663'
  _teardown
}

test_renderer_git_cache_lives_under_home() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  _render "$state" "$(_make_input 42 5.00)" >/dev/null
  local n
  n=$(ls "$FAKE_HOME/.claude/nerdflair/cache/" 2>/dev/null | grep -c '^git-' || true)
  assert_equals "git cache written under HOME, not /tmp" "$n" "1"
  _teardown
}

# Cache contents feed (( )) arithmetic; a planted cache must not execute code.
test_renderer_poisoned_git_cache_is_inert() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  mkdir -p "$FAKE_HOME/.claude/nerdflair/cache"
  local hash
  hash=$(printf '%s' "$FAKE_CWD" | cksum | cut -d' ' -f1)
  printf 'a[$(touch %s/pwned)]\n0\n0\nmain\n0' "$TMPDIR_ROOT" > "$FAKE_HOME/.claude/nerdflair/cache/git-$hash"
  local output
  output=$(_render "$state" "$(_make_input 42 5.00)" 2>/dev/null | _strip_ansi)
  local executed="no"
  [[ -e "$TMPDIR_ROOT/pwned" ]] && executed="yes"
  assert_equals "poisoned cache did not execute" "$executed" "no"
  assert_contains "still renders a row" "$output" "my-project"
  _teardown
}

# current_dir == project_dir is the normal case; the same .mcp.json must not be
# read twice and list every server twice.
test_renderer_mcp_servers_listed_once() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  echo '{"mcpServers":{"alpha":{},"beta":{}}}' > "$FAKE_CWD/.mcp.json"
  local output
  output=$(_render "$state" "$(_make_input 42 5.00)" | _strip_ansi)
  assert_contains "both servers listed" "$output" "alpha, beta"
  assert_not_contains "servers not duplicated" "$output" "alpha, alpha"
  _teardown
}

# Claude Code may send used_percentage as a float; bash arithmetic must not choke.
test_renderer_accepts_fractional_used_percentage() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local input err_file="$TMPDIR_ROOT/err"
  input=$(_make_input 42 5.00 | sed 's/"used_percentage": 42/"used_percentage": 42.5/')
  local output
  output=$(printf '%s' "$input" | HOME="$FAKE_HOME" bash "$RENDERER" 2>"$err_file" | _strip_ansi)
  assert_equals "no arithmetic error on float percentage" "" "$(cat "$err_file")"
  assert_contains "percentage truncated to integer" "$output" "42%"
  _teardown
}

# .mcp.json in a cloned repo is attacker-controlled; escape bytes in a server
# name must never reach the terminal.
test_renderer_strips_escape_bytes_from_mcp_names() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  printf '{"mcpServers":{"srv\\u001b[5mBLINK":{}}}' > "$FAKE_CWD/.mcp.json"
  local raw
  raw=$(_render "$state" "$(_make_input 42 5.00)")
  assert_not_contains "blink escape not emitted" "$raw" $'\033[5m'
  assert_contains "printable part of name still shown" "$(printf "%s" "$raw" | _strip_ansi)" "srv[5mBLINK"
  _teardown
}

test_renderer_mcp_name_star_is_not_glob_expanded() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  echo '{"mcpServers":{"*":{}}}' > "$FAKE_CWD/.mcp.json"
  local output
  output=$(_render "$state" "$(_make_input 42 5.00)" | _strip_ansi)
  assert_not_contains "star not expanded to cwd files" "$output" "file.txt"
  _teardown
}

test_renderer_non_numeric_chime_volume_does_not_error() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1)", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local err_file="$TMPDIR_ROOT/err"
  echo "$state" > "$FAKE_HOME/.claude/nerdflair/state.json"
  _make_input 42 5.00 | HOME="$FAKE_HOME" bash "$RENDERER" >/dev/null 2>"$err_file"
  assert_equals "no awk syntax error from state value" "" "$(cat "$err_file")"
  _teardown
}

# Rows must be exactly COLUMNS wide, and the same width whether or not the
# spawning environment has a UTF-8 locale (Claude Code passes no LANG).
_row_widths() {
  sed $'s/\033\\[[0-9;]*m//g' | awk 'NF' | while IFS= read -r line; do
    printf '%s ' "$(printf '%s' "$line" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')"
  done
}
test_renderer_rows_match_columns_in_any_locale() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  echo "$state" > "$FAKE_HOME/.claude/nerdflair/state.json"
  local w_c w_utf
  w_c=$(_make_input 42 5.00 | COLUMNS=100 LC_ALL=C HOME="$FAKE_HOME" bash "$RENDERER" | _row_widths)
  w_utf=$(_make_input 42 5.00 | COLUMNS=100 LC_ALL=en_US.UTF-8 HOME="$FAKE_HOME" bash "$RENDERER" | _row_widths)
  assert_equals "rows are 100 wide under UTF-8" "$w_utf" "100 100 100 "
  assert_equals "rows are 100 wide under C locale" "$w_c" "100 100 100 "
  _teardown
}

# Rewriting state.json on every render races with the configurator's writes.
test_renderer_does_not_rewrite_state_when_session_unchanged() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  _render "$state" "$(_make_input 42 5.00)" >/dev/null
  local before after
  before=$(stat -f %m "$FAKE_HOME/.claude/nerdflair/state.json" 2>/dev/null || stat -c %Y "$FAKE_HOME/.claude/nerdflair/state.json")
  sleep 1
  _make_input 42 5.00 | HOME="$FAKE_HOME" bash "$RENDERER" >/dev/null
  after=$(stat -f %m "$FAKE_HOME/.claude/nerdflair/state.json" 2>/dev/null || stat -c %Y "$FAKE_HOME/.claude/nerdflair/state.json")
  assert_equals "state file untouched on second render" "$before" "$after"
  _teardown
}

# A linked worktree in a repo with no origin remote must still get the tree icon.
test_renderer_worktree_icon_without_remote() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  (cd "$FAKE_CWD" && git worktree add -q "$TMPDIR_ROOT/wt" -b wt-branch) >/dev/null 2>&1
  local input output
  input=$(_make_input 42 5.00 | sed "s|$FAKE_CWD|$TMPDIR_ROOT/wt|g")
  echo "$state" > "$FAKE_HOME/.claude/nerdflair/state.json"
  output=$(printf '%s' "$input" | HOME="$FAKE_HOME" bash "$RENDERER" | _strip_ansi)
  assert_contains "tree icon on worktree folder" "$output" $'\xef\x86\xbb wt'
  _teardown
}

# Claude Code kills slow renders with SIGTERM; the output buffer must not leak.
test_renderer_removes_buffer_when_killed() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  echo "$state" > "$FAKE_HOME/.claude/nerdflair/state.json"
  local i
  for i in 1 2 3; do
    _make_input 42 5.00 | TMPDIR="$TMPDIR_ROOT" HOME="$FAKE_HOME" bash "$RENDERER" >/dev/null 2>&1 &
    local pid=$!
    sleep 0.05
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  local leaked
  leaked=$(ls "$TMPDIR_ROOT" | grep -c '^nerdflair-sl\.' || true)
  assert_equals "no leaked output buffers after SIGTERM" "$leaked" "0"
  _teardown
}

# Regression for the "500 shows light on green" report. A label glyph landing on
# the fill→empty transition-cap cell must render as part of the fill (covered
# near-black text on the fill background), not with the light empty-area text on
# the dark empty background. The cap cell is the visual cell right after the
# last filled body cell; the fill normally draws a rounded glyph there, so a
# light digit in that cell reads as "light where the fill still is".
#
# Reproduces the exact screenshot geometry: width 94, a 1M context window at
# 50%, giving the label "500k/1M 50%". The boundary falls on the "1", so the
# covered (near-black on fill) run must be "500k/1" = 6 glyphs. Before the fix
# the cap "1" was light-on-empty and only "500k/" = 5 glyphs were covered.
test_renderer_label_covers_transition_cap() {
  _setup
  local state='{"mode": "full", "width": "94", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local input
  input=$(cat <<EOF
{
  "workspace": {"current_dir": "$FAKE_CWD", "project_dir": "$FAKE_CWD"},
  "model": {"display_name": "Opus 4.8"},
  "session_id": "test-session-cap",
  "context_window": {
    "used_percentage": 50,
    "total_input_tokens": 500000,
    "total_output_tokens": 0,
    "context_window_size": 1000000
  }
}
EOF
)
  local covered
  covered=$(_render "$state" "$input" | python3 -c '
import re, sys
COVERED = "18;20;25"                 # near-black FG on filled bar
EMPTY_BGS = {"35;38;45", "18;20;25"} # empty bg, compact-dark bg
for line in sys.stdin.read().split("\n"):
    if "%" not in line or "/" not in line:
        continue
    fg = bg = ""; n = 0
    for part in re.split(r"(\x1b\[[0-9;]*m)", line):
        m = re.match(r"\x1b\[([0-9;]*)m", part)
        if m:
            c = m.group(1)
            if c.startswith("38;2;"): fg = c[5:]
            elif c.startswith("48;2;"): bg = c[5:]
            elif c == "0": fg = bg = ""
            continue
        for ch in part:
            if ch in "0123456789kM%/" and fg == COVERED and bg not in EMPTY_BGS and bg != "":
                n += 1
    print(n); break
')
  # "500k/1" = 6 covered glyphs on the fill (was 5 before the cap fix).
  assert_equals "label covers transition cap (covered glyph count)" "$covered" "6"
  _teardown
}

test_renderer_zero_cost_not_shown() {
  _setup
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input 10 0)" | _strip_ansi)
  # Row 3 should not show $0.00
  assert_not_contains "zero cost hidden" "$output" '$0.00'
  _teardown
}

test_renderer_mcp_servers_shown() {
  _setup
  cat > "$FAKE_HOME/.claude.json" << 'EOF'
{"mcpServers":{"Slack":{},"Glean":{}}}
EOF
  local state='{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}'
  local output
  output=$(_render "$state" "$(_make_input)" | _strip_ansi)
  assert_contains "MCP servers in output" "$output" "Glean"
  _teardown
}

test_renderer_no_state_file_uses_defaults() {
  _setup
  rm -f "$FAKE_HOME/.claude/nerdflair/state.json"
  local output
  output=$(printf '%s' "$(_make_input)" | HOME="$FAKE_HOME" bash "$RENDERER")
  local stripped
  stripped=$(echo "$output" | _strip_ansi)
  # Default is full mode — should have folder, branch, and percentage
  assert_contains "defaults: folder" "$stripped" "my-project"
  assert_contains "defaults: percentage" "$stripped" "42%"
  _teardown
}

test_renderer_width_respected() {
  _setup
  local state_narrow='{"mode": "full", "width": "50", "flair": false, "terminal_bell": "off", "chime_volume": "0", "chime_style": "random", "chime_events": "", "color": "vibrant"}'
  local state_wide='{"mode": "full", "width": "120", "flair": false, "terminal_bell": "off", "chime_volume": "0", "chime_style": "random", "chime_events": "", "color": "vibrant"}'
  local out_narrow out_wide len_narrow len_wide
  out_narrow=$(_render "$state_narrow" "$(_make_input 50 0)" | _strip_ansi | head -1)
  out_wide=$(_render "$state_wide" "$(_make_input 50 0)" | _strip_ansi | head -1)
  len_narrow=${#out_narrow}
  len_wide=${#out_wide}
  if (( len_wide > len_narrow )); then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: wide ($len_wide) should be wider than narrow ($len_narrow)")
  fi
  _teardown
}

# ════════════════════════════════════════════════════════════════
# CONFIGURATOR TESTS
# ════════════════════════════════════════════════════════════════

test_config_default_state_created() {
  _setup
  _configure layout full >/dev/null 2>&1
  local mode
  mode=$(_state_field "mode")
  assert_equals "default mode is full" "$mode" "full"
  _teardown
}

test_config_install_on_fresh_home_writes_defaults() {
  _setup
  _configure install >/dev/null 2>&1 || true
  assert_equals "install default mode" "$(_state_field "mode")" "full"
  assert_equals "install default chime events" "$(_state_field "chime_events")" "Notification,PermissionRequest,PreCompact,SessionEnd,SessionStart,Stop"
  assert_not_contains "dead flair field no longer written" "$(cat "$FAKE_HOME/.claude/nerdflair/state.json")" "flair"
  _teardown
}

test_config_layout_cycle() {
  _setup
  # Start at full, cycle to compact
  _configure layout full >/dev/null 2>&1
  _configure layout >/dev/null 2>&1
  assert_equals "full -> compact" "$(_state_field "mode")" "compact"
  # compact -> minimal
  _configure layout >/dev/null 2>&1
  assert_equals "compact -> minimal" "$(_state_field "mode")" "minimal"
  # minimal -> full
  _configure layout >/dev/null 2>&1
  assert_equals "minimal -> full" "$(_state_field "mode")" "full"
  _teardown
}

test_config_layout_direct_set() {
  _setup
  _configure layout compact >/dev/null 2>&1
  assert_equals "set compact" "$(_state_field "mode")" "compact"
  _configure layout minimal >/dev/null 2>&1
  assert_equals "set minimal" "$(_state_field "mode")" "minimal"
  _teardown
}

test_config_invalid_layout_fails() {
  _setup
  _configure layout full >/dev/null 2>&1
  local rc=0
  _configure layout bogus >/dev/null 2>&1 || rc=$?
  assert_exit_code "invalid layout exits nonzero" "1" "$rc"
  _teardown
}

test_config_width_set() {
  _setup
  _configure layout full >/dev/null 2>&1
  _configure width 60 >/dev/null 2>&1
  assert_equals "width 60" "$(_state_field "width")" "60"
  _configure width auto >/dev/null 2>&1
  assert_equals "width auto" "$(_state_field "width")" "auto"
  _teardown
}

test_config_width_validation() {
  _setup
  _configure layout full >/dev/null 2>&1
  local rc=0
  _configure width 999 >/dev/null 2>&1 || rc=$?
  assert_exit_code "width > 150 rejected" "1" "$rc"
  rc=0
  _configure width 10 >/dev/null 2>&1 || rc=$?
  assert_exit_code "width < 50 rejected" "1" "$rc"
  _teardown
}

test_config_terminal_bell_toggle() {
  _setup
  _configure layout full >/dev/null 2>&1
  assert_equals "bell default on" "$(_state_field "terminal_bell")" "on"
  _configure terminal-bell >/dev/null 2>&1
  assert_equals "bell toggled off" "$(_state_field "terminal_bell")" "off"
  _configure terminal-bell >/dev/null 2>&1
  assert_equals "bell toggled on" "$(_state_field "terminal_bell")" "on"
  _teardown
}

test_config_color_cycle() {
  _setup
  _configure color-palette vibrant >/dev/null 2>&1
  assert_equals "color vibrant" "$(_state_field "color")" "vibrant"
  _configure color-palette >/dev/null 2>&1
  assert_equals "vibrant -> muted" "$(_state_field "color")" "muted"
  _configure color-palette >/dev/null 2>&1
  assert_equals "muted -> mono" "$(_state_field "color")" "mono"
  _configure color-palette >/dev/null 2>&1
  assert_equals "mono -> vibrant" "$(_state_field "color")" "vibrant"
  _teardown
}

test_config_color_direct_set() {
  _setup
  _configure color-palette mono >/dev/null 2>&1
  assert_equals "set mono" "$(_state_field "color")" "mono"
  _teardown
}

test_config_invalid_color_fails() {
  _setup
  _configure layout full >/dev/null 2>&1
  local rc=0
  _configure color-palette neon >/dev/null 2>&1 || rc=$?
  assert_exit_code "invalid color exits nonzero" "1" "$rc"
  _teardown
}

test_config_chime_volume() {
  _setup
  _configure layout full >/dev/null 2>&1
  _configure chime-volume 50 >/dev/null 2>&1
  assert_equals "volume 50%" "$(_state_field "chime_volume")" "0.50"
  _configure chime-volume 0 >/dev/null 2>&1
  assert_equals "volume muted" "$(_state_field "chime_volume")" "0.00"
  _teardown
}

test_config_chime_volume_validation() {
  _setup
  _configure layout full >/dev/null 2>&1
  local rc=0
  _configure chime-volume 200 >/dev/null 2>&1 || rc=$?
  assert_exit_code "volume > 100 rejected" "1" "$rc"
  _teardown
}

test_config_chime_events_toggle() {
  _setup
  _configure layout full >/dev/null 2>&1
  # Default includes all events
  local events
  events=$(_state_field "chime_events")
  assert_contains "default has Stop" "$events" "Stop"
  assert_contains "default has SessionEnd" "$events" "SessionEnd"
  # Toggle Stop off
  _configure chime-events Stop >/dev/null 2>&1
  events=$(_state_field "chime_events")
  if echo ",$events," | grep -q ",Stop,"; then
    (( _fail++ ))
    _errors+=("FAIL: Stop still present as standalone event: $events")
  else
    (( _pass++ ))
  fi
  # Toggle it back on
  _configure chime-events Stop >/dev/null 2>&1
  events=$(_state_field "chime_events")
  assert_contains "Stop re-added" "$events" "Stop"
  _teardown
}

test_config_chime_events_toggle_does_not_corrupt_substring_events() {
  _setup
  _configure layout full >/dev/null 2>&1
  # Enable UserPromptSubmit (not in default) to test substring safety
  _configure chime-events UserPromptSubmit >/dev/null 2>&1
  local events
  events=$(_state_field "chime_events")
  assert_contains "has UserPromptSubmit" "$events" "UserPromptSubmit"
  assert_contains "has Stop" "$events" "Stop"
  # Toggle Stop off — must not corrupt UserPromptSubmit
  _configure chime-events Stop >/dev/null 2>&1
  events=$(_state_field "chime_events")
  # Use comma-sandwich to verify bare "Stop" is gone (can't use plain assert_not_contains
  # because "UserPromptSubmit" contains the substring "Stop")
  if echo ",$events," | grep -q ",Stop,"; then
    (( _fail++ ))
    _errors+=("FAIL: Stop still present as standalone event: $events")
  else
    (( _pass++ ))
  fi
  assert_contains "UserPromptSubmit intact" "$events" "UserPromptSubmit"
  _teardown
}

test_config_invalid_chime_event_fails() {
  _setup
  _configure layout full >/dev/null 2>&1
  local rc=0
  _configure chime-events BogusEvent >/dev/null 2>&1 || rc=$?
  assert_exit_code "invalid event exits nonzero" "1" "$rc"
  _teardown
}

test_config_info_mode() {
  _setup
  _configure layout full >/dev/null 2>&1
  local output
  output=$(_configure info 2>&1 | _strip_ansi)
  assert_contains "info shows mode" "$output" "full"
  assert_contains "info shows width" "$output" "width"
  _teardown
}

test_config_no_args_cycles_layout() {
  _setup
  _configure layout full >/dev/null 2>&1
  _configure >/dev/null 2>&1
  assert_equals "no args cycles to compact" "$(_state_field "mode")" "compact"
  _teardown
}

test_config_invalid_command_fails() {
  _setup
  local rc=0
  _configure nonsense >/dev/null 2>&1 || rc=$?
  assert_exit_code "unknown command exits nonzero" "1" "$rc"
  _teardown
}

# ${var,,} is bash 4 only; the plugin must run on macOS /bin/bash 3.2.
test_config_chime_style_matches_case_insensitively() {
  _setup
  _configure layout full >/dev/null 2>&1
  local err_file="$TMPDIR_ROOT/err"
  HOME="$FAKE_HOME" /bin/bash "$CONFIGURATOR" chime-style balladpiano >/dev/null 2>"$err_file" || true
  assert_equals "chime-style has no stderr on bash 3.2" "" "$(cat "$err_file")"
  assert_equals "chime-style resolves canonical name" "$(_state_field "chime_style")" "BalladPiano"
  _teardown
}

test_config_layout_rejects_regex_like_argument() {
  _setup
  _configure layout full >/dev/null 2>&1
  local rc=0
  _configure layout f.ll >/dev/null 2>&1 || rc=$?
  assert_exit_code "regex-like layout rejected" "1" "$rc"
  assert_equals "layout unchanged after bad arg" "$(_state_field "mode")" "full"
  _teardown
}

test_config_corrupt_state_warns_instead_of_dying_silently() {
  _setup
  echo '{"mode": "full", "wid' > "$FAKE_HOME/.claude/nerdflair/state.json"
  local rc=0 err_file="$TMPDIR_ROOT/err"
  _configure info >/dev/null 2>"$err_file" || rc=$?
  assert_exit_code "info survives corrupt state" "0" "$rc"
  assert_contains "warns about invalid JSON" "$(cat "$err_file")" "not valid JSON"
  _teardown
}

# The state reader joins 14 fields; an empty one (here chime_sound) must not
# shift every later field into the wrong variable.
test_config_reads_state_correctly_with_empty_fields() {
  _setup
  echo '{"mode": "compact", "chime_style": "BalladPiano", "chime_volume": "0.25"}' > "$FAKE_HOME/.claude/nerdflair/state.json"
  local output
  output=$(_configure info 2>/dev/null | _strip_ansi)
  assert_contains "mode read" "$output" "compact"
  assert_contains "chime style read from correct field" "$output" "25% (BalladPiano)"
  _teardown
}

test_config_volume_leading_zero_is_decimal() {
  _setup
  _configure layout full >/dev/null 2>&1
  local err_file="$TMPDIR_ROOT/err"
  _configure chime-volume 08 >/dev/null 2>"$err_file" || true
  assert_equals "no octal error" "" "$(cat "$err_file")"
  assert_equals "08 means 8 percent" "$(_state_field "chime_volume")" "0.08"
  _teardown
}

test_config_volume_uses_dot_decimal_in_any_locale() {
  _setup
  _configure layout full >/dev/null 2>&1
  LC_ALL=de_DE.UTF-8 _configure chime-volume 50 >/dev/null 2>&1 || true
  assert_equals "volume written with a dot" "$(_state_field "chime_volume")" "0.50"
  _teardown
}

test_config_legacy_default_color_migrated() {
  _setup
  # Write state with old "default" color value
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_sound": "Glass", "chime_volume": "1", "chime_style": "random", "chime_events": "Stop", "color": "default"}
EOF
  # Any state-writing action should migrate "default" -> "vibrant"
  _configure layout >/dev/null 2>&1
  assert_equals "default migrated to vibrant" "$(_state_field "color")" "vibrant"
  _teardown
}

# ════════════════════════════════════════════════════════════════
# BELL HOOK TESTS
# ════════════════════════════════════════════════════════════════

test_bell_exits_early_when_all_disabled() {
  _setup
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "off", "chime_sound": "Glass", "chime_volume": "0", "chime_style": "random", "chime_events": "Stop", "color": "vibrant"}
EOF
  local rc=0
  echo '{}' | HOME="$FAKE_HOME" bash "$BELL" Stop || rc=$?
  assert_exit_code "bell exits 0 when all disabled" "0" "$rc"
  _teardown
}

test_bell_reads_state_correctly() {
  _setup
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "off", "chime_sound": "Glass", "chime_volume": "0", "chime_style": "BalladPiano", "chime_events": "Stop", "color": "vibrant"}
EOF
  # With both off, it should exit cleanly without errors
  local output rc=0
  output=$(echo '{}' | HOME="$FAKE_HOME" bash "$BELL" Stop 2>&1) || rc=$?
  assert_exit_code "bell runs without error" "0" "$rc"
  # Should not produce any output when disabled
  assert_equals "bell silent when disabled" "$output" ""
  _teardown
}

test_bell_picks_random_style_on_session_start() {
  _setup
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "off", "chime_sound": "Glass", "chime_volume": "0.50", "chime_style": "random", "chime_events": "SessionStart", "color": "vibrant"}
EOF
  echo '{"session_id":"test-new-session"}' | HOME="$FAKE_HOME" bash "$BELL" SessionStart >/dev/null 2>&1 || true
  # bell.sh should pick a real style on SessionStart and write it to per-session file
  local resolved=""
  local _session_file="$FAKE_HOME/.claude/nerdflair/sessions/test-new-session"
  if [[ -f "$_session_file" ]]; then
    resolved=$(grep -o '"chime"[[:space:]]*:[[:space:]]*"[^"]*"' "$_session_file" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
  fi
  if [[ -n "$resolved" && "$resolved" != "random" ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: per-session chime style should be a real style, got '$resolved'")
  fi
  _teardown
}

# session_id comes from stdin JSON and is used as a filename; reject traversal.
test_bell_rejects_traversal_in_session_id() {
  _setup
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF2'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "off", "chime_sound": "Glass", "chime_volume": "0", "chime_style": "BalladPiano", "chime_events": "SessionStart", "color": "vibrant"}
EOF2
  echo '{"session_id":"../../../pwned"}' | HOME="$FAKE_HOME" bash "$BELL" SessionStart >/dev/null 2>&1 || true
  local escaped="no"
  [[ -e "$FAKE_HOME/pwned" ]] && escaped="yes"
  assert_equals "no file written outside sessions dir" "$escaped" "no"
  _teardown
}

test_bell_suppresses_resume() {
  _setup
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "on", "chime_sound": "Glass", "chime_volume": "1", "chime_style": "random", "chime_events": "SessionStart", "color": "vibrant"}
EOF
  # source=resume should cause bell.sh to exit early without creating a per-session style file
  local rc=0
  echo '{"session_id":"old-session","source":"resume"}' | HOME="$FAKE_HOME" bash "$BELL" SessionStart >/dev/null 2>&1 || rc=$?
  local _session_file="$FAKE_HOME/.claude/nerdflair/sessions/old-session"
  if [[ ! -f "$_session_file" ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: resume should not create per-session style file, but it exists")
  fi
  _teardown
}

test_bell_suppresses_post_compaction_restart() {
  _setup
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF2'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "off", "chime_sound": "Glass", "chime_volume": "0", "chime_style": "random", "chime_events": "SessionStart", "color": "vibrant"}
EOF2
  echo '{"session_id":"compacted-session","source":"compact"}' | HOME="$FAKE_HOME" bash "$BELL" SessionStart >/dev/null 2>&1 || true
  local created="no"
  [[ -f "$FAKE_HOME/.claude/nerdflair/sessions/compacted-session" ]] && created="yes"
  assert_equals "compact restart does not start a new chime session" "$created" "no"
  _teardown
}

test_bell_cleans_up_session_file_on_session_end() {
  _setup
  cat > "$FAKE_HOME/.claude/nerdflair/state.json" <<'EOF'
{"mode": "full", "width": "auto", "flair": true, "terminal_bell": "off", "chime_sound": "Glass", "chime_volume": "0.50", "chime_style": "random", "chime_events": "SessionStart,SessionEnd", "color": "vibrant"}
EOF
  # Create a session file via SessionStart
  echo '{"session_id":"cleanup-session"}' | HOME="$FAKE_HOME" bash "$BELL" SessionStart >/dev/null 2>&1 || true
  local _session_file="$FAKE_HOME/.claude/nerdflair/sessions/cleanup-session"
  # Verify it exists
  if [[ ! -f "$_session_file" ]]; then
    (( _fail++ ))
    _errors+=("FAIL: session file should exist after SessionStart")
    _teardown
    return
  fi
  # SessionEnd should remove it
  echo '{"session_id":"cleanup-session"}' | HOME="$FAKE_HOME" bash "$BELL" SessionEnd >/dev/null 2>&1 || true
  if [[ ! -f "$_session_file" ]]; then
    (( _pass++ ))
  else
    (( _fail++ ))
    _errors+=("FAIL: session file should be removed after SessionEnd")
  fi
  _teardown
}

# ════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ════════════════════════════════════════════════════════════════

# Collect all functions starting with test_
_tests=()
while IFS= read -r fn; do
  _tests+=("$fn")
done < <(declare -F | awk '{print $3}' | grep '^test_' | sort)

# Use temp files to collect results across subshells
_results_dir=$(mktemp -d)
trap 'rm -rf "$_results_dir"' EXIT

echo "Running ${#_tests[@]} tests..."
echo ""

for t in "${_tests[@]}"; do
  printf "  %-55s" "$t"
  # Run each test; capture pass/fail via temp files
  _pass=0
  _fail=0
  _errors=()
  if "$t" 2>/dev/null; then
    if (( _fail > 0 )); then
      echo "FAIL"
      echo "$_fail" >> "$_results_dir/fails"
      for e in "${_errors[@]}"; do
        echo "$e" >> "$_results_dir/errors"
      done
    else
      echo "ok"
      echo "$_pass" >> "$_results_dir/passes"
    fi
  else
    echo "FAIL (crashed)"
    echo "1" >> "$_results_dir/fails"
    echo "FAIL: $t -- crashed or exited nonzero" >> "$_results_dir/errors"
  fi
done

_total_pass=0
_total_fail=0
if [[ -f "$_results_dir/passes" ]]; then
  while read -r n; do (( _total_pass += n )); done < "$_results_dir/passes"
fi
if [[ -f "$_results_dir/fails" ]]; then
  while read -r n; do (( _total_fail += n )); done < "$_results_dir/fails"
fi

echo ""
echo "Results: $_total_pass passed, $_total_fail failed"

if [[ -f "$_results_dir/errors" ]]; then
  echo ""
  while IFS= read -r e; do
    echo "  $e"
  done < "$_results_dir/errors"
  exit 1
fi

exit 0
