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
    [switch]$Silent
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$root\lib\WinApi.ps1"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
            return "$prefix $dirArg powershell.exe -NoExit -Command `"$($tabInfo.cmd)`""
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
    Write-Host "Restoring workspace from $($session.savedAt)..." -ForegroundColor Cyan
    Write-Host "  $($session.windows.Count) window(s)" -ForegroundColor DarkGray
}

# ══════════════════════════════════════════════════════════════
# SPLASH SCREEN — runs on a separate STA runspace
# ══════════════════════════════════════════════════════════════

$splashState = [hashtable]::Synchronized(@{ phase = 'loading'; angle = 0 })

$splashRunspace = [runspacefactory]::CreateRunspace()
$splashRunspace.ApartmentState = 'STA'
$splashRunspace.ThreadOptions = 'ReuseThread'
$splashRunspace.Open()
$splashRunspace.SessionStateProxy.SetVariable('splashState', $splashState)

$splashPS = [powershell]::Create()
$splashPS.Runspace = $splashRunspace
[void]$splashPS.AddScript({
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Cryosave'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object System.Drawing.Point(0, 0)
    $form.Size = New-Object System.Drawing.Size($screen.Width, $screen.Height)
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(15, 20, 35)
    $form.DoubleBuffered = $true
    $form.ShowInTaskbar = $false

    # State
    $script:angle = 0
    $script:doneHoldFrames = 0
    $script:fadeOpacity = 1.0

    # Paint handler
    $form.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

        $cx = $form.Width / 2
        $cy = $form.Height / 2

        $phase = $splashState.phase

        if ($phase -eq 'loading') {
            # ── Draw large snowflake ──
            $iceBlue = [System.Drawing.Color]::FromArgb(0, 180, 235)
            $pen = New-Object System.Drawing.Pen($iceBlue, 3.0)
            $branchPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(100, 210, 255), 2.0)
            $r = 60

            for ($i = 0; $i -lt 6; $i++) {
                $a = [Math]::PI / 3 * $i
                $x2 = $cx + [Math]::Cos($a) * $r
                $y2 = $cy + [Math]::Sin($a) * $r
                $g.DrawLine($pen, [float]$cx, [float]$cy, [float]$x2, [float]$y2)

                # Main branches
                $bx = $cx + [Math]::Cos($a) * ($r * 0.55)
                $by = $cy + [Math]::Sin($a) * ($r * 0.55)
                $bl = $r * 0.35
                $g.DrawLine($branchPen, [float]$bx, [float]$by,
                    [float]($bx + [Math]::Cos($a + 0.7) * $bl), [float]($by + [Math]::Sin($a + 0.7) * $bl))
                $g.DrawLine($branchPen, [float]$bx, [float]$by,
                    [float]($bx + [Math]::Cos($a - 0.7) * $bl), [float]($by + [Math]::Sin($a - 0.7) * $bl))

                # Outer branches
                $ox = $cx + [Math]::Cos($a) * ($r * 0.8)
                $oy = $cy + [Math]::Sin($a) * ($r * 0.8)
                $ol = $r * 0.25
                $g.DrawLine($branchPen, [float]$ox, [float]$oy,
                    [float]($ox + [Math]::Cos($a + 0.6) * $ol), [float]($oy + [Math]::Sin($a + 0.6) * $ol))
                $g.DrawLine($branchPen, [float]$ox, [float]$oy,
                    [float]($ox + [Math]::Cos($a - 0.6) * $ol), [float]($oy + [Math]::Sin($a - 0.6) * $ol))
            }
            $pen.Dispose()
            $branchPen.Dispose()

            # ── Spinning donut ring ──
            $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(0, 180, 235), 5.0)
            $ringPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $ringPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $ringRect = New-Object System.Drawing.RectangleF(($cx - 90), ($cy - 90), 180, 180)
            $g.DrawArc($ringPen, $ringRect, $script:angle, 120)
            $ringPen.Dispose()

            # ── Faint trail arc ──
            $trailPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(40, 0, 180, 235), 3.0)
            $g.DrawArc($trailPen, $ringRect, ($script:angle + 120), 60)
            $trailPen.Dispose()

            # ── "Restoring..." text below ──
            $font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Regular)
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 180, 200, 220))
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = [System.Drawing.StringAlignment]::Center
            $g.DrawString('Restoring workspace...', $font, $brush, [float]$cx, [float]($cy + 120), $sf)
            $font.Dispose(); $brush.Dispose(); $sf.Dispose()

        } elseif ($phase -eq 'done' -or $phase -eq 'fade') {
            # ── "DONE" text with yellow fill + black outline ──
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $fontFamily = New-Object System.Drawing.FontFamily('Segoe UI')
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $textRect = New-Object System.Drawing.RectangleF(($cx - 300), ($cy - 80), 600, 160)
            $path.AddString('DONE', $fontFamily, [int][System.Drawing.FontStyle]::Bold, 110, $textRect, $sf)

            # Black outline
            $outlinePen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 6)
            $outlinePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
            $g.DrawPath($outlinePen, $path)

            # Yellow fill
            $fillBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Gold)
            $g.FillPath($fillBrush, $path)

            $outlinePen.Dispose(); $fillBrush.Dispose(); $path.Dispose()
            $fontFamily.Dispose(); $sf.Dispose()
        }
    })

    # Animation timer — 50ms = 20fps
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 50
    $timer.Add_Tick({
        $phase = $splashState.phase

        if ($phase -eq 'loading') {
            $script:angle = ($script:angle + 8) % 360
            $form.Invalidate()
        }
        elseif ($phase -eq 'done') {
            $script:doneHoldFrames++
            $form.Invalidate()
            # Hold DONE for ~800ms (16 frames at 50ms)
            if ($script:doneHoldFrames -ge 16) {
                $splashState.phase = 'fade'
            }
        }
        elseif ($phase -eq 'fade') {
            $script:fadeOpacity -= 0.07
            if ($script:fadeOpacity -le 0) {
                $timer.Stop()
                $form.Close()
                return
            }
            $form.Opacity = [Math]::Max(0, $script:fadeOpacity)
            $form.Invalidate()
        }
        elseif ($phase -eq 'close') {
            $timer.Stop()
            $form.Close()
        }
    })

    $form.Add_Shown({ $timer.Start() })
    [System.Windows.Forms.Application]::Run($form)
})

$splashHandle = $splashPS.BeginInvoke()

# Brief pause to let splash render first frame
Start-Sleep -Milliseconds 300

# ══════════════════════════════════════════════════════════════
# RESTORE: Launch windows with inline positioning
# ══════════════════════════════════════════════════════════════

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
        $tabsToRestore += $tab
    }

    if ($tabsToRestore.Count -eq 0) { continue }

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
        $p = $win.position
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

    # Small gap between windows
    Start-Sleep -Milliseconds 200
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
