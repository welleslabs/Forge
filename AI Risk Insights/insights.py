#!/usr/bin/env python3
"""Forge Lab · AI Risk Insights — governance rollup engine.

Aggregates results from the other Forge labs (development, infrastructure and
runtime lifecycle stages) plus live environment signals into a single AI asset
inventory and unified risk report.

Standard library only. Python 3.9 compatible. Every print is flushed.
"""

import datetime
import json
import os
import socket
import sys
import time

SLUG = "ai-insights"
W = 86
HR = "─" * W
SEVS = ("critical", "high", "medium", "low")
SEV_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3, "advisory": 4}
RANK_SEV = {0: "critical", 1: "high", 2: "medium", 3: "low"}

DEFAULT_CONFIG = {
    "stage_weights": {"development": 0.35, "infrastructure": 0.40, "runtime": 0.25},
    "severity_points": {"critical": 25, "high": 10, "medium": 4, "low": 1},
    "live_signal_modifiers": {"public_tunnel": 8, "local_model_unmanaged": 4},
    "baseline_unassessed": 20,
}

MISSING_POINTERS = {
    "development":
        "  ○ Development · no scan results yet — run the Code & Container Security lab",
    "infrastructure":
        "  ○ Infrastructure · no posture assessment yet — run the Cloud Risk Posture lab",
    "runtime":
        "  ○ Runtime · no gateway telemetry yet — run the AI Access Control lab",
}

COVERAGE_HINTS = {
    "development": "Run the Code & Container Security lab to scan model code, "
                   "dependencies and container images",
    "infrastructure": "Run the Cloud Risk Posture lab to assess cloud AI infrastructure "
                      "and attack paths",
    "runtime": "Run the AI Access Control lab to capture gateway telemetry and "
               "shadow AI usage",
}


# ── helpers ──────────────────────────────────────────────────────────────────

def out(line=""):
    print(line, flush=True)


def pause():
    time.sleep(0.10)


def root_dir():
    return os.environ.get("TREND_LAB_HOME") or os.path.join(
        os.path.expanduser("~"), ".trend-lab")


def lab_dir():
    return os.path.join(root_dir(), "labs", SLUG)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json(path):
    """Load JSON defensively — any failure returns None."""
    try:
        with open(path, "r") as fh:
            return json.load(fh)
    except Exception:
        return None


def as_int(v, default=0):
    try:
        if isinstance(v, bool):
            return default
        return int(v)
    except Exception:
        try:
            return int(float(v))
        except Exception:
            return default


def as_float(v, default=0.0):
    try:
        if isinstance(v, bool):
            return default
        return float(v)
    except Exception:
        return default


def clip(s, n):
    s = str(s)
    if len(s) <= n:
        return s
    return s[: max(1, n - 1)] + "…"


def counts_str(counts):
    return "%dC/%dH/%dM/%dL" % (
        counts.get("critical", 0), counts.get("high", 0),
        counts.get("medium", 0), counts.get("low", 0))


def load_config(lab):
    cfg = {}
    for k, v in DEFAULT_CONFIG.items():
        cfg[k] = dict(v) if isinstance(v, dict) else v
    data = load_json(os.path.join(lab, "scoring-config.json"))
    if isinstance(data, dict):
        for k in DEFAULT_CONFIG:
            v = data.get(k)
            if isinstance(DEFAULT_CONFIG[k], dict):
                if isinstance(v, dict):
                    cfg[k].update(v)
            elif isinstance(v, (int, float)) and not isinstance(v, bool):
                cfg[k] = v
    return cfg


def load_registry(lab):
    data = load_json(os.path.join(lab, "asset-registry.json"))
    assets = []
    if isinstance(data, dict) and isinstance(data.get("assets"), list):
        for a in data["assets"]:
            if isinstance(a, dict) and a.get("name"):
                assets.append(a)
    return assets


# ── sibling-lab collectors (all defensive) ───────────────────────────────────

def _norm_findings(raw):
    findings = []
    if isinstance(raw, list):
        for f in raw:
            if isinstance(f, dict):
                findings.append(f)
    return findings


def _counts_from(summary, findings):
    counts = {}
    for s in SEVS:
        counts[s] = max(0, as_int(summary.get(s), 0))
    if sum(counts.values()) == 0 and findings:
        for f in findings:
            sev = str(f.get("severity", "")).lower()
            if sev in counts:
                counts[sev] += 1
    return counts


