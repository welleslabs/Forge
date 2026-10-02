#Requires -Version 5.1
<#
.SYNOPSIS
    Switches the FSS ICAP server back to Demo Mock Mode.
    No outbound connection to Vision One FSS is required in this mode.
    EICAR files are BLOCKED locally; all other files are ALLOWED.
#>

$InstallPath = "C:\TrendMicro\FSS-ICAP"
$configPath  = "$InstallPath\fss_config.json"
$serverPath  = "$InstallPath\fss_icap_server.py"

Write-Host ""
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Yellow
Write-Host "|   FSS ICAP Bridge - Switching to DEMO MOCK Mode             |" -ForegroundColor Yellow
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Yellow
Write-Host ""

# Update config: mock_mode = true
Write-Host "Updating config: mock_mode = true ..." -ForegroundColor Yellow
$cfg = Get-Content $configPath -Raw | ConvertFrom-Json
$cfg | Add-Member -NotePropertyName "mock_mode" -NotePropertyValue $true -Force
$cfg | ConvertTo-Json -Depth 3 | ForEach-Object {
    [System.IO.File]::WriteAllText($configPath, $_, [System.Text.UTF8Encoding]::new($false))
}
Write-Host "  Config updated." -ForegroundColor Green

# Restart server
Write-Host "Restarting ICAP server in mock mode..." -ForegroundColor Yellow
Stop-Process -Name python -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$pythonExe = "C:\Program Files\Python311\python.exe"
if (-not (Test-Path $pythonExe)) {
    $pythonExe = (Get-Command python -ErrorAction SilentlyContinue).Source
}
if (-not $pythonExe) { $pythonExe = "python" }

Start-Process -FilePath $pythonExe `
              -ArgumentList $serverPath `
              -WorkingDirectory $InstallPath `
              -NoNewWindow

Start-Sleep -Seconds 5
Write-Host "  Server started in DEMO MOCK MODE." -ForegroundColor Green

Write-Host ""
Write-Host "Running validation tests..." -ForegroundColor Cyan
& "$PSScriptRoot\Test-FSS-ICAP.ps1" -ICAPHost 127.0.0.1 -ICAPPort 1344

Write-Host ""
Write-Host "  Mock mode active. No FSS connection required." -ForegroundColor Yellow
Write-Host "  To switch back to live mode: .\Switch-LiveMode.ps1" -ForegroundColor Cyan
Write-Host ""
