#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Trend Vision One File Storage Security (FSS) - ICAP Demo Setup
    Windows Server 2022

.DESCRIPTION
    Installs and configures a Python-based ICAP server bridge on Windows Server 2022
    that integrates with Trend Vision One File Storage Security for real-time
    file scanning via the ICAP protocol.

    Architecture:
        ICAP Client  -->  ICAP Server (Port 1344)  -->  Vision One FSS API  -->  Verdict

    What this script installs:
        - Chocolatey (Windows package manager)
        - Python 3.11
        - pip packages: requests
        - NSSM (Non-Sucking Service Manager) for Windows service registration
        - fss_icap_server.py  (the ICAP bridge, written to InstallPath)
        - fss_config.json     (configuration file, written to InstallPath)
        - Windows Firewall rule for ICAP port

.PARAMETER ApiKey
    Your Trend Vision One API Key.
    Generate one at: https://portal.xdr.trendmicro.com > Administration > API Keys

.PARAMETER Region
    Your Trend Vision One region. Accepted values:
        us-1   (United States)
        eu-1   (Europe)
        ap-1   (Asia Pacific / Japan)
        ap-2   (Asia Pacific / India)
        ap-3   (Asia Pacific / Singapore)
        au-1   (Australia)
    Default: us-1

.PARAMETER ICAPPort
    TCP port the ICAP server listens on. Default: 1344

.PARAMETER InstallPath
    Directory where scripts and logs are written.
    Default: C:\TrendMicro\FSS-ICAP

.PARAMETER PythonInstallerPath
    Path to a pre-downloaded python-3.11.x-amd64.exe installer.
    Use this when the server has no internet access to python.org or Chocolatey.
    Example: C:\Users\Administrator\Desktop\python-3.11.9-amd64.exe

.EXAMPLE
    .\Setup-FSS-ICAP-Demo.ps1 -ApiKey "YOUR_V1_API_KEY"

.EXAMPLE
    .\Setup-FSS-ICAP-Demo.ps1 -ApiKey "YOUR_V1_API_KEY" -Region "eu-1" -ICAPPort 1344

.EXAMPLE
    # Air-gapped / firewall-restricted server: supply the installer you copied over manually
    .\Setup-FSS-ICAP-Demo.ps1 -ApiKey "YOUR_V1_API_KEY" -PythonInstallerPath "C:\Users\Administrator\Desktop\python-3.11.9-amd64.exe"

.NOTES
    Tested on: Windows Server 2022 (Desktop Experience)
    Requires:  Administrator privileges
    Internet:  Only api.xdr.trendmicro.com:443 is required at runtime.
               Python can be pre-downloaded and supplied via -PythonInstallerPath
               if outbound access to python.org / chocolatey.org is blocked.
    NOTE: Run this script from a plain PowerShell window (not ISE) for best results.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Trend Vision One API Key")]
    [ValidateNotNullOrEmpty()]
    [string]$ApiKey,

    [Parameter(Mandatory = $false)]
    [ValidateSet("us-1","eu-1","ap-1","ap-2","ap-3","au-1")]
    [string]$Region = "us-1",

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 65535)]
    [int]$ICAPPort = 1344,

    [Parameter(Mandatory = $false)]
    [string]$InstallPath = "C:\TrendMicro\FSS-ICAP",

    [Parameter(Mandatory = $false,
               HelpMessage = "Path to a pre-downloaded python-3.11.x-amd64.exe (use when internet access is restricted)")]
    [string]$PythonInstallerPath = "",

    [Parameter(Mandatory = $false,
               HelpMessage = "Run in demo mock mode: simulates FSS results locally (EICAR blocked, all other files allowed). No outbound gRPC connection is required.")]
    [switch]$MockMode
)

# ---------------------------------------------------------------
#  HELPER FUNCTIONS
# ---------------------------------------------------------------

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","SUCCESS","WARNING","ERROR","STEP")]
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"    { "Cyan"    }
        "SUCCESS" { "Green"   }
        "WARNING" { "Yellow"  }
        "ERROR"   { "Red"     }
        "STEP"    { "Magenta" }
        default   { "White"   }
    }
    $entry = "[$ts] [$Level] $Message"
    Write-Host $entry -ForegroundColor $color
    if (Test-Path $InstallPath) {
        Add-Content -Path "$InstallPath\setup.log" -Value $entry -ErrorAction SilentlyContinue
    }
}

function Assert-ExitCode {
    param([string]$Context)
    if ($LASTEXITCODE -ne 0) {
        Write-Log "$Context failed (exit code $LASTEXITCODE)." "ERROR"
        exit 1
    }
}

