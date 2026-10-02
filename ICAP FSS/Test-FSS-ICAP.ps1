#Requires -Version 5.1

<#
.SYNOPSIS
    Validates the Trend Vision One FSS ICAP Bridge by sending test payloads.

.DESCRIPTION
    Sends raw ICAP requests to the local ICAP server and checks responses:
      1. ICAP OPTIONS handshake
      2. A clean (harmless) text file    - expects ICAP 204 allow
      3. EICAR test string               - expects ICAP 200 block (if API key active)
      4. Windows service status check
      5. Log file health check

.PARAMETER ICAPHost
    Hostname or IP of the ICAP server. Default: 127.0.0.1

.PARAMETER ICAPPort
    TCP port of the ICAP server. Default: 1344

.PARAMETER ServiceName
    Windows service name to check. Default: TrendFSSICAPBridge

.EXAMPLE
    .\Test-FSS-ICAP.ps1

.EXAMPLE
    .\Test-FSS-ICAP.ps1 -ICAPHost 192.168.1.50 -ICAPPort 1344
#>

[CmdletBinding()]
param(
    [string]$ICAPHost    = "127.0.0.1",
    [int]   $ICAPPort    = 1344,
    [string]$ServiceName = "TrendFSSICAPBridge"
)

# ---------------------------------------------------------------
#  HELPERS
# ---------------------------------------------------------------

$results = [System.Collections.Generic.List[PSObject]]::new()

function Write-Result {
    param([string]$Label, [bool]$Passed, [string]$Detail = "")
    $status = if ($Passed) { "[  PASS  ]" } else { "[  FAIL  ]" }
    $color  = if ($Passed) { "Green" }      else { "Red" }
    $line   = "$status $Label"
    if ($Detail) { $line += " -- $Detail" }
    Write-Host $line -ForegroundColor $color
    $results.Add([PSCustomObject]@{ Test = $Label; Passed = $Passed; Detail = $Detail })
}

function Send-ICAPRequest {
    param([byte[]]$RequestBytes, [int]$TimeoutMs = 10000)
    try {
        $tcp    = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($ICAPHost, $ICAPPort)
        $stream = $tcp.GetStream()
        $stream.WriteTimeout = $TimeoutMs
        $stream.ReadTimeout  = $TimeoutMs

        $stream.Write($RequestBytes, 0, $RequestBytes.Length)

        $buffer   = New-Object byte[] 65536
        $sb       = New-Object System.Text.StringBuilder
        Start-Sleep -Milliseconds 400

        do {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -gt 0) {
                $sb.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)) | Out-Null
            }
        } while ($stream.DataAvailable)

        $tcp.Close()
        return $sb.ToString()
    } catch {
        return $null
    }
}

