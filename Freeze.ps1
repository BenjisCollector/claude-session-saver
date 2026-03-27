<#
.SYNOPSIS
    Freezes all Windows Terminal windows, tabs, and Claude Code sessions to a JSON snapshot.
.DESCRIPTION
    Scans running Windows Terminal instances, detects Claude Code sessions (local and SSH),
    plain PowerShell tabs, and other processes. Freezes window positions, sizes, working
    directories, and Claude session IDs for later thawing.
.PARAMETER Close
    Close all Windows Terminal windows that contain Claude Code sessions after freezing.
    Non-Claude windows are left untouched.
.PARAMETER Silent
    Suppress console output (used when invoked from the system tray).
.EXAMPLE
    .\Freeze.ps1
    .\Freeze.ps1 -Close
    .\Freeze.ps1 -Silent
#>
param(
    [switch]$Silent,
    [switch]$Close
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$root\lib\WinApi.ps1"

$config = Get-Content "$root\config.json" -Raw | ConvertFrom-Json
$savesDir = Join-Path $root "saves"
if (-not (Test-Path $savesDir)) { New-Item -ItemType Directory -Path $savesDir -Force | Out-Null }

# ── Find Windows Terminal windows ──

$wtProcs = Get-Process -Name "WindowsTerminal" -ErrorAction SilentlyContinue
if (-not $wtProcs) {
    if (-not $Silent) { Write-Host "No Windows Terminal windows found." -ForegroundColor Yellow }
    exit 0
}

$windows = @()
foreach ($wt in $wtProcs) {
    $wins = [WinApi]::GetWindows([uint32]$wt.Id)
    foreach ($w in $wins) {
        $windows += @{
            Hwnd     = $w.Handle
            WtPid    = $wt.Id
            Position = @{ left = $w.Left; top = $w.Top; width = $w.Width; height = $w.Height }
            Title    = $w.Title
            Tabs     = [System.Collections.ArrayList]::new()
        }
    }
}

if ($windows.Count -eq 0) {
    if (-not $Silent) { Write-Host "No visible terminal windows." -ForegroundColor Yellow }
    exit 0
}

# ── Build process tree ──
# Windows Terminal spawns both OpenConsole.exe and shell processes (powershell, ssh, etc.)
# as direct children. Shells may have node.exe children (Claude Code).

$allProcs = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine -ErrorAction SilentlyContinue
$wtPids = $wtProcs | ForEach-Object { $_.Id }

# Direct children of WT that are shells (not OpenConsole)
$shells = $allProcs | Where-Object {
    $_.ParentProcessId -in $wtPids -and
    $_.Name -ne "OpenConsole.exe" -and
    $_.Name -match "powershell|pwsh|cmd|bash|ssh|conhost|wsl|nu"
}

# Also find shells that are children of OpenConsole (varies by WT version)
$openConsoles = $allProcs | Where-Object { $_.Name -eq "OpenConsole.exe" -and $_.ParentProcessId -in $wtPids }
$ocPids = $openConsoles | ForEach-Object { $_.ProcessId }
$ocShells = $allProcs | Where-Object {
    $_.ParentProcessId -in $ocPids -and $_.Name -ne "OpenConsole.exe"
}
if ($ocShells) { $shells = @($shells) + @($ocShells) }

# Collect descendants up to 3 levels deep (handles nested bash > bash > node patterns)
$shellPids = $shells | ForEach-Object { $_.ProcessId }
$level1 = $allProcs | Where-Object { $_.ParentProcessId -in $shellPids }
$level1Pids = $level1 | ForEach-Object { $_.ProcessId }
$level2 = $allProcs | Where-Object { $_.ParentProcessId -in $level1Pids }
$level2Pids = $level2 | ForEach-Object { $_.ProcessId }
$level3 = $allProcs | Where-Object { $_.ParentProcessId -in $level2Pids }
$shellChildren = @($level1) + @($level2) + @($level3)

# ── Claude session files ──

$claudeSessionsDir = Join-Path $env:USERPROFILE ".claude\sessions"

# ── Classify each tab ──

$tabs = @()
foreach ($shell in $shells) {
    $tab = @{ type = "powershell"; cwd = $null; _wtPid = $shell.ParentProcessId }

    # If parent is OpenConsole, the WT PID is one level up
    if ($shell.ParentProcessId -in $ocPids) {
        $oc = $openConsoles | Where-Object { $_.ProcessId -eq $shell.ParentProcessId }
        if ($oc) { $tab._wtPid = $oc.ParentProcessId }
    }

    $name = $shell.Name.ToLower()

    if ($name -match "ssh") {
        $tab.type = "ssh"
        $tab["commandLine"] = $shell.CommandLine
    }
    elseif ($name -match "powershell|pwsh|cmd|bash") {
        $children = $shellChildren | Where-Object { $_.ParentProcessId -eq $shell.ProcessId }

        # Check for SSH child processes (e.g., cmd.exe /k ssh ...)
        $sshChildren = @($children | Where-Object { $_.Name -match "^ssh(\.exe)?$" })
        if ($sshChildren.Count -gt 0) {
            $tab.type = "ssh"
            $tab["commandLine"] = $sshChildren[0].CommandLine
        } else {

        $claudeChildren = @($children | Where-Object { $_.Name -eq "node.exe" -and $_.CommandLine -match "claude" })

        if ($claudeChildren.Count -gt 0) {
            $tab.type = "claude"
            # Use the first (primary) Claude child process
            $claudeChild = $claudeChildren[0]
            $sessionFile = Join-Path $claudeSessionsDir "$($claudeChild.ProcessId).json"
            if (Test-Path $sessionFile) {
                try {
                    $raw = Get-Content $sessionFile -Raw
                    $s = $null
                    # Try normal parse first
                    try { $s = $raw | ConvertFrom-Json } catch { }
                    if (-not $s) {
                        # Malformed JSON: find balanced first object, extract trailing fields
                        $trailingName = $null
                        if ($raw -match '\}"name":"([^"]+)"') { $trailingName = $Matches[1] }
                        $depth = 0; $end = -1
                        for ($ci = 0; $ci -lt $raw.Length; $ci++) {
                            if ($raw[$ci] -eq '{') { $depth++ }
                            elseif ($raw[$ci] -eq '}') { $depth--; if ($depth -eq 0) { $end = $ci; break } }
                        }
                        if ($end -gt 0) {
                            $s = $raw.Substring(0, $end + 1) | ConvertFrom-Json
                            if ($trailingName -and -not $s.name) { $s | Add-Member -NotePropertyName 'name' -NotePropertyValue $trailingName }
                        }
                    }
                    if ($s) {
                        $tab["sessionId"] = $s.sessionId
                        $tab.cwd = $s.cwd
                        if ($s.name) { $tab["sessionName"] = $s.name }
                    }
                } catch {
                    if (-not $Silent) { Write-Host "  Warning: Could not parse session file: $_" -ForegroundColor Yellow }
                }
            }

            # Read model and permissionMode from conversation JSONL
            if ($tab.sessionId) {
                $claudeProjectsDir = Join-Path $env:USERPROFILE ".claude\projects"
                $jsonlFile = $null
                if (Test-Path $claudeProjectsDir) {
                    $jsonlFile = Get-ChildItem -Path $claudeProjectsDir -Recurse -Filter "$($tab.sessionId).jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
                }
                if ($jsonlFile) {
                    # Derive real project CWD from JSONL parent folder name
                    # Folder names like "C--Users-buste-ShotIQ" decode to "C:\Users\buste\ShotIQ"
                    $projFolder = $jsonlFile.Directory.Name
                    $projPath = $projFolder -replace '--', ':\' -replace '-', '\'
                    if (Test-Path $projPath) { $tab.cwd = $projPath }

                    # Read last model and permissionMode from the JSONL (tail approach for speed)
                    try {
                        $tailLines = Get-Content $jsonlFile.FullName -Tail 50 -ErrorAction SilentlyContinue
                        $tailText = $tailLines -join "`n"
                        $modelMatches = [regex]::Matches($tailText, '"model":"([^"]+)"')
                        if ($modelMatches.Count -gt 0) {
                            $tab["model"] = $modelMatches[$modelMatches.Count - 1].Groups[1].Value
                        }
                        $permMatches = [regex]::Matches($tailText, '"permissionMode":"([^"]+)"')
                        if ($permMatches.Count -gt 0) {
                            $tab["permissionMode"] = $permMatches[$permMatches.Count - 1].Groups[1].Value
                        }
                    } catch { }
                }
            }
        }
        } # end SSH else

        # CWD fallback chain: JSONL project path > node.exe PEB > shell PEB
        if ((-not $tab.cwd -or $tab.cwd -eq $env:USERPROFILE) -and $claudeChildren.Count -gt 0) {
            $cwd = [WinApi]::GetProcessCwd($claudeChildren[0].ProcessId)
            if ($cwd -and $cwd -ne $env:USERPROFILE) { $tab.cwd = $cwd }
        }
        if (-not $tab.cwd) {
            $cwd = [WinApi]::GetProcessCwd($shell.ProcessId)
            if ($cwd) { $tab.cwd = $cwd }
        }
    }
    else {
        $tab.type = "other"
        $tab["commandLine"] = $shell.CommandLine
        $cwd = [WinApi]::GetProcessCwd($shell.ProcessId)
        if ($cwd) { $tab.cwd = $cwd }
    }

    $tabs += $tab
}

# ── Group tabs into windows using UI Automation ──
# The old approach matched only against window titles, which show only the ACTIVE tab.
# UIA lets us enumerate ALL tab names per window — far more reliable.

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Get-WtUiaTabs([IntPtr]$hwnd) {
    try {
        $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::TabItem
        )
        $items = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        $names = @()
        foreach ($item in $items) { $names += $item.Current.Name }
        return $names
    } catch { return @() }
}