function Test-CommandExists {
    param([string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------
#  BANNER  (ASCII only - avoids encoding issues on PS 5.1)
# ---------------------------------------------------------------

Write-Host ""
Write-Host "+--------------------------------------------------------------+" -ForegroundColor DarkCyan
Write-Host "|  Trend Vision One File Storage Security - ICAP Demo Setup   |" -ForegroundColor DarkCyan
Write-Host "|  Windows Server 2022  |  PowerShell Setup Script            |" -ForegroundColor DarkCyan
Write-Host "+--------------------------------------------------------------+" -ForegroundColor DarkCyan
Write-Host ""

# ---------------------------------------------------------------
#  STEP 1 - PREREQUISITES CHECK
# ---------------------------------------------------------------

Write-Log "=== STEP 1: Prerequisites Check ===" "STEP"

$os = (Get-WmiObject Win32_OperatingSystem).Caption
Write-Log "Detected OS: $os" "INFO"
if ($os -notmatch "Windows Server 2022") {
    Write-Log "This script targets Windows Server 2022. Detected: $os" "WARNING"
    Write-Log "Continuing anyway - most steps should still work on compatible systems." "WARNING"
}

Write-Log "PowerShell version: $($PSVersionTable.PSVersion)" "INFO"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Log "This script must be run as Administrator." "ERROR"
    exit 1
}
Write-Log "Running as Administrator: OK" "SUCCESS"

Write-Log "Checking connectivity to api.xdr.trendmicro.com:443 ..." "INFO"
try {
    $ping = Test-NetConnection -ComputerName "api.xdr.trendmicro.com" -Port 443 -WarningAction SilentlyContinue
    if ($ping.TcpTestSucceeded) {
        Write-Log "Connectivity to api.xdr.trendmicro.com:443 - OK" "SUCCESS"
    } else {
        Write-Log "Cannot reach api.xdr.trendmicro.com:443. Check firewall/proxy settings." "WARNING"
    }
} catch {
    Write-Log "Connectivity check failed: $_" "WARNING"
}

if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    Write-Log "Created install directory: $InstallPath" "SUCCESS"
} else {
    Write-Log "Install directory already exists: $InstallPath" "INFO"
}

# ---------------------------------------------------------------
#  STEP 2 - INSTALL CHOCOLATEY
# ---------------------------------------------------------------

Write-Log "=== STEP 2: Chocolatey Package Manager ===" "STEP"

if (Test-CommandExists "choco") {
    Write-Log "Chocolatey already installed: $(choco --version)" "SUCCESS"
} else {
    Write-Log "Installing Chocolatey..." "INFO"
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")

    if (Test-CommandExists "choco") {
        Write-Log "Chocolatey installed successfully: $(choco --version)" "SUCCESS"
    } else {
        Write-Log "Chocolatey installation failed. Install manually from https://chocolatey.org/install" "ERROR"
        exit 1
    }
}

# ---------------------------------------------------------------
#  STEP 3 - INSTALL PYTHON 3.11
# ---------------------------------------------------------------

Write-Log "=== STEP 3: Python 3.11 ===" "STEP"

$pythonCmd = $null
foreach ($candidate in @("python","python3","py")) {
    if (Test-CommandExists $candidate) {
        $ver = & $candidate --version 2>&1
        if ($ver -match "3\.(9|10|11|12)") {
            $pythonCmd = $candidate
            Write-Log "Python already available ($ver): using '$candidate'" "SUCCESS"
            break
        }
    }
}

if (-not $pythonCmd) {

    # --- Priority 1: use a pre-supplied local installer (-PythonInstallerPath) ---
    if ($PythonInstallerPath -ne "" -and (Test-Path $PythonInstallerPath)) {
        Write-Log "Using supplied Python installer: $PythonInstallerPath" "INFO"
        $proc = Start-Process -FilePath $PythonInstallerPath `
                    -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0" `
                    -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Write-Log "Python installer exited with code $($proc.ExitCode)." "ERROR"
            exit 1
        }
        Write-Log "Python installed from supplied file." "SUCCESS"

    # --- Priority 2: Chocolatey ---
    } elseif (Test-CommandExists "choco") {
        Write-Log "Attempting Python 3.11 install via Chocolatey..." "INFO"
        choco install python311 -y --no-progress 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Chocolatey install failed (feed may be blocked)." "WARNING"
            Write-Log "Trying direct download from python.org..." "WARNING"
            goto TryDirectDownload
        }

    # --- Priority 3: direct download from python.org ---
    } else {
        :TryDirectDownload
        $pyVersion   = "3.11.9"
        $pyInstaller = "$env:TEMP\python-$pyVersion-amd64.exe"
        $pyUrl       = "https://www.python.org/ftp/python/$pyVersion/python-$pyVersion-amd64.exe"
        Write-Log "Downloading Python $pyVersion from python.org..." "INFO"
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            Invoke-WebRequest -Uri $pyUrl -OutFile $pyInstaller -UseBasicParsing -ErrorAction Stop
            $proc = Start-Process -FilePath $pyInstaller `
                        -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0" `
                        -Wait -PassThru
            if ($proc.ExitCode -ne 0) {
                Write-Log "Python installer exited with code $($proc.ExitCode)." "ERROR"
                exit 1
            }
            Write-Log "Python $pyVersion installed from python.org." "SUCCESS"
        } catch {
            Write-Log "All automatic Python install methods failed." "ERROR"
            Write-Log "" "ERROR"
            Write-Log "  ACTION REQUIRED:" "ERROR"
            Write-Log "  1. On a machine with internet access, download:" "ERROR"
            Write-Log "     https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe" "ERROR"
            Write-Log "  2. Copy the file to this server (e.g. via RDP drag-and-drop)." "ERROR"
            Write-Log "  3. Re-run this script with the -PythonInstallerPath parameter:" "ERROR"
            Write-Log "     .\Setup-FSS-ICAP-Demo.ps1 -ApiKey '...' -PythonInstallerPath 'C:\Users\Administrator\Desktop\python-3.11.9-amd64.exe'" "ERROR"
            exit 1
        }
    }

    # Refresh PATH after any install method
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")

    foreach ($candidate in @("python","python3","py")) {
        if (Test-CommandExists $candidate) {
            $pythonCmd = $candidate
            break
        }
    }

    if ($pythonCmd) {
        Write-Log "Python installed and available: $(& $pythonCmd --version)" "SUCCESS"
    } else {
        Write-Log "Python not found on PATH after install. Try restarting the shell and re-running." "ERROR"
        exit 1
    }
}

