<#
.SYNOPSIS
    Saves all Windows Terminal windows, tabs, and Claude Code sessions to a JSON snapshot.
.DESCRIPTION
    Scans running Windows Terminal instances, detects Claude Code sessions (local and SSH),
    plain PowerShell tabs, and other processes. Saves window positions, sizes, working
    directories, and Claude session IDs for later restoration.
.PARAMETER Silent
    Suppress console output (used when invoked from the system tray).
.EXAMPLE
    .\Save-Sessions.ps1
    .\Save-Sessions.ps1 -Silent
#>
param([switch]$Silent)

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
    $_.Name -match "powershell|pwsh|cmd|bash|ssh|conhost"
}

# Also find shells that are children of OpenConsole (varies by WT version)
$openConsoles = $allProcs | Where-Object { $_.Name -eq "OpenConsole.exe" -and $_.ParentProcessId -in $wtPids }
$ocPids = $openConsoles | ForEach-Object { $_.ProcessId }
$ocShells = $allProcs | Where-Object {
    $_.ParentProcessId -in $ocPids -and $_.Name -ne "OpenConsole.exe"
}
if ($ocShells) { $shells = @($shells) + @($ocShells) }

$shellPids = $shells | ForEach-Object { $_.ProcessId }
$shellChildren = $allProcs | Where-Object { $_.ParentProcessId -in $shellPids }

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
        $claudeChild = $children | Where-Object { $_.Name -eq "node.exe" -and $_.CommandLine -match "claude" }

        if ($claudeChild) {
            $tab.type = "claude"
            $sessionFile = Join-Path $claudeSessionsDir "$($claudeChild.ProcessId).json"
            if (Test-Path $sessionFile) {
                try {
                    $raw = Get-Content $sessionFile -Raw
                    # Fix malformed JSON: some session files have }"name":... outside the object
                    if ($raw -match '^\{.*?\}') {
                        $jsonPart = $Matches[0]
                        # Extract any trailing name field
                        $trailingName = $null
                        if ($raw -match '\}"name":"([^"]+)"') { $trailingName = $Matches[1] }
                        $s = $jsonPart | ConvertFrom-Json
                        $tab["sessionId"] = $s.sessionId
                        $tab.cwd = $s.cwd
                        if ($s.name) { $tab["sessionName"] = $s.name }
                        elseif ($trailingName) { $tab["sessionName"] = $trailingName }
                    }
                } catch { }
            }
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

# ── Group tabs into windows ──
# WT spawns shells and OpenConsoles as direct siblings under one PID, so we can't
# trace which tab belongs to which window via process tree alone.
#
# Strategy: match tabs to windows by comparing session names / SSH commands to window
# titles. Each WT window title typically contains the Claude session name or "ssh".
# Unmatched tabs are distributed round-robin to windows with no matches.

# Filter out off-screen / hidden helper windows (position < -10000)
$visibleWindows = $windows | Where-Object { $_.Position.left -gt -10000 -and $_.Position.top -gt -10000 }

$matched = @{}  # windowIndex -> [tabs]
$unmatched = @()

foreach ($tab in $tabs) {
    $found = $false

    # Try to match by session name or command line against window title
    $matchStr = $null
    if ($tab.sessionName) { $matchStr = $tab.sessionName }
    elseif ($tab.type -eq "ssh") { $matchStr = "ssh" }

    if ($matchStr) {
        for ($wi = 0; $wi -lt $visibleWindows.Count; $wi++) {
            $title = $visibleWindows[$wi].Title
            if ($title -match [regex]::Escape($matchStr)) {
                if (-not $matched[$wi]) { $matched[$wi] = @() }
                $matched[$wi] += $tab
                $found = $true
                break
            }
        }
    }

    if (-not $found) { $unmatched += $tab }
}

# Distribute unmatched tabs to windows that got no tabs yet, then round-robin
$emptyWindows = @()
for ($wi = 0; $wi -lt $visibleWindows.Count; $wi++) {
    if (-not $matched[$wi]) { $emptyWindows += $wi }
}

$umi = 0
foreach ($tab in $unmatched) {
    if ($emptyWindows.Count -gt 0 -and $umi -lt $emptyWindows.Count) {
        $wi = $emptyWindows[$umi]; $umi++
    } else {
        $wi = $umi % $visibleWindows.Count; $umi++
    }
    if (-not $matched[$wi]) { $matched[$wi] = @() }
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
        if ($tab.cwd)         { $t.cwd = $tab.cwd }
        if ($tab.sessionId)   { $t.sessionId = $tab.sessionId }
        if ($tab.sessionName) { $t.sessionName = $tab.sessionName }
        if ($tab.commandLine) { $t.commandLine = $tab.commandLine }
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
$msg = "Saved $($output.windows.Count) window(s), $totalTabs tab(s) ($claudeTabs Claude, $sshTabs SSH)"

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
        $text.Item(0).AppendChild($xml.CreateTextNode("Claude Session Saver")) | Out-Null
        $text.Item(1).AppendChild($xml.CreateTextNode($msg)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(
            "Claude Session Saver").Show($toast)
    } catch { }
}
