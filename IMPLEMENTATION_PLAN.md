# Review fixes

One commit per stage. Tests first where practical.

## Stage 1: Relocate /tmp caches, validate numerics
**Goal**: statusline caches live under ~/.claude/nerdflair/cache; cache fields validated before arithmetic
**Success Criteria**: no /tmp/nerdflair-* files created; poisoned cache cannot execute code
**Tests**: render twice, assert cache under HOME; poisoned cache renders 0
**Status**: Complete

## Stage 2: Configurator crashes (bash 3.2 lowercase, layout regex)
**Status**: Not Started

## Stage 3: MCP double count
**Status**: Not Started

## Stage 4: Fractional used_percentage
**Status**: Not Started

## Stage 5: Sanitizer strips control chars; chime label sanitized
**Status**: Not Started

## Stage 6+: Remaining findings, one commit each
security (glob sort, session_id, awk -v), bugs (cache delimiter, width, locale,
state.json errors, PreCompact source, last_session, tty, volume, trap, set -u),
dead code, dev scripts, tests, docs
**Status**: Not Started