# ---------------------------------------------------------------
#  STEP 4 - INSTALL PYTHON PACKAGES
# ---------------------------------------------------------------

Write-Log "=== STEP 4: Python pip packages ===" "STEP"

# visionone-filesecurity provides the amaas.grpc module for gRPC-based scanning
# It replaces the old REST-based approach which used /v3.0/fss/files/scan (404)
$pipPackages = @("visionone-filesecurity")

foreach ($pkg in $pipPackages) {
    Write-Log "Installing pip package: $pkg" "INFO"
    & $pythonCmd -m pip install --upgrade $pkg --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  $pkg - OK" "SUCCESS"
    } else {
        Write-Log "  $pkg - FAILED (exit $LASTEXITCODE)" "ERROR"
        exit 1
    }
}

# ---------------------------------------------------------------
#  STEP 5 - OBTAIN NSSM (SERVICE MANAGER)
#  Priority: already installed > Chocolatey > direct zip download > Task Scheduler fallback
#  This step is non-fatal: if NSSM cannot be obtained, we fall back to Task Scheduler.
# ---------------------------------------------------------------

Write-Log "=== STEP 5: NSSM / Service Manager ===" "STEP"

# Shared variable used in Step 8 to decide registration method
$nssmExe         = $null
$useTaskScheduler = $false

# Check if already present
foreach ($candidate in @("nssm","C:\ProgramData\chocolatey\bin\nssm.exe","C:\tools\nssm\win64\nssm.exe")) {
    if (Test-CommandExists $candidate -or (Test-Path $candidate -ErrorAction SilentlyContinue)) {
        $nssmExe = $candidate
        Write-Log "NSSM already available: $nssmExe" "SUCCESS"
        break
    }
}

if (-not $nssmExe) {
    # --- Try Chocolatey ---
    Write-Log "Trying Chocolatey for NSSM..." "INFO"
    choco install nssm -y --no-progress 2>&1 | Out-Null
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
    if (Test-CommandExists "nssm") {
        $nssmExe = "nssm"
        Write-Log "NSSM installed via Chocolatey." "SUCCESS"
    }
}

if (-not $nssmExe) {
    # --- Try direct zip download from nssm.cc ---
    Write-Log "Chocolatey feed blocked. Trying direct download of NSSM from nssm.cc..." "WARNING"
    $nssmZip  = "$env:TEMP\nssm-2.24.zip"
    $nssmDir  = "C:\tools\nssm"
    $nssmUrl  = "https://nssm.cc/release/nssm-2.24.zip"
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-WebRequest -Uri $nssmUrl -OutFile $nssmZip -UseBasicParsing -ErrorAction Stop
        Expand-Archive -Path $nssmZip -DestinationPath $nssmDir -Force
        $nssmExe = "$nssmDir\nssm-2.24\win64\nssm.exe"
        if (Test-Path $nssmExe) {
            Write-Log "NSSM downloaded and extracted to $nssmExe" "SUCCESS"
        } else {
            $nssmExe = $null
        }
    } catch {
        Write-Log "NSSM direct download also failed (nssm.cc blocked): $_" "WARNING"
    }
}

