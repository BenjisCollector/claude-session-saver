<#
.SYNOPSIS
    Removes Cryosave shortcuts and startup entry.
#>

$startMenu = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
$startupDir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"

Write-Host ""
Write-Host "  Cryosave — Uninstall" -ForegroundColor Cyan
Write-Host ""

# Kill tray app if running
Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -match "Cryosave\.ps1"
} | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }

# Remove Scheduled Task (v1.0.1+)
$taskName = 'CryosaveTray'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "  [OK] Removed: Scheduled Task ($taskName)" -ForegroundColor Green
}

$files = @(
    "$startMenu\Cryosave - Freeze.lnk",
    "$startMenu\Cryosave - Thaw.lnk",
    "$startupDir\Cryosave.lnk"
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