def collect_code_container(labs):
    data = load_json(os.path.join(labs, "code-container", "findings.json"))
    if not isinstance(data, dict):
        return None
    summary = data.get("summary") if isinstance(data.get("summary"), dict) else {}
    findings = _norm_findings(data.get("findings"))
    return {"counts": _counts_from(summary, findings), "findings": findings}


def collect_cloud_risk(labs):
    data = load_json(os.path.join(labs, "cloud-risk", "assessment.json"))
    if not isinstance(data, dict):
        return None
    summary = data.get("summary") if isinstance(data.get("summary"), dict) else {}
    findings = _norm_findings(data.get("findings"))
    risk = data.get("risk_score")
    risk_num = None
    if isinstance(risk, (int, float)) and not isinstance(risk, bool):
        risk_num = max(0, min(100, int(round(risk))))
    attack = data.get("attack_path")
    return {
        "counts": _counts_from(summary, findings),
        "findings": findings,
        "risk_score": risk_num,
        "attack_path_len": len(attack) if isinstance(attack, list) else 0,
        "remediated": bool(data.get("remediated")),
    }


def collect_ai_access(labs):
    d = os.path.join(labs, "ai-access")
    summary = load_json(os.path.join(d, "summary.json"))
    if not isinstance(summary, dict):
        return None
    totals_raw = summary.get("totals") if isinstance(summary.get("totals"), dict) else {}
    totals = {}
    for k in ("allow", "block", "redact"):
        totals[k] = max(0, as_int(totals_raw.get(k), 0))
    shadow = []
    raw_shadow = summary.get("shadow_services")
    if isinstance(raw_shadow, list):
        for s in raw_shadow:
            if isinstance(s, dict) and s.get("service"):
                shadow.append({
                    "service": str(s.get("service")),
                    "users": max(0, as_int(s.get("users"), 0)),
                    "events": max(0, as_int(s.get("events"), 0)),
                })
    events = 0
    users = set()
    try:
        with open(os.path.join(d, "events.jsonl"), "r") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except Exception:
                    continue
                events += 1
                if isinstance(ev, dict):
                    u = ev.get("user") or ev.get("identity") or ev.get("principal")
                    if u:
                        users.add(str(u))
    except Exception:
        pass
    return {"totals": totals, "shadow": shadow,
            "events": events, "users": len(users)}


# ── live environment probes ──────────────────────────────────────────────────

def probe_local_model(host="127.0.0.1", port=11434, timeout=0.3):
    s = None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((host, port))
        return True
    except Exception:
        return False
    finally:
        try:
            if s is not None:
                s.close()
        except Exception:
            pass


def read_tunnel(root):
    path = os.path.join(root, "tunnel-url")
    try:
        with open(path, "r") as fh:
            content = fh.read().strip()
    except Exception:
        return None
    if not content:
        return None
    return content.splitlines()[0].strip()[:120]


# ── scoring ──────────────────────────────────────────────────────────────────

def sev_points(counts, pts):
    total = 0
    for s in SEVS:
        per = as_int(pts.get(s), DEFAULT_CONFIG["severity_points"][s])
        total += counts.get(s, 0) * max(0, per)
    return min(100, total)


def runtime_score(rt):
    shadow_n = len(rt["shadow"])
    score = shadow_n * 12
    total = sum(rt["totals"].values())
    if total > 0:
        block_pct = 100.0 * rt["totals"]["block"] / total
        redact_pct = 100.0 * rt["totals"]["redact"] / total
        score += int(round(block_pct * 0.5)) + int(round(redact_pct * 0.25))
    return min(100, score)


def status_for(score):
    if score >= 75:
        return "✗ critical exposure"
    if score >= 50:
        return "✗ attention required"
    if score >= 25:
        return "● monitor"
    return "✓ healthy"


def rating(score):
    if score >= 75:
        return "CRITICAL"
    if score >= 50:
        return "ELEVATED"
    if score >= 25:
        return "MODERATE"
    return "LOW"


def score_bar(score, width=30):
    filled = int(round(score / 100.0 * width))
    filled = max(0, min(width, filled))
    return "[" + "█" * filled + "░" * (width - filled) + "]"


# ── report sections ──────────────────────────────────────────────────────────