if (-not $nssmExe) {
    # --- Final fallback: use Windows Task Scheduler (built-in, no download needed) ---
    Write-Log "NSSM unavailable. Will use Windows Task Scheduler to run the ICAP server on startup." "WARNING"
    $useTaskScheduler = $true
}

# ---------------------------------------------------------------
#  STEP 6 - WRITE CONFIGURATION FILE
# ---------------------------------------------------------------

Write-Log "=== STEP 6: Writing configuration file ===" "STEP"

# Vision One File Security uses gRPC (not REST).
# Map Vision One portal region codes to the gRPC AMaaS region identifiers.
# The SDK accepts either the short region name or the full hostname:
#   antimalware.{grpc_region}.cloudone.trendmicro.com:443
# Vision One region codes map directly to the C1 gRPC subdomain.
# Format: antimalware.{region}.cloudone.trendmicro.com:443
# NOTE: Do NOT use AWS region names (us-east-1 etc.) - they are NXDOMAIN.
$regionGrpcMap = @{
    "us-1" = "us-1"
    "eu-1" = "de-1"
    "ap-1" = "jp-1"
    "ap-2" = "in-1"
    "ap-3" = "sg-1"
    "au-1" = "au-1"
}

$grpcRegion  = $regionGrpcMap[$Region]
$fssEndpoint = "antimalware.$grpcRegion.cloudone.trendmicro.com:443"

$configObj = @{
    api_key      = $ApiKey
    region       = $Region
    grpc_region  = $grpcRegion
    fss_grpc_host = $fssEndpoint
    icap_port    = $ICAPPort
    icap_bind    = "0.0.0.0"
    log_path     = "$InstallPath\icap_server.log"
    service_name = "TrendFSSICAPBridge"
    mock_mode    = $MockMode.IsPresent
}

$configJson = $configObj | ConvertTo-Json -Depth 3
$configPath = "$InstallPath\fss_config.json"
# Use WriteAllText with UTF-8 (no BOM) - PowerShell 5.1 Set-Content -Encoding UTF8
# writes a BOM which breaks Python's json.load()
[System.IO.File]::WriteAllText($configPath, $configJson, [System.Text.UTF8Encoding]::new($false))
Write-Log "Configuration written to: $configPath" "SUCCESS"
Write-Log "  Region   : $Region -> gRPC: $fssEndpoint" "INFO"
Write-Log "  ICAP Port: $ICAPPort" "INFO"

# ---------------------------------------------------------------
#  STEP 7 - WRITE PYTHON ICAP SERVER SCRIPT
# ---------------------------------------------------------------

Write-Log "=== STEP 7: Writing ICAP server script ===" "STEP"

$serverScriptPath = "$InstallPath\fss_icap_server.py"

# Python script stored as single-quoted here-string (PowerShell does not expand $ inside it).
# Uses the official visionone-filesecurity gRPC SDK - NOT a REST API.
$pythonScript = @'
#!/usr/bin/env python3
"""
Trend Vision One File Security - ICAP Bridge Server
----------------------------------------------------
Listens on the configured ICAP port and scans file content.

Two modes (set via fss_config.json "mock_mode" key):

  LIVE MODE  (mock_mode: false)
      Uses the visionone-filesecurity gRPC SDK to scan via Vision One FSS.
      Requires outbound TCP 443 to antimalware.*.cloudone.trendmicro.com.

  MOCK MODE  (mock_mode: true)
      Detects the EICAR test string locally - no gRPC call is made.
      EICAR files are BLOCKED; all other files are ALLOWED.
      Use this for demos on networks where the FSS endpoint is unreachable.

Supported ICAP methods:
  OPTIONS  - capability discovery
  REQMOD   - request modification (scan uploads)
  RESPMOD  - response modification (scan response bodies)

Required pip package (live mode only):
  pip install visionone-filesecurity
"""

import os
import re
import sys
import json
import socket
import logging
import threading

# gRPC SDK - only needed in live mode; imported conditionally
try:
    import amaas.grpc
    GRPC_AVAILABLE = True
except ImportError:
    GRPC_AVAILABLE = False

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, "fss_config.json")


def load_config():
    # utf-8-sig handles UTF-8 BOM written by PowerShell 5.1
    with open(CONFIG_PATH, "r", encoding="utf-8-sig") as fh:
        return json.load(fh)


CFG = load_config()

LOG_PATH    = CFG.get("log_path", os.path.join(SCRIPT_DIR, "icap_server.log"))
ICAP_BIND   = CFG.get("icap_bind", "0.0.0.0")
ICAP_PORT   = int(CFG.get("icap_port", 1344))
API_KEY     = CFG.get("api_key", "")
FSS_GRPC    = CFG.get("fss_grpc_host", CFG.get("grpc_region", "us-east-1"))
MOCK_MODE   = bool(CFG.get("mock_mode", False))
SERVICE_VER = "Trend-FSS-ICAP-Bridge/3.0"

