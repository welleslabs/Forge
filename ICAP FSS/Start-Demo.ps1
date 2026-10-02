#Requires -Version 5.1
<#
.SYNOPSIS
    Starts the FSS ICAP server and the web demo client, then opens a browser.
    Run this script on the demo machine as Administrator.

.PARAMETER ICAPHost
    Host the demo web client should connect to for ICAP scanning.
    Default: 127.0.0.1 (local machine)

.PARAMETER ICAPPort
    ICAP server port. Default: 1344

.PARAMETER WebPort
    Port for the demo web UI. Default: 8080

.EXAMPLE
    .\Start-Demo.ps1
    .\Start-Demo.ps1 -ICAPHost 127.0.0.1 -WebPort 8080
#>

param(
    [string]$ICAPHost = "127.0.0.1",
    [int]$ICAPPort    = 1344,
    [int]$WebPort     = 8080
)

$InstallPath = "C:\TrendMicro\FSS-ICAP"
$serverScript = "$InstallPath\fss_icap_server.py"
$clientScript = "$InstallPath\icap_demo_client.py"

Write-Host ""
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "|   Trend Vision One FSS ICAP - Demo Startup                  |" -ForegroundColor Cyan
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------
# Find Python
# ---------------------------------------------------------------

$pythonExe = "C:\Program Files\Python311\python.exe"
if (-not (Test-Path $pythonExe)) {
    $pythonExe = (Get-Command python -ErrorAction SilentlyContinue).Source
}
if (-not $pythonExe) {
    Write-Host "  [ERROR] Python not found. Run Setup-FSS-ICAP-Demo.ps1 first." -ForegroundColor Red
    exit 1
}
Write-Host "  Python : $pythonExe" -ForegroundColor Gray

# ---------------------------------------------------------------
# Stop any existing Python processes cleanly
# ---------------------------------------------------------------

$existing = Get-Process python -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "  Stopping existing Python processes..." -ForegroundColor Yellow
    $existing | Stop-Process -Force
    Start-Sleep -Seconds 2
}

# ---------------------------------------------------------------
# Start ICAP server
# ---------------------------------------------------------------

Write-Host "  Starting ICAP server on port $ICAPPort ..." -ForegroundColor Yellow
Start-Process -FilePath $pythonExe `
              -ArgumentList $serverScript `
              -WorkingDirectory $InstallPath `
              -NoNewWindow

Start-Sleep -Seconds 3

# Verify ICAP server is listening
$icapUp = $false
for ($i = 0; $i -lt 5; $i++) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", $ICAPPort)
        $tcp.Close()
        $icapUp = $true
        break
    } catch {
        Start-Sleep -Seconds 1
    }
}

if ($icapUp) {
    Write-Host "  [OK] ICAP server listening on port $ICAPPort." -ForegroundColor Green
} else {
    Write-Host "  [WARN] ICAP server not responding yet - it may still be starting." -ForegroundColor Yellow
}

# ---------------------------------------------------------------
# Start demo web client
# ---------------------------------------------------------------

Write-Host "  Starting demo web client on port $WebPort ..." -ForegroundColor Yellow
Start-Process -FilePath $pythonExe `
              -ArgumentList "$clientScript --icap-host $ICAPHost --icap-port $ICAPPort --port $WebPort" `
              -WorkingDirectory $InstallPath `
              -NoNewWindow

Start-Sleep -Seconds 2

# ---------------------------------------------------------------
# Open browser
# ---------------------------------------------------------------

$url = "http://localhost:$WebPort"
Write-Host "  Opening browser at $url ..." -ForegroundColor Yellow
Start-Process $url

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------

Write-Host ""
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Green
Write-Host "|   Demo is running!                                           |" -ForegroundColor Green
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Green
Write-Host ""
Write-Host "  Web UI   : http://localhost:$WebPort" -ForegroundColor Cyan
Write-Host "  ICAP     : icap://${ICAPHost}:${ICAPPort}/scan" -ForegroundColor Cyan
Write-Host ""

# Show current mode
$configPath = "$InstallPath\fss_config.json"
if (Test-Path $configPath) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    if ($cfg.mock_mode -eq $true) {
        Write-Host "  Mode     : DEMO MOCK (EICAR blocked, all other files allowed)" -ForegroundColor Yellow
        Write-Host "             To switch to live mode: .\Switch-LiveMode.ps1" -ForegroundColor Gray
    } else {
        Write-Host "  Mode     : LIVE (scanning via Vision One FSS)" -ForegroundColor Green
        Write-Host "             To switch to mock mode: .\Switch-MockMode.ps1" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "  Press Ctrl+C or close this window to stop." -ForegroundColor Gray
Write-Host ""

# Keep window open so user can see logs from both processes
Write-Host "  Streaming ICAP server log (Ctrl+C to stop):" -ForegroundColor Gray
Write-Host ""
$logPath = "$InstallPath\icap_server.log"
if (Test-Path $logPath) {
    Get-Content $logPath -Wait
} else {
    # Wait so the window stays open
    while ($true) { Start-Sleep -Seconds 5 }
}
