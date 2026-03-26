<#
.SYNOPSIS
    Lists all saved session snapshots.
#>
$savesDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "saves"

if (-not (Test-Path $savesDir)) {
    Write-Host "No saves found." -ForegroundColor Yellow
    exit 0
}

$files = Get-ChildItem -Path $savesDir -Filter "20*.json" | Sort-Object Name -Descending
if ($files.Count -eq 0) {
    Write-Host "No saves found." -ForegroundColor Yellow
    exit 0
}

Write-Host "Frozen Workspaces:" -ForegroundColor Cyan
Write-Host ""

foreach ($f in $files) {
    $data = Get-Content $f.FullName -Raw | ConvertFrom-Json
    $totalTabs = ($data.windows | ForEach-Object { $_.tabs.Count } | Measure-Object -Sum).Sum
    $claudeTabs = ($data.windows | ForEach-Object { $_.tabs | Where-Object { $_.type -eq "claude" } } | Measure-Object).Count
    $sshTabs = ($data.windows | ForEach-Object { $_.tabs | Where-Object { $_.type -eq "ssh" } } | Measure-Object).Count

    $marker = if ($f.Name -eq "latest.json") { "" } else { "" }
    $label = if ($f.BaseName -eq "latest") { "  (current)" } else { "" }

    Write-Host "  $marker $($f.BaseName)$label" -ForegroundColor White -NoNewline
    Write-Host " — $($data.windows.Count) win, $totalTabs tabs ($claudeTabs Claude, $sshTabs SSH)" -ForegroundColor Gray
}