# EICAR test string signature - used by mock mode for detection
EICAR_SIGNATURE = b"EICAR-STANDARD-ANTIVIRUS-TEST-FILE"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_PATH, encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("fss_icap")

# ---------------------------------------------------------------------------
# ICAP Constants
# ---------------------------------------------------------------------------

ICAP_VER        = "ICAP/1.0"
ICAP_OK_LINE    = ICAP_VER + " 200 OK\r\n"
ICAP_BAD_REQ    = ICAP_VER + " 400 Bad Request\r\nEncapsulated: null-body=0\r\n\r\n"
ICAP_SERVER_ERR = ICAP_VER + " 500 Server Error\r\nEncapsulated: null-body=0\r\n\r\n"

MAX_RECV   = 8 * 1024 * 1024
RECV_CHUNK = 65536

OPTIONS_RESP = (
    ICAP_OK_LINE
    + "Methods: REQMOD, RESPMOD\r\n"
    + "Service: " + SERVICE_VER + "\r\n"
    + "Preview: 4096\r\n"
    + "Transfer-Preview: *\r\n"
    + "Max-Connections: 100\r\n"
    + "Options-TTL: 3600\r\n"
    + "Allow: 204\r\n"
    + "Encapsulated: null-body=0\r\n"
    + "\r\n"
)

# ---------------------------------------------------------------------------
# Socket helpers
# ---------------------------------------------------------------------------

def recv_all(sock):
    data = b""
    sock.settimeout(5.0)
    try:
        while len(data) < MAX_RECV:
            chunk = sock.recv(RECV_CHUNK)
            if not chunk:
                break
            data += chunk
            if b"\r\n\r\n" in data and len(data) > 256:
                try:
                    sock.settimeout(1.0)
                    while True:
                        extra = sock.recv(RECV_CHUNK)
                        if not extra:
                            break
                        data += extra
                except socket.timeout:
                    break
    except socket.timeout:
        pass
    return data


def dechunk(data):
    result = b""
    pos = 0
    while pos < len(data):
        crlf = data.find(b"\r\n", pos)
        if crlf == -1:
            result += data[pos:]
            break
        size_str = data[pos:crlf].decode("utf-8", errors="ignore").strip().split(";")[0].strip()
        try:
            chunk_size = int(size_str, 16)
        except ValueError:
            result += data[pos:]
            break
        if chunk_size == 0:
            break
        start = crlf + 2
        result += data[start : start + chunk_size]
        pos = start + chunk_size + 2
    return result


def extract_body(raw):
    header_end = raw.find(b"\r\n\r\n")
    if header_end == -1:
        return b""
    headers = raw[:header_end].decode("utf-8", errors="ignore")
    rest    = raw[header_end + 4:]

    enc_match = re.search(r"Encapsulated:\s*(.+)", headers, re.IGNORECASE)
    body_offset = None
    if enc_match:
        for part in enc_match.group(1).split(","):
            part = part.strip()
            if part.startswith(("req-body=", "res-body=", "opt-body=")):
                try:
                    body_offset = int(part.split("=")[1])
                except ValueError:
                    pass
                break

    if body_offset is not None and body_offset <= len(rest):
        body_data = rest[body_offset:]
    else:
        inner_end = rest.find(b"\r\n\r\n")
        body_data = rest[inner_end + 4:] if inner_end != -1 else rest

    return dechunk(body_data) if body_data else b""


# ---------------------------------------------------------------------------
# FSS scan
# ---------------------------------------------------------------------------

def scan_with_fss(file_bytes):
    """
    MOCK MODE : detects EICAR test string locally - no gRPC call is made.
    LIVE MODE : writes bytes to a temp file, scans via amaas.grpc.scan_file().
    Returns (is_malicious: bool, detail: str)
    """

    # --- MOCK MODE: local EICAR detection only, instant response ---
    if MOCK_MODE:
        if EICAR_SIGNATURE in file_bytes:
            log.warning("MOCK: EICAR signature detected - returning BLOCK verdict.")
            return True, "EICAR-STANDARD-ANTIVIRUS-TEST-FILE"
        log.info("MOCK: No threat signature found - returning ALLOW verdict.")
        return False, "clean"

    # --- LIVE MODE: real FSS gRPC scan ---
    tmp_path = None
    handle   = None
    try:
        # Plain open() avoids Windows NamedTemporaryFile exclusive-lock issues
        tmp_path = os.path.join(SCRIPT_DIR, "scan_" + os.urandom(8).hex() + ".tmp")
        with open(tmp_path, "wb") as _f:
            _f.write(file_bytes)

        log.debug("Temp file: %s (%d bytes)", tmp_path, len(file_bytes))

        handle     = amaas.grpc.init(FSS_GRPC, API_KEY, True)
        # SDK 1.4.x argument order: (channel, file_path)
        result_str = amaas.grpc.scan_file(handle, tmp_path)
        result     = json.loads(result_str)

        scan_result  = result.get("scanResult", 0)
        is_malicious = int(scan_result) > 0

        malware_name = ""
        found_list   = result.get("foundMalwares", [])
        if found_list and isinstance(found_list, list):
            malware_name = found_list[0].get("malwareName", "")

        detail = malware_name if malware_name else ("malicious" if is_malicious else "clean")
        log.info("Scan result: %s | detail: %s", scan_result, detail)
        return is_malicious, detail

    except Exception as exc:
        log.error("FSS gRPC scan error: %s", exc)
        return False, "scan_error"

    finally:
        if handle is not None:
            try:
                amaas.grpc.quit(handle)
            except Exception:
                pass
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except Exception:
                pass


