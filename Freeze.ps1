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
    [switch]$Close,
    [string]$Workspace
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$root\lib\WinApi.ps1"

# DPI awareness — must be called before any Screen or GetWindowRect usage
try {
    if (-not ([System.Management.Automation.PSTypeName]'DpiHelper').Type) {
        Add-Type -IgnoreWarnings -TypeDefinition 'using System.Runtime.InteropServices; public class DpiHelper { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }' -ErrorAction SilentlyContinue
    }
    [DpiHelper]::SetProcessDPIAware() | Out-Null
} catch { }

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

# ── Monitor layout detection ──

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

function Get-WindowMonitorInfo($winLeft, $winTop, $winWidth, $winHeight, $monitors) {
    $centerX = $winLeft + $winWidth / 2
    $centerY = $winTop + $winHeight / 2
    $monIdx = 0
    foreach ($m in $monitors) {
        if ($centerX -ge $m.left -and $centerX -lt ($m.left + $m.width) -and
            $centerY -ge $m.top  -and $centerY -lt ($m.top + $m.height)) {
            $monIdx = $m.index; break
        }
    }
    $ownerMon = $monitors | Where-Object { $_.index -eq $monIdx }
    if (-not $ownerMon) { $ownerMon = $monitors[0] }
    $relPos = @{
        leftPct   = [Math]::Round(($winLeft - $ownerMon.left) / $ownerMon.width, 4)
        topPct    = [Math]::Round(($winTop - $ownerMon.top) / $ownerMon.height, 4)
        widthPct  = [Math]::Round($winWidth / $ownerMon.width, 4)
        heightPct = [Math]::Round($winHeight / $ownerMon.height, 4)
    }
    return @{ monitorIndex = $monIdx; relativePosition = $relPos }
}

$monitorLayout = Get-MonitorLayout

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