function Get-TabMatchScore($tab, [string]$uiaName) {
    # Use .Contains() everywhere — -like and -match have wildcard/regex pitfalls
    # that cause phantom matches with special chars in SSH commands, paths, etc.
    $u = $uiaName.ToLower()
    $homeName = (Split-Path $env:USERPROFILE -Leaf).ToLower()

    # Session name match (strongest — Claude Code sets the tab title to session name)
    if ($tab.sessionName) {
        $sn = $tab.sessionName.ToLower()
        if ($u.Contains($sn) -or $sn.Contains($u)) { return 100 }
    }

    # SSH command match — full command or hostname in UIA tab name
    if ($tab.type -eq "ssh" -and $tab.commandLine) {
        $cmdLower = $tab.commandLine.ToLower()
        if ($u.Contains($cmdLower) -or $cmdLower.Contains($u)) { return 90 }
        if ($cmdLower -match '@([\w.-]+)') {
            $sshHost = $Matches[1].ToLower()
            if ($u.Contains($sshHost)) { return 70 }
        }
        if ($u.Contains("ssh")) { return 30 }
    }

    # CWD folder name match (WT often shows folder in tab title)
    # Exclude home folder name — too generic, matches everything
    if ($tab.cwd) {
        $folder = (Split-Path $tab.cwd -Leaf).ToLower()
        if ($folder.Length -gt 1 -and $folder -ne $homeName -and $u.Contains($folder)) { return 50 }
    }

    # Generic type match (weak fallback)
    if ($tab.type -eq "claude" -and $u.Contains("claude")) { return 10 }
    if ($tab.type -eq "powershell" -and ($u.Contains("powershell") -or $u.Contains("pwsh"))) { return 5 }

    return 0
}

