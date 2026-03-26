<#
.SYNOPSIS
    Thaws Windows Terminal windows, tabs, and Claude Code sessions from a frozen snapshot.
.DESCRIPTION
    Reads a previously frozen JSON snapshot and reopens all Windows Terminal windows at their
    exact screen positions. Resumes Claude Code conversations, reconnects SSH sessions, and
    opens plain tabs at their saved working directories.

    Uses two-phase thaw: all windows/tabs are launched rapidly first, then positioned in batch.
.PARAMETER Path
    Path to a specific save file. Defaults to saves/latest.json.
.PARAMETER Silent
    Suppress console output (used when invoked from the system tray).
.EXAMPLE
    .\Thaw.ps1
    .\Thaw.ps1 -Path "saves\2026-03-26T160000.json"
#>
param(
    [string]$Path,
    [switch]$Silent
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$root\lib\WinApi.ps1"

$config = Get-Content "$root\config.json" -Raw | ConvertFrom-Json
$savesDir = Join-Path $root "saves"
$latestPath = if ($Path) { $Path } else { Join-Path $savesDir "latest.json" }

# ── Helpers ──

function Test-Cwd($cwd) {
    if ($cwd -and (Test-Path $cwd)) { return $cwd }
    if ($cwd -and -not $Silent) {
        Write-Host "  Directory not found: $cwd (using HOME)" -ForegroundColor Yellow
    }
    return $env:USERPROFILE
}

function Get-TabCommand($tab) {
    switch ($tab.type) {
        "claude" {
            $cwd = Test-Cwd $tab.cwd
            $claudeCmd = 'claude'
            # Check if session file still exists, fall back to --continue
            if ($tab.sessionId) {
                $sessionDir = Join-Path $env:USERPROFILE ".claude\projects"
                $jsonlExists = $false
                if (Test-Path $sessionDir) {
                    $jsonlExists = [bool](Get-ChildItem -Path $sessionDir -Recurse -Filter "$($tab.sessionId).jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1)
                }
                if ($jsonlExists) {
                    $claudeCmd += " --resume $($tab.sessionId)"
                } else {
                    $claudeCmd += ' --continue'
                }
            } else {
                $claudeCmd += ' --continue'
            }
            # Restore model
            if ($tab.model -and $tab.model -ne '<synthetic>') {
                $claudeCmd += " --model $($tab.model)"
            }
            # Restore permission mode — use --dangerously-skip-permissions for bypass mode
            # to avoid the workspace trust dialog (fixes #2)
            if ($tab.permissionMode -eq 'bypassPermissions') {
                $claudeCmd += " --dangerously-skip-permissions"
            } elseif ($tab.permissionMode -and $tab.permissionMode -ne 'default') {
                $claudeCmd += " --permission-mode $($tab.permissionMode)"
            }
            # Restore session name
            if ($tab.sessionName) {
                $safeName = $tab.sessionName -replace "'", "''"
                $claudeCmd += " --name '$safeName'"
            }
            return @{ cwd = $cwd; cmd = $claudeCmd }
        }
        "ssh" {
            if ($tab.commandLine) {
                $cmd = $tab.commandLine
                if ($cmd -match "(ssh\s+.+)") { $cmd = $Matches[1] }
                return @{ cwd = $env:USERPROFILE; cmd = $cmd }
            }
            return $null
        }
        default {
            return @{ cwd = (Test-Cwd $tab.cwd); cmd = $null }
        }
    }
}

# ── Validate ──

if (-not (Test-Path $latestPath)) {
    $msg = "No frozen workspace found. Run Freeze.ps1 first."
    if (-not $Silent) { Write-Host $msg -ForegroundColor Red }
    exit 1
}

$session = Get-Content $latestPath -Raw | ConvertFrom-Json

# ── Idempotent restore: detect already-running sessions ──

$runningSessionIds = @()
$claudeNodes = Get-CimInstance Win32_Process -Property ProcessId,Name -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'node.exe' }
$claudeSessionsDir = Join-Path $env:USERPROFILE '.claude\sessions'
if ($claudeNodes -and (Test-Path $claudeSessionsDir)) {
    foreach ($node in $claudeNodes) {
        $sf = Join-Path $claudeSessionsDir "$($node.ProcessId).json"
        if (Test-Path $sf) {
            try {
                $raw = Get-Content $sf -Raw
                if ($raw -match '"sessionId":"([^"]+)"') { $runningSessionIds += $Matches[1] }
            } catch { }
        }
    }
}

if (-not $Silent) {
    Write-Host "Thawing workspace from $($session.savedAt)..." -ForegroundColor Cyan
    Write-Host "  $($session.windows.Count) window(s)" -ForegroundColor DarkGray
}

# ── Track existing HWNDs so we can detect new ones ──

$existingHwnds = @()
$wtProc = Get-Process -Name "WindowsTerminal" -ErrorAction SilentlyContinue
if ($wtProc) {
    foreach ($wt in $wtProc) {
        $existingHwnds += ([WinApi]::GetWindows([uint32]$wt.Id) | ForEach-Object { $_.Handle })
    }
}

# ══════════════════════════════════════════════════════════════
# PHASE 1: Launch all windows and tabs rapidly (fixes #1, #4)
# ══════════════════════════════════════════════════════════════

$windowMeta = @()  # Track what we launched for Phase 2 positioning
$winIdx = 0
$skippedTabs = 0

foreach ($win in $session.windows) {
    $winIdx++
    $windowId = "css-$winIdx"

    # Filter out already-running Claude sessions (idempotent restore)
    $tabsToRestore = @()
    foreach ($tab in $win.tabs) {
        if ($tab.type -eq 'claude' -and $tab.sessionId -and $tab.sessionId -in $runningSessionIds) {
            $skippedTabs++
            if (-not $Silent) { Write-Host "  Skipping already-running: $($tab.sessionName)" -ForegroundColor DarkGray }
            continue
        }
        $tabsToRestore += $tab
    }

    if ($tabsToRestore.Count -eq 0) { continue }

    if (-not $Silent) {
        Write-Host "`nWindow $winIdx ($($tabsToRestore.Count) tab(s)):" -ForegroundColor White
    }

    # First tab — creates the window with a named ID
    $first = Get-TabCommand $tabsToRestore[0]
    if ($first.cmd) {
        Start-Process "wt.exe" -ArgumentList "--window $windowId -d `"$($first.cwd)`" powershell.exe -NoExit -Command `"$($first.cmd)`""
    } else {
        Start-Process "wt.exe" -ArgumentList "--window $windowId -d `"$($first.cwd)`""
    }
    if (-not $Silent) { Write-Host "  Tab 1: [$($tabsToRestore[0].type)] $($first.cwd)" -ForegroundColor Gray }

    # Brief delay for WT to register the window before adding tabs
    Start-Sleep -Milliseconds 400

    # Remaining tabs — target the named window (fixes #1)
    for ($i = 1; $i -lt $tabsToRestore.Count; $i++) {
        $t = Get-TabCommand $tabsToRestore[$i]
        if (-not $t) { continue }

        if ($t.cmd) {
            Start-Process "wt.exe" -ArgumentList "--window $windowId new-tab -d `"$($t.cwd)`" powershell.exe -NoExit -Command `"$($t.cmd)`""
        } else {
            Start-Process "wt.exe" -ArgumentList "--window $windowId new-tab -d `"$($t.cwd)`""
        }
        if (-not $Silent) { Write-Host "  Tab $($i+1): [$($tabsToRestore[$i].type)] $($t.cwd)" -ForegroundColor Gray }
        Start-Sleep -Milliseconds 300
    }

    # Track this window for Phase 2 positioning
    $windowMeta += @{
        position = $win.position
        title    = $win.title
        windowId = $windowId
    }

    # Small gap between windows so WT doesn't choke
    Start-Sleep -Milliseconds 300
}

# ══════════════════════════════════════════════════════════════
# PHASE 2: Position all windows in one batch (fixes #3, #4)
# ══════════════════════════════════════════════════════════════

if ($windowMeta.Count -gt 0) {
    if (-not $Silent) { Write-Host "`nPositioning windows..." -ForegroundColor DarkGray }

    # Wait for all windows to fully materialize
    Start-Sleep -Milliseconds 1500

    # Collect all current WT window handles
    $allCurrentWindows = @()
    $wtProcs = Get-Process -Name "WindowsTerminal" -ErrorAction SilentlyContinue
    if ($wtProcs) {
        foreach ($wt in $wtProcs) {
            $wins = [WinApi]::GetWindows([uint32]$wt.Id)
            foreach ($w in $wins) {
                if ($w.Handle -notin $existingHwnds) {
                    $allCurrentWindows += $w
                }
            }
        }
    }

    # Try to match new windows to saved windows by title
    $positioned = @{}
    foreach ($meta in $windowMeta) {
        $savedTitle = $meta.title
        $p = $meta.position

        # Try title match first
        $match = $null
        foreach ($w in $allCurrentWindows) {
            if ($w.Handle -notin $positioned.Values -and $w.Title -and $savedTitle -and $w.Title -like "*$savedTitle*") {
                $match = $w
                break
            }
        }

        if ($match) {
            [WinApi]::MoveWindow($match.Handle, $p.left, $p.top, $p.width, $p.height)
            $positioned[$meta.windowId] = $match.Handle
            if (-not $Silent) {
                Write-Host "  $($meta.title) -> ($($p.left),$($p.top)) $($p.width)x$($p.height)" -ForegroundColor DarkGreen
            }
        }
    }

    # Fallback: assign remaining unmatched windows by creation order
    $unmatchedMeta = $windowMeta | Where-Object { $_.windowId -notin $positioned.Keys }
    $unmatchedWindows = $allCurrentWindows | Where-Object { $_.Handle -notin $positioned.Values }

    $idx = 0
    foreach ($meta in $unmatchedMeta) {
        if ($idx -lt $unmatchedWindows.Count) {
            $w = $unmatchedWindows[$idx]
            $p = $meta.position
            [WinApi]::MoveWindow($w.Handle, $p.left, $p.top, $p.width, $p.height)
            if (-not $Silent) {
                Write-Host "  $($meta.title) -> ($($p.left),$($p.top)) $($p.width)x$($p.height) (by order)" -ForegroundColor DarkYellow
            }
            $idx++
        } else {
            if (-not $Silent) {
                Write-Host "  Could not position: $($meta.title)" -ForegroundColor Yellow
            }
        }
    }
}

# ── Summary ──

$totalTabs = ($session.windows | ForEach-Object { $_.tabs.Count } | Measure-Object -Sum).Sum
$restoredTabs = $totalTabs - $skippedTabs
$msg = "Thawed $restoredTabs tab(s) across $($windowMeta.Count) window(s)"
if ($skippedTabs -gt 0) { $msg += " (skipped $skippedTabs already running)" }

if (-not $Silent) {
    Write-Host "`n$msg" -ForegroundColor Green
}

if ($config.enableToastNotifications) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $text = $xml.GetElementsByTagName("text")
        $text.Item(0).AppendChild($xml.CreateTextNode("Cryosave")) | Out-Null
        $text.Item(1).AppendChild($xml.CreateTextNode($msg)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(
            "Cryosave").Show($toast)
    } catch { }
}
