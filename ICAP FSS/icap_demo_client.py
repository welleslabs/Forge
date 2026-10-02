#!/usr/bin/env python3
"""
Trend Vision One File Security - ICAP Web Demo Client
------------------------------------------------------
Runs a local web server with a browser UI for scanning files
through the ICAP bridge and Trend Vision One File Security.

Usage:
    python3 icap_demo_client.py --icap-host <server-ip>
    python3 icap_demo_client.py --icap-host <server-ip> --icap-port 1344 --port 8080

Then open http://localhost:8080 in your browser.
No extra packages required - uses Python standard library only.
"""

import argparse
import json
import re
import socket
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

DEFAULT_ICAP_PORT = 1344
DEFAULT_WEB_PORT  = 8080

# ---------------------------------------------------------------------------
# ICAP Client
# ---------------------------------------------------------------------------

def build_icap_reqmod(file_bytes, filename, icap_host, icap_port):
    http_req = (
        "POST /upload HTTP/1.1\r\n"
        "Host: demo.example.com\r\n"
        "Content-Type: application/octet-stream\r\n"
        "Content-Disposition: attachment; filename=\"" + filename + "\"\r\n"
        "Content-Length: " + str(len(file_bytes)) + "\r\n"
        "\r\n"
    )
    http_req_bytes = http_req.encode("utf-8")
    body_offset    = len(http_req_bytes)

    chunked_body = (
        format(len(file_bytes), "x").encode() + b"\r\n"
        + file_bytes
        + b"\r\n0\r\n\r\n"
    )

    icap_header = (
        "REQMOD icap://" + icap_host + ":" + str(icap_port) + "/scan ICAP/1.0\r\n"
        "Host: " + icap_host + ":" + str(icap_port) + "\r\n"
        "Connection: close\r\n"
        "Encapsulated: req-hdr=0, req-body=" + str(body_offset) + "\r\n"
        "\r\n"
    )

    return icap_header.encode("utf-8") + http_req_bytes + chunked_body


def scan_via_icap(file_bytes, filename, icap_host, icap_port, timeout=20):
    """Send file bytes to ICAP server. Returns (verdict, detail)."""
    try:
        request = build_icap_reqmod(file_bytes, filename, icap_host, icap_port)

        tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tcp.settimeout(timeout)
        tcp.connect((icap_host, icap_port))
        tcp.sendall(request)

        response = b""
        tcp.settimeout(5.0)
        try:
            while True:
                chunk = tcp.recv(65536)
                if not chunk:
                    break
                response += chunk
        except socket.timeout:
            pass
        tcp.close()

        if not response:
            return "error", "No response from ICAP server"

        first_line = response.split(b"\r\n")[0].decode("utf-8", errors="ignore")

        if "ICAP/1.0 204" in first_line:
            return "clean", "No threats detected"

        if "ICAP/1.0 200" in first_line:
            resp_str = response.decode("utf-8", errors="ignore")
            m = re.search(r"<strong>Threat:</strong>\s*([^<]+)", resp_str)
            threat = m.group(1).strip() if m else "Threat detected"
            return "blocked", threat

        return "error", "Unexpected response: " + first_line

    except ConnectionRefusedError:
        return "error", "Cannot connect to " + icap_host + ":" + str(icap_port) + " - is the server running?"
    except socket.timeout:
        return "error", "Connection timed out - check ICAP host and port"
    except Exception as exc:
        return "error", str(exc)


def parse_multipart(body, boundary):
    """Parse multipart/form-data. Returns (filename, file_bytes) or (None, None)."""
    delimiter = ("--" + boundary).encode()
    for part in body.split(delimiter)[1:]:
        if part.strip() in (b"--", b"--\r\n", b""):
            continue
        header_end = part.find(b"\r\n\r\n")
        if header_end == -1:
            continue
        headers = part[:header_end].decode("utf-8", errors="ignore")
        data    = part[header_end + 4:]
        if data.endswith(b"\r\n"):
            data = data[:-2]
        m = re.search(r'filename="([^"]*)"', headers)
        if m:
            return m.group(1) or "upload.bin", data
    return None, None


