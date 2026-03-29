<#
.SYNOPSIS
    Restores Windows Terminal windows, tabs, and Claude Code sessions from a saved snapshot.
.DESCRIPTION
    Reads a previously saved JSON snapshot and reopens all Windows Terminal windows at their
    exact screen positions. Resumes Claude Code conversations, reconnects SSH sessions, and
    opens plain tabs at their saved working directories.

    Shows a splash screen during restore so the user sees a polished loading experience
    instead of windows spawning chaotically.
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
    [string]$Workspace,
    [switch]$Silent
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# Hide own console window immediately so no PowerShell window flashes before splash
try {
    Add-Type -IgnoreWarnings -Name Win32Hide -Namespace Cryosave -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction SilentlyContinue
    $consoleHwnd = [Cryosave.Win32Hide]::GetConsoleWindow()
    if ($consoleHwnd -ne [IntPtr]::Zero) { [Cryosave.Win32Hide]::ShowWindow($consoleHwnd, 0) | Out-Null }
} catch { }

try { . "$root\lib\WinApi.ps1" } catch {
    if (-not $Silent) { Write-Host "WinApi load failed: $_" -ForegroundColor Red }
}

# Load WinForms for monitor detection (Screen.AllScreens) — splash runspace loads its own copy
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

# DPI awareness — must be called before any Screen or coordinate work
try {
    if (-not ([System.Management.Automation.PSTypeName]'DpiHelper').Type) {
        Add-Type -IgnoreWarnings -TypeDefinition 'using System.Runtime.InteropServices; public class DpiHelper { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }' -ErrorAction SilentlyContinue
    }
    [DpiHelper]::SetProcessDPIAware() | Out-Null
} catch { }

# ── Monitor layout + remap functions ──

function Get-MonitorLayout {
    $screens = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }, { $_.Bounds.Y }
    $monitors = @()
    $idx = 0
    foreach ($scr in $screens) {
        $b = $scr.Bounds
        $monitors += @{
            index      = $idx
            deviceName = $scr.DeviceName
            left       = $b.X
            top        = $b.Y
            width      = $b.Width
            height     = $b.Height
            primary    = [bool]$scr.Primary
        }
        $idx++
    }
    $fp = ($monitors | ForEach-Object { "$($_.width)x$($_.height)@$($_.left),$($_.top)" }) -join '|'
    return @{ monitors = $monitors; fingerprint = $fp }
}

function Get-RemappedPosition($savedWindow, $savedMonitors, $currentMonitors) {
    $savedMonIdx = $savedWindow.monitorIndex
    $savedMon = $savedMonitors | Where-Object { $_.index -eq $savedMonIdx }

    # Find best target monitor: same index if resolution matches, else closest resolution, else primary
    $targetMon = $null
    $sameMon = $currentMonitors | Where-Object { $_.index -eq $savedMonIdx }
    if ($sameMon -and $savedMon -and $sameMon.width -eq $savedMon.width -and $sameMon.height -eq $savedMon.height) {
        $targetMon = $sameMon
    }
    if (-not $targetMon -and $savedMon) {
        # Closest resolution match
        $bestDist = [int]::MaxValue
        foreach ($cm in $currentMonitors) {
            $dist = [Math]::Abs($cm.width - $savedMon.width) + [Math]::Abs($cm.height - $savedMon.height)
            if ($dist -lt $bestDist) { $bestDist = $dist; $targetMon = $cm }
        }
    }
    if (-not $targetMon) {
        $targetMon = $currentMonitors | Where-Object { $_.primary -eq $true }
        if (-not $targetMon) { $targetMon = $currentMonitors[0] }
    }

    $rel = $savedWindow.relativePosition
    $newLeft   = [int]($targetMon.left + $rel.leftPct * $targetMon.width)
    $newTop    = [int]($targetMon.top  + $rel.topPct  * $targetMon.height)
    $newWidth  = [int]($rel.widthPct  * $targetMon.width)
    $newHeight = [int]($rel.heightPct * $targetMon.height)

    # Enforce minimum size
    $newWidth  = [Math]::Max(400, $newWidth)
    $newHeight = [Math]::Max(300, $newHeight)

    return @{ left = $newLeft; top = $newTop; width = $newWidth; height = $newHeight }
}

