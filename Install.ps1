<#
.SYNOPSIS
    Installs Claude Session Saver: adds system tray app to Windows startup
    and creates Start Menu shortcuts.
#>

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$WshShell = New-Object -ComObject WScript.Shell

Write-Host ''
Write-Host '  Claude Session Saver - Install' -ForegroundColor Cyan
Write-Host '  ===============================' -ForegroundColor DarkGray
Write-Host ''

# 1. Create Start Menu shortcuts

$startMenu = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\Start Menu\Programs')

$lnk = $WshShell.CreateShortcut([System.IO.Path]::Combine($startMenu, 'Save Claude Sessions.lnk'))
$lnk.TargetPath = 'powershell.exe'
$lnk.Arguments = ('-ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Silent' -f [System.IO.Path]::Combine($root, 'Save-Sessions.ps1'))
$lnk.WorkingDirectory = $root
$lnk.IconLocation = 'shell32.dll,258'
$lnk.Description = 'Save all terminal windows and Claude Code sessions'
$lnk.Save()
Write-Host '  [OK] Start Menu: Save Claude Sessions' -ForegroundColor Green

$lnk = $WshShell.CreateShortcut([System.IO.Path]::Combine($startMenu, 'Restore Claude Sessions.lnk'))
$lnk.TargetPath = 'powershell.exe'
$lnk.Arguments = ('-ExecutionPolicy Bypass -File "{0}"' -f [System.IO.Path]::Combine($root, 'Restore-Sessions.ps1'))
$lnk.WorkingDirectory = $root
$lnk.IconLocation = 'shell32.dll,137'
$lnk.Description = 'Restore saved terminal windows and Claude Code sessions'
$lnk.Save()
Write-Host '  [OK] Start Menu: Restore Claude Sessions' -ForegroundColor Green

# 2. Add tray app via Scheduled Task (faster than Startup folder)

$taskName = 'ClaudeSessionSaverTray'
$trayScript = [System.IO.Path]::Combine($root, 'SessionSaver.ps1')

# Remove old Startup folder shortcut if it exists (migration from v1.0)
$oldStartupLnk = [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\Start Menu\Programs\Startup\Claude Session Saver.lnk')
if (Test-Path $oldStartupLnk) {
    Remove-Item $oldStartupLnk -Force
    Write-Host '  [OK] Removed old Startup folder shortcut (migrated to Scheduled Task)' -ForegroundColor DarkGray
}

# Remove existing task if present (idempotent install)
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ('-ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $trayScript) `
    -WorkingDirectory $root

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval ([TimeSpan]::FromMinutes(1)) `
    -Priority 4

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description 'Claude Session Saver system tray app' `
    -RunLevel Limited | Out-Null

Write-Host '  [OK] Scheduled Task: tray app starts on login (faster than Startup folder)' -ForegroundColor Green

# 3. Enable Windows Terminal tab persistence as fallback

$wtSettingsPath = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json')
if (Test-Path $wtSettingsPath) {
    $wtSettings = Get-Content $wtSettingsPath -Raw | ConvertFrom-Json
    if (-not $wtSettings.firstWindowPreference) {
        $wtSettings | Add-Member -NotePropertyName 'firstWindowPreference' -NotePropertyValue 'persistedWindowLayout' -Force
        $wtSettings | ConvertTo-Json -Depth 20 | Set-Content $wtSettingsPath -Encoding utf8
        Write-Host '  [OK] Windows Terminal: enabled built-in tab persistence' -ForegroundColor Green
    } else {
        Write-Host '  [--] Windows Terminal: tab persistence already configured' -ForegroundColor DarkGray
    }
} else {
    Write-Host '  [--] Windows Terminal settings not found (skipped)' -ForegroundColor DarkGray
}

# 4. Create saves directory

$savesDir = Join-Path $root 'saves'
if (-not (Test-Path $savesDir)) {
    New-Item -ItemType Directory -Path $savesDir -Force | Out-Null
}

# Done

Write-Host ''
Write-Host '  Installation complete.' -ForegroundColor Green
Write-Host ''
Write-Host '  How to use:' -ForegroundColor White
Write-Host '    1. The tray app starts automatically on login' -ForegroundColor Gray
Write-Host '       (look for it in the bottom-right hidden icons area)' -ForegroundColor Gray
Write-Host '    2. Right-click the tray icon, then Save Sessions' -ForegroundColor Gray
Write-Host '    3. Right-click the tray icon, then Restore Sessions' -ForegroundColor Gray
Write-Host '    4. Double-click the tray icon for a quick save' -ForegroundColor Gray
Write-Host ''
Write-Host '  To pin to taskbar:' -ForegroundColor White
Write-Host '    Open Start, search Save Claude Sessions, right-click, Pin to taskbar' -ForegroundColor Gray
Write-Host ''

# Launch tray app now

Write-Host '  Starting tray app...' -ForegroundColor DarkGray
Start-Process -FilePath 'powershell.exe' -ArgumentList @('-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $trayScript) -WindowStyle Hidden
Write-Host '  [OK] Tray app running' -ForegroundColor Green
Write-Host ''