# ---------------------------------------------------------------------------
# ICAP response builders
# ---------------------------------------------------------------------------

def build_allow_response():
    return (ICAP_VER + " 204 No Content\r\nConnection: keep-alive\r\n\r\n").encode()


def build_block_response(threat_detail):
    html = (
        "<html><head><title>Access Blocked</title></head><body>"
        "<h1 style='color:red'>[BLOCKED] Threat Detected by Trend Vision One</h1>"
        "<p><strong>Threat:</strong> " + threat_detail + "</p>"
        "<p>This file was blocked by Trend Vision One File Security.</p>"
        "<hr><small>Trend Micro ICAP Bridge - " + SERVICE_VER + "</small>"
        "</body></html>"
    ).encode("utf-8")

    chunked_body = format(len(html), "x").encode() + b"\r\n" + html + b"\r\n0\r\n\r\n"

    resp_header = (
        "HTTP/1.1 403 Forbidden\r\n"
        "Content-Type: text/html; charset=utf-8\r\n"
        "Content-Length: " + str(len(html)) + "\r\n\r\n"
    ).encode()

    icap_hdr = (
        ICAP_OK_LINE
        + "Connection: keep-alive\r\n"
        + "Encapsulated: res-hdr=0, res-body=" + str(len(resp_header)) + "\r\n\r\n"
    ).encode()

    return icap_hdr + resp_header + chunked_body


# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------

def handle_client(conn, addr):
    log.info("Connection from %s:%d", addr[0], addr[1])
    try:
        raw = recv_all(conn)
        if not raw:
            return

        first_line = raw.split(b"\r\n", 1)[0].decode("utf-8", errors="ignore")
        parts  = first_line.split(" ")
        method = parts[0].upper() if parts else "UNKNOWN"
        log.info("ICAP %s  (%d bytes total)", method, len(raw))

        if method == "OPTIONS":
            conn.sendall(OPTIONS_RESP.encode())
            log.info("Sent OPTIONS response.")

        elif method in ("REQMOD", "RESPMOD"):
            file_bytes = extract_body(raw)
            if not file_bytes:
                log.info("No body - allowing through.")
                conn.sendall(build_allow_response())
                return

            engine = "mock engine" if MOCK_MODE else "FSS gRPC"
            log.info("Scanning %d bytes via %s...", len(file_bytes), engine)
            is_malicious, detail = scan_with_fss(file_bytes)

            if is_malicious:
                log.warning("THREAT DETECTED [%s] - blocking.", detail)
                conn.sendall(build_block_response(detail))
            else:
                log.info("Clean (%s) - allowing.", detail)
                conn.sendall(build_allow_response())

        else:
            log.warning("Unsupported ICAP method: %s", method)
            conn.sendall(ICAP_BAD_REQ.encode())

    except Exception as exc:
        log.error("Client error %s: %s", addr, exc)
        try:
            conn.sendall(ICAP_SERVER_ERR.encode())
        except Exception:
            pass
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Server main loop
# ---------------------------------------------------------------------------

def main():
    log.info("=" * 60)
    log.info("Trend Vision One FSS ICAP Bridge v3 starting...")
    log.info("  ICAP bind   : %s:%d", ICAP_BIND, ICAP_PORT)
    if MOCK_MODE:
        log.warning("  Mode        : DEMO MOCK MODE (no FSS connection)")
        log.warning("  EICAR files -> BLOCKED | all other files -> ALLOWED")
        log.warning("  To switch to live mode: set mock_mode=false in fss_config.json")
    else:
        log.info("  Mode        : LIVE (FSS gRPC)")
        log.info("  FSS gRPC    : %s", FSS_GRPC)
        log.info("  Region      : %s", CFG.get("region", "unknown"))
        log.info("  SDK         : visionone-filesecurity (amaas.grpc)")
    log.info("=" * 60)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((ICAP_BIND, ICAP_PORT))
    srv.listen(50)
    log.info("Listening on port %d  (Ctrl+C to stop)", ICAP_PORT)

    while True:
        try:
            conn, addr = srv.accept()
            t = threading.Thread(target=handle_client, args=(conn, addr), daemon=True)
            t.start()
        except KeyboardInterrupt:
            log.info("Shutdown requested.")
            break
        except Exception as exc:
            log.error("Accept error: %s", exc)

    srv.close()
    log.info("ICAP server stopped.")