function Clamp-ToScreen($pos) {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    # Ensure at least 100px visible within the virtual screen
    $pos.left   = [Math]::Max($vs.X - $pos.width + 100, [Math]::Min($pos.left, $vs.X + $vs.Width - 100))
    $pos.top    = [Math]::Max($vs.Y - $pos.height + 100, [Math]::Min($pos.top, $vs.Y + $vs.Height - 100))
    $pos.width  = [Math]::Max(400, $pos.width)
    $pos.height = [Math]::Max(300, $pos.height)
    return $pos
}

$config = Get-Content "$root\config.json" -Raw | ConvertFrom-Json
$savesDir = Join-Path $root "saves"

# Resolve save file: -Path > -Workspace > auto-detect > latest.json
if ($Path) {
    $latestPath = $Path
} elseif ($Workspace) {
    $latestPath = Join-Path $savesDir "workspaces\$Workspace.json"
} else {
    # Auto-detect: scan workspaces for matching monitor fingerprint
    $autoDetect = if ($config.autoDetectWorkspace -ne $false) { $true } else { $false }
    $latestPath = Join-Path $savesDir "latest.json"
    if ($autoDetect) {
        $wsDir = Join-Path $savesDir "workspaces"
        if (Test-Path $wsDir) {
            $currentLayout = Get-MonitorLayout
            $wsFiles = Get-ChildItem -Path $wsDir -Filter "*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
            foreach ($wsf in $wsFiles) {
                try {
                    $wsData = Get-Content $wsf.FullName -Raw | ConvertFrom-Json
                    if ($wsData.monitorFingerprint -eq $currentLayout.fingerprint) {
                        $latestPath = $wsf.FullName
                        if (-not $Silent) {
                            Write-Host "Auto-detected workspace '$($wsf.BaseName)' (monitors match)" -ForegroundColor Cyan
                        }
                        break
                    }
                } catch { }
            }
        }
    }
}

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
            # Always skip trust prompt during restore — user already trusts their own workspace
            $claudeCmd += " --dangerously-skip-permissions"
            # Restore session name
            if ($tab.sessionName) {
                $safeName = $tab.sessionName -replace "'", "''"
                $claudeCmd += " --name '$safeName'"
            }
            return @{ cwd = $cwd; cmd = $claudeCmd; shell = 'powershell' }
        }
        "ssh" {
            if ($tab.commandLine) {
                $cmd = $tab.commandLine
                if ($cmd -match "(ssh\s+.+)") { $cmd = $Matches[1] }
                return @{ cwd = $env:USERPROFILE; cmd = $cmd; shell = 'cmd' }
            }
            return $null
        }
        default {
            return @{ cwd = (Test-Cwd $tab.cwd); cmd = $null; shell = 'powershell' }
        }
    }
}

function Get-AllWtHwnds {
    # Use window class name — reliable on Win11 where PID-based lookup fails
    # due to WT's monarch/peasant architecture
    return [WinApi]::FindWindowsByClass("CASCADIA_HOSTING_WINDOW_CLASS")
}

function Wait-NewWindow($beforeHwnds, $timeoutMs = 2000) {
    $elapsed = 0
    while ($elapsed -lt $timeoutMs) {
        Start-Sleep -Milliseconds 100
        $elapsed += 100
        $currentHwnds = Get-AllWtHwnds
        foreach ($h in $currentHwnds) {
            if ($h -notin $beforeHwnds) { return $h }
        }
    }
    return $null
}

# ── Build launch command for wt.exe ──