def section_collect(dev, infra, rt):
    out("● Collecting results from sibling Forge labs ...")
    if dev:
        out("  ✓ Development     code-container/findings.json   %d findings · %s"
            % (len(dev["findings"]), counts_str(dev["counts"])))
    else:
        out(MISSING_POINTERS["development"])
    if infra:
        risk_txt = str(infra["risk_score"]) if infra["risk_score"] is not None else "n/a"
        out("  ✓ Infrastructure  cloud-risk/assessment.json     risk %s · %d findings · "
            "path %d hops · fixed %s"
            % (risk_txt, len(infra["findings"]), infra["attack_path_len"],
               "yes" if infra["remediated"] else "no"))
    else:
        out(MISSING_POINTERS["infrastructure"])
    if rt:
        t = rt["totals"]
        out("  ✓ Runtime         ai-access/summary.json         %d allow · %d block · "
            "%d redact · %d shadow"
            % (t["allow"], t["block"], t["redact"], len(rt["shadow"])))
        if rt["events"]:
            out("                    ai-access/events.jsonl         %d gateway events · "
                "%d distinct identities" % (rt["events"], rt["users"]))
    else:
        out(MISSING_POINTERS["runtime"])


def section_live(local_model, tunnel, root):
    out("● Probing live environment signals ...")
    if local_model:
        out("  ✓ Local model runtime listening on 127.0.0.1:11434 (Ollama-compatible API)")
    else:
        out("  ○ No local model runtime detected on 127.0.0.1:11434")
    if tunnel:
        out("  ✗ Public tunnel registered: %s" % clip(tunnel, 60))
        out("    → a local AI endpoint is reachable from the internet")
    else:
        out("  ○ No public tunnel registered (no tunnel-url file in state root)")


def section_inventory(registry, infra, rt, local_model, tunnel):
    rows = []
    for a in registry:
        env = str(a.get("environment", "-"))
        dc = str(a.get("data_class", "-"))
        rows.append((str(a.get("type", "asset")), str(a.get("name", "-")),
                     "asset registry", "managed · %s · %s" % (env, dc)))
    if infra:
        seen = {}
        order = []
        for f in infra["findings"]:
            r = str(f.get("resource") or "").strip()
            if not r:
                continue
            rank = SEV_RANK.get(str(f.get("severity", "")).lower(), 5)
            if r not in seen:
                order.append(r)
                seen[r] = rank
            elif rank < seen[r]:
                seen[r] = rank
        order.sort(key=lambda r: seen[r])
        for r in order[:5]:
            rows.append(("cloud-resource", r, "cloud-risk lab",
                         "flagged · %s finding" % RANK_SEV.get(seen[r], "info")))
    if rt:
        for s in rt["shadow"]:
            rows.append(("ai-service", s["service"], "ai-access lab",
                         "shadow · %d users · %d events" % (s["users"], s["events"])))
    if local_model:
        rows.append(("model-endpoint", "127.0.0.1:11434 (local LLM runtime)",
                     "live probe", "unregistered · active"))
    if tunnel:
        rows.append(("public-endpoint", tunnel, "live probe", "✗ internet-exposed"))

    out("SECTION 1 · AI ASSET INVENTORY")
    out("  %-14s %-36s %-14s %s" % ("TYPE", "ASSET", "SOURCE", "EXPOSURE / STATE"))
    out("  " + "─" * (W - 2))
    for t, name, src, note in rows:
        out("  %-14s %-36s %-14s %s"
            % (clip(t, 14), clip(name, 36), clip(src, 14), clip(note, 28)))
    live_n = (1 if local_model else 0) + (1 if tunnel else 0)
    out("  " + "─" * (W - 2))
    out("  %d assets tracked · %d registered · %d discovered from lab telemetry · "
        "%d discovered live" % (len(rows), len(registry),
                                len(rows) - len(registry) - live_n, live_n))