# ---------------------------------------------------------------------------
# HTML Page
# ---------------------------------------------------------------------------

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Trend Vision One - File Security Demo</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0d1117;color:#e6edf3;min-height:100vh}
header{background:#161b22;border-bottom:1px solid #30363d;padding:16px 32px;display:flex;align-items:center;gap:14px}
.logo{width:36px;height:36px;flex-shrink:0}
.logo-text h1{font-size:17px;font-weight:600;color:#fff}
.logo-text span{font-size:13px;color:#8b949e}
.badge{margin-left:auto;background:#21262d;border:1px solid #30363d;border-radius:20px;padding:5px 14px;font-size:12px;color:#8b949e;white-space:nowrap}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#3fb950;margin-right:6px}
main{max-width:780px;margin:40px auto;padding:0 20px}
.card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:28px;margin-bottom:20px}
.card h2{font-size:15px;font-weight:600;margin-bottom:6px}
.card>p{font-size:13px;color:#8b949e;line-height:1.6;margin-bottom:22px}
.drop-zone{border:2px dashed #30363d;border-radius:8px;padding:44px 20px;text-align:center;cursor:pointer;transition:.2s;position:relative}
.drop-zone:hover,.drop-zone.over{border-color:#d63f3f;background:rgba(214,63,63,.05)}
.drop-zone input{position:absolute;inset:0;opacity:0;cursor:pointer;width:100%;height:100%}
.drop-icon{font-size:36px;margin-bottom:10px}
.drop-zone h3{font-size:14px;font-weight:500;margin-bottom:4px}
.drop-zone small{font-size:12px;color:#8b949e}
.file-row{display:none;align-items:center;gap:12px;background:#21262d;border:1px solid #30363d;border-radius:8px;padding:12px 14px;margin-top:14px}
.file-row.show{display:flex}
.file-icon{font-size:22px}
.file-name{font-size:13px;font-weight:500}
.file-size{font-size:12px;color:#8b949e;margin-top:2px}
.scan-btn{width:100%;margin-top:14px;padding:11px;background:#d63f3f;color:#fff;border:none;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer;display:none;transition:.2s}
.scan-btn.show{display:block}
.scan-btn:hover{background:#b83333}
.scan-btn:disabled{background:#6e3333;cursor:not-allowed}
.spinner-wrap{display:none;text-align:center;padding:24px}
.spinner-wrap.show{display:block}
.spinner{width:44px;height:44px;border:3px solid #30363d;border-top-color:#d63f3f;border-radius:50%;animation:spin .7s linear infinite;margin:0 auto 12px}
@keyframes spin{to{transform:rotate(360deg)}}
.spinner-wrap p{font-size:13px;color:#8b949e}
.result{display:none;border-radius:8px;padding:24px;text-align:center;margin-top:14px}
.result.show{display:block}
.result.clean{background:rgba(63,185,80,.08);border:1px solid rgba(63,185,80,.25)}
.result.blocked{background:rgba(214,63,63,.08);border:1px solid rgba(214,63,63,.25)}
.result.error{background:rgba(210,153,34,.08);border:1px solid rgba(210,153,34,.25)}
.result-icon{font-size:44px;margin-bottom:10px}
.result h3{font-size:20px;font-weight:700;margin-bottom:6px}
.result.clean h3{color:#3fb950}
.result.blocked h3{color:#d63f3f}
.result.error h3{color:#d29522}
.result .sub{font-size:13px;color:#8b949e;margin-bottom:12px}
.threat-pill{display:inline-block;background:rgba(214,63,63,.15);border:1px solid rgba(214,63,63,.35);color:#f47067;border-radius:20px;padding:4px 16px;font-size:12px;font-weight:500;font-family:monospace}
.reset-btn{margin-top:14px;background:transparent;border:1px solid #30363d;color:#8b949e;border-radius:6px;padding:7px 18px;font-size:12px;cursor:pointer;transition:.2s}
.reset-btn:hover{border-color:#8b949e;color:#e6edf3}
.endpoint{background:#21262d;border-radius:6px;padding:8px 12px;font-size:11px;color:#8b949e;font-family:monospace;margin-top:16px}
table{width:100%;border-collapse:collapse;font-size:13px}
th{text-align:left;padding:8px 10px;color:#8b949e;font-weight:500;border-bottom:1px solid #30363d}
td{padding:9px 10px;border-bottom:1px solid #21262d;vertical-align:middle}
tr:last-child td{border-bottom:none}
.v-clean{color:#3fb950;font-weight:600}
.v-blocked{color:#d63f3f;font-weight:600}
.v-error{color:#d29522;font-weight:600}
.empty{text-align:center;color:#8b949e;padding:24px;font-size:13px}
</style>
</head>
<body>
<header>
  <svg class="logo" viewBox="0 0 36 36" fill="none">
    <rect width="36" height="36" rx="8" fill="#D63F3F"/>
    <path d="M18 8L28 14V22L18 28L8 22V14Z" fill="white" opacity=".9"/>
    <path d="M18 13L23 16V22L18 25L13 22V16Z" fill="#D63F3F"/>
  </svg>
  <div class="logo-text">
    <h1>Trend Vision One</h1>
    <span>File Security &mdash; ICAP Demo</span>
  </div>
  <div class="badge"><span class="dot"></span>ICAP Bridge Active</div>
</header>

<main>
  <div class="card">
    <h2>Scan a File</h2>
    <p>Upload any file to scan it through the ICAP bridge and Trend Vision One File Security.
       Clean files are allowed through instantly. Malicious files are blocked and the threat name is shown.</p>

    <div class="drop-zone" id="dz">
      <input type="file" id="fi" onchange="onPick(this.files[0])">
      <div class="drop-icon">&#128196;</div>
      <h3>Drop a file here or click to browse</h3>
      <small>Any file type &mdash; try the EICAR test file to see a block</small>
    </div>

    <div class="file-row" id="fr">
      <span class="file-icon">&#128196;</span>
      <div>
        <div class="file-name" id="fn"></div>
        <div class="file-size" id="fs"></div>
      </div>
    </div>

    <button class="scan-btn" id="sb" onclick="doScan()">Scan with Vision One FSS</button>

    <div class="spinner-wrap" id="sw">
      <div class="spinner"></div>
      <p>Sending to ICAP bridge &rarr; Vision One FSS&hellip;</p>
    </div>

    <div class="result" id="rv">
      <div class="result-icon" id="ri"></div>
      <h3 id="rt"></h3>
      <div class="sub" id="rd"></div>
      <div class="threat-pill" id="rp" style="display:none"></div>
      <br>
      <button class="reset-btn" onclick="reset()">Scan another file</button>
    </div>

    <div class="endpoint" id="ep"></div>
  </div>

  <div class="card">
    <h2>Scan History</h2>
    <div id="hist"><div class="empty">No scans yet &mdash; upload a file above to get started.</div></div>
  </div>
</main>

<script>
var HOST="%%ICAP_HOST%%", PORT=%%ICAP_PORT%%;
var selectedFile=null, scanLog=[];

document.getElementById("ep").textContent="ICAP endpoint: icap://"+HOST+":"+PORT+"/scan";

var dz=document.getElementById("dz");
dz.addEventListener("dragover",function(e){e.preventDefault();dz.classList.add("over")});
dz.addEventListener("dragleave",function(){dz.classList.remove("over")});
dz.addEventListener("drop",function(e){
  e.preventDefault();dz.classList.remove("over");
  if(e.dataTransfer.files[0])onPick(e.dataTransfer.files[0]);
});

function onPick(f){
  selectedFile=f;
  document.getElementById("fn").textContent=f.name;
  document.getElementById("fs").textContent=fmtBytes(f.size);
  document.getElementById("fr").classList.add("show");
  document.getElementById("sb").classList.add("show");
  document.getElementById("rv").className="result";
  document.getElementById("sw").classList.remove("show");
}

function fmtBytes(b){
  if(b<1024)return b+" B";
  if(b<1048576)return (b/1024).toFixed(1)+" KB";
  return (b/1048576).toFixed(1)+" MB";
}

async function doScan(){
  if(!selectedFile)return;
  document.getElementById("sb").disabled=true;
  document.getElementById("sw").classList.add("show");
  document.getElementById("rv").className="result";
  var fd=new FormData();
  fd.append("file",selectedFile);
  try{
    var r=await fetch("/scan",{method:"POST",body:fd});
    var d=await r.json();
    showResult(d);
    addToLog(selectedFile.name,selectedFile.size,d);
  }catch(e){
    showResult({verdict:"error",detail:"Request failed: "+e.message});
  }
  document.getElementById("sw").classList.remove("show");
  document.getElementById("sb").disabled=false;
}

function showResult(d){
  var el=document.getElementById("rv");
  var icons={clean:"&#9989;",blocked:"&#9940;",error:"&#9888;"};
  var titles={clean:"File Allowed",blocked:"File Blocked",error:"Scan Error"};
  el.className="result show "+(d.verdict||"error");
  document.getElementById("ri").innerHTML=icons[d.verdict]||icons.error;
  document.getElementById("rt").textContent=titles[d.verdict]||titles.error;
  var pill=document.getElementById("rp");
  if(d.verdict==="blocked"){
    document.getElementById("rd").textContent=(selectedFile?selectedFile.name+" was":"File was")+" blocked by Vision One File Security.";
    pill.textContent=d.detail;
    pill.style.display="inline-block";
  }else{
    document.getElementById("rd").textContent=d.detail;
    pill.style.display="none";
  }
}

function addToLog(name,size,d){
  scanLog.unshift({name:name,size:size,d:d,time:new Date().toLocaleTimeString()});
  var rows=scanLog.map(function(s){
    var cls=s.d.verdict==="clean"?"v-clean":s.d.verdict==="blocked"?"v-blocked":"v-error";
    var label=s.d.verdict==="clean"?"ALLOWED":s.d.verdict==="blocked"?"BLOCKED":"ERROR";
    var threat=s.d.verdict==="blocked"?s.d.detail:"";
    return "<tr><td>"+s.time+"</td><td>"+s.name+"</td><td>"+fmtBytes(s.size)+"</td>"
      +"<td class='"+cls+"'>"+label+"</td>"
      +"<td style='color:#8b949e;font-family:monospace;font-size:12px'>"+threat+"</td></tr>";
  }).join("");
  document.getElementById("hist").innerHTML=
    "<table><thead><tr><th>Time</th><th>File</th><th>Size</th><th>Verdict</th><th>Threat</th></tr></thead>"
    +"<tbody>"+rows+"</tbody></table>";
}

function reset(){
  selectedFile=null;
  document.getElementById("fi").value="";
  document.getElementById("fr").classList.remove("show");
  document.getElementById("sb").classList.remove("show");
  document.getElementById("rv").className="result";
}
</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------

class DemoHandler(BaseHTTPRequestHandler):

    icap_host = "127.0.0.1"
    icap_port = 1344

    def log_message(self, fmt, *args):
        pass  # suppress default access log

    def do_GET(self):
        page = (HTML_TEMPLATE
                .replace("%%ICAP_HOST%%", self.icap_host)
                .replace("%%ICAP_PORT%%", str(self.icap_port)))
        data = page.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/scan":
            self.send_response(404)
            self.end_headers()
            return

        content_type   = self.headers.get("Content-Type", "")
        content_length = int(self.headers.get("Content-Length", 0))
        body           = self.rfile.read(content_length)

        boundary = ""
        for part in content_type.split(";"):
            part = part.strip()
            if part.startswith("boundary="):
                boundary = part[9:].strip('"')
                break

        filename, file_bytes = parse_multipart(body, boundary) if boundary else (None, None)

        if not file_bytes:
            result = {"verdict": "error", "detail": "No file data received"}
        else:
            verdict, detail = scan_via_icap(
                file_bytes, filename or "upload.bin",
                self.icap_host, self.icap_port
            )
            result = {"verdict": verdict, "detail": detail}
            label  = "ALLOWED" if verdict == "clean" else "BLOCKED" if verdict == "blocked" else "ERROR"
            print(f"  [{label:7s}] {filename}  ({len(file_bytes):,} bytes)  {detail}")

        resp = json.dumps(result).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Trend Vision One FSS - ICAP Web Demo Client"
    )
    parser.add_argument(
        "--icap-host", required=True,
        help="IP or hostname of the ICAP server (Windows box)"
    )
    parser.add_argument(
        "--icap-port", type=int, default=DEFAULT_ICAP_PORT,
        help=f"ICAP server port (default: {DEFAULT_ICAP_PORT})"
    )
    parser.add_argument(
        "--port", type=int, default=DEFAULT_WEB_PORT,
        help=f"Local web UI port (default: {DEFAULT_WEB_PORT})"
    )
    args = parser.parse_args()

    DemoHandler.icap_host = args.icap_host
    DemoHandler.icap_port = args.icap_port

    print()
    print("+--------------------------------------------------------------+")
    print("|   Trend Vision One FSS - ICAP Web Demo Client               |")
    print("+--------------------------------------------------------------+")
    print(f"  ICAP server  :  icap://{args.icap_host}:{args.icap_port}/scan")
    print(f"  Browser UI   :  http://localhost:{args.port}")
    print()
    print("  Open the URL above in your browser, then upload a file.")
    print("  Press Ctrl+C to stop.")
    print()

    server = HTTPServer(("0.0.0.0", args.port), DemoHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  Stopped.")
        sys.exit(0)


if __name__ == "__main__":
    main()