function Build-ICAPReqmod {
    param([byte[]]$FileBytes, [string]$Filename = "test.txt")

    $httpReqHeader = "POST /upload HTTP/1.1`r`nHost: demo.example.com`r`nContent-Type: application/octet-stream`r`nContent-Disposition: attachment; filename=`"$Filename`"`r`nContent-Length: $($FileBytes.Length)`r`n`r`n"
    $httpReqHeaderBytes = [System.Text.Encoding]::UTF8.GetBytes($httpReqHeader)

    $chunkSizeHex = "{0:x}" -f $FileBytes.Length
    $chunkedBody  = [System.Text.Encoding]::UTF8.GetBytes("$chunkSizeHex`r`n") +
                    $FileBytes +
                    [System.Text.Encoding]::UTF8.GetBytes("`r`n0`r`n`r`n")

    $bodyOffset  = $httpReqHeaderBytes.Length
    $icapHeader  = "REQMOD icap://${ICAPHost}:${ICAPPort}/scan ICAP/1.0`r`nHost: ${ICAPHost}:${ICAPPort}`r`nConnection: close`r`nEncapsulated: req-hdr=0, req-body=$bodyOffset`r`n`r`n"
    $icapHeaderBytes = [System.Text.Encoding]::UTF8.GetBytes($icapHeader)

    return $icapHeaderBytes + $httpReqHeaderBytes + $chunkedBody
}

function Build-ICAPOptions {
    $req = "OPTIONS icap://${ICAPHost}:${ICAPPort}/scan ICAP/1.0`r`nHost: ${ICAPHost}:${ICAPPort}`r`nConnection: close`r`n`r`n"
    return [System.Text.Encoding]::UTF8.GetBytes($req)
}

# ---------------------------------------------------------------
#  BANNER
# ---------------------------------------------------------------

Write-Host ""
Write-Host "+--------------------------------------------------------------+" -ForegroundColor DarkCyan
Write-Host "|   Trend Vision One FSS ICAP Bridge -- Validation Tests      |" -ForegroundColor DarkCyan
Write-Host "+--------------------------------------------------------------+" -ForegroundColor DarkCyan
Write-Host "  Target: icap://${ICAPHost}:${ICAPPort}/scan"
Write-Host ""

# ---------------------------------------------------------------
#  TEST 1 -- Windows Service Status
# ---------------------------------------------------------------

Write-Host "--- Test 1: Windows Service Status ---" -ForegroundColor DarkGray
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    $running = ($svc.Status -eq "Running")
    Write-Result "Service '$ServiceName' is Running" $running $svc.Status.ToString()
} else {
    Write-Result "Service '$ServiceName' registered" $false "Service not found - may be running manually"
}

# ---------------------------------------------------------------
#  TEST 2 -- TCP Port Availability
# ---------------------------------------------------------------

Write-Host "--- Test 2: TCP Port Availability ---" -ForegroundColor DarkGray
$portOpen = $false
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect($ICAPHost, $ICAPPort)
    $portOpen = $true
    $tcp.Close()
} catch {}
Write-Result "Port ${ICAPPort} is reachable at ${ICAPHost}" $portOpen

if (-not $portOpen) {
    Write-Host ""
    Write-Host "  Cannot connect to ICAP server. Ensure the service is running:" -ForegroundColor Yellow
    Write-Host "    nssm start $ServiceName" -ForegroundColor Yellow
    Write-Host "  Or manually:" -ForegroundColor Yellow
    Write-Host "    python C:\TrendMicro\FSS-ICAP\fss_icap_server.py" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# ---------------------------------------------------------------
#  TEST 3 -- ICAP OPTIONS Handshake
# ---------------------------------------------------------------

Write-Host "--- Test 3: ICAP OPTIONS Handshake ---" -ForegroundColor DarkGray
$optionsRequest  = Build-ICAPOptions
$optionsResponse = Send-ICAPRequest -RequestBytes $optionsRequest

if ($optionsResponse) {
    $icapOk     = $optionsResponse -match "ICAP/1\.0 200 OK"
    $hasReqmod  = $optionsResponse -match "REQMOD"
    $hasRespmod = $optionsResponse -match "RESPMOD"
    Write-Result "OPTIONS returns ICAP 200 OK"       $icapOk
    Write-Result "OPTIONS advertises REQMOD method"  $hasReqmod
    Write-Result "OPTIONS advertises RESPMOD method" $hasRespmod
    $excerpt = ($optionsResponse -split "`n" | Select-Object -First 5) -join " | "
    Write-Host "  [INFO] Response: $excerpt" -ForegroundColor Gray
} else {
    Write-Result "OPTIONS request received a response" $false "No response or connection failed"
}

# ---------------------------------------------------------------
#  TEST 4 -- Clean File (Expect 204 Allow)
# ---------------------------------------------------------------

Write-Host "--- Test 4: Clean File (expect ALLOW) ---" -ForegroundColor DarkGray
$cleanContent  = [System.Text.Encoding]::UTF8.GetBytes("This is a harmless test file for Trend Vision One FSS ICAP demo. $(Get-Date)")
$cleanRequest  = Build-ICAPReqmod -FileBytes $cleanContent -Filename "clean_test.txt"
$cleanResponse = Send-ICAPRequest -RequestBytes $cleanRequest

if ($cleanResponse) {
    $allowed    = $cleanResponse -match "ICAP/1\.0 204"
    $notBlocked = -not ($cleanResponse -match "403 Forbidden")
    $firstLine  = ($cleanResponse -split "`r`n" | Select-Object -First 1)
    Write-Result "Clean file returns ICAP 204 No Content" $allowed    $firstLine
    Write-Result "Clean file is NOT blocked"              $notBlocked
} else {
    Write-Result "Clean file scan received a response" $false "No response received"
}

