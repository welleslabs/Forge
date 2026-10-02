#!/usr/bin/env python3
"""
Trend Vision One - Code & Container Security scanner (Forge demo engine, MOCK)

Offline stand-in for the two live tmas scans of the Nimbus AI Chat Service:
  scan-code    Code Security scan — pinned dependencies (requirements.txt) vs
               data/cve-db.json, plus static source analysis of app.py
               (secrets, unsafe eval, insecure pickle, disabled TLS).
  scan-image   Container Image scan — Dockerfile hardening lint (pass/fail rules).

The two modes mirror the two buttons: in Live mode "Scan Code & Dependencies"
runs a real tmas source scan and "Audit Container Image" scans the built image;
this engine is the offline fallback. Each mode writes $LAB/findings-<mode>.json.

Python 3.9-compatible, stdlib only. Never executes the app.
"""

import json
import os
import re
import sys
from datetime import datetime, timezone

# ----------------------------------------------------------------------------
# Environment / paths (single workload: the Python chat service)
# ----------------------------------------------------------------------------
LAB = os.environ.get("LAB")
if not LAB:
    sys.stderr.write("error: LAB environment variable is not set\n")
    sys.exit(2)

APP_DIR = os.path.join(LAB, "app")
DATA_DIR = os.path.join(LAB, "data")
APP_PY = os.path.join(APP_DIR, "app.py")
REQS = os.path.join(APP_DIR, "requirements.txt")
DOCKERFILE = os.path.join(APP_DIR, "Dockerfile")
CVE_DB = os.path.join(DATA_DIR, "cve-db.json")

WIDTH = 92
SEV_ORDER = ["critical", "high", "medium", "low"]
SEV_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3}
SEV_LABEL = {"critical": "CRITICAL", "high": "HIGH", "medium": "MEDIUM", "low": "LOW"}


# ----------------------------------------------------------------------------
# Output helpers (plain unicode, no ANSI)
# ----------------------------------------------------------------------------
def out(line=""):
    print(line, flush=True)


def hr(char="─"):
    out(char * WIDTH)


def wrap(text, indent, first_indent=None):
    if first_indent is None:
        first_indent = indent
    lines, cur, started = [], first_indent, False
    for w in text.split():
        candidate = (cur + " " + w) if started else (cur + w)
        if len(candidate) > WIDTH and started:
            lines.append(cur)
            cur = indent + w
        else:
            cur = candidate
        started = True
    if started:
        lines.append(cur)
    return lines


def emit_wrapped(label, text):
    prefix = "    " + label + " : "
    cont = " " * len(prefix)
    for ln in wrap(text, cont, prefix):
        out(ln)


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def die(msg):
    sys.stderr.write("error: " + msg + "\n")
    sys.exit(1)


def _read_lines(path):
    with open(path, "r") as fh:
        return fh.read().splitlines()


# ----------------------------------------------------------------------------
# Findings store (one file per mode; rewriting is idempotent)
# ----------------------------------------------------------------------------
def assign_ids(findings):
    for n, f in enumerate(findings, start=1):
        f["id"] = "CCS-%03d" % n
    return findings


def summarize(findings):
    s = {"critical": 0, "high": 0, "medium": 0, "low": 0}
    for f in findings:
        if f.get("severity") in s:
            s[f["severity"]] += 1
    return s


def write_findings(mode, findings):
    findings = sorted(findings, key=lambda f: (SEV_RANK.get(f.get("severity"), 9), f.get("id", "")))
    path = os.path.join(LAB, "findings-%s.json" % mode)
    doc = {
        "lab": "code-container",
        "mode": mode,
        "generated": now_iso(),
        "summary": summarize(findings),
        "findings": findings,
    }
    with open(path, "w") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    return doc, path


def render_findings_table(findings):
    subset = sorted(findings, key=lambda f: (SEV_RANK.get(f.get("severity"), 9), f.get("id", "")))
    if not subset:
        out("No findings.")
        return
    for sev in SEV_ORDER:
        group = [f for f in subset if f.get("severity") == sev]
        if not group:
            continue
        out()
        out("%s  (%d)" % (SEV_LABEL[sev], len(group)))
        hr("─")
        for f in group:
            out("%s  ● %s" % (f["id"], f["title"]))
            if f.get("category") == "dependency":
                emit_wrapped("fix     ", f.get("fix", "-"))
            else:
                out("    resource : %s" % f.get("file", "-"))
                emit_wrapped("detail  ", f.get("detail", "-"))
                emit_wrapped("fix     ", f.get("fix", "-"))


