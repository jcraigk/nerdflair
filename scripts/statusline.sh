#!/bin/bash
set -uo pipefail
# Note: -e is intentionally omitted because arithmetic expressions like
# (( x == 0 )) return exit code 1, which would cause spurious termination.

input=$(cat)

# Buffer all output and flush at exit so Claude Code sees complete output
# atomically — prevents partial first-render from locking statusline height.
_SL_BUF=$(mktemp "${TMPDIR:-/tmp}/nerdflair-sl.XXXXXX")
exec 3>&1 1>"$_SL_BUF"
trap 'cat "$_SL_BUF" >&3; rm -f "$_SL_BUF"' EXIT

# ── Shared library ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
_nf_require_jq

# ── Layout mode & width from state file ──────────────────────────
_nf_read_state
_SL_MODE="$NF_CUR_MODE"
_SL_WIDTH="$NF_CUR_WIDTH"
_SL_COLOR_MODE="$NF_CUR_COLOR"
_SL_TERMINAL_BELL="$NF_CUR_TERMINAL_BELL"
_SL_CHIME_VOLUME="$NF_CUR_CHIME_VOLUME"
_SL_CHIME_STYLE="$NF_CUR_CHIME_STYLE"
_SL_LAST_SESSION="$NF_CUR_LAST_SESSION"
# Per-session data (chime style) is stored in ~/.claude/nerdflair/sessions/<session_id>
# by bell.sh on SessionStart. The statusline reads it from there.
# ── Sanitize external strings ─────────────────────────────────────
# Strip backslashes so that printf '%b' cannot expand backslash-escape
# sequences (e.g. \033, \e, \x1b) into terminal control characters.
# Applied to user-controlled values: branch names, directory names, MCP
# server names, and model IDs.
_sanitize() { printf '%s' "$1" | sed 's/\\//g'; }

# ── Extract fields from Claude Code JSON ──────────────────────────
cwd=$(echo "$input" | jq -r '.workspace.current_dir // empty')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // empty')
# Resolve symlinks so the path matches the key stored in ~/.claude.json
[[ -n "$project_dir" && -d "$project_dir" ]] && project_dir=$(cd "$project_dir" && pwd -P)

# Model: prefer the display_name Claude Code provides; fall back to parsing the ID.
# Parse out just the family + version so suffixes like "(1M context)" or a date
# stamp are never shown. Matching is case-insensitive because display_name is
# title-cased ("Opus 4.8 (1M context)") while IDs are lowercase ("claude-opus-4-8").
raw_model=$(echo "$input" | jq -r 'if .model | type == "object" then (.model.display_name // .model.id // empty) else (.model // empty) end')
model=""
shopt -s nocasematch
if [[ "$raw_model" =~ (opus|sonnet|haiku|fable) ]]; then
  name="${BASH_REMATCH[1]}"
  # Capitalize first letter
  model="$(tr '[:lower:]' '[:upper:]' <<< "${name:0:1}")${name:1}"
  # Version: "4.8" or "4-8" → "4.8"; else a bare major like "5". A dotted/dashed
  # pair is matched first so a date stamp (e.g. "-20251001") is not picked up.
  if [[ "$raw_model" =~ [0-9]+[.-][0-9]+ ]]; then
    model+=" ${BASH_REMATCH[0]//-/.}"
  elif [[ "$raw_model" =~ [0-9]+ ]]; then
    model+=" ${BASH_REMATCH[0]}"
  fi
else
  model=$(_sanitize "$raw_model")
fi
shopt -u nocasematch

# Worktree info (optional, absent in normal sessions)
worktree_branch=$(echo "$input" | jq -r '.worktree.branch // empty')

cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
total_duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
total_api_ms=$(echo "$input" | jq -r '.cost.total_api_duration_ms // empty')
output_style=$(echo "$input" | jq -r '.output_style.name // empty')
# Reasoning effort level (low/medium/high/xhigh/max). Absent when the model
# does not support the effort parameter; ultracode reports as "xhigh".
effort_level=$(echo "$input" | jq -r '.effort.level // empty')
# Extended thinking toggle and fast mode. Session state indicators.
thinking_enabled=$(echo "$input" | jq -r '.thinking.enabled // empty')
fast_mode=$(echo "$input" | jq -r '.fast_mode // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
# Context window
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
input_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
output_tokens=$(echo "$input" | jq -r '.context_window.total_output_tokens // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')

# MCP servers — aggregate from global ~/.claude.json, project-scoped servers
# in ~/.claude.json, and project/cwd .mcp.json files.
# Only active (non-disabled, not project-disabled) servers are collected.
mcp_total=0
mcp_enabled=0
mcp_names=()
_claude_json="$HOME/.claude.json"
# Project-level disabled servers (from ~/.claude.json .projects[project_dir].disabledMcpServers)
_proj_disabled_names=()
if [[ -n "$project_dir" && -f "$_claude_json" ]]; then
  while IFS= read -r _dname; do
    [[ -n "$_dname" ]] && _proj_disabled_names+=("$_dname")
  done < <(jq -r --arg p "$project_dir" '.projects[$p].disabledMcpServers // [] | .[]' "$_claude_json" 2>/dev/null)
fi
_is_proj_disabled() {
  local _n="$1"
  for _pd in ${_proj_disabled_names[@]+"${_proj_disabled_names[@]}"}; do
    [[ "$_pd" == "$_n" ]] && return 0
  done
  return 1
}
for mcp_file in "$_claude_json" "${project_dir}/.mcp.json" "${cwd}/.mcp.json"; do
  if [[ -f "$mcp_file" ]]; then
    while IFS= read -r _name; do
      if [[ -n "$_name" ]]; then
        if [[ "$mcp_file" == "$_claude_json" ]] && _is_proj_disabled "$_name"; then
          continue
        fi
        mcp_names+=("$(_sanitize "$_name")")
        (( mcp_enabled++ ))
      fi
    done < <(jq -r '[.mcpServers // {} | to_entries[] | select(.value.disabled != true) | .key] | sort[]' "$mcp_file" 2>/dev/null)
  fi
done
# Also read project-scoped MCP servers from ~/.claude.json .projects[project_dir].mcpServers
if [[ -n "$project_dir" && -f "$_claude_json" ]]; then
  while IFS= read -r _name; do
    if [[ -n "$_name" ]] && ! _is_proj_disabled "$_name"; then
      mcp_names+=("$(_sanitize "$_name")")
      (( mcp_enabled++ ))
    fi
  done < <(jq -r --arg p "$project_dir" '[.projects[$p].mcpServers // {} | to_entries[] | select(.value.disabled != true) | .key] | sort[]' "$_claude_json" 2>/dev/null)
fi
mcp_total=$mcp_enabled
# Sort names alphabetically (handles names from multiple files)
IFS=$'\n' mcp_names_sorted=($(printf '%s\n' "${mcp_names[@]}" | sort -f)); unset IFS

# ── Colors (4-color palette + brand) ──────────────────────────────────
# Primary: workspace identity
BLUE="\033[38;2;95;179;255m"
MAGENTA="\033[38;2;198;120;221m"
CYAN="\033[38;2;86;182;194m"
# Model-state suffixes (effort, thinking, style, fast)
STATE_COLOR="\033[38;2;72;200;170m"
# Muted: secondary info (mode, timing)
MAUVE="\033[38;2;145;130;155m"
# MCP tool list
MCP_COLOR="\033[38;2;195;130;140m"
# Accent: money
DARK_GREEN="\033[38;2;110;155;95m"
# Alert: warnings (progress bar caution)
ALERT="\033[38;2;220;175;100m"
# Danger: critical (progress bar 80%+)
RED="\033[38;2;224;108;117m"
# Progress bar healthy state
GREEN="\033[38;2;152;195;121m"
# Agent name
ORANGE="\033[38;2;235;150;60m"
# Accent: dirty files
MUSTARD="\033[38;2;180;155;95m"
# Time/cost
SAGE="\033[38;2;190;150;120m"
# Cost
COST_GREEN="\033[38;2;90;120;82m"
# Diff
DIFF_PLUS="\033[38;2;130;190;110m"
DIFF_MINUS="\033[38;2;235;100;90m"
# Utility
DIM="\033[38;2;85;90;100m"
RESET="\033[0m"

# ── Color mode overrides ────────────────────────────────────────
# Palette swaps based on _SL_COLOR_MODE. The vibrant palette above
# is left untouched; mono/dim simply reassign the same variable names.
if [[ "$_SL_COLOR_MODE" == "mono" ]]; then
  # Monochrome: shades of gray only
  BLUE="\033[38;2;190;190;190m"
  MAGENTA="\033[38;2;170;170;170m"
  CYAN="\033[38;2;180;180;180m"
  STATE_COLOR="\033[38;2;150;150;150m"
  MAUVE="\033[38;2;140;140;140m"
  MCP_COLOR="\033[38;2;170;170;170m"
  ORANGE="\033[38;2;200;200;200m"
  DARK_GREEN="\033[38;2;150;150;150m"
  ALERT="\033[38;2;200;200;200m"
  RED="\033[38;2;210;210;210m"
  GREEN="\033[38;2;170;170;170m"
  MUSTARD="\033[38;2;185;185;185m"
  SAGE="\033[38;2;145;145;145m"
  COST_GREEN="\033[38;2;150;150;150m"
  DIFF_PLUS="\033[38;2;160;160;160m"
  DIFF_MINUS="\033[38;2;160;160;160m"
  DIM="\033[38;2;90;90;90m"
elif [[ "$_SL_COLOR_MODE" == "muted" ]]; then
  # Muted: same hues, ~40% saturation
  BLUE="\033[38;2;140;170;210m"
  MAGENTA="\033[38;2;170;145;185m"
  CYAN="\033[38;2;130;165;170m"
  STATE_COLOR="\033[38;2;95;175;150m"
  MAUVE="\033[38;2;140;135;150m"
  MCP_COLOR="\033[38;2;170;138;142m"
  ORANGE="\033[38;2;200;160;100m"
  DARK_GREEN="\033[38;2;125;145;115m"
  ALERT="\033[38;2;185;165;125m"
  RED="\033[38;2;185;140;140m"
  GREEN="\033[38;2;150;170;135m"
  MUSTARD="\033[38;2;185;170;115m"
  SAGE="\033[38;2;165;145;125m"
  COST_GREEN="\033[38;2;120;135;118m"
  DIFF_PLUS="\033[38;2;115;135;110m"
  DIFF_MINUS="\033[38;2;175;125;118m"
  DIM="\033[38;2;95;95;105m"
fi

SEP="  "
BULLET="${DIM} · ${RESET}"
# Separator before the state-suffix run. No trailing space. The first
# suffix supplies it, so it reads like BULLET but spans 2 columns.
OPT_BULLET="${DIM} ·${RESET}"

# ── Detect effective git repo (current dir or one level deep) ────
# Sets one of: git_dir (cwd is a repo, or wraps exactly one), or
# _multi_git_subs (cwd wraps 2+ repos → multi-branch summary). When git_dir is
# adopted from a subfolder, _adopted_repo_name holds its basename for the prefix.
git_dir=""
_multi_git_subs=()
_adopted_repo_name=""
if [[ -n "$cwd" ]]; then
  cd "$cwd" 2>/dev/null
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_dir="$cwd"
  else
    # Look one level deep for git repos (wrapper folder pattern).
    git_subs=()
    for sub in "$cwd"/*/; do
      if [[ -d "$sub/.git" ]]; then
        git_subs+=("${sub%/}")
      fi
    done
    if (( ${#git_subs[@]} == 1 )); then
      git_dir="${git_subs[0]}"
      _adopted_repo_name=$(basename "$git_dir")
    elif (( ${#git_subs[@]} > 1 )); then
      _multi_git_subs=("${git_subs[@]}")
    fi
  fi
fi

# ── Helper: format number with commas ──────────────────────────
_fmt_num() {
  printf "%'d" "$1" 2>/dev/null || printf "%d" "$1"
}

# ── Git cache (3-second TTL) ──────────────────────────────────────
# Cache git status/diff results to avoid running git on every render.
_GIT_CACHE_TTL=3
_git_cache_file=""
_git_cache_fresh=false
if [[ -n "$git_dir" ]]; then
  _git_dir_hash=$(printf '%s' "$git_dir" | cksum | cut -d' ' -f1)
  _git_cache_file="/tmp/nerdflair-git-${_git_dir_hash}"
  if [[ -f "$_git_cache_file" ]]; then
    _cache_age=$(( $(date +%s) - $(stat -c %Y "$_git_cache_file" 2>/dev/null || stat -f %m "$_git_cache_file" 2>/dev/null || echo 0) ))
    (( _cache_age < _GIT_CACHE_TTL )) && _git_cache_fresh=true
  fi
  if [[ "$_git_cache_fresh" == "false" ]]; then
    cd "$git_dir" 2>/dev/null
    _gc_dirty=$(git -c core.useBuiltinFSMonitor=false status --porcelain --ignore-submodules=dirty 2>/dev/null | wc -l | tr -d ' ')
    _gc_added=0
    _gc_removed=0
    if (( _gc_dirty > 0 )); then
      while IFS=$'\t' read -r added removed _; do
        [[ "$added" == "-" ]] && continue
        (( _gc_added += added ))
        (( _gc_removed += removed ))
      done < <(git diff --numstat HEAD 2>/dev/null || git diff --numstat 2>/dev/null)
      _ucount=0
      while IFS= read -r ufile; do
        (( _ucount++ ))
        (( _ucount > 100 )) && break
        ulines=$(wc -l < "$ufile" 2>/dev/null | tr -d ' ')
        (( _gc_added += ${ulines:-0} ))
      done < <(git ls-files --others --exclude-standard 2>/dev/null)
    fi
    _gc_branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
    # In a linked worktree --git-dir and --git-common-dir differ; in the main checkout they match.
    _gc_worktree=0
    if [[ "$(git rev-parse --git-common-dir 2>/dev/null)" != "$(git rev-parse --git-dir 2>/dev/null)" ]]; then
      _gc_worktree=1
    fi
    # Remote URL for clickable links (convert SSH → HTTPS)
    _gc_remote=$(git remote get-url origin 2>/dev/null || true)
    _gc_remote=$(printf '%s' "$_gc_remote" | sed 's|^git@github\.com:|https://github.com/|' | sed 's|^git@\([^:]*\):|https://\1/|' | sed 's|\.git$||')
    printf '%s\t%s\t%s\t%s\t%s\t%s' "$_gc_dirty" "$_gc_added" "$_gc_removed" "$_gc_branch" "$_gc_remote" "$_gc_worktree" > "$_git_cache_file"
  fi
  IFS=$'\t' read -r _gc_dirty _gc_added _gc_removed _gc_branch _gc_remote _gc_worktree < "$_git_cache_file"
fi

# ── Uncommitted files segment ────────────────────────────────────
dirty_segment=""
if [[ -n "$git_dir" ]]; then
  dirty_count="${_gc_dirty:-0}"
  if (( dirty_count > 0 )); then
    dirty_icon=$(printf '\xef\x81\x84')  # U+F044 nf-fa-pencil
    dirty_segment="${MUSTARD}${dirty_icon} $(_fmt_num "$dirty_count")${RESET}"
    lines_added="${_gc_added:-0}"
    lines_removed="${_gc_removed:-0}"
    plus_icon="+"
    minus_icon="-"
    diff_parts=""
    if (( lines_added > 0 )); then
      diff_parts+="${DIFF_PLUS}${plus_icon}$(_fmt_num "$lines_added")${RESET}"
    fi
    if (( lines_removed > 0 )); then
      [[ -n "$diff_parts" ]] && diff_parts+=" "
      diff_parts+="${DIFF_MINUS}${minus_icon}$(_fmt_num "$lines_removed")${RESET}"
    fi
    if [[ -n "$diff_parts" ]]; then
      dirty_segment+=" \033[1;38;2;72;78;74m[${RESET}${diff_parts}\033[1;38;2;72;78;74m]${RESET}"
    fi
  fi
fi

# ── Multi-repo branch summary (wrapper folder with 2+ git subfolders) ──
# Repos NOT on main/master show as "folder:branch" (joined) when they fit, else
# collapse to "N branches" (off-default count). When all are on main/master,
# show "N repos" (total count). Cached for the git TTL, keyed on cwd.
_multi_branch_list=""
_multi_off_count=0
_multi_total_count=0
if (( ${#_multi_git_subs[@]} > 0 )); then
  _multi_total_count=${#_multi_git_subs[@]}
  _multi_cache_fresh=false
  _cwd_hash=$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)
  _multi_cache_file="/tmp/nerdflair-multibranch-${_cwd_hash}"
  if [[ -f "$_multi_cache_file" ]]; then
    _mcache_age=$(( $(date +%s) - $(stat -c %Y "$_multi_cache_file" 2>/dev/null || stat -f %m "$_multi_cache_file" 2>/dev/null || echo 0) ))
    (( _mcache_age < _GIT_CACHE_TTL )) && _multi_cache_fresh=true
  fi
  if [[ "$_multi_cache_fresh" == "false" ]]; then
    _mb_list=""
    _mb_off=0
    for _sub in "${_multi_git_subs[@]}"; do
      _sub_branch=$(git -C "$_sub" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$_sub" rev-parse --short HEAD 2>/dev/null)
      [[ -z "$_sub_branch" ]] && continue
      if [[ "$_sub_branch" == "main" || "$_sub_branch" == "master" ]]; then
        continue
      fi
      (( _mb_off++ ))
      [[ -n "$_mb_list" ]] && _mb_list+=", "
      _mb_list+="$(basename "$_sub"):${_sub_branch}"
    done
    # Cache: off-count on line 1, joined list on line 2 (list may be empty).
    printf '%s\n%s' "$_mb_off" "$_mb_list" > "$_multi_cache_file"
  fi
  IFS= read -r _multi_off_count < "$_multi_cache_file"
  _multi_branch_list=$(sed -n '2,$p' "$_multi_cache_file")
  _multi_off_count=${_multi_off_count:-0}
  _multi_branch_list=$(_sanitize "$_multi_branch_list")
fi

ELLIPSIS=$(printf '\xe2\x80\xa6')  # U+2026 horizontal ellipsis (matches spinner verb)
MIN_BRANCH=10
# Floor a single-repo branch truncates to when we shrink it to make room for
# the effort label. Above this the branch yields width to keep effort visible;
# at or below it, effort drops instead of crushing the branch further.
MIN_BRANCH_FIT=15

# Min visible chars each side (repo, branch) of a multi-repo entry keeps when
# truncated, before the colon and ELLIPSIS.
_MULTI_SIDE_MIN=5

# Separator between entries. Rendered inside the magenta branch run, so it reads
# as a purple bullet. The cached list uses ", " internally; this is applied only
# when joining for display. _MULTI_SEP_W is its visible width.
_MULTI_SEP=" · "
_MULTI_SEP_W=3

# ── Render one "repo:branch" entry to a target visible width ────────
# Truncates repo and/or branch independently (start kept, ELLIPSIS appended),
# each floored at _MULTI_SIDE_MIN, colon always kept. Whichever side fits whole
# yields its surplus to the other; otherwise the budget (minus colon) splits
# evenly. Names are ASCII and ELLIPSIS is one column, so char count == width.
_render_multi_entry() {
  local _e="$1" _width=$2
  local _repo="${_e%%:*}" _br="${_e#*:}"
  local _rlen=${#_repo} _blen=${#_br}
  (( ${#_e} <= _width )) && { printf '%s' "$_e"; return; }

  local _avail=$(( _width - 1 ))  # minus colon
  (( _avail < 2 )) && _avail=2
  local _half=$(( _avail / 2 ))
  local _max_repo _max_br
  if (( _rlen <= _half )); then
    _max_repo=$_rlen
    _max_br=$(( _avail - _max_repo ))
  elif (( _blen <= _avail - _half )); then
    _max_br=$_blen
    _max_repo=$(( _avail - _max_br ))
  else
    _max_repo=$_half
    _max_br=$(( _avail - _max_repo ))
  fi
  (( _max_repo < _MULTI_SIDE_MIN )) && _max_repo=$_MULTI_SIDE_MIN
  (( _max_br < _MULTI_SIDE_MIN )) && _max_br=$_MULTI_SIDE_MIN

  local _repo_out="$_repo" _br_out="$_br"
  (( _rlen > _max_repo )) && _repo_out="${_repo:0:$((_max_repo - 1))}${ELLIPSIS}"
  (( _blen > _max_br )) && _br_out="${_br:0:$((_max_br - 1))}${ELLIPSIS}"
  printf '%s:%s' "$_repo_out" "$_br_out"
}

# ── Fit the multi-repo branch list into a target visible width ──────
# Returns the entries joined with _MULTI_SEP, or "" if they can't fit (caller
# collapses to "N branches"). When the full list overflows, width is shared
# round-robin: trim one char at a time from the longest entry, so long entries
# shrink together rather than one staying full while another is clipped. Each
# entry truncates via _render_multi_entry.
_fit_multi_branches() {
  local _target=$1

  local _entries=() _rest="$_multi_branch_list"
  while [[ "$_rest" == *", "* ]]; do
    _entries+=("${_rest%%, *}")
    _rest="${_rest#*, }"
  done
  _entries+=("$_rest")
  local _n=${#_entries[@]}
  local _sep_cost=$(( (_n - 1) * _MULTI_SEP_W ))
  local _content_budget=$(( _target - _sep_cost ))

  # Fast path: full list fits as-is.
  local _full_content=0 _i
  for (( _i=0; _i<_n; _i++ )); do (( _full_content += ${#_entries[$_i]} )); done
  if (( _full_content <= _content_budget )); then
    local _out=""
    for (( _i=0; _i<_n; _i++ )); do
      [[ -n "$_out" ]] && _out+="$_MULTI_SEP"
      _out+="${_entries[$_i]}"
    done
    printf '%s' "$_out"
    return
  fi

  # Per-entry floor (smallest render width) and starting allowance (full length).
  # A side over _MULTI_SIDE_MIN floors at that many chars + 1 ELLIPSIS; plus the
  # colon. The floor never exceeds the entry's own length.
  local _floor=() _alloc=() _i
  for (( _i=0; _i<_n; _i++ )); do
    local _e="${_entries[$_i]}"
    local _elen=${#_e}
    local _rp="${_e%%:*}" _bp="${_e#*:}"
    local _rmin=${#_rp} _bmin=${#_bp}
    (( _rmin > _MULTI_SIDE_MIN )) && _rmin=$(( _MULTI_SIDE_MIN + 1 ))
    (( _bmin > _MULTI_SIDE_MIN )) && _bmin=$(( _MULTI_SIDE_MIN + 1 ))
    local _f=$(( _rmin + 1 + _bmin ))
    (( _f > _elen )) && _f=$_elen
    _floor[$_i]=$_f
    _alloc[$_i]=$_elen
  done

  # If even all entries at their floor don't fit, collapse to a count.
  local _floor_sum=0
  for (( _i=0; _i<_n; _i++ )); do (( _floor_sum += _floor[_i] )); done
  (( _floor_sum > _content_budget )) && { printf ''; return; }

  # Trim the longest above-floor entry one char at a time until within budget.
  # Ties break to the earliest index, keeping output stable across renders.
  local _total=0
  for (( _i=0; _i<_n; _i++ )); do (( _total += _alloc[_i] )); done
  while (( _total > _content_budget )); do
    local _longest=-1 _longest_len=-1
    for (( _i=0; _i<_n; _i++ )); do
      if (( _alloc[_i] > _floor[_i] && _alloc[_i] > _longest_len )); then
        _longest_len=${_alloc[$_i]}
        _longest=$_i
      fi
    done
    (( _longest < 0 )) && break
    (( _alloc[_longest]-- ))
    (( _total-- ))
  done

  local _out=""
  for (( _i=0; _i<_n; _i++ )); do
    [[ -n "$_out" ]] && _out+="$_MULTI_SEP"
    _out+="$(_render_multi_entry "${_entries[$_i]}" "${_alloc[$_i]}")"
  done
  printf '%s' "$_out"
}

# ── Folder + branch segment ──────────────────────────────────────
# Folder always reflects cwd; branch comes from git_dir (which may differ).
folder_name=""
branch=""
folder_segment=""
# _branch_is_multi flags the joined multi-repo list case for the truncation and
# collapse logic below. Default it here (not only inside the guard block) so it
# is always defined when referenced later, even when there is no display dir.
_branch_is_multi=0
_display_dir="${project_dir:-$cwd}"
if [[ -n "$_display_dir" ]]; then
  # Folder name: based on project_dir (launch directory) so it stays stable
  # even when Claude cd's into subdirectories during a session
  if [[ "$_display_dir" == "$HOME" ]]; then
    folder_name=""
    _is_home=1
  else
    folder_name=$(_sanitize "$(basename "$_display_dir")")
  fi
  # Branch: prefer worktree, then cached git branch, then multi-repo summary.
  if [[ -n "$worktree_branch" ]]; then
    branch=$(_sanitize "$worktree_branch")
  elif [[ -n "${_gc_branch:-}" ]]; then
    branch=$(_sanitize "$_gc_branch")
    # Adopted subfolder off main/master: prefix "repo:" to match the multi format.
    if [[ -n "$_adopted_repo_name" && "$_gc_branch" != "main" && "$_gc_branch" != "master" ]]; then
      branch="$(_sanitize "$_adopted_repo_name"):${branch}"
    fi
  elif (( _multi_total_count > 0 )); then
    if (( _multi_off_count > 0 )); then
      # Apply the display separator now so width budgeting matches the final
      # render; _fit_multi_branches resolves the real fit once width is known.
      branch="${_multi_branch_list//, /$_MULTI_SEP}"
      _branch_is_multi=1
    else
      branch="${_multi_total_count} repos"
    fi
  fi
fi

# Worktree indicator lives on the folder segment, where the worktree's directory name shows.
folder_icon=$'\xef\x86\xbb'  # U+F1BB nf-fa-tree (worktree)
if [[ "${_gc_worktree:-0}" != "1" && -z "$worktree_branch" ]]; then
  folder_icon=$'\xf3\xb0\x89\x8b'  # U+F024B nf-md-folder (normal)
fi

# ── Helper: format milliseconds ──────────────────────────────────
# Seconds/minutes: whole numbers only. Hours: up to 2 decimals, trim trailing zeros.
_fmt_duration() {
  local ms=$1
  local total_secs=$(( ms / 1000 ))
  local total_mins=$(( total_secs / 60 ))
  if (( total_mins >= 60 )); then
    # Decimal hours: e.g. 1.25h, 2.5h, 3h — with commas for 1,000+
    local hundredths=$(( total_mins * 100 / 60 ))
    local whole=$(( hundredths / 100 ))
    local frac=$(( hundredths % 100 ))
    local whole_fmt
    whole_fmt=$(_fmt_num "$whole")
    local tenths=$(( (frac + 5) / 10 ))
    if (( tenths >= 10 )); then
      whole=$(( whole + 1 ))
      tenths=0
      whole_fmt=$(_fmt_num "$whole")
    fi
    if (( tenths == 0 )); then
      printf '%sh' "$whole_fmt"
    else
      printf '%s.%dh' "$whole_fmt" "$tenths"
    fi
  elif (( total_mins > 0 )); then
    printf '%dm' "$total_mins"
  else
    printf '%ds' "$total_secs"
  fi
}

# ── MCP servers segment ─────────────────────────────────────────
mcp_segment=""
mcp_segment_expanded=""
if (( mcp_enabled > 0 )); then
  mcp_icon=$(printf '\xef\x87\xa6')  # U+F1E6
  mcp_segment="${MCP_COLOR}${mcp_icon} ${mcp_enabled} MCP${RESET}"
  # Build expanded form with sorted names: "MCP proxy, slack" (list only, no count)
  # Also build truncated variants: "Slack, Glean, 4 more"
  if (( ${#mcp_names_sorted[@]} > 0 )); then
    _mcp_name_list=""
    for _mn in "${mcp_names_sorted[@]}"; do
      [[ -n "$_mcp_name_list" ]] && _mcp_name_list+=", "
      _mcp_name_list+="$_mn"
    done
    mcp_segment_expanded="${MCP_COLOR}${mcp_icon} ${_mcp_name_list}${RESET}"

    # Build truncated variants showing first N names + ", X more"
    _mcp_count=${#mcp_names_sorted[@]}
    mcp_segments_truncated=()
    if (( _mcp_count > 1 )); then
      for (( _i = _mcp_count - 1; _i >= 1; _i-- )); do
        _partial=""
        for (( _j = 0; _j < _i; _j++ )); do
          [[ -n "$_partial" ]] && _partial+=", "
          _partial+="${mcp_names_sorted[$_j]}"
        done
        _remaining=$(( _mcp_count - _i ))
        _partial+=", ${_remaining} more"
        mcp_segments_truncated+=("${MCP_COLOR}${mcp_icon} ${_partial}${RESET}")
      done
    fi
  fi
fi


# ── Context usage segment ───────────────────────────────────────
ctx_segment=""
ctx_total=200000  # default context window size
total_used=0
pct=0

if [[ -n "$used_pct" && -n "$ctx_size" ]]; then
  # used_pct is the authoritative context fill percentage from Claude Code.
  # Derive total_used from it rather than cumulative token counts, which
  # measure something different (total tokens across all API calls).
  ctx_total="$ctx_size"
  pct="$used_pct"
  total_used=$(( ctx_total * pct / 100 ))
else
  # Fall back: parse last usage entry from transcript JSONL
  transcript=$(echo "$input" | jq -r '.transcript_path // empty')
  if [[ -n "$transcript" && -f "$transcript" ]]; then
    last_usage=$(grep '"usage"' "$transcript" 2>/dev/null | tail -1 | jq -r '.message.usage // empty' 2>/dev/null)
    if [[ -n "$last_usage" && "$last_usage" != "null" ]]; then
      u_input=$(echo "$last_usage" | jq -r '.input_tokens // 0')
      u_cache_create=$(echo "$last_usage" | jq -r '.cache_creation_input_tokens // 0')
      u_cache_read=$(echo "$last_usage" | jq -r '.cache_read_input_tokens // 0')
      u_output=$(echo "$last_usage" | jq -r '.output_tokens // 0')
      total_used=$(( u_input + u_cache_create + u_cache_read + u_output ))
      pct=$(( total_used * 100 / ctx_total ))
      (( pct > 100 )) && pct=99
    fi
  fi
fi

# Default to 0 usage so we always show the context gauge (even on startup)
if [[ -z "$total_used" ]] || ! (( total_used > 0 )) 2>/dev/null; then
  total_used=0
  pct=0
fi

# ── Per-session data: chime style ────
# bell.sh writes ~/.claude/nerdflair/sessions/<session_id> on SessionStart:
#   {"chime":"StyleName"}
_SESSION_DIR="$NF_SESSION_DIR"
_session_file=""
_session_chime=""
if [[ -n "$session_id" ]]; then
  _session_file="$_SESSION_DIR/${session_id}"
  if [[ -f "$_session_file" ]]; then
    _session_chime=$(jq -r '.chime // empty' "$_session_file" 2>/dev/null || true)
  fi
fi

# Persist last_session to shared state file (used by bell.sh to suppress
# duplicate SessionStart on compaction). Uses _nf_update_field for atomic
# jq-based update, avoiding the fragile sed-chain approach.
if [[ -n "$session_id" ]]; then
  _nf_update_field "last_session" "$session_id"
fi

if (( total_used >= 1000000 )); then
  used_fmt="$(( total_used / 1000000 ))M"
elif (( total_used >= 1000 )); then
  used_fmt="$(( total_used / 1000 ))k"
else
  used_fmt="$total_used"
fi
if (( ctx_total >= 1000000 )); then
  size_fmt="$(( ctx_total / 1000000 ))M"
elif (( ctx_total >= 1000 )); then
  size_fmt="$(( ctx_total / 1000 ))k"
else
  size_fmt="$ctx_total"
fi

if (( pct >= 70 )); then
  ctx_color="$RED"
elif (( pct >= 40 )); then
  ctx_color="$ALERT"
else
  ctx_color="$GREEN"
fi

# Context label for embedding in progress bar
ctx_label="${used_fmt}/${size_fmt} ${pct}%"

# ── Helper: visible width of an ANSI string ──────────────────────
_vis_len() {
  # Strip ANSI escapes, then count characters (wc -m handles multibyte)
  local stripped
  stripped=$(printf '%b' "$1" | sed $'s/\033\\[[0-9;]*m//g')
  printf '%s' "$stripped" | wc -m | tr -d ' '
}

# ── Helper: join parts with separator ────────────────────────────
_join_parts() {
  local result="\033[0m"
  local i=0
  for part in "$@"; do
    (( i > 0 )) && result+="${SEP}"
    result+="$part"
    (( i++ ))
  done
  printf '%s' "$result"
}

# ── Helper: build justified row (left parts | padding | right parts)
# Usage: _justified_row max_width left_parts_str sep right_parts_str
_justified_row() {
  local max_w=$1
  shift
  local left_str="$1"
  local right_str="$2"
  local left_len=$(_vis_len "$left_str")
  local right_len=$(_vis_len "$right_str")
  local pad_len=$(( max_w - left_len - right_len ))
  (( pad_len < 2 )) && pad_len=2
  local pad=""
  for (( p=0; p<pad_len; p++ )); do pad+=" "; done
  printf '%b%s%b%b' "$left_str" "$pad" "$right_str" "${RESET}"
}

# ── Total row width = bar max + 2 caps ────────────────────────────
# Limits: min 50, default 80, max 150 (enforced here regardless of state)
if [[ "$_SL_WIDTH" != "auto" && "$_SL_WIDTH" =~ ^[0-9]+$ ]]; then
  MAX_BAR=$_SL_WIDTH
  (( MAX_BAR < 50 )) && MAX_BAR=50
  (( MAX_BAR > 150 )) && MAX_BAR=150
else
  MAX_BAR=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
  (( MAX_BAR < 50 )) && MAX_BAR=50
  (( MAX_BAR > 150 )) && MAX_BAR=150
fi
ROW_WIDTH=$(( MAX_BAR + 2 ))

# ── Row 1: proactive budget-based truncation ──────────────────────
# Right side (dirty segment) is never truncated — measure it first.
# In minimal mode everything goes on the left, so right side is empty.
row1_right="\033[0m"
if [[ "$_SL_MODE" != "minimal" ]]; then
  [[ -n "$dirty_segment" ]] && row1_right+="$dirty_segment"
fi
right_width=$(_vis_len "$row1_right")

# Left side budget = total width minus right side minus 3 char min padding
# In minimal mode, reserve space for pill + dirty (both appended to left later)
_extra_reserve=0
if [[ "$_SL_MODE" == "minimal" ]]; then
  # bullet(3) + pill: cap(1) + space(1) + label + space(1) + cap(1) = label_len + 7
  _extra_reserve=$(( ${#pct} + 8 ))
  # dirty segment (if present): bullet(3) + dirty visual width
  if [[ -n "$dirty_segment" ]]; then
    _extra_reserve=$(( _extra_reserve + 3 + $(_vis_len "$dirty_segment") ))
  fi
fi
left_budget=$(( ROW_WIDTH - right_width - 3 - _extra_reserve ))
(( left_budget < 20 )) && left_budget=20

# Chrome overhead on the left side (icons + spaces, not counting text):
#   folder: "󰉋 " (2)  branch: " 󰘬 " (3)  bullet: " · " (3)  model: "icon " (2)
# With branch:  2 + folder_name + 3 + branch + 3 + 2 + model_text = 10 + text
# Without branch: 2 + folder_name + 3 + 2 + model_text = 7 + text
model_icon=$(printf '\xef\x94\x9b')  # U+F51B

# Build model text (may include style icon)
model_text="$model"
style_suffix=""  # icon suffix appended after model_text in the segment
if [[ -n "$output_style" && "$output_style" != "default" ]]; then
  _style_lower="$(tr '[:upper:]' '[:lower:]' <<< "${output_style:0:1}")"
  case "$_style_lower" in
    e) style_suffix=" $(printf '\xef\x81\x9a')" ;;  # U+F05A for Explanatory
    l) style_suffix=" $(printf '\xef\x81\x99')" ;;  # U+F059 for Learning
    p) style_suffix=" $(printf '\xf3\xb0\xb7\xb8')" ;;  # U+F0DF8 for Proactive
    *) style_suffix=" $(tr '[:lower:]' '[:upper:]' <<< "$_style_lower")" ;;
  esac
fi

# ── Model-state suffixes: effort, thinking, style, fast mode ──────
# Each suffix exists in two forms: a plain-text form (measured for width
# budgeting and dropped when the model segment is truncated) and a colored
# form (used only at final assembly). Display order is effort, thinking,
# style icon, then fast mode last. Drop priority when space is tight:
# effort first, then thinking/fast glyphs, finally the style icon — mirroring
# the existing "drop suffix before truncating the name" behavior.
effort_suffix=""          # plain text, e.g. " xhigh"
effort_suffix_colored=""
if [[ -n "$effort_level" ]]; then
  effort_suffix=" ${effort_level}"
  effort_suffix_colored=" ${STATE_COLOR}${effort_level}${RESET}"
fi

# Thinking glyph (single nerd-font icon, plain length 2 because of the
# leading space).
state_suffix=""           # plain text holding the thinking glyph
state_suffix_colored=""
if [[ "$thinking_enabled" == "true" ]]; then
  _think_icon=$(printf '\xf3\xb0\xa0\xa0')  # U+F0820 (thinking)
  state_suffix+=" ${_think_icon}"
  state_suffix_colored+=" ${STATE_COLOR}${_think_icon}${RESET}"
fi
# Fast mode glyph — rendered last (after the style icon) so it always sits
# at the very end of the model segment. Plain length 2 with leading space.
fast_suffix=""
fast_suffix_colored=""
if [[ "$fast_mode" == "true" ]]; then
  _fast_icon=$(printf '\xf3\xb1\xa0\x87')   # U+F1807 (fast)
  fast_suffix=" ${_fast_icon}"
  fast_suffix_colored=" ${STATE_COLOR}${_fast_icon}${RESET}"
fi

# Calculate chrome: folder_icon(2) + [bullet(3) + branch_icon(2) if branch] + bullet(3) + model_icon(2)
# Home icon is just 1 char with no folder name text, so chrome is smaller
if [[ "${_is_home:-0}" == "1" ]]; then
  chrome=7  # home_icon(2) + bullet(3) + model_icon(2)
  [[ -n "$branch" ]] && chrome=12  # add bullet(3) + branch_icon(2)
else
  chrome=7  # folder_icon(2) + bullet(3) + model_icon(2)
  [[ -n "$branch" ]] && chrome=12  # add bullet(3) + branch_icon(2)
fi

# Available text budget after chrome
text_budget=$(( left_budget - chrome ))
(( text_budget < 10 )) && text_budget=10

# Allocate: path/branch get priority, model gets the remainder
style_suffix_len=${#style_suffix}
effort_suffix_len=${#effort_suffix}
state_suffix_len=${#state_suffix}
fast_suffix_len=${#fast_suffix}
# OPT_BULLET sits between the name and the suffix run, costing 2 columns,
# but only when at least one suffix is present. Recomputed by the drop
# logic below so the budget stays honest as suffixes fall away.
_opt_bullet_width() {
  (( style_suffix_len + effort_suffix_len + state_suffix_len + fast_suffix_len > 0 )) && echo 2 || echo 0
}
model_text_len=$(( ${#model_text} + style_suffix_len + effort_suffix_len + state_suffix_len + fast_suffix_len + $(_opt_bullet_width) ))
path_len=${#folder_name}
# Visible width, not byte count: bullet/ELLIPSIS glyphs are multibyte but one
# column, so ${#branch} would overcount and distort the budget.
branch_len=$(_vis_len "$branch")
path_branch_len=$(( path_len + branch_len ))

# Model needs at least 10 chars so "icon + name" stays readable (e.g. " Opus 4.6")
min_model=10
# Reserve room for the effort label when a long single-repo branch can absorb
# the cost. The branch yields down to MIN_BRANCH_FIT to keep effort visible;
# only if it's already at/below that floor does effort drop (via the priority
# logic below). Multi-repo lists have their own fitting path and are excluded.
effort_floor=$min_model
if [[ -n "$branch" ]] && (( _branch_is_multi == 0 )) && (( effort_suffix_len > 0 )); then
  # Cost of showing effort: the label plus the OPT_BULLET separator (2 cols).
  _effort_cost=$(( effort_suffix_len + 2 ))
  # Slack the branch can give up before hitting its floor.
  _branch_slack=$(( branch_len - MIN_BRANCH_FIT ))
  (( _branch_slack < 0 )) && _branch_slack=0
  if (( _branch_slack >= _effort_cost )); then
    effort_floor=$(( min_model + _effort_cost ))
  fi
fi
model_budget=$(( text_budget - path_branch_len ))
(( model_budget < effort_floor )) && model_budget=$effort_floor

# Path+branch budget is what remains after model
pb_budget=$(( text_budget - model_budget ))
# But if model fits fully, give all remaining back to path+branch
if (( model_text_len <= model_budget )); then
  model_budget=$model_text_len
  pb_budget=$(( text_budget - model_budget ))
fi

# Multi-repo list overflow: fit it (folder keeps full length, list gets the
# rest minus the model floor), or collapse to "N branches". Recompute budget
# terms afterward since the model may reclaim freed space.
if (( _branch_is_multi == 1 )) && (( path_len + branch_len > pb_budget )); then
  _multi_min=$(( _MULTI_SIDE_MIN + 1 + _MULTI_SIDE_MIN ))  # one minimal entry
  # Prefer reserving room for the effort label: shrink the list further to keep
  # effort visible, but only if it still fits after giving up that width. If the
  # reserved target would force a collapse to "N branches", fall back to the
  # plain min_model target so we keep the list rather than the effort label.
  _model_reserve=$min_model
  if (( effort_suffix_len > 0 )); then
    _reserve_with_effort=$(( min_model + effort_suffix_len + 2 ))  # + OPT_BULLET
    _target_effort=$(( text_budget - path_len - _reserve_with_effort ))
    (( _target_effort < _multi_min )) && _target_effort=$_multi_min
    [[ -n "$(_fit_multi_branches "$_target_effort")" ]] && _model_reserve=$_reserve_with_effort
  fi
  _branch_target=$(( text_budget - path_len - _model_reserve ))
  (( _branch_target < _multi_min )) && _branch_target=$_multi_min
  _fitted=$(_fit_multi_branches "$_branch_target")
  if [[ -n "$_fitted" ]]; then
    branch="$_fitted"
  else
    branch="${_multi_off_count} branches"
  fi
  _branch_is_multi=0
  branch_len=$(_vis_len "$branch")
  path_branch_len=$(( path_len + branch_len ))
  model_budget=$(( text_budget - path_branch_len ))
  (( model_budget < min_model )) && model_budget=$min_model
  pb_budget=$(( text_budget - model_budget ))
  if (( model_text_len <= model_budget )); then
    model_budget=$model_text_len
    pb_budget=$(( text_budget - model_budget ))
  fi
fi

# Truncate path and branch to fit pb_budget
if (( path_branch_len > pb_budget )); then
  if [[ -n "$branch" ]]; then
    # Split budget 50/50, but if one side fits, give surplus to the other
    half=$(( pb_budget / 2 ))
    if (( path_len <= half )); then
      # Path fits in its half — branch gets the rest
      max_path=$path_len
      max_branch=$(( pb_budget - max_path ))
    elif (( branch_len <= half )); then
      # Branch fits in its half — path gets the rest
      max_branch=$branch_len
      max_path=$(( pb_budget - max_branch ))
    else
      # Both contest — split evenly
      max_path=$half
      max_branch=$(( pb_budget - max_path ))
    fi
    (( max_path < 4 )) && max_path=4
    (( max_branch < 4 )) && max_branch=4
    if (( branch_len > max_branch )); then
      # Keep the start of the branch name, ellipsis at the end.
      branch="${branch:0:$((max_branch - 1))}${ELLIPSIS}"
    fi
    if (( ${#folder_name} > max_path )); then
      folder_name="${ELLIPSIS}${folder_name:$((${#folder_name} - max_path + 1))}"
    fi
  else
    if (( path_len > pb_budget )); then
      folder_name="${ELLIPSIS}${folder_name:$((path_len - pb_budget + 1))}"
    fi
  fi
fi

# Truncate model text if needed. Drop suffixes in priority order before
# truncating the name: effort label, then thinking/fast glyphs, then the
# style icon. Re-check the budget after each drop so we keep what fits.
if (( model_text_len > model_budget )); then
  # Step 1: drop the effort label
  effort_suffix=""
  effort_suffix_colored=""
  effort_suffix_len=0
  model_text_len=$(( ${#model_text} + style_suffix_len + state_suffix_len + fast_suffix_len + $(_opt_bullet_width) ))
  # Step 2: drop thinking + fast glyphs
  if (( model_text_len > model_budget )); then
    state_suffix=""
    state_suffix_colored=""
    state_suffix_len=0
    fast_suffix=""
    fast_suffix_colored=""
    fast_suffix_len=0
    model_text_len=$(( ${#model_text} + style_suffix_len + $(_opt_bullet_width) ))
  fi
  # Step 3: drop the style icon
  if (( model_text_len > model_budget )); then
    style_suffix=""
    style_suffix_len=0
    model_text_len=${#model_text}
  fi
  # Step 4: truncate model name if still too long
  if (( model_text_len > model_budget )); then
    model_text="${model_text:0:$((model_budget - 1))}${ELLIPSIS}"
  fi
fi



# Assemble folder segment
if [[ "${_is_home:-0}" == "1" ]]; then
  if [[ -n "$branch" ]]; then
    folder_segment="${BLUE} ${BULLET}${MAGENTA}󰘬 ${branch}${RESET}"
  else
    folder_segment="${BLUE} ${RESET}"
  fi
elif [[ -n "$folder_name" ]]; then
  if [[ -n "$branch" ]]; then
    folder_segment="${BLUE}${folder_icon} ${folder_name}${BULLET}${MAGENTA}󰘬 ${branch}${RESET}"
  else
    folder_segment="${BLUE}${folder_icon} ${folder_name}${RESET}"
  fi
fi

# Assemble model segment: icon + name + bullet + effort + thinking + style icon + fast.
# Fast mode is rendered last so it always trails the segment. Suffixes use
# their colored forms; the plain forms above were only for width.
model_segment=""
if [[ -n "$model_text" ]]; then
  model_segment="${CYAN}${model_icon} ${model_text}${RESET}"
  [[ -n "$effort_suffix$state_suffix$style_suffix$fast_suffix" ]] && model_segment+="${OPT_BULLET}"
  model_segment+="${effort_suffix_colored}${state_suffix_colored}${STATE_COLOR}${style_suffix}${RESET}${fast_suffix_colored}"
fi

# Build row 1 left
row1_left="\033[0m"
[[ -n "$folder_segment" ]] && row1_left+="$folder_segment"
if [[ -n "$model_segment" ]]; then
  [[ -n "$folder_segment" ]] && row1_left+="${BULLET}"
  row1_left+="$model_segment"
fi

# Row 1: folder/branch/model + dirty (non-minimal modes render now;
# minimal deferred until after TIER arrays are defined for the pill)
if [[ "$_SL_MODE" != "minimal" ]]; then
  _justified_row "$ROW_WIDTH" "$row1_left" "$row1_right"
fi

# ── Build time + cost segments for row 3 ─────────────────────────
time_segment=""
cost_icon=$(printf '\xef\x85\x95')       # U+F155 dollar
time_icon=$(printf '\xef\x80\x97')       # U+F017 clock

TIME_COLOR="$MAUVE"
api_fmt=""
if [[ -n "$total_api_ms" && "$total_api_ms" -gt 999 ]] 2>/dev/null; then
  api_fmt=$(_fmt_duration "$total_api_ms")
  time_segment="${TIME_COLOR}${api_fmt}${RESET}"
fi

# Token speed (output tokens / API seconds)
speed_segment=""
if [[ -n "$output_tokens" && -n "$total_api_ms" ]] && (( output_tokens > 0 && total_api_ms > 0 )); then
  _tok_per_sec=$(( output_tokens * 1000 / total_api_ms ))
  if (( _tok_per_sec >= 1000 )); then
    _speed_fmt="$(( _tok_per_sec / 1000 )).$(( _tok_per_sec % 1000 / 100 ))k"
  else
    _speed_fmt="$_tok_per_sec"
  fi
  speed_segment="${MAUVE}󰓅 ${_speed_fmt}${RESET}"
fi

COST_COLOR="${COST_GREEN}"
formatted_cost=$(printf '%.2f' "${cost:-0}")
cost_segment=""
if [[ "$formatted_cost" != "0.00" ]]; then
  cost_segment="${COST_COLOR}${cost_icon}${formatted_cost}${RESET}"
fi

# ── Row 3 (built here, printed last): left: mcp | right: time · cost
# Build right side first so we can measure it for MCP name fit check
row3_right="\033[0m"

# Always resolve chime style label for display
_chime_label=""
if awk "BEGIN {exit (${_SL_CHIME_VOLUME:-1} > 0) ? 0 : 1}"; then
  # Use cached chime value from session JSON (read earlier)
  _session_resolved="$_session_chime"
  if [[ -n "$_session_resolved" && "$_session_resolved" != "random" ]]; then
    _chime_label="$_session_resolved"
  elif [[ "$_SL_CHIME_STYLE" == "random" && -f "$NF_STATE_FILE" ]]; then
    # No per-session style yet — show the last entry from chime_recent_styles
    _last_recent=$(jq -r '.chime_recent_styles // [] | last // empty' "$NF_STATE_FILE" 2>/dev/null || true)
    _chime_label="${_last_recent:-random}"
  elif [[ -n "$_SL_CHIME_STYLE" ]]; then
    _chime_label="$_SL_CHIME_STYLE"
  fi
fi

# Build chime style segment
# Only show the resolved style name when on "random" and before any cost is incurred
_chime_segment=""
if [[ -n "$_chime_label" ]]; then
  _show_label=false
  if [[ "$_SL_CHIME_STYLE" == "random" && "$formatted_cost" == "0.00" ]]; then
    _show_label=true
  fi
  _vol_icon=$(printf '\xef\x80\xa8')  # U+F028  volume icon
  _vol_pct=$(awk "BEGIN {printf \"%g\", ${_SL_CHIME_VOLUME:-1} * 100}")
  if [[ "$_show_label" == "true" ]]; then
    if [[ "$_vol_pct" != "100" ]]; then
      _chime_segment="${MAUVE}${_vol_icon}  ${_chime_label} ${_vol_pct}%${RESET}"
    else
      _chime_segment="${MAUVE}${_vol_icon}  ${_chime_label}${RESET}"
    fi
  fi
fi

if [[ -n "$cost_segment" ]]; then
  if [[ -n "$_chime_segment" ]]; then
    row3_right+="${_chime_segment}${BULLET}"
  fi
  if [[ -n "$speed_segment" ]]; then
    row3_right+="${speed_segment}${BULLET}"
  fi
  if [[ -n "$time_segment" ]]; then
    row3_right+="${time_segment}${BULLET}"
  fi
  row3_right+="$cost_segment"
elif [[ -n "$_chime_segment" ]]; then
  row3_right+="$_chime_segment"
fi

_row3_right_len=$(_vis_len "$row3_right")

# Determine which MCP segment variant to use.
# Priority: expanded names if they fit, otherwise short count.
_mcp_to_use=""
if [[ -n "$mcp_segment" ]]; then
  _mcp_to_use="$mcp_segment"

  _row3_fits() {
    local _candidate="$1"
    local _clen=$(_vis_len "$_candidate")
    (( _clen + _row3_right_len + 2 <= ROW_WIDTH ))
  }

  if [[ -n "$mcp_segment_expanded" ]]; then
    _try="\033[0m${mcp_segment_expanded}"
    if _row3_fits "$_try"; then
      _mcp_to_use="$mcp_segment_expanded"
    elif (( ${#mcp_segments_truncated[@]} > 0 )); then
      # Try truncated variants (most names first, fewest last)
      for _trunc in "${mcp_segments_truncated[@]}"; do
        _try="\033[0m${_trunc}"
        if _row3_fits "$_try"; then
          _mcp_to_use="$_trunc"
          break
        fi
      done
    fi
  fi
fi

row3_left="\033[0m"
if [[ -n "$_mcp_to_use" ]]; then
  row3_left+="${_mcp_to_use}"
elif [[ -n "$time_segment" || -n "$cost_segment" || -n "$_chime_segment" || -n "$speed_segment" ]]; then
  # No MCP servers — show cost/time/speed/chime on the left instead of right
  if [[ -n "$cost_segment" ]]; then
    row3_left+="$cost_segment"
    [[ -n "$time_segment" ]] && row3_left+="${BULLET}${time_segment}"
    [[ -n "$speed_segment" ]] && row3_left+="${BULLET}${speed_segment}"
  elif [[ -n "$time_segment" ]]; then
    row3_left+="$time_segment"
    [[ -n "$speed_segment" ]] && row3_left+="${BULLET}${speed_segment}"
  fi
  [[ -n "$_chime_segment" ]] && { [[ "$row3_left" != "\033[0m" ]] && row3_left+="${BULLET}"; row3_left+="$_chime_segment"; }
  # Clear right side to avoid duplication
  row3_right="\033[0m"
  _row3_right_len=$(_vis_len "$row3_right")
fi

# ── Row 2: progress bar with Powerline caps ─────────────────────
bar_width=$ROW_WIDTH

# Bar fill colors — 10-tier gradient: grey-green → green → gold → orange
# Each tier: BG (fill background), FG (powerline cap foreground), TEXT (label text)
# Starts near the empty bar color (35;38;45) with a subtle green tint,
# then gradually saturates through green to gold to orange.
#   0–10%  off grey-green    (barely distinguishable from empty bar)
#   11–20% grey-green        (subtle hint of green)
#   21–30% muted green       (green becoming visible)
#   31–40% soft green        (clearly green now)
#   41–50% green             (solid green)
#   51–60% green             (still green, barely warming)
#   61–70% green-gold        (first hint of warmth)
#   71–80% gold              (noticeable transition)
#   81–90% warm gold-orange  (approaching compaction)
#   91–100% orange            (near compaction, not red)
TIER_BG=(
  "\033[48;2;42;48;46m"     # 0–10   off grey-green (close to empty bar 35;38;45)
  "\033[48;2;46;56;48m"     # 11–20  grey-green
  "\033[48;2;50;65;50m"     # 21–30  muted green
  "\033[48;2;56;76;54m"     # 31–40  soft green
  "\033[48;2;64;88;56m"     # 41–50  green
  "\033[48;2;76;100;56m"    # 51–60  green (barely warming)
  "\033[48;2;95;105;55m"    # 61–70  green-gold
  "\033[48;2;120;115;58m"   # 71–80  soft gold
  "\033[48;2;148;125;60m"   # 81–90  muted gold-orange
  "\033[48;2;170;130;62m"   # 91–100 muted orange
)
TIER_FG=(
  "\033[38;2;42;48;46m"
  "\033[38;2;46;56;48m"
  "\033[38;2;50;65;50m"
  "\033[38;2;56;76;54m"
  "\033[38;2;64;88;56m"
  "\033[38;2;76;100;56m"
  "\033[38;2;95;105;55m"
  "\033[38;2;120;115;58m"
  "\033[38;2;148;125;60m"
  "\033[38;2;170;130;62m"
)
# Wind icons: darker than fill BG (~30-40 units)
TIER_WIND=(
  "\033[38;2;27;35;30m"     # 0–10
  "\033[38;2;29;43;30m"     # 11–20
  "\033[38;2;32;52;31m"     # 21–30
  "\033[38;2;38;63;31m"     # 31–40
  "\033[38;2;50;71;30m"     # 41–50
  "\033[38;2;66;78;29m"     # 51–60
  "\033[38;2;86;84;28m"     # 61–70
  "\033[38;2;109;91;30m"    # 71–80
  "\033[38;2;131;93;30m"    # 81–90
  "\033[38;2;153;66;27m"    # 91–100
)
EMPTY_BG="\033[48;2;35;38;45m"
EMPTY_FG="\033[38;2;35;38;45m"
LIGHT_FG="\033[38;2;85;90;100m"    # dim text on empty bg
LABEL_COVERED_FG="\033[38;2;18;20;25m"  # near-black label text on filled bar

# ── Color mode overrides for progress bar gradient ───────────────
if [[ "$_SL_COLOR_MODE" == "mono" ]]; then
  # Monochrome gradient: 10 gray tiers from dark to bright
  TIER_BG=(
    "\033[48;2;60;60;60m"     # 0–10
    "\033[48;2;72;72;72m"     # 11–20
    "\033[48;2;84;84;84m"     # 21–30
    "\033[48;2;96;96;96m"     # 31–40
    "\033[48;2;108;108;108m"  # 41–50
    "\033[48;2;120;120;120m"  # 51–60
    "\033[48;2;135;135;135m"  # 61–70
    "\033[48;2;150;150;150m"  # 71–80
    "\033[48;2;170;170;170m"  # 81–90
    "\033[48;2;190;190;190m"  # 91–100
  )
  TIER_FG=(
    "\033[38;2;60;60;60m"
    "\033[38;2;72;72;72m"
    "\033[38;2;84;84;84m"
    "\033[38;2;96;96;96m"
    "\033[38;2;108;108;108m"
    "\033[38;2;120;120;120m"
    "\033[38;2;135;135;135m"
    "\033[38;2;150;150;150m"
    "\033[38;2;170;170;170m"
    "\033[38;2;190;190;190m"
  )
  TIER_WIND=(
    "\033[38;2;28;28;28m"
    "\033[38;2;35;35;35m"
    "\033[38;2;44;44;44m"
    "\033[38;2;54;54;54m"
    "\033[38;2;66;66;66m"
    "\033[38;2;78;78;78m"
    "\033[38;2;92;92;92m"
    "\033[38;2;107;107;107m"
    "\033[38;2;126;126;126m"
    "\033[38;2;146;146;146m"
  )
  EMPTY_BG="\033[48;2;38;38;38m"
  EMPTY_FG="\033[38;2;38;38;38m"
  LIGHT_FG="\033[38;2;90;90;90m"
  LABEL_COVERED_FG="\033[38;2;22;22;22m"
elif [[ "$_SL_COLOR_MODE" == "muted" ]]; then
  # Muted gradient: same green → yellow → orange hues, reduced saturation (~40%)
  TIER_BG=(
    "\033[48;2;68;82;66m"     # 0–10   muted soft green
    "\033[48;2;70;85;68m"     # 11–20  muted green
    "\033[48;2;73;88;69m"     # 21–30  muted green
    "\033[48;2;76;90;68m"     # 31–40  muted green
    "\033[48;2;80;93;67m"     # 41–50  muted green
    "\033[48;2;85;96;65m"     # 51–60  muted green (barely warming)
    "\033[48;2;100;103;64m"   # 61–70  muted green-gold
    "\033[48;2;130;122;68m"   # 71–80  muted gold
    "\033[48;2;158;132;70m"   # 81–90  muted gold-orange
    "\033[48;2;178;132;68m"   # 91–100 muted orange
  )
  TIER_FG=(
    "\033[38;2;68;82;66m"
    "\033[38;2;70;85;68m"
    "\033[38;2;73;88;69m"
    "\033[38;2;76;90;68m"
    "\033[38;2;80;93;67m"
    "\033[38;2;85;96;65m"
    "\033[38;2;100;103;64m"
    "\033[38;2;130;122;68m"
    "\033[38;2;158;132;70m"
    "\033[38;2;178;132;68m"
  )
  TIER_WIND=(
    "\033[38;2;33;47;31m"
    "\033[38;2;35;49;33m"
    "\033[38;2;37;52;34m"
    "\033[38;2;40;54;32m"
    "\033[38;2;44;57;31m"
    "\033[38;2;48;60;30m"
    "\033[38;2;62;66;28m"
    "\033[38;2;92;83;32m"
    "\033[38;2;120;93;34m"
    "\033[38;2;140;93;32m"
  )
  EMPTY_BG="\033[48;2;38;40;45m"
  EMPTY_FG="\033[38;2;38;40;45m"
  LIGHT_FG="\033[38;2;88;92;102m"
  LABEL_COVERED_FG="\033[38;2;20;24;20m"
fi

# ── Smooth gradient control points per color mode ────────────────
# 10 control points (one per tier), linearly interpolated per-cell in _render_bar.
# Default: grey-green → green → gold → orange → red at the very end
GRAD_BG_R=(48 50 55 65  88  115 140 160 180 200)
GRAD_BG_G=(62 74 88 105 112 116 122 125 120 55)
GRAD_BG_B=(48 48 50 52  54  55  58  60  58  50)
GRAD_WN_R=(27 29 32 38 50  66  86  109 131 153)
GRAD_WN_G=(35 43 52 63 71  78  84  91  93  66)
GRAD_WN_B=(30 30 31 31 30  29  28  30  30  27)

if [[ "$_SL_COLOR_MODE" == "mono" ]]; then
  # Monochrome: dark grey → bright grey, subtle brightness ramp
  GRAD_BG_R=(45 55 65 76 88  100 115 132 155 185)
  GRAD_BG_G=(45 55 65 76 88  100 115 132 155 185)
  GRAD_BG_B=(45 55 65 76 88  100 115 132 155 185)
  GRAD_WN_R=(28 35 44 54 66  78  92  107 126 146)
  GRAD_WN_G=(28 35 44 54 66  78  92  107 126 146)
  GRAD_WN_B=(28 35 44 54 66  78  92  107 126 146)
elif [[ "$_SL_COLOR_MODE" == "muted" ]]; then
  # Muted: same hue progression as default but desaturated (~40% saturation)
  GRAD_BG_R=(48 52 55 62 76  92  110 132 150 168)
  GRAD_BG_G=(52 58 65 74 86  96  104 108 104 68)
  GRAD_BG_B=(50 52 54 56 58  58  60  62  60  56)
  GRAD_WN_R=(33 35 37 40 44  48  62  92  120 140)
  GRAD_WN_G=(47 49 52 54 57  60  66  83  93  93)
  GRAD_WN_B=(31 33 34 32 31  30  28  32  34  32)
fi

# Powerline semicircle glyphs
PL_RIGHT=$(printf '\xee\x82\xb4')  # U+E0B4 right semicircle (closing cap)
PL_LEFT=$(printf '\xee\x82\xb6')   # U+E0B6 left semicircle (opening cap)

# ── Mini context pill for minimal mode ─────────────────────────────
# A compact Powerline-capped badge showing just the percentage, colored
# with the same tier gradient the full progress bar would use.
if [[ "$_SL_MODE" == "minimal" ]]; then
  _pill_pct=$(( pct * 100 / 80 ))
  (( _pill_pct > 100 )) && _pill_pct=100
  _pill_tier=$(( _pill_pct / 10 ))
  (( _pill_tier > 9 )) && _pill_tier=9
  (( _pill_tier < 0 )) && _pill_tier=0
  _PILL_BG="${TIER_BG[$_pill_tier]}"
  _PILL_FG="${TIER_FG[$_pill_tier]}"
  _PILL_TEXT_FG="\033[38;2;18;20;25m"
  pill_label="${pct}%"
  pill_segment="${_PILL_FG}${PL_LEFT}${_PILL_BG}${_PILL_TEXT_FG} ${pill_label} ${RESET}${_PILL_FG}${PL_RIGHT}${RESET}"
  # Append bullet + pill to row 1 left
  row1_left+="${BULLET}${pill_segment}"
  # Move dirty segment from right to left with bullet (if present)
  if [[ -n "$dirty_segment" ]]; then
    row1_left+="${BULLET}${dirty_segment}"
  fi
  _justified_row "$ROW_WIDTH" "$row1_left" "\033[0m"
fi

# ── _compute_gradient_cache: pre-compute per-cell ANSI colors ────
# Populates _cell_bg_cache, _cell_fg_cache, _cell_wind_cache in the
# caller's scope. Interpolates RGB between GRAD_* control points.
_compute_gradient_cache() {
  local _filled=$1 _body_area=$2 _compact_mark_pct="$3"
  _cell_bg_cache=()
  _cell_wind_cache=()
  _cell_fg_cache=()
  for (( _ci=0; _ci<_filled; _ci++ )); do
    local _cpct=$(( (_ci + 1) * 100 / _body_area ))
    if [[ -n "$_compact_mark_pct" ]] && (( _compact_mark_pct > 0 && _compact_mark_pct < 100 )); then
      _cpct=$(( _cpct * 100 / _compact_mark_pct ))
      (( _cpct > 100 )) && _cpct=100
    fi
    local _ft=$(( _cpct * 9 ))
    (( _ft > 900 )) && _ft=900
    local _lo=$(( _ft / 100 ))
    (( _lo > 8 )) && _lo=8
    local _hi=$(( _lo + 1 ))
    local _frac=$(( _ft - _lo * 100 ))
    local _r=$(( GRAD_BG_R[_lo] + (GRAD_BG_R[_hi] - GRAD_BG_R[_lo]) * _frac / 100 ))
    local _g=$(( GRAD_BG_G[_lo] + (GRAD_BG_G[_hi] - GRAD_BG_G[_lo]) * _frac / 100 ))
    local _b=$(( GRAD_BG_B[_lo] + (GRAD_BG_B[_hi] - GRAD_BG_B[_lo]) * _frac / 100 ))
    _cell_bg_cache[$_ci]="\033[48;2;${_r};${_g};${_b}m"
    _cell_fg_cache[$_ci]="\033[38;2;${_r};${_g};${_b}m"
    _r=$(( GRAD_WN_R[_lo] + (GRAD_WN_R[_hi] - GRAD_WN_R[_lo]) * _frac / 100 ))
    _g=$(( GRAD_WN_G[_lo] + (GRAD_WN_G[_hi] - GRAD_WN_G[_lo]) * _frac / 100 ))
    _b=$(( GRAD_WN_B[_lo] + (GRAD_WN_B[_hi] - GRAD_WN_B[_lo]) * _frac / 100 ))
    _cell_wind_cache[$_ci]="\033[38;2;${_r};${_g};${_b}m"
  done
}

# ── _compute_logo_gradient: pre-compute per-cell BG/FG for logo ──
# Populates _logo_bg_cache, _logo_fg_cache in the caller's scope.
# Creates a dark center → light edges ambient glow effect.
_compute_logo_gradient() {
  local _bar_area=$1
  _logo_bg_cache=()
  _logo_fg_cache=()
  local _lg_dark_r=8 _lg_dark_g=8 _lg_dark_b=12
  local _lg_peak_r _lg_peak_g _lg_peak_b
  case "$_SL_COLOR_MODE" in
    mono)  _lg_peak_r=38; _lg_peak_g=38; _lg_peak_b=38 ;;
    muted) _lg_peak_r=38; _lg_peak_g=40; _lg_peak_b=45 ;;
    *)     _lg_peak_r=35; _lg_peak_g=38; _lg_peak_b=45 ;;
  esac
  local _dark_start=$(( _bar_area * 325 / 1000 ))
  local _dark_end=$(( _bar_area * 675 / 1000 ))
  for (( _gi=0; _gi<_bar_area; _gi++ )); do
    local _t=0
    if (( _gi < _dark_start )); then
      _t=$(( 100 - _gi * 100 / _dark_start ))
    elif (( _gi >= _dark_end )); then
      local _wing_len=$(( _bar_area - _dark_end ))
      if (( _wing_len > 0 )); then
        _t=$(( (_gi - _dark_end) * 100 / _wing_len ))
      fi
    fi
    local _r=$(( _lg_dark_r + (_lg_peak_r - _lg_dark_r) * _t / 100 ))
    local _g=$(( _lg_dark_g + (_lg_peak_g - _lg_dark_g) * _t / 100 ))
    local _b=$(( _lg_dark_b + (_lg_peak_b - _lg_dark_b) * _t / 100 ))
    _logo_bg_cache[$_gi]="\033[48;2;${_r};${_g};${_b}m"
    _logo_fg_cache[$_gi]="\033[38;2;${_r};${_g};${_b}m"
  done
}

# ── _render_bar: render a progress bar given pct and label ──────
# Usage: _render_bar <pct> <label> [suffix_colored] [compact_mark_pct] [right_label]
# compact_mark_pct: if set (0–100), draws a vertical divider at that % and
#   darkens the empty region beyond it.
# right_label: if set, displayed right-aligned in the empty area with 2-char padding.
_render_bar() {
  local _pct=$1
  local _label="$2"
  local _suffix="${3:-}"
  local _compact_mark_pct="${4:-}"
  local _right_label="${5:-}"

  # NerdFlair logo: shown right-aligned in empty area of bar
  local _logo_icons=()
  local _logo_start=0
  local _NF_BRAND_COLOR="\033[38;2;145;130;155m"
  local _NF_BRAND_COLORS=()
  local _i
  for (( _i=0; _i<17; _i++ )); do _NF_BRAND_COLORS+=("$_NF_BRAND_COLOR"); done
  _logo_icons=(
    "$(printf '\xee\xa0\xb8')" " "
    "$(printf '\xf3\xb0\xaf\xb7')" " "
    "$(printf '\xf3\xb0\xb0\x9e')" " "
    "$(printf '\xf3\xb0\xaf\xb4')" " "
    "$(printf '\xef\x8c\xb5')" " "
    "$(printf '\xf3\xb0\xb0\x8c')" " "
    "$(printf '\xf3\xb0\xaf\xab')" " "
    "$(printf '\xf3\xb0\xb0\x83')" " "
    "$(printf '\xf3\xb0\xb0\x9e')"
  )
  local _logo_end=0

  # Compute top tier for outer caps and label text
  local _tier_pct=$_pct
  if [[ -n "$_compact_mark_pct" ]] && (( _compact_mark_pct > 0 && _compact_mark_pct < 100 )); then
    _tier_pct=$(( _pct * 100 / _compact_mark_pct ))
    (( _tier_pct > 100 )) && _tier_pct=100
  fi
  local _top_tier_idx=$(( _tier_pct / 10 ))
  (( _top_tier_idx > 9 )) && _top_tier_idx=9
  (( _top_tier_idx < 0 )) && _top_tier_idx=0
  local _FILL_BG="${TIER_BG[$_top_tier_idx]}"
  local _FILL_FG="${TIER_FG[$_top_tier_idx]}"
  local _WIND_FG="${TIER_WIND[$_top_tier_idx]}"

  # Bar area: fixed width, clamped to MAX_BAR
  local _bar_area=$(( bar_width - 2 ))
  (( _bar_area > MAX_BAR )) && _bar_area=$MAX_BAR
  (( _bar_area < 20 )) && _bar_area=20

  # Position logo centered in the bar area (only when bar is empty)
  if (( ${#_logo_icons[@]} > 0 && _pct == 0 )); then
    _logo_start=$(( (_bar_area - ${#_logo_icons[@]}) / 2 ))
    (( _logo_start < 0 )) && _logo_start=0
    _logo_end=$(( _logo_start + ${#_logo_icons[@]} ))
  elif (( _pct > 0 )); then
    _logo_icons=()
  fi

  # Pre-compute logo background gradient
  local _logo_bg_cache=()
  local _logo_fg_cache=()
  if (( ${#_logo_icons[@]} > 0 )); then
    _compute_logo_gradient "$_bar_area"
  fi

  # Compact mark: visual position of the compaction divider (-1 = none)
  local _compact_mark_pos=-1
  local _COMPACT_EMPTY_BG="\033[48;2;18;20;25m"
  local _COMPACT_EMPTY_FG="\033[38;2;18;20;25m"
  if [[ -n "$_compact_mark_pct" ]] && (( _compact_mark_pct > 0 && _compact_mark_pct < 100 )); then
    _compact_mark_pos=$(( _bar_area * _compact_mark_pct / 100 ))
  fi

  # When partially filled, one cell is consumed by the inner transition cap
  local _has_inner_cap=0
  if (( _pct > 0 && _pct < 100 )); then
    _has_inner_cap=1
  fi
  local _body_area=$(( _bar_area - _has_inner_cap ))

  local _filled=$(( _body_area * _pct / 100 ))
  (( _filled > _body_area )) && _filled=$_body_area

  # Padded label centered in the full bar_area
  local _label_padded=" ${_label} "
  local _label_len=${#_label_padded}
  local _label_start=$(( (_bar_area - _label_len) / 2 ))
  (( _label_start < 0 )) && _label_start=0
  local _label_end=$(( _label_start + _label_len ))
  if (( ${#_logo_icons[@]} > 0 )); then
    _label_start=-1
    _label_end=-1
  fi

  # Right-aligned label in empty area
  local _rlabel_start=-1
  local _rlabel_end=-1
  local _rlabel_padded=""
  if [[ -n "$_right_label" ]]; then
    _rlabel_padded="${_right_label}"
    local _rlabel_len=${#_rlabel_padded}
    _rlabel_start=$(( _bar_area - _rlabel_len ))
    (( _rlabel_start < 0 )) && _rlabel_start=0
    _rlabel_end=$(( _rlabel_start + _rlabel_len ))
  fi

  # Pre-compute per-cell gradient colors
  local _cell_bg_cache=() _cell_wind_cache=() _cell_fg_cache=()
  _compute_gradient_cache "$_filled" "$_body_area" "$_compact_mark_pct"

  # Outer cap colors — left cap uses first filled cell, right cap uses last
  local _left_cap_fg _right_cap_fg
  if (( _pct > 0 )); then
    _left_cap_fg="${TIER_FG[0]}"
  elif (( ${#_logo_icons[@]} > 0 && ${#_logo_bg_cache[@]} > 0 )); then
    _left_cap_fg="${_logo_fg_cache[0]}"
  elif (( ${#_logo_icons[@]} > 0 )); then
    _left_cap_fg="$_COMPACT_EMPTY_FG"
  else
    _left_cap_fg="$EMPTY_FG"
  fi

  if (( _pct >= 100 )); then
    _right_cap_fg="$_FILL_FG"
  elif (( ${#_logo_icons[@]} > 0 && ${#_logo_bg_cache[@]} > 0 )); then
    _right_cap_fg="${_logo_fg_cache[$((_bar_area - 1))]}"
  elif (( ${#_logo_icons[@]} > 0 )); then
    _right_cap_fg="$_COMPACT_EMPTY_FG"
  elif (( _compact_mark_pos >= 0 )); then
    _right_cap_fg="$_COMPACT_EMPTY_FG"
  else
    _right_cap_fg="$EMPTY_FG"
  fi

  # Override caps with smooth gradient endpoints
  if (( _filled > 0 )); then
    _left_cap_fg="${_cell_fg_cache[0]}"
    if (( _pct >= 100 )); then
      _right_cap_fg="${_cell_fg_cache[$((_filled - 1))]}"
    fi
  fi

  # Build bar body cell by cell
  local _bar=""
  local _vis=0  # visual position (0..bar_area-1)
  local _body_i=0  # body cell index (0..body_area-1)

  while (( _vis < _bar_area )); do
    # Insert inner transition cap at the fill boundary (fill → empty)
    if (( _has_inner_cap && _body_i == _filled )); then
      # Pick correct empty BG based on whether we're past the compact mark
      # or logo is showing (uses darker BG everywhere)
      local _cap_empty_bg="$EMPTY_BG"
      if (( ${#_logo_icons[@]} > 0 )); then
        _cap_empty_bg="$_COMPACT_EMPTY_BG"
      elif (( _compact_mark_pos >= 0 && _vis >= _compact_mark_pos )); then
        _cap_empty_bg="$_COMPACT_EMPTY_BG"
      fi
      # Use the last filled cell's FG/BG for the transition cap
      local _last_fill_fg="$_FILL_FG"
      local _last_fill_bg="$_FILL_BG"
      if (( _filled > 0 )); then
        _last_fill_fg="${_cell_fg_cache[$((_filled - 1))]}"
        _last_fill_bg="${_cell_bg_cache[$((_filled - 1))]}"
      fi
      if (( _vis >= _label_start && _vis < _label_end )); then
        # A label character sits on the cap cell. The cap normally renders a
        # filled (green) rounded glyph, so treat this cell as part of the fill:
        # keep the covered-label styling (fill BG + near-black FG) so the digit
        # matches the covered digits before it instead of flipping to light text.
        local _ci=$(( _vis - _label_start ))
        local _ch="${_label_padded:$_ci:1}"
        _bar+="${_last_fill_bg}${LABEL_COVERED_FG}${_ch}"
      else
        _bar+="${_cap_empty_bg}${_last_fill_fg}${PL_RIGHT}"
      fi
      _has_inner_cap=0
      (( _vis++ ))
      continue
    fi

    # Determine the empty BG for this position (darker at and beyond compact mark,
    # or gradient when logo is showing)
    local _cur_empty_bg="$EMPTY_BG"
    local _cur_light_fg="$LIGHT_FG"
    if (( ${#_logo_icons[@]} > 0 && ${#_logo_bg_cache[@]} > 0 )); then
      _cur_empty_bg="${_logo_bg_cache[$_vis]}"
    elif (( ${#_logo_icons[@]} > 0 )); then
      _cur_empty_bg="$_COMPACT_EMPTY_BG"
    elif (( _compact_mark_pos >= 0 && _vis >= _compact_mark_pos )); then
      _cur_empty_bg="$_COMPACT_EMPTY_BG"
    fi

    # Render compact mark divider (│) at the mark position in the empty zone
    # Skip when logo is showing — nothing to divide at 0%
    if (( ${#_logo_icons[@]} == 0 && _compact_mark_pos >= 0 && _vis == _compact_mark_pos && _body_i >= _filled )); then
      if (( _vis >= _label_start && _vis < _label_end )); then
        local _ci=$(( _vis - _label_start ))
        local _ch="${_label_padded:$_ci:1}"
        _bar+="${_cur_empty_bg}${_cur_light_fg}${_ch}"
      else
        _bar+="${_COMPACT_EMPTY_BG}${EMPTY_FG}${PL_RIGHT}"
      fi
      (( _body_i++ ))
      (( _vis++ ))
      continue
    fi

    # Per-cell smooth gradient colors from pre-computed cache
    local _cell_bg="$_FILL_BG"
    local _cell_fg="$_FILL_FG"
    local _cell_wind="$_WIND_FG"
    if (( _body_i < _filled )); then
      _cell_bg="${_cell_bg_cache[$_body_i]}"
      _cell_fg="${_cell_fg_cache[$_body_i]}"
      _cell_wind="${_cell_wind_cache[$_body_i]}"
    fi

    if (( _vis >= _label_start && _vis < _label_end )); then
      local _ci=$(( _vis - _label_start ))
      local _ch="${_label_padded:$_ci:1}"
      if (( _body_i < _filled )); then
        _bar+="${_cell_bg}${LABEL_COVERED_FG}${_ch}"
      else
        _bar+="${_cur_empty_bg}${_cur_light_fg}${_ch}"
      fi
    elif (( _rlabel_start >= 0 && _vis >= _rlabel_start && _vis < _rlabel_end && _body_i >= _filled )); then
      # Right-aligned label in empty area
      local _ri=$(( _vis - _rlabel_start ))
      local _rch="${_rlabel_padded:$_ri:1}"
      _bar+="${_cur_empty_bg}${_cur_light_fg}${_rch}"
    else
      if (( _body_i < _filled )); then
        _bar+="${_cell_bg} "
      else
        if (( ${#_logo_icons[@]} > 0 && _vis >= _logo_start && _vis < _logo_end )); then
          local _li=$(( _vis - _logo_start ))
          local _lc="${_NF_BRAND_COLORS[$_li]:-${_NF_BRAND_COLOR}}"
          _bar+="${_cur_empty_bg}${_lc}${_logo_icons[$_li]}"
        else
          _bar+="${_cur_empty_bg} "
        fi
      fi
    fi
    (( _body_i++ ))
    (( _vis++ ))
  done

  # Assemble and print the bar
  printf '\n%b%b%b%b%b' \
    "${RESET}${_left_cap_fg}${PL_LEFT}" \
    "${_bar}" \
    "${RESET}${_right_cap_fg}${PL_RIGHT}" \
    "${_suffix}" \
    "${RESET}"
}


_bar_label="$ctx_label"

# Render the real progress bar (skip in minimal — context pill is on row 1)
if [[ "$_SL_MODE" != "minimal" ]]; then
  _compact_mark=80
  # In compact mode, show cost right-aligned inside the bar's empty area
  _bell_icon=""
  if awk "BEGIN {exit (${_SL_CHIME_VOLUME:-1} <= 0) ? 0 : 1}"; then
    _bell_icon=$(printf '\xf3\xb0\xe5\xa9')  # U+F0969 speaker-off
  fi

  _bar_right_label=""
  # Calculate available space in the dark zone for right-aligned content
  # Dark zone = bar_area * (100 - compact_mark%) / 100, minus 1 for the right cap
  _bar_area_est=$(( bar_width - 2 ))
  (( _bar_area_est > 78 )) && _bar_area_est=78
  (( _bar_area_est < 20 )) && _bar_area_est=20
  _dark_zone=$(( _bar_area_est - _bar_area_est * 80 / 100 ))

  # Build compact mode right label: time  cost + bell, dropping time then cost if too wide
  _compact_time=""
  if [[ -n "$api_fmt" ]]; then
    _compact_time="${api_fmt} "
  fi
  _compact_cost=""
  if [[ "$formatted_cost" != "0.00" ]]; then
    _compact_cost="\$${formatted_cost} "
  fi

  if [[ "$_SL_MODE" == "compact" ]]; then
    # Try full: time + cost + bell
    _try="${_compact_time}${_compact_cost}${_bell_icon}"
    if (( ${#_try} > _dark_zone )); then
      # Drop time, keep cost + bell
      _try="${_compact_cost}${_bell_icon}"
    fi
    if (( ${#_try} > _dark_zone )); then
      # Drop cost too, keep bell only
      _try="${_bell_icon}"
    fi
    _bar_right_label="$_try"
  fi
  _render_bar "$pct" "$_bar_label" "" "$_compact_mark" "$_bar_right_label"
fi

# Row 3: mcp | time + cost (full mode only)
if [[ "$_SL_MODE" == "full" ]]; then
  printf '\n'
  _justified_row "$ROW_WIDTH" "$row3_left" "$row3_right"
fi
