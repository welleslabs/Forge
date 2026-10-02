#!/usr/bin/env python3
# Forge Lab · Trend Vision One — AI Secure Access
# Demo policy engine: replays employee→AI traffic, renders ALLOW/BLOCK/REDACT
# verdicts, and produces a Shadow AI discovery report.
# Python 3.9 compatible · stdlib only.

import json
import os
import re
import sys
import time
from datetime import datetime, timezone

DIV = "─" * 78
MAXW = 100
SLEEP = 0.05
LAB_SLUG = "ai-access"


def out(line=""):
    if len(line) > MAXW:
        line = line[: MAXW - 1] + "…"
    print(line, flush=True)


def die(msg):
    print("ERROR: %s" % msg, file=sys.stderr, flush=True)
    sys.exit(2)


class PolicyBundle(object):
    def __init__(self, raw):
        self.raw = raw
        self.version = raw.get("version", "?")
        self.approved = {}
        for svc in raw.get("approved_services", []):
            self.approved[svc["host"]] = svc["service"]
        self.dlp = []
        for p in raw.get("dlp_patterns", []) + raw.get("source_code_patterns", []):
            self.dlp.append(
                (p["id"], p["name"], p["category"], re.compile(p["regex"]), p["action"])
            )
        self.injection = []
        for p in raw.get("injection_patterns", []):
            self.injection.append((p["id"], p["name"], re.compile(p["regex"])))
        self.blocked_kinds = {}
        for b in raw.get("upload_rules", {}).get("blocked_kinds", []):
            self.blocked_kinds[b["kind"]] = b["reason"]
        # policy id -> display name (for the "top violated policies" table)
        self.names = {
            "SEC-SHADOW-AI": "Unapproved AI service (Shadow AI)",
            "SEC-UPLOAD-01": "Sensitive file upload control",
        }
        for pid, name, _cat, _rx, _act in self.dlp:
            self.names[pid] = "DLP — " + name
        for pid, name, _rx in self.injection:
            self.names[pid] = "Prompt injection — " + name


def load_bundle(data_dir):
    pol_path = os.path.join(data_dir, "policies.json")
    trf_path = os.path.join(data_dir, "traffic.jsonl")
    if not os.path.isfile(pol_path) or not os.path.isfile(trf_path):
        die("lab data not found under %s (run: lab.sh setup)" % data_dir)
    with open(pol_path, "r") as fh:
        pol = PolicyBundle(json.load(fh))
    events = []
    with open(trf_path, "r") as fh:
        for line in fh:
            line = line.strip()
            if line:
                events.append(json.loads(line))
    events.sort(key=lambda e: e.get("time", ""))
    return pol, events


def evaluate(ev, pol):
    """Return (action, category, policy_id, reason) for one traffic event."""
    host = ev.get("host", "")
    prompt = ev.get("prompt") or ""
    # 1. Service approval (Shadow AI)
    if host not in pol.approved:
        return ("BLOCK", "shadow-ai", "SEC-SHADOW-AI",
                "Shadow AI — unapproved service, egress blocked")
    # 2. Prompt-injection signatures
    for pid, _name, rx in pol.injection:
        if rx.search(prompt):
            return ("BLOCK", "prompt-injection", pid,
                    "%s prompt-injection signature — blocked" % pid)
    # 3. Upload controls
    att = ev.get("attachment")
    if att and att.get("kind") in pol.blocked_kinds:
        return ("BLOCK", "sensitive-upload", "SEC-UPLOAD-01",
                "upload blocked: %s" % att.get("name", "attachment"))
    # 4. Inline DLP on the prompt body
    hits = []
    for pid, name, cat, rx, action in pol.dlp:
        if rx.search(prompt):
            hits.append((pid, name, cat, action))
    for pid, name, cat, action in hits:
        if action == "block":
            return ("BLOCK", cat, pid, "%s: %s — blocked" % (pid, name))
    for pid, name, cat, action in hits:
        if action == "redact":
            return ("REDACT", cat, pid,
                    "%s: %s — redacted at egress" % (pid, name))
    # 5. Clean
    if att:
        return ("ALLOW", "approved-use", "-", "upload scanned · no policy findings")
    return ("ALLOW", "approved-use", "-", "approved service · no policy findings")


