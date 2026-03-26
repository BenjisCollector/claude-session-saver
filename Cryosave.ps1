<#
.SYNOPSIS
    System tray application for Cryosave.
.DESCRIPTION
    Runs silently in the notification area (system tray).
    Features:
    - Right-click menu: Freeze, Thaw, List Saves, Open Folder, Settings
    - Double-click: quick freeze
    - Auto-freeze every N minutes (configurable, default 5)
    - Global hotkey: Ctrl+Shift+S to freeze (optional)
#>

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Single-instance guard ──

$script:mutex = New-Object System.Threading.Mutex($false, 'CryosaveTray')
if (-not $script:mutex.WaitOne(0)) {
    exit 0
}

# ── Load config ──

$configPath = Join-Path $root 'config.json'
$config = @{ maxSaves = 10; restoreDelayMs = 1500; enableToastNotifications = $true; autoSaveMinutes = 5 }
if (Test-Path $configPath) {
    try { $config = Get-Content $configPath -Raw | ConvertFrom-Json } catch { }
}

# ── Create tray icon ──

$icon = [System.Drawing.SystemIcons]::Application
$customIconPath = Join-Path $root 'assets\icon.ico'
if (Test-Path $customIconPath) {
    try { $icon = New-Object System.Drawing.Icon($customIconPath) } catch { }
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icon
$tray.Text = 'Cryosave'
$tray.Visible = $true

# ── Save helper ──

function Invoke-Save {
    try {
        $saveScript = Join-Path $root 'Freeze.ps1'
        # Fire-and-forget — don't block the UI thread
        Start-Process powershell.exe -ArgumentList @(
            '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', $saveScript, '-Silent'
        ) -WindowStyle Hidden
    } catch {
        $tray.ShowBalloonTip(3000, 'Error', "Freeze failed: $_", [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

# ── Context menu ──

$menu = New-Object System.Windows.Forms.ContextMenuStrip

# Save
$saveItem = New-Object System.Windows.Forms.ToolStripMenuItem('Freeze Workspace')
$saveItem.Font = New-Object System.Drawing.Font($saveItem.Font, [System.Drawing.FontStyle]::Bold)
$saveItem.ShortcutKeyDisplayString = 'Dbl-click'
$saveItem.Add_Click({ Invoke-Save })
$menu.Items.Add($saveItem) | Out-Null

# Restore
$restoreItem = New-Object System.Windows.Forms.ToolStripMenuItem('Thaw Workspace')
$restoreItem.Add_Click({
    $latestPath = Join-Path $root 'saves\latest.json'
    if (-not (Test-Path $latestPath)) {
        $tray.ShowBalloonTip(3000, 'No Saves', 'No frozen workspace found. Freeze first.', [System.Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    $restoreScript = Join-Path $root 'Thaw.ps1'
    Start-Process powershell.exe -ArgumentList @(
        '-ExecutionPolicy', 'Bypass', '-File', $restoreScript
    )
})
$menu.Items.Add($restoreItem) | Out-Null

# Separator
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# Last save info
$infoItem = New-Object System.Windows.Forms.ToolStripMenuItem('Last freeze: (none)')
$infoItem.Enabled = $false
$menu.Items.Add($infoItem) | Out-Null

# Update info label when menu opens
$menu.Add_Opening({
    $latestPath = Join-Path $root 'saves\latest.json'
    if (Test-Path $latestPath) {
        try {
            $data = Get-Content $latestPath -Raw | ConvertFrom-Json
            $tabs = ($data.windows | ForEach-Object { $_.tabs.Count } | Measure-Object -Sum).Sum
            $infoItem.Text = "Last freeze: $($data.savedAt) ($($data.windows.Count) win, $tabs tabs)"
        } catch {
            $infoItem.Text = 'Last freeze: (error reading)'
        }
    } else {
        $infoItem.Text = 'Last freeze: (none)'
    }
})

# Separator
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# List saves
$listItem = New-Object System.Windows.Forms.ToolStripMenuItem('List Saves')
$listItem.Add_Click({
    $savesDir = Join-Path $root 'saves'
    if (-not (Test-Path $savesDir)) {
        $tray.ShowBalloonTip(3000, 'No Saves', 'No saves directory found.', [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }
    $files = Get-ChildItem -Path $savesDir -Filter '20*.json' | Sort-Object Name -Descending
    if ($files.Count -eq 0) {
        $tray.ShowBalloonTip(3000, 'No Saves', 'No snapshots found.', [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }
    $list = ($files | Select-Object -First 8 | ForEach-Object {
        $data = Get-Content $_.FullName -Raw | ConvertFrom-Json
        $tabs = ($data.windows | ForEach-Object { $_.tabs.Count } | Measure-Object -Sum).Sum
        "$($_.BaseName) - $($data.windows.Count) win, $tabs tabs"
    }) -join "`n"
    $tray.ShowBalloonTip(10000, "Frozen Workspaces ($($files.Count))", $list, [System.Windows.Forms.ToolTipIcon]::Info)
})
$menu.Items.Add($listItem) | Out-Null

# Open folder
$folderItem = New-Object System.Windows.Forms.ToolStripMenuItem('Open Saves Folder')
$folderItem.Add_Click({
    $savesDir = Join-Path $root 'saves'
    if (-not (Test-Path $savesDir)) { New-Item -ItemType Directory -Path $savesDir -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList $savesDir
})
$menu.Items.Add($folderItem) | Out-Null

# Separator
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# Auto-save toggle
$autoSaveMinutes = if ($config.autoSaveMinutes) { $config.autoSaveMinutes } else { 5 }
$autoSaveItem = New-Object System.Windows.Forms.ToolStripMenuItem("Auto-freeze every ${autoSaveMinutes}min")
$autoSaveItem.Checked = $true
$autoSaveItem.CheckOnClick = $true
$menu.Items.Add($autoSaveItem) | Out-Null

# Separator
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# Exit
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')
$exitItem.Add_Click({
    # Save one last time before exiting
    Invoke-Save
    $timer.Stop()
    $timer.Dispose()
    $tray.Visible = $false
    $tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
$menu.Items.Add($exitItem) | Out-Null

$tray.ContextMenuStrip = $menu

# Double-click = save
$tray.Add_DoubleClick({ Invoke-Save })

# ── Auto-save timer ──

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $autoSaveMinutes * 60 * 1000
$timer.Add_Tick({
    if ($autoSaveItem.Checked) {
        # Only auto-save if Windows Terminal is running
        $wt = Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue
        if ($wt) { Invoke-Save }
    }
})
$timer.Start()

# ── Cleanup on unexpected exit ──

[System.Windows.Forms.Application]::add_ApplicationExit({
    $tray.Visible = $false
    $tray.Dispose()
    if ($script:mutex) { $script:mutex.ReleaseMutex(); $script:mutex.Dispose() }
})

# ── Run message loop ──

[System.Windows.Forms.Application]::Run()
