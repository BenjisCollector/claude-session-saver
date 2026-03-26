# Claude Session Saver

Save and restore your entire Claude Code workspace with one click — window positions, tabs, working directories, SSH connections, and conversation sessions.

Built for developers who run multiple Claude Code instances across different projects and need to shut down without losing their setup.

## The Problem

You have 6 Claude Code windows spread across your screen — each in a different project, some SSH'd into a remote server. You need to shut down your laptop. When you boot back up, you've lost everything: which projects were open, where the windows were positioned, and which conversations were active.

## The Solution

Claude Session Saver sits quietly in your system tray (bottom-right notification area). Before shutting down, right-click the icon and hit **Save Sessions**. When you boot back up, hit **Restore Sessions** — every window reopens at the exact same position with Claude Code resuming your conversations.

## Features

- **Window positions** — saves and restores exact screen coordinates and sizes
- **Claude Code sessions** — resumes conversations with full context via `claude --resume`
- **SSH sessions** — reconnects to remote servers automatically
- **Plain tabs** — reopens PowerShell/cmd tabs at their working directories
- **Model and mode** — saves which Claude model (opus, sonnet, haiku) and permission mode (plan, default, etc.) each session was using, and restores them
- **Session names** — preserves `--name` labels so your restored sessions keep their titles
- **System tray** — lives in the hidden icons area, out of your way
- **Auto-save** — configurable timer (default: every 5 minutes) so you never lose your setup
- **Snapshot history** — keeps your last 10 saves with timestamps
- **Toast notifications** — quick confirmation when saving
- **Zero dependencies** — pure PowerShell + built-in Windows APIs

## Requirements

