# Cryosave Roadmap

## Current State (v1.0)

Working:
- Save/restore window positions, sizes, and all tabs
- Claude Code session resume with model, permission mode, and session name
- SSH session reconnection with full command
- System tray app with auto-save timer
- Idempotent restore (safe to run twice)
- 3-level deep process tree detection

Not working:
- Virtual desktop assignment (which desktop each window belongs to)
- Multi-monitor awareness (coordinates are absolute pixels)
- Pane/split detection within tabs

---

## v1.1 — Virtual Desktop Support

**Problem**: Windows 11 virtual desktops let you spread windows across Desktop 1, Desktop 2, etc. Currently, save captures all windows but doesn't know which desktop they're on. Restore opens everything on the current desktop.

**Approach**: Use [MScholtes/VirtualDesktop](https://github.com/MScholtes/VirtualDesktop) as an external CLI tool. It's a C# wrapper around the undocumented COM APIs that gets updated with each Windows build. This is more reliable than embedding the COM calls directly (the GUIDs change with every Windows update).

**Tasks**:
- [ ] On save: call `VirtualDesktop.exe` to get the desktop ID for each window HWND
- [ ] Save desktop index (1, 2, 3...) alongside window position in JSON
- [ ] On restore: create virtual desktops if they don't exist
- [ ] On restore: use `VirtualDesktop.exe` to move each window to its saved desktop
- [ ] Make virtual desktop support optional (works without `VirtualDesktop.exe` installed)
- [ ] Add install instructions for the VirtualDesktop dependency

**Risk**: The undocumented APIs change frequently. MScholtes maintains updated builds, but there's always a lag after major Windows updates.

---

## v1.2 — Multi-Monitor Awareness

**Problem**: Window coordinates are absolute pixels. If you save while docked (2 monitors) and restore undocked (1 monitor), windows placed on the second monitor appear off-screen.

**Tasks**:
- [ ] On save: record monitor layout (count, resolutions, positions) via `Screen.AllScreens`
- [ ] On restore: detect current monitor layout
- [ ] If layout matches: use saved coordinates directly
- [ ] If layout differs: remap coordinates proportionally to available screen space
- [ ] Clamp windows to visible screen bounds (never restore off-screen)

---

## v1.3 — Tab Panes / Splits

**Problem**: Windows Terminal supports split panes within a tab (Ctrl+Shift+D). Currently, we only detect tabs, not pane layouts.

**Tasks**:
- [ ] Investigate if WT exposes pane layout via its state files or JSON settings
- [ ] Parse `state.json` (where WT stores its own persistence data)
- [ ] On restore: recreate split panes with correct orientations and sizes

---

## v1.4 — Richer Session Intelligence

Ideas from researching [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect), [ccmanager](https://github.com/kbwo/ccmanager), [agent-deck](https://github.com/asheshgoplani/agent-deck), and [claude-sessions](https://github.com/tradchenko/claude-sessions):

- [ ] **Session status indicators**: show if Claude is idle/busy/waiting in the tray menu
- [ ] **Cost tracking**: read token usage from Claude session logs, show daily/weekly totals
- [ ] **Session forking**: ability to duplicate a conversation as a branch
- [ ] **Quick-switch menu**: tray menu shows all running Claude sessions with one-click focus
- [ ] **Keyboard shortcut**: global hotkey (e.g., Ctrl+Shift+S) for instant save
- [ ] **Export/import**: share session layouts between machines (strip machine-specific paths)

---

## v2.0 — Cross-Platform

- [ ] macOS support (use AppleScript / Accessibility API for window management)
- [ ] Linux support (wmctrl + tmux for terminal management)
- [ ] Shared JSON format across platforms

---

## Contributing

If any of these features interest you, open an issue or PR. The codebase is pure PowerShell with no external dependencies (except the optional VirtualDesktop CLI for v1.1).