def section_stages(dev, infra, rt, scores):
    out("SECTION 2 · RISK BY LIFECYCLE STAGE")
    out("  %-16s %-26s %-22s %5s  %s"
        % ("STAGE", "SOURCE", "SIGNALS", "SCORE", "STATUS"))
    out("  " + "─" * (W - 2))

    def row(stage, source, signals, score):
        if score is None:
            out("  %-16s %-26s %-22s %5s  %s"
                % (stage, source, signals, "—", "○ not assessed"))
        else:
            out("  %-16s %-26s %-22s %5d  %s"
                % (stage, clip(source, 26), clip(signals, 22), score,
                   status_for(score)))

    if dev:
        row("Development", "Code & Container Security", counts_str(dev["counts"]),
            scores["development"])
    else:
        row("Development", "—", "—", None)
    if infra:
        sig = counts_str(infra["counts"])
        if infra["remediated"]:
            sig += " · fixed"
        row("Infrastructure", "Cloud Risk Posture", sig, scores["infrastructure"])
    else:
        row("Infrastructure", "—", "—", None)
    if rt:
        total = sum(rt["totals"].values())
        pct = int(round(100.0 * rt["totals"]["block"] / total)) if total else 0
        row("Runtime", "AI Access Control",
            "%d shadow · %d%% blocked" % (len(rt["shadow"]), pct), scores["runtime"])
    else:
        row("Runtime", "—", "—", None)


def section_overall(scores, cfg, local_model, tunnel):
    weights = cfg["stage_weights"]
    mods_cfg = cfg["live_signal_modifiers"]
    present = [k for k in ("development", "infrastructure", "runtime")
               if scores.get(k) is not None]
    mods = []
    bump = 0
    if tunnel:
        b = as_int(mods_cfg.get("public_tunnel"), 8)
        bump += b
        mods.append("+%d public tunnel exposure" % b)
    if local_model:
        b = as_int(mods_cfg.get("local_model_unmanaged"), 4)
        bump += b
        mods.append("+%d unregistered local model runtime" % b)

    if present:
        wsum = sum(max(0.0, as_float(weights.get(k), 0.0)) for k in present)
        if wsum <= 0:
            base = sum(scores[k] for k in present) / float(len(present))
        else:
            base = sum(scores[k] * max(0.0, as_float(weights.get(k), 0.0))
                       for k in present) / wsum
    else:
        base = as_float(cfg.get("baseline_unassessed"), 20.0)
    overall = int(round(min(100.0, max(0.0, base + bump))))

    out("SECTION 3 · OVERALL AI RISK SCORE")
    if present:
        out("  coverage  : %d of 3 lifecycle stages reporting (%s)"
            % (len(present), ", ".join(present)))
    else:
        out("  coverage  : 0 of 3 lifecycle stages reporting — "
            "score reflects unassessed baseline exposure")
    out("  weighting : development %.2f · infrastructure %.2f · runtime %.2f "
        "(renormalized)"
        % (as_float(weights.get("development"), 0.35),
           as_float(weights.get("infrastructure"), 0.40),
           as_float(weights.get("runtime"), 0.25)))
    out("  modifiers : %s" % (" · ".join(mods) if mods else "none"))
    out("")
    out("  OVERALL AI RISK : %3d / 100   %s  %s"
        % (overall, score_bar(overall), rating(overall)))
    return overall


def build_actions(dev, infra, rt, local_model, tunnel, scores):
    acts = []
    if dev:
        for f in dev["findings"]:
            sev = str(f.get("severity", "")).lower()
            if sev not in SEV_RANK:
                sev = "low"
            acts.append({
                "sev": sev,
                "title": str(f.get("title") or f.get("id") or "code finding"),
                "ref": str(f.get("id") or "-"),
                "source": "Development · Code & Container Security",
                "fix": str(f.get("fix") or
                           "review and remediate in the source repository"),
            })
    if infra:
        for f in infra["findings"]:
            sev = str(f.get("severity", "")).lower()
            if sev not in SEV_RANK:
                sev = "low"
            rule = str(f.get("rule") or f.get("id") or "posture finding")
            res = str(f.get("resource") or "").strip()
            title = "%s — %s" % (rule, res) if res else rule
            acts.append({
                "sev": sev,
                "title": title,
                "ref": str(f.get("id") or "-"),
                "source": "Infrastructure · Cloud Risk Posture",
                "fix": str(f.get("fix") or "apply the recommended posture control"),
            })
    if rt:
        for s in rt["shadow"]:
            acts.append({
                "sev": "high",
                "title": "Shadow AI service in use: %s (%d users, %d events)"
                         % (s["service"], s["users"], s["events"]),
                "ref": "SHADOW-AI",
                "source": "Runtime · AI Access Control",
                "fix": "Sanction the service behind the AI Gateway or block it "
                       "via Zero Trust Secure Access policy",
            })
    if tunnel:
        acts.append({
            "sev": "high",
            "title": "Local model endpoint exposed through a public tunnel",
            "ref": "LIVE-TUNNEL",
            "source": "Live signal · environment probe",
            "fix": "Revoke the tunnel (%s) and front the endpoint with the "
                   "AI Gateway" % clip(tunnel, 48),
        })
    if local_model:
        acts.append({
            "sev": "medium",
            "title": "Unregistered local model runtime on 127.0.0.1:11434",
            "ref": "LIVE-11434",
            "source": "Live signal · environment probe",
            "fix": "Register the runtime in the AI asset inventory and enable "
                   "AI Guard inspection on its traffic",
        })
    acts.sort(key=lambda a: SEV_RANK.get(a["sev"], 5))
    for stage in ("development", "infrastructure", "runtime"):
        if len(acts) >= 5:
            break
        if scores.get(stage) is None:
            acts.append({
                "sev": "advisory",
                "title": "%s stage has no telemetry — visibility gap"
                         % stage.capitalize(),
                "ref": "COVERAGE",
                "source": "Coverage · AI Risk Insights",
                "fix": COVERAGE_HINTS[stage],
            })
    return acts[:5]