- Windows 10 or 11
- [Windows Terminal](https://aka.ms/terminal)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- PowerShell 5.1+ (included with Windows)

## Install

```powershell
git clone https://github.com/BenjisCollector/claude-session-saver.git
cd claude-session-saver
powershell -ExecutionPolicy Bypass -File .\Install.ps1
```

The installer does three things:
1. Adds a **system tray app** that starts on login (hidden icons area, bottom-right)
2. Creates **Start Menu shortcuts** (searchable, can be pinned to taskbar)
3. Enables **Windows Terminal's built-in tab persistence** as a fallback

## Usage

### System Tray (recommended)

After install, the tray icon appears in your hidden icons area (click the `^` arrow in the bottom-right of your taskbar).

| Action | What it does |
|--------|-------------|
| **Right-click > Save Sessions** | Captures all windows, tabs, and Claude sessions |
| **Right-click > Restore Sessions** | Reopens everything from last save |
| **Right-click > List Saves** | Shows available snapshots |
| **Right-click > Open Saves Folder** | Browse saved JSON files |
| **Double-click** | Quick save |

### Command Line

```powershell
# Save all current sessions
.\Save-Sessions.ps1

# Restore from last save
.\Restore-Sessions.ps1

# Restore a specific snapshot
.\Restore-Sessions.ps1 -Path "saves\2026-03-26T160000.json"

# List all saves
.\List-Saves.ps1
```

### Taskbar Shortcuts

Open Start Menu, search for **"Save Claude Sessions"** or **"Restore Claude Sessions"**, right-click, and select **Pin to taskbar**.

## What Gets Saved

Each save creates a timestamped JSON snapshot in the `saves/` folder:

```json
{
  "savedAt": "2026-03-26T16:00:00",
  "windows": [
    {
      "position": { "left": 100, "top": 50, "width": 900, "height": 700 },
      "title": "my-project",
      "tabs": [
        {
          "type": "claude",
          "cwd": "C:\\Users\\you\\my-project",
          "sessionId": "a26b1898-799d-4448-b8b7-7775dcf6babb",
          "sessionName": "feature-auth",
          "model": "claude-opus-4-6",
          "permissionMode": "bypassPermissions"
        },
        {
          "type": "ssh",
          "commandLine": "ssh root@my-server.com"
        },
        {
          "type": "powershell",
          "cwd": "C:\\Users\\you\\another-project"
        }
      ]
    }
  ]
}
```

### Tab types detected

| Type | How it's detected | What's saved | How it's restored |
|------|------------------|-------------|-------------------|
| `claude` | Node.js child process running Claude CLI | Session ID, working directory, session name, model, permission mode | `claude --resume <sessionId> --model <model> --permission-mode <mode>` |
| `ssh` | SSH process in tab | Full SSH command line | Re-runs the SSH command |
| `powershell` | Default PowerShell/cmd/bash | Working directory | Opens tab at saved directory |
| `other` | Anything else | Command line, working directory | Opens tab at saved directory |

## How It Works

```
Save flow:
  Windows Terminal process
    -> EnumWindows (user32.dll) -> window positions & sizes
    -> Process tree walk (WMI) -> shell -> child processes
    -> Claude session files (~/.claude/sessions/*.json) -> session IDs
    -> Conversation JSONL (~/.claude/projects/) -> model, permissionMode, real CWD
    -> JSON snapshot

Restore flow:
  JSON snapshot
    -> wt.exe new-tab -d <dir> -> opens tabs at saved directories
    -> claude --resume <id> --model <m> --permission-mode <p> -> resumes with full state
    -> SetWindowPos (user32.dll) -> positions windows on screen
```

### Process tree detection

Windows Terminal runs one `OpenConsole.exe` per tab, each hosting a shell process. The save script walks this tree:

```
WindowsTerminal.exe (PID 17104)
  ├─ OpenConsole.exe (tab 1)
  │    └─ powershell.exe
  │         └─ node.exe (claude)  ← detected as "claude" tab
  ├─ OpenConsole.exe (tab 2)
  │    └─ ssh.exe                 ← detected as "ssh" tab
  └─ OpenConsole.exe (tab 3)
       └─ powershell.exe          ← detected as "powershell" tab
```

## SSH + Remote Claude Code

For tabs where you're SSH'd into a server running Claude Code:

1. **Save** captures the SSH command (e.g., `ssh root@my-server.com`)
2. **Restore** reconnects the SSH session automatically
3. Once connected, run `claude --continue` on the remote to resume your conversation

## Configuration

Edit `config.json`:

```json
{
  "maxSaves": 10,
  "restoreDelayMs": 1500,
  "enableToastNotifications": true,
  "autoSaveMinutes": 5
}
```

| Setting | Default | Description |
|---------|---------|-------------|
| `maxSaves` | `10` | Number of timestamped snapshots to keep |
| `restoreDelayMs` | `1500` | Delay (ms) between opening windows. Increase to 2000-2500 on slower machines |
| `enableToastNotifications` | `true` | Show Windows toast notification after saving |
| `autoSaveMinutes` | `5` | Auto-save interval in minutes. The tray app saves automatically when WT is running. Toggle on/off via tray menu |

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

Removes shortcuts and startup entry. Your saved sessions in `saves/` are kept.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Windows don't position correctly | Increase `restoreDelayMs` in `config.json` to 2000 or 2500 |
| Claude session not found | Falls back to `claude --continue` (resumes most recent conversation in that directory) |
| "Access denied" on some tabs | Admin/elevated tabs can't be read from a non-elevated script |
| Toast notifications don't appear | Cosmetic only — save still works. Disable in `config.json` |
| Tray icon not visible | Click the `^` arrow in the bottom-right taskbar to show hidden icons |

## Project Structure

```
claude-session-saver/
  SessionSaver.ps1        # System tray app (lives in notification area)
  Save-Sessions.ps1       # Save logic (standalone or called by tray)
  Restore-Sessions.ps1    # Restore logic (standalone or called by tray)
  List-Saves.ps1          # List available snapshots
  Install.ps1             # Installer (shortcuts + startup + WT persistence)
  Uninstall.ps1           # Removes shortcuts and startup entry
  config.json             # User configuration
  lib/
    WinApi.ps1            # Win32 interop (window management, process inspection)
  saves/                  # Saved session snapshots (gitignored)
```

## License

MIT

## Contributing

Issues and PRs welcome. This was built to solve a real problem — if you have ideas for making it better, open an issue.