# Filter out off-screen / hidden helper windows (position < -10000)
$visibleWindows = $windows | Where-Object { $_.Position.left -gt -10000 -and $_.Position.top -gt -10000 }

# Enumerate UIA tab names per window
$windowUiaTabs = @{}
$uiaAvailable = $false
for ($wi = 0; $wi -lt $visibleWindows.Count; $wi++) {
    $windowUiaTabs[$wi] = @(Get-WtUiaTabs $visibleWindows[$wi].Hwnd)
    if ($windowUiaTabs[$wi].Count -gt 0) { $uiaAvailable = $true }
    if (-not $Silent) {
        Write-Host "  Window $($wi+1) UIA tabs ($($windowUiaTabs[$wi].Count)): $($windowUiaTabs[$wi] -join ' | ')" -ForegroundColor DarkGray
    }
}

$matched = @{}  # windowIndex -> [tabs]
$claimed = @{}  # tabIndex -> $true (prevents double-assignment)

if ($uiaAvailable) {
    # Global score-sorted matching: collect ALL (window, uia_tab, detected_tab, score)
    # tuples, then assign greedily from highest score first. This prevents a weak match
    # (e.g., generic "claude" score=10) from stealing a tab that has a strong match
    # (e.g., folder name "shotiq" score=50) to a different window.
    for ($wi = 0; $wi -lt $visibleWindows.Count; $wi++) { $matched[$wi] = @() }

    $candidates = @()
    for ($wi = 0; $wi -lt $visibleWindows.Count; $wi++) {
        for ($ui = 0; $ui -lt $windowUiaTabs[$wi].Count; $ui++) {
            $uiaName = $windowUiaTabs[$wi][$ui]
            for ($ti = 0; $ti -lt $tabs.Count; $ti++) {
                $score = Get-TabMatchScore $tabs[$ti] $uiaName
                if ($score -gt 0) {
                    $candidates += [pscustomobject]@{ wi=$wi; ui=$ui; ti=$ti; score=$score; uia=$uiaName }
                }
            }
        }
    }

    # Sort highest score first — strongest matches get priority
    $candidates = $candidates | Sort-Object -Property score -Descending
    $uiaClaimed = @{}  # "wi:ui" -> true (each UIA slot takes one tab)

    foreach ($c in $candidates) {
        $uiaKey = "$($c.wi):$($c.ui)"
        if ($claimed[$c.ti] -or $uiaClaimed[$uiaKey]) { continue }
        $matched[$c.wi] += $tabs[$c.ti]
        $claimed[$c.ti] = $true
        $uiaClaimed[$uiaKey] = $true
        if (-not $Silent) {
            Write-Host "    Matched tab $($c.ti) ($($tabs[$c.ti].type)) -> Window $($c.wi+1) UIA '$($c.uia)' (score=$($c.score))" -ForegroundColor DarkCyan
        }
    }
} else {
    # Fallback: match by window title (old approach — only sees active tab)
    if (-not $Silent) { Write-Host "  UIA unavailable, falling back to title matching" -ForegroundColor Yellow }
    for ($wi = 0; $wi -lt $visibleWindows.Count; $wi++) { $matched[$wi] = @() }
    for ($ti = 0; $ti -lt $tabs.Count; $ti++) {
        $tab = $tabs[$ti]
        $matchStr = $null
        if ($tab.sessionName) { $matchStr = $tab.sessionName }
        elseif ($tab.type -eq "ssh") { $matchStr = "ssh" }

        if ($matchStr) {
            for ($wi = 0; $wi -lt $visibleWindows.Count; $wi++) {
                if ($visibleWindows[$wi].Title -match [regex]::Escape($matchStr)) {
                    $matched[$wi] += $tab
                    $claimed[$ti] = $true
                    break
                }
            }
        }
    }
}

