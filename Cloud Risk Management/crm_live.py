#!/usr/bin/env python3
"""Cloud Risk Management — LIVE adapter for Trend Vision One.

Pulls real posture/risk data from your Vision One tenant. Standard library only.

Auth / conventions (confirmed via Vision One docs):
  • Region-aware host: US = https://api.xdr.trendmicro.com
  • Header: Authorization: Bearer <token>   (token = your Vision One API key)
  • Versioned paths under /v3.0/ ; JSON responses, standard HTTP codes.

Endpoint discovery: the exact Cloud Risk Management / CREM resource path isn't
published in the KB (only in the interactive Automation Center), so this adapter
PROBES a ranked list of documented candidate endpoints with read-only GETs. It uses
the first that returns 200 and renders it; if none do, it prints a path→status table
that identifies the correct one, then exits non-zero so the launcher falls back to
the offline mock. A 401/403 means the key/scope is the issue; a 404 means that path
isn't the one for this tenant. Nothing is fabricated — only what the tenant returns
is shown.

Exit codes: 0 = live data retrieved; non-zero = caller should fall back to mock.
"""
import json
import os
import sys
import urllib.request
import urllib.error

REGION_HOSTS = {
    "us": "https://api.xdr.trendmicro.com",
    "eu": "https://api.eu.xdr.trendmicro.com",
    "jp": "https://api.xdr.trendmicro.co.jp",
    "sg": "https://api.sg.xdr.trendmicro.com",
    "au": "https://api.au.xdr.trendmicro.com",
    "in": "https://api.in.xdr.trendmicro.com",
    "mea": "https://api.mea.xdr.trendmicro.com",
}

BAR = "─" * 88

# Ranked candidate endpoints. The /v3.0/asrm/attackSurface* paths are the ones Trend
# support confirms for CREM (case TM-03960199) — tried first. Then the other CREM/risk
# and Cloud Posture resources. The probe stops at the first 200.
CANDIDATES = [
    ("Attack surface devices",      "/v3.0/asrm/attackSurfaceDevices"),
    ("Attack surface users",        "/v3.0/asrm/attackSurfaceUsers"),
    ("High-risk devices",           "/v3.0/asrm/highRiskDevices"),
    ("High-risk users",             "/v3.0/asrm/highRiskUsers"),
    ("Cyber Risk Index",            "/v3.0/asrm/riskScore"),
    ("Cloud accounts",              "/v3.0/cloudPosture/accounts"),
    ("Cloud accounts (AWS)",        "/v3.0/cloudPosture/awsAccounts"),
    ("Cloud posture checks",        "/v3.0/cloudPosture/checks"),
]


def host() -> str:
    region = (os.environ.get("V1_REGION") or "us").lower()
    return REGION_HOSTS.get(region, REGION_HOSTS["us"])


def token() -> str:
    return os.environ.get("V1_API_KEY") or os.environ.get("TMAS_API_KEY") or ""


def get(path: str, timeout: float = 12.0):
    """GET <host><path> with Bearer auth → (status, parsed_json_or_text)."""
    req = urllib.request.Request(host() + path, method="GET")
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", "replace")
            try:
                return resp.status, json.loads(body)
            except json.JSONDecodeError:
                return resp.status, body
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace") if e.fp else ""
        return e.code, detail
    except Exception as e:  # noqa: BLE001
        return 0, str(e)


def lab_dir() -> str:
    root = os.environ.get("TREND_LAB_HOME") or os.path.join(os.path.expanduser("~"), ".trend-lab")
    return os.path.join(root, "labs", "cloud-risk")


def band(score) -> str:
    """Map a 0–100 risk score to a severity band."""
    try:
        s = int(score)
    except (TypeError, ValueError):
        return "low"
    if s >= 75:
        return "critical"
    if s >= 50:
        return "high"
    if s >= 25:
        return "medium"
    return "low"


def write_assessment(risk_score, summary, findings) -> str:
    """Persist the same schema the mock writes, so Status + AI Risk Insights keep working."""
    import datetime
    out = {
        "lab": "cloud-risk",
        "source": "live",
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "risk_score": risk_score,
        "summary": summary,
        "findings": findings,
        "attack_path": [],
        "remediated": False,
    }
    d = lab_dir()
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "assessment.json")
    with open(path, "w") as fh:
        json.dump(out, fh, indent=2)
    return path