def shadow_aggregate(events, verdicts):
    """host -> aggregation dict for unapproved-service traffic."""
    agg = {}
    for ev, v in zip(events, verdicts):
        if v[1] != "shadow-ai":
            continue
        host = ev["host"]
        a = agg.get(host)
        if a is None:
            a = {"service": ev.get("service", host), "events": 0, "users": {},
                 "departments": [], "first": ev["time"], "last": ev["time"],
                 "prompts": []}
            agg[host] = a
        a["events"] += 1
        a["users"][ev["user"]] = a["users"].get(ev["user"], 0) + 1
        dept = ev.get("department", "Unknown")
        if dept not in a["departments"]:
            a["departments"].append(dept)
        if ev["time"] < a["first"]:
            a["first"] = ev["time"]
        if ev["time"] > a["last"]:
            a["last"] = ev["time"]
        a["prompts"].append(ev.get("prompt") or "")
    return agg


def write_results(lab_dir, events, verdicts):
    ev_path = os.path.join(lab_dir, "events.jsonl")
    sm_path = os.path.join(lab_dir, "summary.json")
    with open(ev_path, "w") as fh:
        for ev, v in zip(events, verdicts):
            fh.write(json.dumps({
                "user": ev["user"],
                "service": ev.get("service", ev.get("host", "")),
                "action": v[0],
                "category": v[1],
                "detail": v[3],
            }) + "\n")
    totals = {"allow": 0, "block": 0, "redact": 0}
    for v in verdicts:
        totals[v[0].lower()] += 1
    agg = shadow_aggregate(events, verdicts)
    shadow = []
    for host in sorted(agg, key=lambda h: (-agg[h]["events"], h)):
        shadow.append({
            "service": host,
            "users": len(agg[host]["users"]),
            "events": agg[host]["events"],
        })
    summary = {
        "lab": LAB_SLUG,
        "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "totals": totals,
        "shadow_services": shadow,
    }
    with open(sm_path, "w") as fh:
        json.dump(summary, fh, indent=2)
        fh.write("\n")
    return ev_path, sm_path


def hhmmss(iso):
    return iso[11:19] if len(iso) >= 19 else iso


def header(subtitle):
    out(DIV)
    out("Forge Lab · Trend Vision One — AI Secure Access")
    out(subtitle)
    out(DIV)


def cmd_replay(lab_dir, data_dir):
    pol, events = load_bundle(data_dir)
    header("Traffic replay · policy bundle v%s · gateway: sase-edge-us-west · tenant: %s"
           % (pol.version, pol.raw.get("tenant", "trend-demo")))
    out("Loaded %d approved services · %d DLP patterns · %d injection signatures · %d upload rules"
        % (len(pol.approved), len(pol.dlp), len(pol.injection), len(pol.blocked_kinds)))
    out("Replaying %d employee→AI events from data/traffic.jsonl" % len(events))
    out(DIV)

    t0 = time.time()
    verdicts = []
    policy_hits = {}
    for ev in events:
        v = evaluate(ev, pol)
        verdicts.append(v)
        if v[0] != "ALLOW":
            policy_hits[v[2]] = policy_hits.get(v[2], 0) + 1
        out("%s %-13s → %-18s %-6s %s"
            % (hhmmss(ev["time"]), ev["user"], ev.get("service", ev["host"]), v[0], v[3]))
        time.sleep(SLEEP)

    totals = {"ALLOW": 0, "BLOCK": 0, "REDACT": 0}
    for v in verdicts:
        totals[v[0]] += 1

    out(DIV)
    out("Replay complete · %d events processed in %.1fs" % (len(events), time.time() - t0))
    out("  ALLOW  : %2d" % totals["ALLOW"])
    out("  BLOCK  : %2d" % totals["BLOCK"])
    out("  REDACT : %2d" % totals["REDACT"])
    out("")
    out("Top violated policies:")
    ranked = sorted(policy_hits.items(), key=lambda kv: (-kv[1], kv[0]))
    for pid, count in ranked:
        out("  %-14s %-40s %2d event%s"
            % (pid, pol.names.get(pid, pid), count, "s" if count != 1 else ""))
    ev_path, sm_path = write_results(lab_dir, events, verdicts)
    out("")
    out("Results written:")
    out("  " + ev_path)
    out("  " + sm_path)
    out(DIV)