# ---------------------------------------------------------------
#  TEST 5 -- EICAR Test String (Expect 200 Block)
# ---------------------------------------------------------------

Write-Host "--- Test 5: EICAR Test File (expect BLOCK) ---" -ForegroundColor DarkGray
Write-Host "  [INFO] Sending EICAR test string - should be flagged as malicious by FSS." -ForegroundColor Gray
Write-Host "  [INFO] NOTE: Detection requires a valid, active FSS API key." -ForegroundColor Gray

# Standard EICAR test string - harmless but universally detected by AV engines
$eicarStr   = 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
$eicarBytes = [System.Text.Encoding]::ASCII.GetBytes($eicarStr)
$eicarReq   = Build-ICAPReqmod -FileBytes $eicarBytes -Filename "eicar_test.com"
$eicarResp  = Send-ICAPRequest -RequestBytes $eicarReq -TimeoutMs 20000

if ($eicarResp) {
    $blocked   = $eicarResp -match "ICAP/1\.0 200"
    $has403    = $eicarResp -match "403 Forbidden"
    $firstLine = ($eicarResp -split "`r`n" | Select-Object -First 1)
    Write-Result "EICAR returns ICAP 200 (modified/blocked)"  $blocked  $firstLine
    Write-Result "EICAR response contains 403 Forbidden page" $has403

    if (-not $blocked) {
        Write-Host "  [WARN] EICAR was NOT blocked. Possible causes:" -ForegroundColor Yellow
        Write-Host "         - FSS API key is invalid or not yet provisioned" -ForegroundColor Yellow
        Write-Host "         - FSS endpoint is unreachable (check outbound port 443)" -ForegroundColor Yellow
        Write-Host "         - Review C:\TrendMicro\FSS-ICAP\icap_server.log" -ForegroundColor Yellow
    }
} else {
    Write-Result "EICAR scan received a response" $false "No response - check if service is running"
}

# ---------------------------------------------------------------
#  TEST 6 -- Log File Check
# ---------------------------------------------------------------

Write-Host "--- Test 6: Log File ---" -ForegroundColor DarkGray
$logPath = "C:\TrendMicro\FSS-ICAP\icap_server.log"
if (Test-Path $logPath) {
    $logLines  = Get-Content $logPath -Tail 5 -ErrorAction SilentlyContinue
    $hasErrors = ($logLines -join " ") -match "ERROR|CRITICAL"
    Write-Result "Log file exists at $logPath"               $true
    Write-Result "No critical errors in recent log entries"  (-not $hasErrors)
    Write-Host ""
    Write-Host "  Last 5 log lines:" -ForegroundColor Gray
    $logLines | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
} else {
    Write-Result "Log file exists" $false "Not found at $logPath"
}

# ---------------------------------------------------------------
#  SUMMARY
# ---------------------------------------------------------------

Write-Host ""
Write-Host "--------------------------------------------------------------" -ForegroundColor DarkGray
$passed = ($results | Where-Object { $_.Passed }).Count
$total  = $results.Count
$allOk  = ($passed -eq $total)

$summaryColor = if ($allOk) { "Green" } else { "Yellow" }
Write-Host "  Results: $passed / $total tests passed" -ForegroundColor $summaryColor

if (-not $allOk) {
    Write-Host ""
    Write-Host "  Failed tests:" -ForegroundColor Red
    $results | Where-Object { -not $_.Passed } | ForEach-Object {
        Write-Host "    [FAIL] $($_.Test)" -ForegroundColor Red
        if ($_.Detail) { Write-Host "           $($_.Detail)" -ForegroundColor DarkRed }
    }
}

Write-Host ""
if ($allOk) {
    Write-Host "  [ALL PASS] ICAP bridge is operational and connected to Trend Vision One FSS!" -ForegroundColor Green
} else {
    Write-Host "  [WARN] Some checks failed. Review the log and FSS API key configuration." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  ICAP endpoint: icap://${ICAPHost}:${ICAPPort}/scan" -ForegroundColor Cyan
Write-Host "  Point your ICAP-capable client, proxy, or NAS device here." -ForegroundColor Cyan
Write-Host ""