if __name__ == "__main__":
    main()
'@

# Write without BOM so Python can read the file cleanly
[System.IO.File]::WriteAllText($serverScriptPath, $pythonScript, [System.Text.UTF8Encoding]::new($false))
Write-Log "ICAP server script written to: $serverScriptPath" "SUCCESS"

# ---------------------------------------------------------------
#  STEP 8 - REGISTER AS PERSISTENT SERVICE
#  Method A: NSSM (if available)
#  Method B: Windows Task Scheduler (built-in, zero downloads needed)
# ---------------------------------------------------------------

Write-Log "=== STEP 8: Service Registration ===" "STEP"

$serviceName = "TrendFSSICAPBridge"
$taskName    = "TrendFSSICAPBridge"

# Resolve full Python executable path
$pythonExe = $null
$rawPath = (Get-Command $pythonCmd -ErrorAction SilentlyContinue).Source
if ($rawPath -and $rawPath -notmatch "\.bat$" -and (Test-Path $rawPath)) {
    $pythonExe = $rawPath
}
if (-not $pythonExe) {
    foreach ($p in @(
        "C:\Python311\python.exe",
        "C:\Program Files\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
    )) {
        if (Test-Path $p) { $pythonExe = $p; break }
    }
}
if (-not $pythonExe) {
    $found = where.exe python 2>$null | Select-Object -First 1
    if ($found) { $pythonExe = $found.Trim() }
}
Write-Log "Python executable: $pythonExe" "INFO"

# ---- Method A: NSSM Windows Service ----
if ($nssmExe -and $pythonExe) {
    Write-Log "Registering Windows service via NSSM..." "INFO"

    # Remove stale service first
    $existingSvc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($existingSvc) {
        Write-Log "Removing existing service '$serviceName'..." "WARNING"
        & $nssmExe stop   $serviceName 2>$null
        & $nssmExe remove $serviceName confirm 2>$null
        Start-Sleep -Seconds 2
    }

    & $nssmExe install $serviceName $pythonExe $serverScriptPath
    & $nssmExe set     $serviceName AppDirectory  $InstallPath
    & $nssmExe set     $serviceName DisplayName   "Trend Vision One FSS ICAP Bridge"
    & $nssmExe set     $serviceName Description   "ICAP server bridge for Trend Vision One File Storage Security"
    & $nssmExe set     $serviceName Start         SERVICE_AUTO_START
    & $nssmExe set     $serviceName AppStdout     "$InstallPath\service_stdout.log"
    & $nssmExe set     $serviceName AppStderr     "$InstallPath\service_stderr.log"
    & $nssmExe set     $serviceName AppRotateFiles 1
    & $nssmExe set     $serviceName AppRotateBytes 10485760
    Write-Log "Service '$serviceName' registered via NSSM." "SUCCESS"

# ---- Method B: Task Scheduler (no NSSM required) ----
} elseif ($pythonExe) {
    Write-Log "NSSM not available - using Windows Task Scheduler instead." "INFO"

    # Remove stale task if present
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    $action    = New-ScheduledTaskAction `
                     -Execute $pythonExe `
                     -Argument $serverScriptPath `
                     -WorkingDirectory $InstallPath
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $settings  = New-ScheduledTaskSettingsSet `
                     -StartWhenAvailable `
                     -RestartCount 3 `
                     -RestartInterval (New-TimeSpan -Minutes 1) `
                     -ExecutionTimeLimit ([TimeSpan]::Zero)
    $principal = New-ScheduledTaskPrincipal `
                     -UserId "SYSTEM" `
                     -LogonType ServiceAccount `
                     -RunLevel Highest

    Register-ScheduledTask `
        -TaskName  $taskName `
        -Action    $action `
        -Trigger   $trigger `
        -Settings  $settings `
        -Principal $principal `
        -Description "Trend Vision One FSS ICAP Bridge - auto-start on boot" `
        -Force | Out-Null

    Write-Log "Task '$taskName' registered in Task Scheduler (runs as SYSTEM on startup)." "SUCCESS"
    Write-Log "To manage: Get-ScheduledTask -TaskName '$taskName'" "INFO"

} else {
    Write-Log "Cannot register service - Python path not resolved." "WARNING"
    Write-Log "Start manually: python $serverScriptPath" "INFO"
}

# ---------------------------------------------------------------
#  STEP 9 - WINDOWS FIREWALL RULE
# ---------------------------------------------------------------

Write-Log "=== STEP 9: Windows Firewall Rule ===" "STEP"

$ruleName    = "Trend FSS ICAP Port $ICAPPort"
$existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

if ($existingRule) {
    Write-Log "Firewall rule '$ruleName' already exists." "INFO"
} else {
    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Direction   Inbound `
        -Protocol    TCP `
        -LocalPort   $ICAPPort `
        -Action      Allow `
        -Profile     Any `
        -Description "Trend Vision One FSS ICAP Bridge inbound ICAP traffic" | Out-Null
    Write-Log "Firewall rule created: TCP inbound port $ICAPPort" "SUCCESS"
}