def render_devices(data) -> None:
    """Render live Attack Surface device risk as a demo-grade posture assessment."""
    items = data.get("items", []) if isinstance(data, dict) else []
    total = data.get("totalCount", len(items)) if isinstance(data, dict) else len(items)

    # Rank by latest risk score.
    def score_of(d):
        try:
            return int(d.get("latestRiskScore", 0))
        except (TypeError, ValueError):
            return 0
    ranked = sorted([d for d in items if isinstance(d, dict)], key=score_of, reverse=True)

    counts = {"critical": 0, "high": 0, "medium": 0, "low": 0}
    total_cves = 0
    for d in ranked:
        counts[band(score_of(d))] += 1
        try:
            total_cves += int(d.get("cveCount", 0))
        except (TypeError, ValueError):
            pass

    peak = score_of(ranked[0]) if ranked else 0
    avg = round(sum(score_of(d) for d in ranked) / len(ranked)) if ranked else 0

    print("✓ Live Attack Surface Risk · Trend Vision One CREM")
    print(BAR)
    print("Attack surface: %d assets discovered · showing top %d by risk" % (total, len(ranked)))
    print("Risk bands (by latest risk score):")
    print("  Critical (75-100): %-4d High (50-74): %-4d Medium (25-49): %-4d Low (0-24): %d"
          % (counts["critical"], counts["high"], counts["medium"], counts["low"]))
    print(BAR)
    print("Highest-risk assets:")
    for d in ranked[:14]:
        name = (d.get("deviceName") or d.get("id") or "—")[:26]
        osp = (d.get("osPlatform") or d.get("osName") or "")[:16]
        crit = (d.get("criticality") or "")[:8]
        cves = d.get("cveCount", 0)
        user = (d.get("lastUser") or "")[:22]
        print("  [%3s] %-8s %-26s %-16s %5s CVEs  %s"
              % (score_of(d), crit, name, osp, cves, user))
    print(BAR)
    print("Peak asset risk: %d/100 · average (shown): %d/100 · total CVEs (shown): %d"
          % (peak, avg, total_cves))

    # Persist for Status + AI Risk Insights aggregation.
    findings = []
    for d in ranked[:25]:
        findings.append({
            "id": (d.get("id") or "")[:12],
            "severity": band(score_of(d)),
            "rule": "Asset risk exposure",
            "resource": d.get("deviceName") or d.get("id") or "—",
            "detail": "%s · risk %d/100 · %s CVEs · last user %s"
                      % (d.get("osName") or d.get("osPlatform") or "unknown OS",
                         score_of(d), d.get("cveCount", 0), d.get("lastUser") or "—"),
            "fix": "Review this asset in Vision One → Cyber Risk Exposure Management → Attack Surface.",
        })
    path = write_assessment(peak, counts, findings)
    print("Assessment written: %s" % path)
    print(BAR)
    print("✓ Live Cloud Risk data retrieved from your Vision One tenant.")


def render_generic(label: str, path: str, data) -> None:
    """Fallback renderer for any other endpoint that returns 200."""
    print("✓ Live data from %s  (%s)" % (label, path))
    print(BAR)
    raw = json.dumps(data, indent=2) if not isinstance(data, str) else data
    print(raw[:2048])
    print(BAR)
    print("✓ Live Cloud Risk data retrieved from your Vision One tenant.")


def main() -> int:
    if not token():
        print("! No Vision One API key in the environment. Falling back to mock.")
        return 2

    print("Forge Lab · Cloud Risk Management")
    print(BAR)
    print("Mode: LIVE · Trend Vision One   host: %s   region: %s"
          % (host(), (os.environ.get("V1_REGION") or "us")))
    print(BAR)

    def reason(status, data) -> str:
        if status in (401, 403):
            return "auth/scope — key lacks permission for this resource"
        if status == 404:
            return "path not available for this tenant"
        if status == 0:
            return "network/transport error: %s" % (str(data)[:80])
        # For 400 etc., surface the API's own message — often "missing required param".
        if isinstance(data, dict):
            err = data.get("error") or {}
            msg = err.get("message") or data.get("message") or ""
            if msg:
                return str(msg)[:100]
        return str(data)[:100] if data else ""

    probe = []
    for label, path in CANDIDATES:
        status, data = get(path)
        probe.append((label, path, status, reason(status, data)))
        if status == 200:
            if path.endswith("attackSurfaceDevices"):
                render_devices(data)
            else:
                render_generic(label, path, data)
            return 0

    # Nothing returned 200 — show what each candidate did so we can pinpoint the path.
    print("No candidate endpoint returned data. Probe results:")
    print(BAR)
    for label, path, status, why in probe:
        print(("  %-3s  %-32s %s" % (status, path, why)).rstrip())
    print(BAR)
    print("Share this table and the exact live path will be locked in.")
    print("Falling back to the offline mock assessment.")
    return 3


if __name__ == "__main__":
    sys.exit(main())
