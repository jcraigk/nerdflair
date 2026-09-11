# Changelog

## Unreleased

### Fixed
- Numbers over 999 (lines added/removed, cost, dirty files) now show thousands separators regardless of locale
- Statusline caches moved from `/tmp` to `~/.claude/nerdflair/cache` and validated before use
- `chime-style` and `chime-session` no longer crash on macOS `/bin/bash` 3.2; `layout` rejects invalid names instead of corrupting state
- MCP servers from a project `.mcp.json` were listed twice; they now also honour Claude Code approval
- Fractional `used_percentage`, escape bytes in server/folder names, and a missing `LANG` no longer break rendering or width
- Auto width rows are exactly `$COLUMNS` wide; the worktree icon survives a repo without `origin`
- State fields are read with a delimiter that preserves empty values; state writes are locked and atomic
- Post-compaction `SessionStart` is detected from the hook `source` field instead of a global marker
- Linux TTY detection, `chime-volume 08`, and non-English locales no longer misbehave

### Removed
- Clickable OSC 8 hyperlinks (removed earlier; the changelog still listed them)
- Dead code: `flair` state field, wind gradient, unused colors and helpers

## 1.1.0 — 2026-03-19

### Added
- Linux audio support via `paplay` (PulseAudio/PipeWire) — chimes now work on Linux
- Token speed display (`t/s`) on row 3 in full mode
- Clickable OSC 8 hyperlinks on folder name (links to GitHub repo) and branch (links to branch)
- Git data caching (3-second TTL) to reduce git subprocess overhead per render
- Auto terminal width detection (`$COLUMNS`) for `width: auto` instead of hardcoded 80
- Worktree branch display when running with `--worktree`
- `PreCompact` and `UserPromptSubmit` hook events registered in hooks.json
- `PreCompact` added to default chime events
- `install` command (idempotent: initializes defaults on first run, preserves existing settings on upgrade)
- This changelog

### Changed
- Audio playback abstracted to shared `_nf_play_audio` helper in lib.sh

## 1.0.0 — 2026-03-09

Initial release.

- 3 layout modes: full, compact, minimal
- Context bar with color gradient, compaction threshold marker, and randomizable textures
- 3 color palettes: vibrant, muted, mono
- 20 audio chime styles with per-event configuration (macOS)
- 150 custom spinner verbs
- Terminal bell on Notification, PermissionRequest, Stop
- Git branch, dirty file count, lines added/removed
- Model name with output style indicator
- MCP server display with smart truncation
- Session cost and API duration
- Per-session random chime style and bar texture
- `/nerdflair` skill for configuration via natural language
