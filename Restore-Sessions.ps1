<#
.SYNOPSIS
    Restores Windows Terminal windows, tabs, and Claude Code sessions from a saved snapshot.
.DESCRIPTION
    Reads a previously saved JSON snapshot and reopens all Windows Terminal windows at their
    exact screen positions. Resumes Claude Code conversations, reconnects SSH sessions, and
    opens plain tabs at their saved working directories.
.PARAMETER Path
    Path to a specific save file. Defaults to saves/latest.json.
.PARAMETER Silent
    Suppress console output (used when invoked from the system tray).
.EXAMPLE
    .\Restore-Sessions.ps1
    .\Restore-Sessions.ps1 -Path "saves\2026-03-26T160000.json"
#>
param(
    [string]$Path,
    [switch]$Silent
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$root\lib\WinApi.ps1"

$config = Get-Content "$root\config.json" -Raw | ConvertFrom-Json
$delay = if ($config.restoreDelayMs) { $config.restoreDelayMs } else { 1500 }
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
            if ($tab.sessionId) {
                return @{ cwd = $cwd; cmd = "claude --resume $($tab.sessionId)" }
            }
            return @{ cwd = $cwd; cmd = "claude --continue" }
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
    $msg = "No saved session found. Run Save-Sessions.ps1 first."
    if (-not $Silent) { Write-Host $msg -ForegroundColor Red }
    exit 1
}

$session = Get-Content $latestPath -Raw | ConvertFrom-Json
if (-not $Silent) {
    Write-Host "Restoring session from $($session.savedAt)..." -ForegroundColor Cyan
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

# ── Restore each window ──

$winIdx = 0
foreach ($win in $session.windows) {
    $winIdx++
    if ($win.tabs.Count -eq 0) { continue }

    if (-not $Silent) {
        Write-Host "`nWindow $winIdx ($($win.tabs.Count) tab(s)):" -ForegroundColor White
    }

    # First tab — creates the window
    $first = Get-TabCommand $win.tabs[0]
    if ($first.cmd) {
        Start-Process "wt.exe" -ArgumentList "-d `"$($first.cwd)`" powershell.exe -NoExit -Command `"$($first.cmd)`""
    } else {
        Start-Process "wt.exe" -ArgumentList "-d `"$($first.cwd)`""
    }
    if (-not $Silent) { Write-Host "  Tab 1: [$($win.tabs[0].type)] $($first.cwd)" -ForegroundColor Gray }
    Start-Sleep -Milliseconds $delay

    # Remaining tabs — add to the most recent window
    for ($i = 1; $i -lt $win.tabs.Count; $i++) {
        $t = Get-TabCommand $win.tabs[$i]
        if (-not $t) { continue }

        if ($t.cmd) {
            Start-Process "wt.exe" -ArgumentList "-w 0 new-tab -d `"$($t.cwd)`" powershell.exe -NoExit -Command `"$($t.cmd)`""
        } else {
            Start-Process "wt.exe" -ArgumentList "-w 0 new-tab -d `"$($t.cwd)`""
        }
        if (-not $Silent) { Write-Host "  Tab $($i+1): [$($win.tabs[$i].type)] $($t.cwd)" -ForegroundColor Gray }
        Start-Sleep -Milliseconds 500
    }

    # ── Position the window ──
    Start-Sleep -Milliseconds 500
    $positioned = $false

    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        $wtProc = Get-Process -Name "WindowsTerminal" -ErrorAction SilentlyContinue
        if ($wtProc) {
            foreach ($wt in $wtProc) {
                $current = [WinApi]::GetWindows([uint32]$wt.Id)
                foreach ($w in $current) {
                    if ($w.Handle -notin $existingHwnds) {
                        $p = $win.position
                        [WinApi]::MoveWindow($w.Handle, $p.left, $p.top, $p.width, $p.height)
                        if (-not $Silent) {
                            Write-Host "  Positioned at ($($p.left),$($p.top)) $($p.width)x$($p.height)" -ForegroundColor DarkGreen
                        }
                        $existingHwnds += $w.Handle
                        $positioned = $true
                        break
                    }
                }
                if ($positioned) { break }
            }
        }
        if ($positioned) { break }
        Start-Sleep -Milliseconds 200
    }

    if (-not $positioned -and -not $Silent) {
        Write-Host "  Could not position window" -ForegroundColor Yellow
    }

    Start-Sleep -Milliseconds 500
}

# ── Summary ──

$totalTabs = ($session.windows | ForEach-Object { $_.tabs.Count } | Measure-Object -Sum).Sum
$msg = "Restored $($session.windows.Count) window(s), $totalTabs tab(s)"

if (-not $Silent) {
    Write-Host "`n$msg" -ForegroundColor Green
}

if ($config.enableToastNotifications) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $text = $xml.GetElementsByTagName("text")
        $text.Item(0).AppendChild($xml.CreateTextNode("Claude Session Saver")) | Out-Null
        $text.Item(1).AppendChild($xml.CreateTextNode($msg)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(
            "Claude Session Saver").Show($toast)
    } catch { }
}