RECOMMENDED = {
    "free-llm.example.net":
        "Block at the secure web gateway; migrate both users to ChatGPT Enterprise.",
    "chat.quickai.example.io":
        "Block domain; enroll Support and Marketing in the AI usage coaching campaign.",
    "promptpal.example.org":
        "Block domain; review lead-data handling with Sales and Marketing leadership.",
}
RISK_NOTES = {
    "free-llm.example.net":
        "account lists and internal notes sent to a consumer service with no DPA or retention terms",
    "chat.quickai.example.io":
        "customer-facing content drafted on an unvetted service; provider trains on submitted data",
    "promptpal.example.org":
        "lead and pipeline data shared with a free tool; terms grant provider broad reuse rights",
}


def cmd_shadow_report(lab_dir, data_dir):
    pol, events = load_bundle(data_dir)
    verdicts = [evaluate(ev, pol) for ev in events]
    agg = shadow_aggregate(events, verdicts)

    day = events[0]["time"][:10] if events else "-"
    header("Shadow AI discovery report · window: %s (24h) · policy bundle v%s"
           % (day, pol.version))

    all_users = {}
    all_depts = []
    total_ev = 0
    for host in agg:
        total_ev += agg[host]["events"]
        for u in agg[host]["users"]:
            all_users[u] = True
        for d in agg[host]["departments"]:
            if d not in all_depts:
                all_depts.append(d)
    out("Unapproved AI services detected: %d · %d events · %d distinct users · %d departments"
        % (len(agg), total_ev, len(all_users), len(all_depts)))
    out("Approved alternatives available: %s"
        % ", ".join(sorted(pol.approved.values())))
    out(DIV)

    dept_of = {}
    for ev in events:
        dept_of[ev["user"]] = ev.get("department", "Unknown")

    rank = sorted(agg, key=lambda h: (-agg[h]["events"], h))
    idx = 0
    for host in rank:
        idx += 1
        a = agg[host]
        out("● %d. %s  (“%s”)" % (idx, host, a["service"]))
        out("   events: %d · users: %d · departments: %s"
            % (a["events"], len(a["users"]), ", ".join(sorted(a["departments"]))))
        user_bits = []
        for u in sorted(a["users"], key=lambda x: (-a["users"][x], x)):
            n = a["users"][u]
            user_bits.append("%s (%s, %d event%s)" % (u, dept_of.get(u, "?"), n,
                                                      "s" if n != 1 else ""))
        out("   users:  " + "; ".join(user_bits))
        out("   first seen %s · last seen %s" % (hhmmss(a["first"]), hhmmss(a["last"])))
        example = max(a["prompts"], key=len) if a["prompts"] else ""
        if len(example) > 62:
            example = example[:61] + "…"
        out("   example prompt: “%s”" % example)
        out("   risk: %s" % RISK_NOTES.get(host, "corporate data leaving the tenant with no contractual controls"))
        out("   recommended action: %s"
            % RECOMMENDED.get(host, "Block at the secure web gateway and notify the user's manager."))
        out("")
        time.sleep(SLEEP)

    out(DIV)
    out("Summary of recommended controls:")
    out("  1. Add all three domains to the SWG block list (category: Generative AI — Unapproved).")
    out("  2. Redirect blocked sessions to the approved-AI landing page (ChatGPT Enterprise SSO).")
    out("  3. Notify managers of the %d affected users; no punitive action on first offense."
        % len(all_users))
    out("  4. Re-run this report weekly; alert when a new unapproved AI domain appears.")
    ev_path, sm_path = write_results(lab_dir, events, verdicts)
    out("")
    out("Results written:")
    out("  " + ev_path)
    out("  " + sm_path)
    out(DIV)


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    lab_dir = None
    i = 2
    while i < len(argv):
        if argv[i] == "--lab" and i + 1 < len(argv):
            lab_dir = argv[i + 1]
            i += 2
        else:
            i += 1  # ignore unrecognized args silently
    if not lab_dir:
        die("missing --lab <dir>")
    data_dir = os.path.join(lab_dir, "data")
    if mode == "replay":
        cmd_replay(lab_dir, data_dir)
    elif mode == "shadow-report":
        cmd_shadow_report(lab_dir, data_dir)
    else:
        die("unknown mode %r (expected: replay | shadow-report)" % mode)


if __name__ == "__main__":
    main(sys.argv)
