<#
.SYNOPSIS
    System tray application for Claude Session Saver.
.DESCRIPTION
    Runs silently in the notification area (system tray). Right-click the icon to:
    - Save Sessions: capture all windows, tabs, and Claude sessions
    - Restore Sessions: reopen everything from last save
    - List Saves: see available snapshots
    - Open Saves Folder: browse saved JSON files
    - Exit: close the tray app
#>

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Create tray icon ──

$icon = [System.Drawing.SystemIcons]::Application
$customIconPath = Join-Path $root "assets\icon.ico"
if (Test-Path $customIconPath) {
    $icon = New-Object System.Drawing.Icon($customIconPath)
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icon
$tray.Text = "Claude Session Saver"
$tray.Visible = $true

# ── Context menu ──

$menu = New-Object System.Windows.Forms.ContextMenuStrip

# Save
$saveItem = New-Object System.Windows.Forms.ToolStripMenuItem("Save Sessions")
$saveItem.Font = New-Object System.Drawing.Font($saveItem.Font, [System.Drawing.FontStyle]::Bold)
$saveItem.Add_Click({
    try {
        $proc = Start-Process powershell.exe -ArgumentList @(
            "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
            "-File", "`"$root\Save-Sessions.ps1`"", "-Silent"
        ) -PassThru -WindowStyle Hidden
        $proc.WaitForExit(30000)
    } catch {
        $tray.ShowBalloonTip(3000, "Error", "Save failed: $_", [System.Windows.Forms.ToolTipIcon]::Error)
    }
})
$menu.Items.Add($saveItem) | Out-Null

# Restore
$restoreItem = New-Object System.Windows.Forms.ToolStripMenuItem("Restore Sessions")
$restoreItem.Add_Click({
    $latestPath = Join-Path $root "saves\latest.json"
    if (-not (Test-Path $latestPath)) {
        $tray.ShowBalloonTip(3000, "No Saves", "No saved sessions found. Save first.", [System.Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    Start-Process powershell.exe -ArgumentList @(
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$root\Restore-Sessions.ps1`""
    )
})
$menu.Items.Add($restoreItem) | Out-Null

# Separator
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# List saves
$listItem = New-Object System.Windows.Forms.ToolStripMenuItem("List Saves")
$listItem.Add_Click({
    $savesDir = Join-Path $root "saves"
    if (-not (Test-Path $savesDir)) {
        $tray.ShowBalloonTip(3000, "No Saves", "No saves directory found.", [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }
    $files = Get-ChildItem -Path $savesDir -Filter "20*.json" | Sort-Object Name -Descending
    if ($files.Count -eq 0) {
        $tray.ShowBalloonTip(3000, "No Saves", "No snapshots found.", [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }
    $list = ($files | ForEach-Object {
        $data = Get-Content $_.FullName -Raw | ConvertFrom-Json
        $tabs = ($data.windows | ForEach-Object { $_.tabs.Count } | Measure-Object -Sum).Sum
        "$($_.BaseName) — $($data.windows.Count) win, $tabs tabs"
    }) -join "`n"
    $tray.ShowBalloonTip(10000, "Saved Sessions ($($files.Count))", $list, [System.Windows.Forms.ToolTipIcon]::Info)
})
$menu.Items.Add($listItem) | Out-Null

# Open folder
$folderItem = New-Object System.Windows.Forms.ToolStripMenuItem("Open Saves Folder")
$folderItem.Add_Click({
    $savesDir = Join-Path $root "saves"
    if (-not (Test-Path $savesDir)) { New-Item -ItemType Directory -Path $savesDir -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList $savesDir
})
$menu.Items.Add($folderItem) | Out-Null

# Separator
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# Exit
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
$exitItem.Add_Click({
    $tray.Visible = $false
    $tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
$menu.Items.Add($exitItem) | Out-Null

$tray.ContextMenuStrip = $menu

# Double-click = save (quick access)
$tray.Add_DoubleClick({
    $saveItem.PerformClick()
})

# ── Run message loop ──

[System.Windows.Forms.Application]::Run()
