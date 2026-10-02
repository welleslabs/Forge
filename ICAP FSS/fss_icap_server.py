#!/usr/bin/env python3
"""
Trend Vision One File Security - ICAP Bridge Server v3
-------------------------------------------------------
Two modes controlled by fss_config.json "mock_mode" key:

  LIVE MODE  (mock_mode: false)
      Scans via Vision One FSS gRPC SDK (visionone-filesecurity).
      Requires outbound TCP 443 to antimalware.*.cloudone.trendmicro.com.

  MOCK MODE  (mock_mode: true)
      Detects the EICAR test string locally - no gRPC call is made.
      EICAR files are BLOCKED; all other files are ALLOWED.
      Use for demos on networks where the FSS endpoint is unreachable.

Supported ICAP methods: OPTIONS, REQMOD, RESPMOD
"""

import os
import re
import sys
import json
import socket
import logging
import threading

# gRPC SDK - only needed in live mode
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

# EICAR test string signature - used by mock mode for local detection
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

    # --- MOCK MODE: instant local detection, no network required ---
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