# Distribute unclaimed tabs to windows that still need tabs, then round-robin
$unmatched = @()
for ($ti = 0; $ti -lt $tabs.Count; $ti++) {
    if (-not $claimed[$ti]) { $unmatched += $tabs[$ti] }
}

$emptyWindows = @()
for ($wi = 0; $wi -lt $visibleWindows.Count; $wi++) {
    if ($matched[$wi].Count -eq 0) { $emptyWindows += $wi }
}

$umi = 0
foreach ($tab in $unmatched) {
    if ($emptyWindows.Count -gt 0 -and $umi -lt $emptyWindows.Count) {
        $wi = $emptyWindows[$umi]; $umi++
    } else {
        $wi = $umi % $visibleWindows.Count; $umi++
    }
    $matched[$wi] += $tab
}

# Apply matches
for ($wi = 0; $wi -lt $visibleWindows.Count; $wi++) {
    if ($matched[$wi]) {
        foreach ($t in $matched[$wi]) { $visibleWindows[$wi].Tabs.Add($t) | Out-Null }
    }
}

# Use visible windows only for output (drop hidden/helper windows)
$windows = $visibleWindows

# ── Build output ──

$output = @{
    savedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    windows = @()
}

foreach ($win in $windows) {
    $w = @{ position = $win.Position; title = $win.Title; tabs = @() }
    foreach ($tab in $win.Tabs) {
        $t = @{ type = $tab.type }
        if ($tab.cwd)            { $t.cwd = $tab.cwd }
        if ($tab.sessionId)      { $t.sessionId = $tab.sessionId }
        if ($tab.sessionName)    { $t.sessionName = $tab.sessionName }
        if ($tab.model)          { $t.model = $tab.model }
        if ($tab.permissionMode) { $t.permissionMode = $tab.permissionMode }
        if ($tab.commandLine)    { $t.commandLine = $tab.commandLine }
        $w.tabs += $t
    }
    $output.windows += $w
}

