---
name: nerdflair
description: Configure or install the nerdflair statusline. Use when user asks to set up, setup, install, configure, toggle, or change the statusline layout, mode, terminal-bell, chimes, color-palette, spinner-verbs, or width.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskUserQuestion
disable-model-invocation: true
---

Configure the nerdflair statusline. This skill handles both first-time install and ongoing configuration.

Base directory for this skill: $CLAUDE_PLUGIN_ROOT

## First: check what the user asked for

If the user provided arguments (e.g., `/nerdflair install`, `/nerdflair layout full`), handle that request directly using the **Install** or **Configure** sections below.

If the user invoked `/nerdflair` with NO arguments, first run `info` to get the current state, then display a complete command reference showing current settings and all available commands. Format it like a CLI help page:

1. Show current settings from `info` output as a formatted summary
2. List ALL available commands alphabetically with their current values and what they do:

```
nerdflair

Current settings:
  layout: full   width: auto
  terminal-bell: on   chimes: on (BalladPiano)   color-palette: vibrant

Commands:
  /nerdflair chime-events       Show/toggle which events play chimes
  /nerdflair chime-session [style] Set chime for this session only (plays preview)
  /nerdflair chime-style [style]   Set or cycle global chime style (random, BalladPiano, ...)
  /nerdflair chime-volume [0-100]  Set chime volume (0 = muted)
  /nerdflair color-palette [mode]  Set or cycle palette (vibrant, muted, mono)
  /nerdflair layout [mode]      Set or cycle layout (full, compact, minimal)
  /nerdflair info                Show current settings without changing anything
  /nerdflair install             Install or upgrade (font check, settings.json; preserves settings)
  /nerdflair uninstall           Remove nerdflair from settings and clean up data
  /nerdflair spinner-verbs      Toggle custom spinner verbs on/off (or: enable | disable)
  /nerdflair terminal-bell      Toggle terminal bell on/off (tab indicator)
  /nerdflair width [auto|50-150]   Set layout width
```

Stop after displaying the help. Do NOT prompt the user or use AskUserQuestion — just print the settings and commands, then wait for the user to run a command themselves.

## Install

### Step 0: Check jq

`jq` is **required** -- the statusline and configurator parse JSON with it, and the install script exits immediately if it's missing.

```bash
command -v jq >/dev/null 2>&1 && echo "jq found" || echo "jq MISSING"
```

**If found:** Continue to Step 1.

**If missing:** Use AskUserQuestion with header "jq":

**Question:** "nerdflair requires jq to run. How would you like to install it?"

**Options:**
1. **Homebrew (recommended)** - "Install jq via brew (macOS)"
2. **apt** - "Install jq via apt (Debian/Ubuntu)"
3. **Skip for now** - "I'll install jq later (the statusline won't run without it)"

Handle each response:
- **Homebrew:** Run `brew install jq`, then continue to Step 1.
- **apt:** Run `sudo apt install jq`, then continue to Step 1.
- **Skip for now:** Warn that the statusline will not render until jq is installed, then stop (do not run the install script -- it will fail).

### Step 1: Check Nerd Font

A Nerd Font is **required** -- the progress bar, icons, and Powerline caps all use Nerd Font glyphs. Without one, the statusline renders as broken boxes.

```bash
find ~/Library/Fonts /Library/Fonts ~/.local/share/fonts ~/.fonts /usr/share/fonts -maxdepth 2 -iname '*nerd*' 2>/dev/null | head -5
```

**If fonts are found:** Tell the user and continue to Step 2.

**If no fonts found:** Use AskUserQuestion with header "Nerd Font":

**Question:** "nerdflair requires a Nerd Font for icons and the progress bar. How would you like to install one?"

**Options:**
1. **Homebrew (recommended)** - "Install JetBrains Mono Nerd Font via brew"
2. **I already have one** - "My terminal is already configured with a Nerd Font"
3. **Skip for now** - "I'll install a font later (statusline will look broken)"

Handle each response:
- **Homebrew:** Run `brew install --cask font-jetbrains-mono-nerd-font`, then continue to Step 1b.
- **I already have one:** Continue to Step 1b.
- **Skip for now:** Warn that icons will render as boxes, then skip to Step 2.

### Step 1b: Configure the terminal font

Installing a font only puts the files on disk -- the user must also select it in their terminal app. Use AskUserQuestion with header "Terminal Font Setup":