function Get-WtLaunchArgs($windowId, $tabInfo, $isNewTab) {
    $prefix = if ($isNewTab) { "--window $windowId new-tab" } else { "--window $windowId" }
    $dirArg = "-d `"$($tabInfo.cwd)`""

    if ($tabInfo.cmd) {
        if ($tabInfo.shell -eq 'cmd') {
            # SSH and other bash-ism commands: use cmd.exe /k to keep window open
            $escapedCmd = $tabInfo.cmd -replace '"', '\"'
            return "$prefix $dirArg cmd.exe /k `"$escapedCmd`""
        } else {
            # Use -EncodedCommand to avoid all quoting/escaping issues through WT's arg parser
            $bytes = [System.Text.Encoding]::Unicode.GetBytes($tabInfo.cmd)
            $encoded = [Convert]::ToBase64String($bytes)
            return "$prefix $dirArg powershell.exe -NoExit -EncodedCommand $encoded"
        }
    } else {
        return "$prefix $dirArg"
    }
}

# ── Validate ──

if (-not (Test-Path $latestPath)) {
    $msg = "No saved workspace found. Run Freeze.ps1 first."
    if (-not $Silent) { Write-Host $msg -ForegroundColor Red }
    exit 1
}

$session = Get-Content $latestPath -Raw | ConvertFrom-Json

# ── Pre-trust all Claude tab CWDs so the workspace trust dialog never appears ──

$claudeJsonPath = Join-Path $env:USERPROFILE ".claude.json"
$claudeCwds = @()
foreach ($win in $session.windows) {
    foreach ($tab in $win.tabs) {
        if ($tab.type -eq "claude" -and $tab.cwd -and (Test-Path $tab.cwd)) {
            $fwd = $tab.cwd -replace '\\', '/'
            if ($fwd -notin $claudeCwds) { $claudeCwds += $fwd }
        }
    }
}

