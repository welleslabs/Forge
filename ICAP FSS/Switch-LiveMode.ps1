#Requires -Version 5.1
<#
.SYNOPSIS
    Switches the FSS ICAP server from Demo Mock Mode to Live Mode.
    Live mode scans files via Trend Vision One FSS gRPC and logs
    events to the Vision One portal.

.NOTES
    Requires outbound TCP 443 to:
        antimalware.us-east-1.cloudone.trendmicro.com
    If that hostname is blocked, ask your network team to whitelist it.
#>

$InstallPath = "C:\TrendMicro\FSS-ICAP"
$configPath  = "$InstallPath\fss_config.json"
$serverPath  = "$InstallPath\fss_icap_server.py"

Write-Host ""
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "|   FSS ICAP Bridge - Switching to LIVE Mode                  |" -ForegroundColor Cyan
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------
# 1. Verify the gRPC endpoint is reachable before switching
# ---------------------------------------------------------------

Write-Host "Checking connectivity to Vision One FSS gRPC endpoint..." -ForegroundColor Yellow
$cfg        = Get-Content $configPath -Raw | ConvertFrom-Json
$grpcHost   = $cfg.fss_grpc_host -replace ":443",""
$connTest   = Test-NetConnection -ComputerName $grpcHost -Port 443 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue

if (-not $connTest.TcpTestSucceeded) {
    Write-Host ""
    Write-Host "  [BLOCKED] Cannot reach $grpcHost on port 443." -ForegroundColor Red
    Write-Host ""
    Write-Host "  The corporate firewall is blocking this connection." -ForegroundColor Yellow
    Write-Host "  Ask your network team to whitelist outbound TCP 443 to:" -ForegroundColor Yellow
    Write-Host "      $grpcHost" -ForegroundColor White
    Write-Host ""
    Write-Host "  Once unblocked, re-run this script." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Host "  [OK] $grpcHost :443 is reachable." -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------
# 2. Update config: mock_mode = false
# ---------------------------------------------------------------

Write-Host "Updating config: mock_mode = false ..." -ForegroundColor Yellow
$cfg | Add-Member -NotePropertyName "mock_mode" -NotePropertyValue $false -Force
$cfg | ConvertTo-Json -Depth 3 | ForEach-Object {
    [System.IO.File]::WriteAllText($configPath, $_, [System.Text.UTF8Encoding]::new($false))
}
Write-Host "  Config updated." -ForegroundColor Green

# ---------------------------------------------------------------
# 3. Stop old server and restart with live mode
# ---------------------------------------------------------------

Write-Host "Restarting ICAP server in live mode..." -ForegroundColor Yellow
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
Write-Host "  Server started." -ForegroundColor Green

# ---------------------------------------------------------------
# 4. Run validation test
# ---------------------------------------------------------------

Write-Host ""
Write-Host "Running validation tests..." -ForegroundColor Cyan
& "$PSScriptRoot\Test-FSS-ICAP.ps1" -ICAPHost 127.0.0.1 -ICAPPort 1344

Write-Host ""
Write-Host "  Live mode active. Scan events will now appear in Vision One." -ForegroundColor Green
Write-Host "  Monitor: Get-Content '$InstallPath\icap_server.log' -Wait" -ForegroundColor Cyan
Write-Host ""
