<#
.SYNOPSIS
    Removes Claude Session Saver shortcuts and startup entry.
#>

$startMenu = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
$startupDir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"

Write-Host ""
Write-Host "  Claude Session Saver — Uninstall" -ForegroundColor Cyan
Write-Host ""

# Kill tray app if running
Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -match "SessionSaver\.ps1"
} | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }

# Remove Scheduled Task (v1.0.1+)
$taskName = 'ClaudeSessionSaverTray'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "  [OK] Removed: Scheduled Task ($taskName)" -ForegroundColor Green
}

$files = @(
    "$startMenu\Save Claude Sessions.lnk",
    "$startMenu\Restore Claude Sessions.lnk",
    "$startupDir\Claude Session Saver.lnk"
)

foreach ($f in $files) {
    if (Test-Path $f) {
        Remove-Item $f -Force
        Write-Host "  [OK] Removed: $(Split-Path -Leaf $f)" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "  Uninstalled. Your saved sessions in saves/ are kept." -ForegroundColor Gray
Write-Host ""