if ($claudeCwds.Count -gt 0 -and (Test-Path $claudeJsonPath)) {
    try {
        # String-index approach — ConvertFrom-Json fails on duplicate keys in .claude.json
        $raw = [System.IO.File]::ReadAllText($claudeJsonPath)
        $modified = $false
        foreach ($cwd in $claudeCwds) {
            $searchKey = "`"$cwd`""
            $keyIdx = $raw.IndexOf($searchKey)
            if ($keyIdx -ge 0) {
                # Path exists — fix trust flags within the next 1000 chars
                $sub = $raw.Substring($keyIdx, [Math]::Min(1000, $raw.Length - $keyIdx))
                $trustStr = '"hasTrustDialogAccepted": false'
                $tidx = $sub.IndexOf($trustStr)
                if ($tidx -ge 0) {
                    $absIdx = $keyIdx + $tidx
                    $raw = $raw.Remove($absIdx, $trustStr.Length).Insert($absIdx, '"hasTrustDialogAccepted": true')
                    $modified = $true
                }
                $sub = $raw.Substring($keyIdx, [Math]::Min(1000, $raw.Length - $keyIdx))
                $onboardStr = '"hasCompletedProjectOnboarding": false'
                $oidx = $sub.IndexOf($onboardStr)
                if ($oidx -ge 0) {
                    $absIdx = $keyIdx + $oidx
                    $raw = $raw.Remove($absIdx, $onboardStr.Length).Insert($absIdx, '"hasCompletedProjectOnboarding": true')
                    $modified = $true
                }
            } else {
                # Path doesn't exist — insert new entry inside "projects"
                $projIdx = $raw.IndexOf('"projects"')
                if ($projIdx -ge 0) {
                    $braceIdx = $raw.IndexOf('{', $projIdx) + 1
                    $newEntry = "`n    `"$cwd`": {`"allowedTools`":[],`"mcpContextUris`":[],`"mcpServers`":{},`"enabledMcpjsonServers`":[],`"disabledMcpjsonServers`":[],`"hasTrustDialogAccepted`":true,`"projectOnboardingSeenCount`":0,`"hasClaudeMdExternalIncludesApproved`":false,`"hasClaudeMdExternalIncludesWarningShown`":false,`"hasCompletedProjectOnboarding`":true},"
                    $raw = $raw.Insert($braceIdx, $newEntry)
                    $modified = $true
                }
            }
        }
        if ($modified) {
            [System.IO.File]::WriteAllText($claudeJsonPath, $raw, [System.Text.Encoding]::UTF8)
            if (-not $Silent) {
                Write-Host "Pre-trusted $($claudeCwds.Count) workspace(s) for Claude Code" -ForegroundColor DarkGray
            }
        }
    } catch {
        if (-not $Silent) { Write-Host "  Warning: could not pre-trust workspaces: $_" -ForegroundColor Yellow }
    }
}

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

# ── Exclude tabs by session name (from config) ──
$excludeNames = @()
if ($config.excludeSessionNames) { $excludeNames = @($config.excludeSessionNames) }

# ── Dedup: if the save file has the same sessionId in multiple windows, keep only the first ──
$seenSessionIds = @{}
foreach ($win in $session.windows) {
    $deduped = @()
    foreach ($tab in $win.tabs) {
        if ($tab.type -eq 'claude' -and $tab.sessionId) {
            if ($seenSessionIds[$tab.sessionId]) {
                if (-not $Silent) { Write-Host "  Dedup: skipping duplicate sessionId $($tab.sessionId)" -ForegroundColor DarkYellow }
                continue
            }
            $seenSessionIds[$tab.sessionId] = $true
        }
        $deduped += $tab
    }
    $win.tabs = $deduped
}

if (-not $Silent) {
    Write-Host "Restoring workspace from $($session.savedAt)..." -ForegroundColor Cyan
    Write-Host "  $($session.windows.Count) window(s)" -ForegroundColor DarkGray
}

# ══════════════════════════════════════════════════════════════
# SPLASH SCREEN — runs on a separate STA runspace
# ══════════════════════════════════════════════════════════════

$splashState = [hashtable]::Synchronized(@{ phase = 'loading'; angle = 0; ready = $false })

$splashRunspace = [runspacefactory]::CreateRunspace()
$splashRunspace.ApartmentState = 'STA'
$splashRunspace.ThreadOptions = 'ReuseThread'
$splashRunspace.Open()
$splashRunspace.SessionStateProxy.SetVariable('splashState', $splashState)

$splashPS = [powershell]::Create()
$splashPS.Runspace = $splashRunspace
[void]$splashPS.AddScript({
    try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch { $splashState.ready = $true; return }

    # Span entire virtual screen (all monitors) so splash covers everything
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $sw = $vs.Width; $sh = $vs.Height; $sx = $vs.X; $sy = $vs.Y

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Cryosave'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object System.Drawing.Point($sx, $sy)
    $form.Size = New-Object System.Drawing.Size($sw, $sh)
    $form.TopMost = $true
    $form.ShowInTaskbar = $false

    # Enable all WinForms double-buffer flags to eliminate flicker
    $flags = [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor
              [System.Windows.Forms.ControlStyles]::UserPaint -bor
              [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer
    $form.GetType().GetMethod('SetStyle', [System.Reflection.BindingFlags]'Instance,NonPublic').Invoke($form, @($flags, $true))

    # Pre-allocate persistent back buffer (avoids per-frame allocation)
    $script:backBuf = New-Object System.Drawing.Bitmap($sw, $sh)
    $script:bg = [System.Drawing.Graphics]::FromImage($script:backBuf)
    $script:bg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality

    # Pre-create reusable drawing objects
    $bgColor = [System.Drawing.Color]::FromArgb(15, 20, 35)
    $script:bgBrush = New-Object System.Drawing.SolidBrush($bgColor)
    $script:ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(0, 180, 235), 10.0)
    $script:ringPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $script:ringPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $script:checkPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(0, 200, 120), 8.0)
    $script:checkPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $script:checkPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $script:checkPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $script:textFont = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Regular)
    $script:textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 180, 200, 220))
    $script:textFmt = New-Object System.Drawing.StringFormat
    $script:textFmt.Alignment = [System.Drawing.StringAlignment]::Center

    $cx = [float]($sw / 2); $cy = [float]($sh / 2)
    $ringRect = New-Object System.Drawing.RectangleF(($cx - 70), ($cy - 70), 140, 140)

    # State
    $script:angle = 0
    $script:doneHoldFrames = 0
    $script:fadeOpacity = 1.0

    $form.Add_Paint({
        param($s, $e)
        $g = $script:bg

        # Clear only — no separate background erase (AllPaintingInWmPaint handles this)
        $g.FillRectangle($script:bgBrush, 0, 0, $sw, $sh)

        $phase = $splashState.phase

        if ($phase -eq 'loading') {
            $g.DrawArc($script:ringPen, $ringRect, $script:angle, 120)
            $g.DrawString('Restoring workspace...', $script:textFont, $script:textBrush, $cx, ($cy + 100), $script:textFmt)

        } elseif ($phase -eq 'done' -or $phase -eq 'fade') {
            $g.DrawArc($script:ringPen, $ringRect, 0, 360)
            $g.DrawLine($script:checkPen, ($cx - 30), $cy, ($cx - 5), ($cy + 28))
            $g.DrawLine($script:checkPen, ($cx - 5), ($cy + 28), ($cx + 35), ($cy - 25))
            $g.DrawString('Done', $script:textFont, $script:textBrush, $cx, ($cy + 100), $script:textFmt)
        }

        # Single
        $e.Graphics.DrawImageUnscaled($script:backBuf, 0, 0)
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 33  # ~30fps for smoother animation
    $timer.Add_Tick({
        $phase = $splashState.phase

        if ($phase -eq 'loading') {
            $script:angle = ($script:angle + 6) % 360
            $form.Invalidate()
        }
        elseif ($phase -eq 'done') {
            $script:doneHoldFrames++
            if ($script:doneHoldFrames -eq 1) { $form.Invalidate() }  # Draw once, no repeated invalidation
            if ($script:doneHoldFrames -ge 24) { $splashState.phase = 'fade' }
        }
        elseif ($phase -eq 'fade') {
            $script:fadeOpacity -= 0.05
            if ($script:fadeOpacity -le 0) {
                $timer.Stop()
                $form.Close()
                return
            }
            $form.Opacity = [Math]::Max(0, $script:fadeOpacity)
        }
        elseif ($phase -eq 'close') {
            $timer.Stop()
            $form.Close()
        }
    })

    $form.Add_Shown({ $timer.Start(); $splashState.ready = $true })
    $form.Add_FormClosed({
        # Cleanup persistent resources
        try { $script:bg.Dispose() } catch { }
        try { $script:backBuf.Dispose() } catch { }
        try { $script:ringPen.Dispose() } catch { }
        try { $script:checkPen.Dispose() } catch { }
        try { $script:textFont.Dispose() } catch { }
        try { $script:textBrush.Dispose() } catch { }
        try { $script:textFmt.Dispose() } catch { }
        try { $script:bgBrush.Dispose() } catch { }
    })
    [System.Windows.Forms.Application]::Run($form)
})

$splashHandle = $splashPS.BeginInvoke()

# Wait for splash to be fully rendered before launching windows behind it
$waitMs = 0
while (-not $splashState.ready -and $waitMs -lt 2000) {
    Start-Sleep -Milliseconds 50
    $waitMs += 50
}

# Apply configured restore delay (gives splash time to fully cover screen)
$restoreDelay = $config.restoreDelayMs
if ($restoreDelay -and $restoreDelay -gt 0) {
    Start-Sleep -Milliseconds $restoreDelay
}

# ══════════════════════════════════════════════════════════════
# RESTORE: Launch windows with inline positioning
# ══════════════════════════════════════════════════════════════

# Detect if monitor layout changed — if so, remap window positions
$currentLayout = Get-MonitorLayout
$needsRemap = $false
if ($session.monitorFingerprint -and $session.monitorFingerprint -ne $currentLayout.fingerprint) {
    $needsRemap = $true
    if (-not $Silent) {
        Write-Host "Monitor layout changed — remapping window positions" -ForegroundColor Yellow
        Write-Host "  Saved:   $($session.monitorFingerprint)" -ForegroundColor DarkGray
        Write-Host "  Current: $($currentLayout.fingerprint)" -ForegroundColor DarkGray
    }
}

$windowMeta = @()
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
        if ($tab.sessionName -and $tab.sessionName -in $excludeNames) {
            $skippedTabs++
            if (-not $Silent) { Write-Host "  Skipping excluded: $($tab.sessionName)" -ForegroundColor DarkGray }
            continue
        }
        $tabsToRestore += $tab
    }

    if ($tabsToRestore.Count -eq 0) { continue }

    # Skip windows with only generic shell tabs (no session, no meaningful content)
    $hasMeaningful = $false
    foreach ($t in $tabsToRestore) {
        if ($t.sessionId -or $t.sessionName -or $t.type -eq 'ssh' -or $t.type -eq 'claude') {
            $hasMeaningful = $true; break
        }
    }
    if (-not $hasMeaningful) {
        if (-not $Silent) { Write-Host "  Skipping window $winIdx (only generic shell tabs)" -ForegroundColor DarkGray }
        continue
    }

    if (-not $Silent) {
        Write-Host "`nWindow $winIdx ($($tabsToRestore.Count) tab(s)):" -ForegroundColor White
    }

    # Snapshot current HWNDs before launching
    $beforeHwnds = Get-AllWtHwnds

    # First tab — creates the window with a named ID
    $first = Get-TabCommand $tabsToRestore[0]
    $args = Get-WtLaunchArgs $windowId $first $false
    Start-Process "wt.exe" -ArgumentList $args
    if (-not $Silent) { Write-Host "  Tab 1: [$($tabsToRestore[0].type)] $($first.cwd)" -ForegroundColor Gray }

    # Detect the new window and position it immediately
    $newHwnd = Wait-NewWindow $beforeHwnds 2500
    if ($newHwnd) {
        # Determine position: remap if layout changed, else use raw coords
        if ($needsRemap -and $win.relativePosition) {
            $p = Get-RemappedPosition $win $session.monitors $currentLayout.monitors
            if (-not $Silent) { Write-Host "  Remapped from monitor $($win.monitorIndex)" -ForegroundColor DarkYellow }
        } else {
            $p = @{ left = $win.position.left; top = $win.position.top; width = $win.position.width; height = $win.position.height }
        }
        # Always clamp to visible screen bounds (safety net for v1 saves too)
        $p = Clamp-ToScreen $p
        [WinApi]::MoveWindow($newHwnd, $p.left, $p.top, $p.width, $p.height)
        if (-not $Silent) {
            Write-Host "  Positioned: ($($p.left),$($p.top)) $($p.width)x$($p.height)" -ForegroundColor DarkGreen
        }
    } else {
        if (-not $Silent) { Write-Host "  Could not detect window for positioning" -ForegroundColor Yellow }
    }

    # Remaining tabs — target the named window
    for ($i = 1; $i -lt $tabsToRestore.Count; $i++) {
        $t = Get-TabCommand $tabsToRestore[$i]
        if (-not $t) { continue }

        $args = Get-WtLaunchArgs $windowId $t $true
        Start-Process "wt.exe" -ArgumentList $args
        if (-not $Silent) { Write-Host "  Tab $($i+1): [$($tabsToRestore[$i].type)] $($t.cwd)" -ForegroundColor Gray }
        Start-Sleep -Milliseconds 300
    }

    $windowMeta += @{ windowId = $windowId; title = $win.title }

    # Longer gap between windows to prevent HWND race conditions
    Start-Sleep -Milliseconds 800
}

# ══════════════════════════════════════════════════════════════
# SPLASH: Show "DONE" and fade out
# ══════════════════════════════════════════════════════════════

$splashState.phase = 'done'

# Wait for splash to finish its done+fade animation (~2s)
$splashWait = 0
while (-not $splashHandle.IsCompleted -and $splashWait -lt 3000) {
    Start-Sleep -Milliseconds 100
    $splashWait += 100
}

# Cleanup splash runspace
try {
    if ($splashHandle.IsCompleted) { $splashPS.EndInvoke($splashHandle) }
    $splashPS.Dispose()
    $splashRunspace.Close()
    $splashRunspace.Dispose()
} catch { }

# ── Summary ──

$totalTabs = ($session.windows | ForEach-Object { $_.tabs.Count } | Measure-Object -Sum).Sum
$restoredTabs = $totalTabs - $skippedTabs
$msg = "Restored $restoredTabs tab(s) across $($windowMeta.Count) window(s)"
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