def section_actions(acts):
    out("SECTION 4 · TOP RECOMMENDED ACTIONS")
    out("  " + "─" * (W - 2))
    if not acts:
        out("  ✓ No open actions — all reporting stages are clean")
        return
    for i, a in enumerate(acts, 1):
        out("  %d. [%s] %s" % (i, a["sev"].upper(), clip(a["title"], 70)))
        out("     source: %s · ref: %s" % (a["source"], a["ref"]))
        out("     → %s" % clip(a["fix"], 90))


# ── main verb ────────────────────────────────────────────────────────────────

def cmd_report():
    started = time.time()
    root = root_dir()
    labs = os.path.join(root, "labs")
    lab = lab_dir()
    cfg = load_config(lab)
    registry = load_registry(lab)

    out(HR)
    out("Forge Lab · AI Risk Insights")
    out("Unified AI asset inventory & governance risk rollup — Trend Vision One")
    out(HR)
    out("state root : %s" % root)
    out("generated  : %s" % now_iso())
    out("")
    pause()

    dev = collect_code_container(labs)
    infra = collect_cloud_risk(labs)
    rt = collect_ai_access(labs)
    section_collect(dev, infra, rt)
    out("")
    pause()

    local_model = probe_local_model()
    tunnel = read_tunnel(root)
    section_live(local_model, tunnel, root)
    out("")
    pause()

    out(HR)
    section_inventory(registry, infra, rt, local_model, tunnel)
    out("")
    pause()

    pts = cfg["severity_points"]
    scores = {
        "development": sev_points(dev["counts"], pts) if dev else None,
        "infrastructure": (infra["risk_score"]
                           if infra and infra["risk_score"] is not None
                           else (sev_points(infra["counts"], pts) if infra else None)),
        "runtime": runtime_score(rt) if rt else None,
    }

    out(HR)
    section_stages(dev, infra, rt, scores)
    out("")
    pause()

    out(HR)
    overall = section_overall(scores, cfg, local_model, tunnel)
    out("")
    pause()

    out(HR)
    acts = build_actions(dev, infra, rt, local_model, tunnel, scores)
    section_actions(acts)
    out("")

    sources = []
    if dev:
        sources.append("code-container")
    if infra:
        sources.append("cloud-risk")
    if rt:
        sources.append("ai-access")
    report = {
        "lab": "ai-insights",
        "generated": now_iso(),
        "overall_score": overall,
        "sources_present": sources,
        "stage_scores": {
            "development": scores["development"],
            "infrastructure": scores["infrastructure"],
            "runtime": scores["runtime"],
        },
        "rating": rating(overall),
        "live_signals": {
            "local_model_11434": bool(local_model),
            "public_tunnel": tunnel,
        },
    }
    os.makedirs(lab, exist_ok=True)
    report_path = os.path.join(lab, "report.json")
    with open(report_path, "w") as fh:
        json.dump(report, fh, indent=2)
        fh.write("\n")

    out(HR)
    out("✓ Report written:")
    out("  %s" % report_path)
    out("✓ Rollup complete · %d lab source(s) · overall risk %d/100 (%s) · %.1fs"
        % (len(sources), overall, rating(overall), time.time() - started))
    out(HR)
    return 0


def main(argv):
    verb = argv[1] if len(argv) > 1 else "report"
    if verb != "report":
        out("usage: insights.py report")
        return 1
    return cmd_report()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