def render_summary(doc, report_path):
    out()
    hr()
    out("Scan summary")
    s = doc["summary"]
    out("  critical %d   high %d   medium %d   low %d   (total %d)"
        % (s["critical"], s["high"], s["medium"], s["low"], sum(s.values())))
    home = os.environ.get("HOME", "")
    if home and report_path.startswith(home):
        report_path = "~" + report_path[len(home):]
    out("  report: " + report_path)


# ----------------------------------------------------------------------------
# Dependency parsing / CVE matching
# ----------------------------------------------------------------------------
def parse_requirements(path):
    deps = []
    for raw in _read_lines(path):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([A-Za-z0-9_.\-]+)\s*==\s*([A-Za-z0-9_.\-]+)", line)
        if m:
            deps.append((m.group(1).lower(), m.group(2)))
    return deps


def scan_dependencies():
    deps = parse_requirements(REQS)
    with open(CVE_DB, "r") as fh:
        records = json.load(fh).get("records", [])
    by_key = {}
    for r in records:
        by_key.setdefault((r["package"].lower(), r["affected_version"]), []).append(r)

    findings, clean = [], []
    vuln_pkgs = total_cves = 0
    for pkg, ver in deps:
        matches = [m for m in by_key.get((pkg, ver), []) if m.get("severity") in SEV_RANK]
        if not matches:
            clean.append((pkg, ver))
            continue
        vuln_pkgs += 1
        for m in sorted(matches, key=lambda x: SEV_RANK.get(x["severity"], 9)):
            total_cves += 1
            fix = m.get("fixed_in") or "an upstream patched release"
            findings.append({
                "severity": m["severity"],
                "title": "%s %s — %s (CVSS %s)" % (pkg, ver, m["cve"], m.get("cvss", "?")),
                "category": "dependency",
                "file": "app/requirements.txt",
                "detail": m.get("summary", "").strip(),
                "fix": "Upgrade %s to %s or later." % (pkg, fix),
            })
    stats = {"deps": len(deps), "clean": clean, "vuln_pkgs": vuln_pkgs, "cves": total_cves}
    return findings, stats


# ----------------------------------------------------------------------------
# Static source analysis of app.py
# ----------------------------------------------------------------------------
def scan_source():
    lines = _read_lines(APP_PY)
    findings = []
    secret_patterns = [
        (re.compile(r"sk-live-[A-Za-z0-9]{16,}"), "provider live API key"),
        (re.compile(r"AKIA[0-9A-Z]{16}"), "AWS access key id"),
        (re.compile(r"(?i)(secret|api[_-]?key|token)\s*=\s*[\"'][^\"']{12,}[\"']"),
         "hardcoded credential assignment"),
    ]
    seen = set()
    for i, line in enumerate(lines, start=1):
        for rx, label in secret_patterns:
            if rx.search(line) and i not in seen:
                seen.add(i)
                findings.append({
                    "severity": "critical",
                    "title": "Hardcoded secret in source (%s)" % label,
                    "category": "code",
                    "file": "app/app.py:%d" % i,
                    "detail": "A long-lived credential is embedded directly in source and will be "
                    "committed to version control and baked into every build artifact.",
                    "fix": "Remove the literal, rotate the exposed key, and load secrets at runtime "
                    "from a secrets manager or injected env var.",
                })
                break

    def flag(rx, sev, title, detail, fix):
        hit = False
        for i, line in enumerate(lines, start=1):
            if re.search(rx, line):
                hit = True
                findings.append({"severity": sev, "title": title, "category": "code",
                                 "file": "app/app.py:%d" % i, "detail": detail, "fix": fix})
        return hit

    c_eval = flag(r"\beval\s*\(", "critical",
                  "Arbitrary code execution via eval() on model output",
                  "Model-generated text is passed to eval(). A prompt-injected response can execute "
                  "arbitrary Python in the service process.",
                  "Never eval() untrusted text. Use ast.literal_eval for data or a sandboxed "
                  "arithmetic parser for expressions.")
    c_pickle = flag(r"pickle\.load[s]?\s*\(", "high",
                    "Insecure deserialization with pickle",
                    "pickle deserializes arbitrary objects and will run code embedded in a crafted "
                    "payload. One call reads an uploaded blob directly from a request.",
                    "Do not unpickle untrusted input. Use a safe format (JSON, or a signed/validated "
                    "model loader) for model weights and request bodies.")
    c_tls = flag(r"verify\s*=\s*False", "high",
                 "TLS certificate verification disabled",
                 "An HTTPS request is made with verify=False, disabling certificate validation and "
                 "exposing the model call to man-in-the-middle interception, including the token.",
                 "Enable verification. Distribute the internal CA bundle and pass "
                 "verify=/path/to/ca.pem instead of disabling it.")
    checks = [
        ("Hardcoded secrets", any(f["title"].startswith("Hardcoded secret") for f in findings)),
        ("Unsafe eval on model output", c_eval),
        ("Insecure deserialization (pickle)", c_pickle),
        ("TLS verification disabled", c_tls),
    ]
    return findings, checks