# ── Write files ──

$ts = (Get-Date).ToString("yyyy-MM-ddTHHmmss")
$savePath = Join-Path $savesDir "$ts.json"
$latestPath = Join-Path $savesDir "latest.json"

$json = $output | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($savePath, $json, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($latestPath, $json, [System.Text.Encoding]::UTF8)

# ── Prune old saves ──

$saves = Get-ChildItem -Path $savesDir -Filter "20*.json" | Sort-Object Name -Descending
$max = $config.maxSaves
if (-not $max) { $max = 10 }
if ($saves.Count -gt $max) {
    $saves | Select-Object -Skip $max | ForEach-Object { Remove-Item $_.FullName -Force }
}

# ── Summary ──

$totalTabs = ($output.windows | ForEach-Object { $_.tabs.Count } | Measure-Object -Sum).Sum
$claudeTabs = ($output.windows | ForEach-Object { $_.tabs | Where-Object { $_.type -eq "claude" } } | Measure-Object).Count
$sshTabs = ($output.windows | ForEach-Object { $_.tabs | Where-Object { $_.type -eq "ssh" } } | Measure-Object).Count
$msg = "Frozen $($output.windows.Count) window(s), $totalTabs tab(s) ($claudeTabs Claude, $sshTabs SSH)"

if (-not $Silent) {
    Write-Host $msg -ForegroundColor Green
    Write-Host "File: $savePath" -ForegroundColor DarkGray
}

# ── Toast notification ──

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

# ── Close Claude windows if requested ──

if ($Close -and $claudeTabs -gt 0) {
    # Find which WT PIDs had Claude tabs
    $claudeWtPids = @()
    foreach ($win in $windows) {
        $hasClaude = $win.Tabs | Where-Object { $_.type -eq "claude" }
        if ($hasClaude) { $claudeWtPids += $win.WtPid }
    }
    $claudeWtPids = $claudeWtPids | Select-Object -Unique

    # Force-kill WT processes that had Claude sessions
    # WM_CLOSE doesn't work (WT shows confirmation dialog)
    # Stop-Process can fail silently on UWP/MSIX WT on Windows 11
    $closed = 0
    foreach ($pid in $claudeWtPids) {
        # Try taskkill first (more reliable for UWP apps), then Stop-Process as fallback
        $result = & taskkill /F /PID $pid /T 2>&1
        if ($LASTEXITCODE -ne 0) {
            Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
        }
        $closed++
    }

    # Fallback: if WT is still running, kill by name
    Start-Sleep -Milliseconds 300
    $stillRunning = Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue
    if ($stillRunning) {
        & taskkill /F /IM WindowsTerminal.exe /T 2>&1 | Out-Null
    }

    if (-not $Silent) {
        Write-Host "Closed $closed Windows Terminal process(es) containing Claude sessions." -ForegroundColor Yellow
    }
}