# Sort shells by PID for deterministic tab ordering (CIM returns in undefined order)
$shells = $shells | Sort-Object -Property ProcessId

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

            # Override sessionName from shell's --name arg if present
            # (session file name can be wrong when --continue resumed a different session)
            if ($shell.CommandLine -match "--name\s+'([^']+)'") {
                $tab["sessionName"] = $Matches[1]
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
        # Fallback: shell's CommandLine contains "claude" but no node.exe child (idle/exited session)
        elseif ($tab.type -eq "powershell" -and $shell.CommandLine -match "claude") {
            $tab.type = "claude"
            # Try to extract --resume sessionId from the shell's launch command
            if ($shell.CommandLine -match '--resume\s+([0-9a-f-]{36})') {
                $resumeId = $Matches[1]
                $tab["sessionId"] = $resumeId
                # Find the JSONL to get sessionName
                $claudeProjectsDir = Join-Path $env:USERPROFILE ".claude\projects"
                if (Test-Path $claudeProjectsDir) {
                    $jsonlFile = Get-ChildItem -Path $claudeProjectsDir -Recurse -Filter "$resumeId.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($jsonlFile) {
                        $projFolder = $jsonlFile.Directory.Name
                        $projPath = $projFolder -replace '--', ':\' -replace '-', '\'
                        if (Test-Path $projPath) { $tab.cwd = $projPath }
                    }
                }
            }
            elseif ($shell.CommandLine -match "--name\s+'([^']+)'") {
                $tab["sessionName"] = $Matches[1]
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

# ── Load exclude names for window-level exclusion later ──
$excludeNames = @()
if ($config.excludeSessionNames) { $excludeNames = @($config.excludeSessionNames) }

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

    # Claude with non-home CWD (moderate — project-specific but no folder name match)
    if ($tab.type -eq "claude" -and $tab.cwd -and $tab.cwd -ne $env:USERPROFILE) {
        if ($u.Contains("claude")) { return 15 }
    }

    # Generic type match (weak fallback)
    if ($tab.type -eq "claude" -and $u.Contains("claude")) { return 10 }
    if ($tab.type -eq "powershell" -and ($u.Contains("powershell") -or $u.Contains("pwsh"))) { return 5 }

    return 0
}

# Filter out off-screen / hidden helper windows (position < -10000)
# Sort by HWND for deterministic window ordering (EnumWindows order is undefined)
$visibleWindows = $windows | Where-Object { $_.Position.left -gt -10000 -and $_.Position.top -gt -10000 } | Sort-Object -Property { $_.Hwnd.ToInt64() }

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

    # Sort highest score first with stable tiebreakers (PowerShell Sort-Object is unstable)
    $candidates = $candidates | Sort-Object -Property @(
        @{ Expression = { $_.score }; Descending = $true }
        @{ Expression = { $_.wi }; Descending = $false }
        @{ Expression = { $_.ui }; Descending = $false }
        @{ Expression = { $_.ti }; Descending = $false }
    )
    $uiaClaimed = @{}  # "wi:ui" -> true (each UIA slot takes one tab)

    # Process-tree validation: when multiple WT processes exist, tabs can only match
    # windows owned by their parent WT process (ground-truth from process tree)
    $multiWt = (($wtPids | Select-Object -Unique).Count -gt 1)

    foreach ($c in $candidates) {
        $uiaKey = "$($c.wi):$($c.ui)"
        if ($claimed[$c.ti] -or $uiaClaimed[$uiaKey]) { continue }
        # If multiple WT processes, enforce process-tree ownership
        if ($multiWt -and $tabs[$c.ti]._wtPid -ne $visibleWindows[$c.wi].WtPid) { continue }
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

# Deterministic distribution: assign to window with fewest tabs, lowest index as tiebreaker
foreach ($tab in $unmatched) {
    $bestWi = 0; $bestCount = [int]::MaxValue
    for ($wi = 0; $wi -lt $visibleWindows.Count; $wi++) {
        if ($matched[$wi].Count -lt $bestCount) {
            $bestCount = $matched[$wi].Count; $bestWi = $wi
        }
    }
    $matched[$bestWi] += $tab
    if (-not $Silent) {
        Write-Host "    Unmatched tab ($($tab.type)) -> Window $($bestWi+1) (fewest tabs=$bestCount)" -ForegroundColor DarkYellow
    }
}

# Apply matches
for ($wi = 0; $wi -lt $visibleWindows.Count; $wi++) {
    if ($matched[$wi]) {
        foreach ($t in $matched[$wi]) { $visibleWindows[$wi].Tabs.Add($t) | Out-Null }
    }
}

# Use visible windows only for output (drop hidden/helper windows)
$windows = $visibleWindows

# ── Post-matching exclusion: remove excluded tabs and their windows ──
if ($excludeNames.Count -gt 0) {
    $beforeCount = $windows.Count

    # Step 1: Remove excluded tabs from all windows
    foreach ($win in $windows) {
        $cleanTabs = [System.Collections.ArrayList]::new()
        foreach ($t in $win.Tabs) {
            $excluded = $false
            if ($t.sessionName) {
                foreach ($exName in $excludeNames) {
                    if ($t.sessionName -eq $exName) { $excluded = $true; break }
                }
            }
            if (-not $excluded) { $cleanTabs.Add($t) | Out-Null }
        }
        $win.Tabs = $cleanTabs
    }

    # Step 2: Drop windows that have UIA tabs matching excluded names
    # (this catches the actual window even when the tab wasn't matched to it)
    $windows = @($windows | Where-Object {
        $dominated = $false
        for ($wi = 0; $wi -lt $visibleWindows.Count; $wi++) {
            if ($visibleWindows[$wi].Hwnd -eq $_.Hwnd) {
                foreach ($uia in $windowUiaTabs[$wi]) {
                    foreach ($exName in $excludeNames) {
                        if ($uia -and $uia.ToLower().Contains($exName.ToLower())) { $dominated = $true }
                    }
                }
                break
            }
        }
        # Also check window title
        if ($_.Title) {
            foreach ($exName in $excludeNames) {
                if ($_.Title.ToLower().Contains($exName.ToLower())) { $dominated = $true }
            }
        }
        -not $dominated
    })

    $dropped = $beforeCount - $windows.Count
    if (-not $Silent) {
        $removedTabs = $beforeCount * 0  # just need a number
        Write-Host "  Exclusion: removed tabs/windows matching [$($excludeNames -join ', ')]" -ForegroundColor DarkGray
    }
}

# ── Build output ──

$output = @{
    formatVersion      = 2
    savedAt            = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    workspace          = if ($Workspace) { $Workspace } else { $null }
    monitors           = $monitorLayout.monitors
    monitorFingerprint = $monitorLayout.fingerprint
    windows            = @()
}

foreach ($win in $windows) {
    if ($win.Tabs.Count -eq 0) { continue }
    $p = $win.Position
    $monInfo = Get-WindowMonitorInfo $p.left $p.top $p.width $p.height $monitorLayout.monitors
    $w = @{
        position         = $p
        monitorIndex     = $monInfo.monitorIndex
        relativePosition = $monInfo.relativePosition
        title            = $win.Title
        tabs             = @()
    }
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

# Write workspace file if -Workspace specified
if ($Workspace) {
    $wsDir = Join-Path $savesDir "workspaces"
    if (-not (Test-Path $wsDir)) { New-Item -ItemType Directory -Path $wsDir -Force | Out-Null }
    $safeName = $Workspace -replace '[\\/:*?"<>|]', '-'
    $wsPath = Join-Path $wsDir "$safeName.json"
    [System.IO.File]::WriteAllText($wsPath, $json, [System.Text.Encoding]::UTF8)
    if (-not $Silent) { Write-Host "Workspace '$safeName' saved" -ForegroundColor Cyan }
}

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