**Question:** "Which terminal are you using? I'll give you the exact steps to activate the Nerd Font."

**Options:**
1. **iTerm2**
2. **Terminal.app**
3. **Warp**
4. **Ghostty**
5. **VS Code integrated terminal**
6. **Other / I'll figure it out**

Give terminal-specific instructions based on their selection:

- **iTerm2:** Open Settings (Cmd+,) -> Profiles -> Text -> Font -> select "JetBrainsMono Nerd Font" from the dropdown. If you have multiple profiles, update the one marked as Default.
- **Terminal.app:** Open Settings (Cmd+,) -> Profiles -> select your active profile -> click "Font" -> click "Change..." -> find and select "JetBrainsMono Nerd Font" -> set your preferred size -> click Done.
- **Warp:** Open Settings (Cmd+,) -> Appearance -> scroll to "Terminal font" -> select "JetBrainsMono Nerd Font".
- **Ghostty:** Add `font-family = JetBrainsMono Nerd Font` to `~/.config/ghostty/config` (create the file if it doesn't exist), then restart Ghostty.
- **VS Code integrated terminal:** Open Settings (Cmd+,) -> search "terminal font" -> set **Terminal > Integrated: Font Family** to `JetBrainsMono Nerd Font`. Alternatively, add `"terminal.integrated.fontFamily": "JetBrainsMono Nerd Font"` to your `settings.json`.
- **Other:** Tell the user to find their terminal's font settings and select "JetBrainsMono Nerd Font" (or whichever Nerd Font they installed).

After giving instructions, tell the user they can verify with `echo ""` -- if they see a box or question mark instead of an icon, the font isn't active yet.

### Step 2: Initialize state and configure statusLine

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" install
```

This is idempotent: on first install it creates state with defaults; on upgrade it preserves existing settings. It also points the `statusLine` entry in `~/.claude/settings.json` at this plugin's `scripts/statusline.sh` (absolute, quoted path).

Before running, check if a **non-nerdflair** statusLine is already configured:

- If `statusLine` is **absent or already points to nerdflair** (command contains `nerdflair`): proceed.
- If `statusLine` **exists and points to something else**: warn the user that a different statusline is configured and use AskUserQuestion to ask whether to replace it. Show the current command. If they decline, skip this step.

### Step 3: Enable spinner verbs

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" spinner-verbs enable
```

This loads the custom thinking/spinner phrases from `assets/text/spinners.txt` into `~/.claude/settings.json`. If existing non-nerdflair spinner verbs are present, they are backed up first. If nerdflair verbs are already installed, they are refreshed in place (no backup needed).

### Step 4: Verify and summarize

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" info
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" chime-events
```

Display a summary table of settings from the `info` output. Format the table as follows:
- Bold the **Setting** and **Value** column headers
- Title-case the values (e.g. "Full", "Vibrant", "On", "Auto", "Random (per session)") for readability
- Alphabetize the rows by setting name
- For chime events, list the actual enabled event names (from the `chime-events` output) instead of just a count
- Do NOT include a "Font" row (we only check for fonts to help install -- we can't tell which font the terminal is actually using)
- Do NOT include the statusline command path

Tell the user to restart Claude Code for the changes to take effect.

## Configure

Run the appropriate command based on what the user asked for. After running it, briefly confirm the change. The effect is visible on the next statusline render.

### Examples

Cycle to the next layout:
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" layout
```

Set layout directly:
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" layout full
```

Cycle chime style (random -> BalladPiano -> DelicateBells -> ...):
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" chime-style
```

Set chime for this session only (plays SessionStart sound):
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" chime-session Vibraphone
```

List available session chime styles (no argument):
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" chime-session
```
When the user runs `/nerdflair chime-session` with no argument, run the command above to get the numbered list,
then use AskUserQuestion to let them pick a style (use the numbered style names as options).
After they choose, run `chime-session <name>` or `chime-session <number>` to apply it.

Set chime volume (0 = muted, 100 = full):
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" chime-volume 50
```

Cycle color palette (vibrant -> muted -> mono):
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" color-palette
```

Toggle terminal bell on/off (tab indicator on Notification, PermissionRequest, Stop):
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" terminal-bell
```

Set width:
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" width 60
```

Reset width to auto:
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" width auto
```

Show current settings without changing anything:
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" info
```

### Layout
- **layout**: cycles or sets the statusline mode
  - **full**: 3 rows -- folder/branch, progress bar, mcp/cost
  - **compact**: 2 rows -- folder/branch, progress bar (cost folded into bar label)
  - **minimal**: 1 row -- progress bar only
- Cycle order: full -> compact -> minimal -> full

### Width
- **width**: sets the layout width (50-150, or "auto")
  - **auto** (default): the detected terminal width (`$COLUMNS`), clamped to 50-150
  - **50-150**: fixed bar width in columns

### Terminal Bell
- **terminal-bell**: toggles the terminal bell (BEL character) on/off (default: on)
  - The BEL fires on 3 hard-coded events only: **Notification**, **PermissionRequest**, **Stop**
  - Shows a tab indicator in terminals that support BEL (Ghostty, iTerm2, Terminal.app, Kitty, WezTerm, etc.)
  - The bell events are not user-configurable (use **chime-events** to control which events play audio)

### Chimes
- **chime-volume**: sets the chime playback volume (0-100, default 100)
  - **0** = muted (no audio plays)
  - Affects all sessions (plugin-wide setting)
  - Shown in the statusline next to chime style when not 100%
- **chime-style**: cycles through audio styles (run `ls "$CLAUDE_PLUGIN_ROOT/assets/audio/"` to discover available styles; "random" is always an option)
  - "random" picks a style per session (locked to session_id, persists across context clears)
  - Each style has per-event sounds (Notification, PermissionRequest, Stop, etc.)
- **chime-session**: set the chime style for the current session only (does not change global setting)
  - Overrides the global `chime-style` (or the random pick) for this session
  - Plays the SessionStart sound immediately so you can hear the style
  - Resets when the session ends (session file is cleaned up)
  - No argument: lists available styles numbered (use AskUserQuestion to let user pick)
  - With argument: set directly by name or number: `chime-session Vibraphone` or `chime-session 19`
- **chime-events**: user-configurable list of events that play audio chimes (default: Notification, PermissionRequest, PreCompact, SessionEnd, SessionStart, Stop)
  - Available events: Notification, PermissionRequest, PreCompact, SessionEnd, SessionStart, Stop, UserPromptSubmit
  - Toggle individual events with `chime-events <EventName>`
- `chime_sound` (state.json only, default `Glass`): macOS system sound played when the active style has no file for an event

### Spinner Verbs
- **spinner-verbs**: toggle nerdflair's custom spinner/thinking text on or off
- The shimmering text shown while Claude is working (e.g. "Thinking...", "Reasoning...")
- When enabled, loads verbs from `$CLAUDE_PLUGIN_ROOT/assets/text/spinners.txt` (one per line) into `~/.claude/settings.json`
- When disabled, removes the `spinnerVerbs` field from settings (restores Claude Code defaults)
- Users can also edit `assets/text/spinners.txt` directly to customize the verb list
- Changes require a Claude Code restart to take effect
- **spinner-verbs** (no args): toggle on/off
- **spinner-verbs enable**: enable nerdflair verbs
- **spinner-verbs disable**: disable (restore defaults)

Examples:
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" spinner-verbs
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" spinner-verbs enable
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" spinner-verbs disable
```

### Color Palette
- **color-palette**: cycles the color palette -- vibrant -> muted -> mono -> vibrant
- **vibrant**: full-color palette (blues, greens, ambers, reds)
- **muted**: same hues as vibrant but desaturated (~40% saturation) for a subdued look
- **mono**: grayscale only -- all text and progress bar gradients use shades of gray

### Uninstall
- **uninstall**: removes all nerdflair traces from `~/.claude/`
  - Removes `spinnerVerbs` from `~/.claude/settings.json`
  - Removes `statusLine` from `~/.claude/settings.json`
  - Removes `~/.claude/nerdflair/` directory (state, sessions)
  - The plugin files themselves remain in place — disable or remove the plugin from Claude Code settings to fully remove

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/nerdflair.sh" uninstall
```

### Legacy command aliases
Older names still work and map onto the commands above: `bell` (terminal-bell), `chimes` (toggle mute), `bell-sound` / `audio-style` (chime-style), `audio-events` (chime-events), `volume` (chime-volume), `spinner` (spinner-verbs), `color` (color-palette), `-w` / `--width` (width), and a bare layout name such as `/nerdflair compact` (layout). Prefer the canonical names in new instructions.