# ----------------------------------------------------------------------------
# Dockerfile linter
# ----------------------------------------------------------------------------
def lint_dockerfile():
    lines = _read_lines(DOCKERFILE)
    text_lines = [(i, ln) for i, ln in enumerate(lines, start=1)]
    findings, results = [], []

    def add(sev, title, line_no, detail, fix):
        findings.append({"severity": sev, "title": title, "category": "container",
                         "file": ("app/Dockerfile:%d" % line_no) if line_no else "app/Dockerfile",
                         "detail": detail, "fix": fix})

    def find_line(rx):
        for i, ln in text_lines:
            if re.search(rx, ln):
                return i, ln
        return None, None

    ln, _ = find_line(r"^\s*FROM\s+\S+:latest\b")
    if ln is None:
        ln, _ = find_line(r"^\s*FROM\s+[^:@\s]+\s*$")
    if ln:
        results.append(("DL-01", "Base image is pinned to a digest or fixed tag", False))
        add("high", "Unpinned base image (floating tag)", ln,
            "FROM uses a floating tag, so rebuilds are non-reproducible and can silently pull in a "
            "new, unvetted base with fresh vulnerabilities.",
            "Pin to an immutable tag and digest, e.g. FROM <image>:<version>@sha256:<digest>.")
    else:
        results.append(("DL-01", "Base image is pinned to a digest or fixed tag", True))

    secret_env_lines = [i for i, ln in text_lines
                        if re.match(r"^\s*ENV\b", ln)
                        and re.search(r"(?i)(API_KEY|SECRET|TOKEN|PASSWORD|sk-live-|AKIA)", ln)]
    if secret_env_lines:
        results.append(("DL-02", "No secrets baked into image layers", False))
        for i in secret_env_lines:
            add("critical", "Secret baked into image via ENV", i,
                "A credential is written into an ENV instruction. It persists in the image history "
                "and is readable by anyone who can pull the image.",
                "Remove the secret from the Dockerfile; inject it at runtime via an orchestrator "
                "secret or --secret build mount.")
    else:
        results.append(("DL-02", "No secrets baked into image layers", True))

    ln, _ = find_line(r"^\s*ADD\s+https?://")
    if ln:
        results.append(("DL-03", "No remote fetch via ADD from a URL", False))
        add("medium", "Remote artifact fetched with ADD from a URL", ln,
            "ADD from a URL fetches an unverified remote file at build time with no checksum, "
            "integrity, or provenance guarantee.",
            "Fetch the artifact in a verified step (pinned checksum) or pull it from a trusted "
            "registry; use COPY for local files.")
    else:
        results.append(("DL-03", "No remote fetch via ADD from a URL", True))

    ln, _ = find_line(r"curl[^\n|]*\|\s*(bash|sh)\b")
    if ln:
        results.append(("DL-04", "No pipe-to-shell installers (curl | bash)", False))
        add("high", "Untrusted installer piped to a shell (curl | bash)", ln,
            "A remote script is piped straight into a shell and executed with no review or integrity "
            "check, giving the remote host arbitrary control of the build.",
            "Download the installer, verify its checksum/signature, inspect it, then run it as a "
            "separate, pinned step.")
    else:
        results.append(("DL-04", "No pipe-to-shell installers (curl | bash)", True))

    user_lines = [(i, ln) for i, ln in text_lines if re.match(r"^\s*USER\b", ln)]
    runs_as_root, root_line = (not user_lines), None
    if user_lines:
        last_i, last_ln = user_lines[-1]
        if re.search(r"^\s*USER\s+(root|0)\b", last_ln):
            runs_as_root, root_line = True, last_i
    if runs_as_root:
        results.append(("DL-05", "Container runs as a non-root user", False))
        add("high", "Container runs as root", root_line or 0,
            "No non-root USER is set (or USER is root), so the service and any exploit of it run with "
            "full root privileges inside the container.",
            "Create a dedicated unprivileged user and add USER appuser before CMD.")
    else:
        results.append(("DL-05", "Container runs as a non-root user", True))

    ln, _ = find_line(r"^\s*HEALTHCHECK\b")
    if ln is None:
        results.append(("DL-06", "Image declares a HEALTHCHECK", False))
        add("low", "No HEALTHCHECK defined", 0,
            "The image declares no HEALTHCHECK, so orchestrators cannot detect a hung or unhealthy "
            "container and will keep routing traffic to it.",
            "Add a HEALTHCHECK that probes /healthz so the platform can restart on failure.")
    else:
        results.append(("DL-06", "Image declares a HEALTHCHECK", True))

    pip_bad = None
    for i, ln in text_lines:
        if re.search(r"pip\s+install", ln) and "--no-cache-dir" not in ln:
            pip_bad = i
            break
    if pip_bad:
        results.append(("DL-07", "pip install uses --no-cache-dir", False))
        add("low", "pip install without --no-cache-dir", pip_bad,
            "pip leaves its download cache in the layer, enlarging the image and shipping extra files "
            "that widen the attack surface.",
            "Add --no-cache-dir to pip install invocations.")
    else:
        results.append(("DL-07", "pip install uses --no-cache-dir", True))

    ln, _ = find_line(r"^\s*COPY\s+\.\s+\.")
    if ln:
        results.append(("DL-08", "Build context is scoped (no COPY . .)", False))
        add("medium", "Entire build context copied into the image (COPY . .)", ln,
            "COPY . . pulls the whole working directory in, which can drag secrets, .git history, and "
            "local artifacts into the image.",
            "Copy only what the service needs and add a .dockerignore to exclude secrets and VCS metadata.")
    else:
        results.append(("DL-08", "Build context is scoped (no COPY . .)", True))

    return findings, results