# ---------------------------------------------------------------
#  STEP 10 - START THE ICAP SERVER
# ---------------------------------------------------------------

Write-Log "=== STEP 10: Starting ICAP Server ===" "STEP"

if (-not $useTaskScheduler) {
    # NSSM Windows Service
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($svc) {
        Start-Service -Name $serviceName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        $svc.Refresh()
        if ($svc.Status -eq "Running") {
            Write-Log "Service '$serviceName' is RUNNING." "SUCCESS"
        } else {
            Write-Log "Service status: $($svc.Status). Check $InstallPath\service_stderr.log" "WARNING"
        }
    } else {
        Write-Log "Service not found - starting Python directly in background..." "WARNING"
        Start-Process -FilePath $pythonExe -ArgumentList $serverScriptPath -WindowStyle Hidden
        Start-Sleep -Seconds 2
        Write-Log "Python ICAP server launched in background." "INFO"
    }
} else {
    # Task Scheduler
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 3
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        Write-Log "Task '$taskName' triggered. Last run: $($taskInfo.LastRunTime)" "SUCCESS"
        Write-Log "The server will also auto-start on every reboot." "INFO"
    } else {
        Write-Log "Scheduled task not found - starting Python directly in background..." "WARNING"
        Start-Process -FilePath $pythonExe -ArgumentList $serverScriptPath -WindowStyle Hidden
        Start-Sleep -Seconds 2
        Write-Log "Python ICAP server launched in background." "INFO"
    }
}

# ---------------------------------------------------------------
#  STEP 11 - VERIFY PORT IS LISTENING
# ---------------------------------------------------------------

Write-Log "=== STEP 11: Port Verification ===" "STEP"

Start-Sleep -Seconds 2
$listener = netstat -ano | Select-String ":$ICAPPort\s"
if ($listener) {
    Write-Log "Port $ICAPPort is listening - ICAP server is up." "SUCCESS"
} else {
    Write-Log "Port $ICAPPort is NOT listening yet. Server may still be starting." "WARNING"
    Write-Log "Check: $InstallPath\icap_server.log" "INFO"
}

# ---------------------------------------------------------------
#  SUMMARY
# ---------------------------------------------------------------

Write-Host ""
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Green
Write-Host "|                      SETUP COMPLETE                         |" -ForegroundColor Green
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Green
Write-Host ""
Write-Host "  ICAP Endpoint : icap://$(hostname):$ICAPPort/scan" -ForegroundColor White
Write-Host "  FSS Region    : $Region ($fssEndpoint)" -ForegroundColor White
Write-Host "  Install Path  : $InstallPath" -ForegroundColor White
Write-Host "  Service Name  : $serviceName" -ForegroundColor White
Write-Host "  Server Log    : $InstallPath\icap_server.log" -ForegroundColor White
if ($MockMode) {
    Write-Host "  Scan Mode     : DEMO MOCK (EICAR blocked, all other files allowed)" -ForegroundColor Yellow
    Write-Host "                  No FSS gRPC connection is required in this mode." -ForegroundColor Yellow
} else {
    Write-Host "  Scan Mode     : LIVE (FSS gRPC via $fssEndpoint)" -ForegroundColor White
}
Write-Host ""
Write-Host "  Next Steps:" -ForegroundColor Cyan
Write-Host "    1. Run the test script:" -ForegroundColor White
Write-Host "       .\Test-FSS-ICAP.ps1 -ICAPHost 127.0.0.1 -ICAPPort $ICAPPort" -ForegroundColor Yellow
Write-Host "    2. Point your ICAP client/proxy to:" -ForegroundColor White
Write-Host "       icap://$(hostname):$ICAPPort/scan" -ForegroundColor Yellow
Write-Host "    3. Monitor activity:" -ForegroundColor White
Write-Host "       Get-Content '$InstallPath\icap_server.log' -Wait" -ForegroundColor Yellow
Write-Host ""
Write-Log "Setup complete. Full log: $InstallPath\setup.log" "SUCCESS"