# ----------------------------------------------------------------------------
# Modes (mirror the two buttons)
# ----------------------------------------------------------------------------
def mode_scan_code():
    for p in (REQS, APP_PY, CVE_DB):
        if not os.path.exists(p):
            die("required input missing: " + p)
    out("Forge Lab · Code & Container Security — Code Security Scan (Nimbus AI Chat Service)")
    hr()
    out("target   : app/  (source + pinned dependencies)")
    out("scanners : dependency CVE match, static source analysis")
    out("mode     : MOCK (offline)   scanned: " + now_iso())

    out()
    out("[1/2] Dependency scan — requirements.txt vs Trend CVE database")
    hr("─")
    dep_findings, ds = scan_dependencies()
    out("  packages analyzed     : %d" % ds["deps"])
    out("  vulnerable packages   : %d" % ds["vuln_pkgs"])
    out("  CVEs matched          : %d" % ds["cves"])
    if ds["clean"]:
        out("  no known CVEs         : " + ", ".join("%s==%s" % pv for pv in ds["clean"]))

    out()
    out("[2/2] Static source analysis — app.py")
    hr("─")
    src_findings, checks = scan_source()
    for name, hit in checks:
        out("  %-38s %s" % (name, "✗ flagged" if hit else "✓ clean"))

    findings = assign_ids(dep_findings + src_findings)
    doc, path = write_findings("code", findings)
    out()
    hr()
    out("Findings — code & dependencies")
    render_findings_table(findings)
    render_summary(doc, path)
    out()
    out("Result: scan complete. %d issues to remediate before this build ships." % len(findings))
    return 0


def mode_scan_image():
    if not os.path.exists(DOCKERFILE):
        die("required input missing: " + DOCKERFILE)
    out("Forge Lab · Code & Container Security — Container Image Scan (Nimbus AI Chat Service)")
    hr()
    out("target   : app/Dockerfile")
    out("scanner  : Dockerfile hardening linter")
    out("mode     : MOCK (offline)   scanned: " + now_iso())

    out()
    out("[1/1] Dockerfile lint — image hardening rules")
    hr("─")
    img_findings, results = lint_dockerfile()
    passed = sum(1 for _, _, ok in results if ok)
    for rid, desc, ok in results:
        out("  %-6s %-46s %s" % (rid, desc, "✓ PASS" if ok else "✗ FAIL"))
    out()
    out("  rules evaluated : %d    passed : %d    failed : %d"
        % (len(results), passed, len(results) - passed))

    findings = assign_ids(img_findings)
    doc, path = write_findings("image", findings)
    out()
    hr()
    out("Findings — container image")
    render_findings_table(findings)
    render_summary(doc, path)
    out()
    out("Result: image scan complete. %d hardening rules failed; %d findings recorded."
        % (len(results) - passed, len(findings)))
    return 0


def main(argv):
    if len(argv) < 2:
        die("usage: ccs.py {scan-code|scan-image}")
    mode = argv[1]
    if mode == "scan-code":
        return mode_scan_code()
    if mode == "scan-image":
        return mode_scan_image()
    die("unknown mode: " + mode + " (expected scan-code or scan-image)")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
