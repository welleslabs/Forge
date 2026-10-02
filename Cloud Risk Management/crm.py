#!/usr/bin/env python3
# Forge Lab · Trend Vision One — Cloud Risk Management
# Demo posture engine: evaluates weighted CSPM rules against a mock cloud
# estate, derives a defensive attack-path narrative from the actual findings,
# and applies remediations to show the risk score drop.
# Python 3.9 compatible · stdlib only.

import json
import os
import sys
import time
from datetime import datetime, timezone

DIV = "─" * 78
MAXW = 100
SLEEP = 0.06
LAB_SLUG = "cloud-risk"

# Severity ordering + per-finding point weight that feeds the risk score.
SEV_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3}
SEV_WEIGHT = {"critical": 25, "high": 14, "medium": 6, "low": 2}


def out(line=""):
    if len(line) > MAXW:
        line = line[: MAXW - 1] + "…"
    print(line, flush=True)


def die(msg):
    print("ERROR: %s" % msg, file=sys.stderr, flush=True)
    sys.exit(2)


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# ── inventory access helpers ────────────────────────────────────────────────

def load_inventory(data_dir):
    path = os.path.join(data_dir, "inventory.json")
    if not os.path.isfile(path):
        die("lab data not found under %s (run: lab.sh setup)" % data_dir)
    with open(path, "r") as fh:
        return json.load(fh)


def save_inventory(data_dir, inv):
    path = os.path.join(data_dir, "inventory.json")
    with open(path, "w") as fh:
        json.dump(inv, fh, indent=2)
        fh.write("\n")


def buckets(inv):
    return inv.get("storage_buckets", [])


def roles(inv):
    return inv.get("iam_roles", [])


def sgs(inv):
    return inv.get("security_groups", [])


def services(inv):
    return inv.get("ai_services", [])


def find_by_id(items, ident):
    for it in items:
        if it.get("id") == ident:
            return it
    return None


# ── posture rules ───────────────────────────────────────────────────────────
# Each rule returns a list of findings. A finding is a dict:
#   id, severity, rule (title), resource, detail, fix
# Rules are pure functions of the inventory, so remediation is simply mutating
# the inventory and re-running the same rule set.

def r_crm001_public_bucket(inv):
    fs = []
    for b in buckets(inv):
        if b.get("public_access"):
            fs.append({
                "id": "CRM-001", "severity": "critical",
                "rule": "Storage bucket exposed to the public internet",
                "resource": "s3://%s" % b["id"],
                "detail": "Public read is enabled (%s); %s objects reachable without credentials."
                          % (b.get("public_access_reason", "public policy"), b.get("objects", "?")),
                "fix": "Enable S3 Block Public Access and remove the wildcard bucket policy.",
            })
    return fs


def r_crm002_unencrypted_bucket(inv):
    fs = []
    for b in buckets(inv):
        if str(b.get("encryption", "none")).lower() in ("none", "", "off"):
            fs.append({
                "id": "CRM-002", "severity": "high",
                "rule": "Storage bucket without server-side encryption",
                "resource": "s3://%s" % b["id"],
                "detail": "Data at rest is unencrypted (%s corpus, class=%s)."
                          % (b.get("purpose", "data"), b.get("tags", {}).get("data-class", "?")),
                "fix": "Enable default SSE-KMS with a customer-managed key.",
            })
    return fs


def r_crm003_bucket_no_versioning(inv):
    fs = []
    for b in buckets(inv):
        if not b.get("versioning") and b.get("sensitivity") in ("restricted", "confidential"):
            fs.append({
                "id": "CRM-003", "severity": "low",
                "rule": "Sensitive bucket without object versioning",
                "resource": "s3://%s" % b["id"],
                "detail": "Versioning disabled on a %s bucket; no rollback after tamper/delete."
                          % b.get("sensitivity", "sensitive"),
                "fix": "Enable versioning and an MFA-delete lifecycle policy.",
            })
    return fs


def r_crm004_iam_wildcard(inv):
    fs = []
    for role in roles(inv):
        for pol in role.get("policies", []):
            for st in pol.get("statements", []):
                if st.get("effect") == "Allow" and st.get("action") == "*" and st.get("resource") == "*":
                    fs.append({
                        "id": "CRM-004", "severity": "critical",
                        "rule": "IAM role grants Action:\"*\" on Resource:\"*\"",
                        "resource": "role/%s" % role["id"],
                        "detail": "Policy \"%s\" allows every action on every resource (attached to %s)."
                                  % (pol.get("name", "?"), role.get("purpose", "workload")),
                        "fix": "Replace wildcard with least-privilege model-invoke + scoped S3 read.",
                    })
    return fs


def r_crm005_stale_access_key(inv):
    fs = []
    for role in roles(inv):
        for k in role.get("access_keys", []):
            if k.get("age_days", 0) >= 180:
                fs.append({
                    "id": "CRM-005", "severity": "medium",
                    "rule": "Long-lived access key past rotation window",
                    "resource": "role/%s key %s" % (role["id"], k.get("id", "?")),
                    "detail": "Key age %s days (policy: rotate at 90); last used %s."
                              % (k.get("age_days", "?"), k.get("last_used", "unknown")),
                    "fix": "Rotate the key and migrate the CI job to short-lived STS credentials.",
                })
    return fs


def r_crm006_mfa_disabled(inv):
    fs = []
    for role in roles(inv):
        if role.get("mfa") == "disabled" and role.get("access_keys"):
            fs.append({
                "id": "CRM-006", "severity": "medium",
                "rule": "Principal with long-lived keys and MFA disabled",
                "resource": "role/%s" % role["id"],
                "detail": "MFA is disabled on a principal that holds static access keys.",
                "fix": "Enforce MFA and remove static keys in favor of federated access.",
            })
    return fs


def r_crm007_sg_open_ingress(inv):
    fs = []
    for sg in sgs(inv):
        for ing in sg.get("ingress", []):
            if ing.get("cidr") == "0.0.0.0/0":
                fs.append({
                    "id": "CRM-007", "severity": "high",
                    "rule": "Security group allows 0.0.0.0/0 ingress",
                    "resource": "%s :%s" % (sg["id"], ing.get("port", "?")),
                    "detail": "Port %s/%s open to the entire internet (%s), fronting %s."
                              % (ing.get("port", "?"), ing.get("proto", "tcp"),
                                 ing.get("desc", ""), sg.get("attached_to", "?")),
                    "fix": "Restrict ingress to the API gateway / WAF prefix list; drop 0.0.0.0/0.",
                })
    return fs


def r_crm008_public_endpoint_no_auth(inv):
    fs = []
    for s in services(inv):
        if s.get("type") in ("ai-endpoint",) and s.get("public_access") and s.get("authentication") == "none":
            fs.append({
                "id": "CRM-008", "severity": "critical",
                "rule": "AI inference endpoint public with no authentication",
                "resource": "endpoint/%s" % s["id"],
                "detail": "\"%s\" is internet-reachable with authentication=none."
                          % s.get("name", s["id"]),
                "fix": "Put the endpoint behind OIDC/API-gateway auth; disable anonymous invoke.",
            })
    return fs


def r_crm009_shadow_service(inv):
    fs = []
    for s in services(inv):
        if not s.get("registered", True):
            fs.append({
                "id": "CRM-009", "severity": "high",
                "rule": "Unregistered (shadow) AI service in the estate",
                "resource": "endpoint/%s" % s["id"],
                "detail": "\"%s\" is not in the model registry; reads from %s."
                          % (s.get("name", s["id"]), ", ".join(s.get("reads_from", [])) or "?"),
                "fix": "Register or decommission; unmanaged endpoints bypass all guardrails.",
            })
    return fs


def r_crm010_no_guardrails(inv):
    fs = []
    for s in services(inv):
        if s.get("type") == "ai-endpoint" and s.get("guardrails") is False:
            fs.append({
                "id": "CRM-010", "severity": "medium",
                "rule": "Production LLM endpoint without content guardrails",
                "resource": "endpoint/%s" % s["id"],
                "detail": "\"%s\" has no prompt-injection / output guardrails enabled."
                          % s.get("name", s["id"]),
                "fix": "Attach the Vision One AI guardrail policy (injection + output filtering).",
            })
    return fs


def r_crm011_endpoint_reads_public_bucket(inv):
    fs = []
    pub = set()
    for b in buckets(inv):
        if b.get("public_access"):
            pub.add(b["id"])
    for s in services(inv):
        for src in s.get("reads_from", []):
            if src in pub:
                fs.append({
                    "id": "CRM-011", "severity": "high",
                    "rule": "AI service sources data from a public bucket",
                    "resource": "endpoint/%s → s3://%s" % (s["id"], src),
                    "detail": "\"%s\" indexes s3://%s, which is publicly writable-exposed — RAG poisoning risk."
                              % (s.get("name", s["id"]), src),
                    "fix": "Lock the source bucket down (CRM-001) before it feeds the model.",
                })
    return fs


def r_crm012_public_pii_bucket(inv):
    fs = []
    for b in buckets(inv):
        cls = b.get("tags", {}).get("data-class", "")
        if b.get("public_access") and ("pii" in cls or b.get("sensitivity") == "restricted"):
            fs.append({
                "id": "CRM-012", "severity": "critical",
                "rule": "Public bucket holds restricted/PII data",
                "resource": "s3://%s" % b["id"],
                "detail": "Public bucket tagged data-class=%s — direct data-exposure exposure." % cls,
                "fix": "Block public access immediately and audit access logs for exfiltration.",
            })
    return fs


def r_crm013_shadow_reads_restricted(inv):
    fs = []
    restricted = {}
    for b in buckets(inv):
        restricted[b["id"]] = b.get("sensitivity")
    for s in services(inv):
        if s.get("registered", True):
            continue
        for src in s.get("reads_from", []):
            if restricted.get(src) == "restricted":
                fs.append({
                    "id": "CRM-013", "severity": "high",
                    "rule": "Shadow service reads restricted training data",
                    "resource": "endpoint/%s → s3://%s" % (s["id"], src),
                    "detail": "Unregistered \"%s\" reads restricted s3://%s (customer-PII corpus)."
                              % (s.get("name", s["id"]), src),
                    "fix": "Cut the shadow endpoint's access to restricted buckets; then decommission it.",
                })
    return fs


def r_crm014_wildcard_plus_public_path(inv):
    """Correlation rule: a wildcard-IAM workload sitting behind an open SG."""
    fs = []
    open_sgs = set()
    for sg in sgs(inv):
        for ing in sg.get("ingress", []):
            if ing.get("cidr") == "0.0.0.0/0":
                open_sgs.add(sg["id"])
    wildcard_roles = []
    for role in roles(inv):
        for pol in role.get("policies", []):
            for st in pol.get("statements", []):
                if st.get("action") == "*" and st.get("resource") == "*":
                    wildcard_roles.append(role["id"])
    # The inference endpoint behind an open SG runs on the wildcard workload role.
    for s in services(inv):
        if s.get("security_group") in open_sgs and s.get("public_access") and wildcard_roles:
            fs.append({
                "id": "CRM-014", "severity": "critical",
                "rule": "Toxic combination: internet-open endpoint + over-privileged workload",
                "resource": "endpoint/%s + role/%s" % (s["id"], wildcard_roles[0]),
                "detail": "Public endpoint \"%s\" runs on wildcard role %s — a single compromise = full-account access."
                          % (s.get("name", s["id"]), wildcard_roles[0]),
                "fix": "Break either link: scope the role (CRM-004) or close the SG (CRM-007).",
            })
            break
    return fs


def r_crm015_no_versioning_state(inv):
    fs = []
    for b in buckets(inv):
        if b.get("id", "").endswith("terraform-state") and not b.get("versioning"):
            fs.append({
                "id": "CRM-015", "severity": "medium",
                "rule": "IaC state backend without versioning",
                "resource": "s3://%s" % b["id"],
                "detail": "Terraform state bucket lacks versioning; corrupt state is unrecoverable.",
                "fix": "Enable versioning and state locking on the backend.",
            })
    return fs


RULES = [
    r_crm001_public_bucket,
    r_crm002_unencrypted_bucket,
    r_crm003_bucket_no_versioning,
    r_crm004_iam_wildcard,
    r_crm005_stale_access_key,
    r_crm006_mfa_disabled,
    r_crm007_sg_open_ingress,
    r_crm008_public_endpoint_no_auth,
    r_crm009_shadow_service,
    r_crm010_no_guardrails,
    r_crm011_endpoint_reads_public_bucket,
    r_crm012_public_pii_bucket,
    r_crm013_shadow_reads_restricted,
    r_crm014_wildcard_plus_public_path,
    r_crm015_no_versioning_state,
]


def evaluate(inv):
    findings = []
    for rule in RULES:
        findings.extend(rule(inv))
    findings.sort(key=lambda f: (SEV_ORDER.get(f["severity"], 9), f["id"], f["resource"]))
    return findings


def score(findings):
    """0-100 risk score. 0 = clean, higher = worse. Weighted, capped at 100."""
    total = 0
    for f in findings:
        total += SEV_WEIGHT.get(f["severity"], 0)
    return min(100, total)


def grade(risk):
    if risk >= 75:
        label = "Critical risk"
    elif risk >= 50:
        label = "High risk"
    elif risk >= 25:
        label = "Moderate risk"
    elif risk > 0:
        label = "Low risk"
    else:
        label = "No open findings"
    return "%d/100 — %s" % (risk, label)


def sev_counts(findings):
    c = {"critical": 0, "high": 0, "medium": 0, "low": 0}
    for f in findings:
        if f["severity"] in c:
            c[f["severity"]] += 1
    return c


# ── attack path (defensive narrative) ───────────────────────────────────────

def build_attack_path(inv, findings):
    """Derive a logical dependency chain from the *actual* findings.
    This explains WHY misconfigurations compound; it is not an exploit recipe."""
    ids = set(f["id"] for f in findings)
    steps = []

    open_sg = None
    for sg in sgs(inv):
        for ing in sg.get("ingress", []):
            if ing.get("cidr") == "0.0.0.0/0":
                open_sg = (sg["id"], ing.get("port", "?"))
                break
        if open_sg:
            break

    pub_endpoint = None
    for s in services(inv):
        if s.get("type") == "ai-endpoint" and s.get("public_access") and s.get("authentication") == "none":
            pub_endpoint = s
            break

    wildcard_role = None
    for role in roles(inv):
        for pol in role.get("policies", []):
            for st in pol.get("statements", []):
                if st.get("action") == "*" and st.get("resource") == "*":
                    wildcard_role = role["id"]
                    break

    pub_bucket = None
    for b in buckets(inv):
        if b.get("public_access"):
            pub_bucket = b["id"]
            break

    model_bucket = None
    for b in buckets(inv):
        if b.get("id", "").endswith("model-artifacts"):
            model_bucket = b["id"]

    n = 0
    if open_sg and "CRM-007" in ids:
        n += 1
        steps.append("Step %d — Entry: %s allows 0.0.0.0/0 on port %s, so the inference tier is "
                     "reachable from anywhere on the internet (finding CRM-007)."
                     % (n, open_sg[0], open_sg[1]))
    if pub_endpoint and "CRM-008" in ids:
        n += 1
        steps.append("Step %d — Foothold: endpoint %s is public with authentication=none, so requests "
                     "hit the model with no credential check (finding CRM-008)."
                     % (n, pub_endpoint["id"]))
    if wildcard_role and ("CRM-004" in ids or "CRM-014" in ids):
        n += 1
        steps.append("Step %d — Privilege: that workload runs on role %s, which grants Action:\"*\" on "
                     "Resource:\"*\" — one compromised process inherits full-account rights (CRM-004)."
                     % (n, wildcard_role))
    if pub_bucket and ("CRM-001" in ids or "CRM-011" in ids):
        n += 1
        steps.append("Step %d — Data path: the RAG source s3://%s is publicly exposed and feeds the "
                     "model, so its contents (and any poisoned document) reach inference (CRM-011)."
                     % (n, pub_bucket))
    if model_bucket and wildcard_role:
        n += 1
        steps.append("Step %d — Objective: with wildcard IAM the same identity can read the model store "
                     "s3://%s — proprietary weights and checkpoints — the crown-jewel target."
                     % (n, model_bucket))

    if not steps:
        steps.append("No exploitable chain: the open-ingress / public-endpoint / wildcard-IAM "
                     "prerequisites are no longer all present. Chain is broken.")
        return steps

    steps.append("Impact — Chained together these five weaknesses turn one internet request into "
                 "read access over customer data and proprietary model weights, with no auth barrier.")
    steps.append("Break the chain (remediation) — 1) Close %s to a WAF/prefix list (CRM-007); "
                 "2) Scope role %s to least privilege (CRM-004). Removing either link stops the path."
                 % (open_sg[0] if open_sg else "the open SG",
                    wildcard_role if wildcard_role else "the workload role"))
    return steps


# ── result file ─────────────────────────────────────────────────────────────

def write_assessment(lab_dir, inv, findings, remediated):
    risk = score(findings)
    path = os.path.join(lab_dir, "assessment.json")
    doc = {
        "lab": LAB_SLUG,
        "generated": now_iso(),
        "risk_score": risk,
        "summary": sev_counts(findings),
        "findings": [
            {"id": f["id"], "severity": f["severity"], "rule": f["rule"],
             "resource": f["resource"], "detail": f["detail"], "fix": f["fix"]}
            for f in findings
        ],
        "attack_path": build_attack_path(inv, findings),
        "remediated": bool(remediated),
    }
    with open(path, "w") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    return path


# ── rendering ───────────────────────────────────────────────────────────────

def header(subtitle):
    out(DIV)
    out("Forge Lab · Trend Vision One — Cloud Risk Management")
    out(subtitle)
    out(DIV)


def sev_tag(sev):
    return {"critical": "CRIT", "high": "HIGH", "medium": "MED ", "low": "LOW "}.get(sev, sev[:4].upper())


def estate_summary(inv):
    return ("Estate: account %s (%s) · %d buckets · %d IAM roles · %d security groups · %d AI services"
            % (inv.get("account", "?"), inv.get("region", "?"),
               len(buckets(inv)), len(roles(inv)), len(sgs(inv)), len(services(inv))))


# ── commands ────────────────────────────────────────────────────────────────

def cmd_assess(lab_dir, data_dir, remediated_flag=None):
    inv = load_inventory(data_dir)
    header("Posture assessment · CSPM rule pack v2026.07 · %d rules · provider: aws"
           % len(RULES))
    out(estate_summary(inv))
    out("Scanning resources against %d weighted posture rules…" % len(RULES))
    out(DIV)

    findings = evaluate(inv)
    t0 = time.time()
    idx = 0
    for f in findings:
        idx += 1
        out("[%s] %-8s %-52s" % (sev_tag(f["severity"]), f["id"], f["rule"]))
        out("        resource : %s" % f["resource"])
        out("        detail   : %s" % f["detail"])
        out("        fix      : %s" % f["fix"])
        out("")
        time.sleep(SLEEP)

    counts = sev_counts(findings)
    risk = score(findings)
    out(DIV)
    out("Assessment complete · %d findings in %.1fs" % (len(findings), time.time() - t0))
    out("  Critical : %2d" % counts["critical"])
    out("  High     : %2d" % counts["high"])
    out("  Medium   : %2d" % counts["medium"])
    out("  Low      : %2d" % counts["low"])
    out("")
    out("Overall cloud risk score: %s" % grade(risk))
    if remediated_flag is None:
        remediated_flag = _read_remediated(lab_dir)
    path = write_assessment(lab_dir, inv, findings, remediated_flag)
    out("Assessment written: %s" % path)
    out(DIV)
    return findings, risk


def cmd_attack_path(lab_dir, data_dir):
    inv = load_inventory(data_dir)
    findings = evaluate(inv)
    header("Attack-path analysis · derived from live findings · defensive narrative")
    out(estate_summary(inv))
    crit_high = [f for f in findings if f["severity"] in ("critical", "high")]
    out("Correlating %d critical/high findings into a risk chain…" % len(crit_high))
    out(DIV)

    steps = build_attack_path(inv, findings)
    for step in steps:
        # Blank line before Impact / Break-the-chain for readability.
        if step.startswith("Impact") or step.startswith("Break the chain"):
            out("")
        out(step)
        time.sleep(SLEEP)

    out(DIV)
    out("This chain is a logical dependency map of misconfigurations — it shows why the findings")
    out("matter together. Remediating any single linking finding collapses the path.")
    # Refresh the result file so attack_path is persisted with current state.
    write_assessment(lab_dir, inv, findings, _read_remediated(lab_dir))
    out(DIV)


def _read_remediated(lab_dir):
    path = os.path.join(lab_dir, "assessment.json")
    if os.path.isfile(path):
        try:
            with open(path, "r") as fh:
                return bool(json.load(fh).get("remediated", False))
        except Exception:
            return False
    return False


def _apply_remediations(inv):
    """Mutate the inventory to fix the linking findings. Returns list of changes."""
    changes = []

    # CRM-007: close the 0.0.0.0/0 ingress on the inference SG.
    for sg in sgs(inv):
        for ing in sg.get("ingress", []):
            if ing.get("cidr") == "0.0.0.0/0":
                ing["cidr"] = "198.51.100.0/24"
                ing["desc"] = "inference API (HTTPS) — restricted to API-gateway prefix list"
                changes.append("CRM-007  %s :%s ingress 0.0.0.0/0 → 198.51.100.0/24 (gateway prefix)"
                               % (sg["id"], ing.get("port", "?")))

    # CRM-001 / CRM-012 / CRM-011: block public access on the RAG bucket.
    for b in buckets(inv):
        if b.get("public_access"):
            b["public_access"] = False
            b["public_access_reason"] = "Block Public Access enabled; wildcard policy removed"
            changes.append("CRM-001  s3://%s public read → Block Public Access ON" % b["id"])

    # CRM-002: enable encryption on the unencrypted bucket.
    for b in buckets(inv):
        if str(b.get("encryption", "none")).lower() in ("none", "", "off"):
            b["encryption"] = "SSE-KMS"
            changes.append("CRM-002  s3://%s encryption none → SSE-KMS (CMK)" % b["id"])

    # CRM-004 / CRM-014: scope the wildcard workload role to least privilege.
    for role in roles(inv):
        for pol in role.get("policies", []):
            new_st = []
            replaced = False
            for st in pol.get("statements", []):
                if st.get("action") == "*" and st.get("resource") == "*":
                    replaced = True
                    new_st.append({"effect": "Allow", "action": "bedrock:InvokeModel",
                                   "resource": "arn:aws:bedrock:us-east-1::model/acme-instruct-13b"})
                    new_st.append({"effect": "Allow", "action": "s3:GetObject",
                                   "resource": "arn:aws:s3:::acme-vector-db/*"})
                else:
                    new_st.append(st)
            if replaced:
                pol["statements"] = new_st
                changes.append("CRM-004  role/%s Action:* Resource:* → scoped invoke + read"
                               % role["id"])

    # CRM-008 / CRM-010: put the public no-auth endpoint behind auth + guardrails.
    for s in services(inv):
        if s.get("type") == "ai-endpoint" and s.get("public_access") and s.get("authentication") == "none" \
                and s.get("registered", True):
            s["public_access"] = False
            s["authentication"] = "oidc"
            s["guardrails"] = True
            changes.append("CRM-008  endpoint/%s public+no-auth → private + OIDC + guardrails" % s["id"])

    # CRM-009 / CRM-013: decommission the shadow endpoint.
    keep = []
    for s in services(inv):
        if not s.get("registered", True):
            changes.append("CRM-009  endpoint/%s (shadow) decommissioned and removed" % s["id"])
        else:
            keep.append(s)
    inv["ai_services"] = keep

    # CRM-005 / CRM-006: rotate the stale key + enforce MFA.
    for role in roles(inv):
        if role.get("access_keys"):
            for k in role["access_keys"]:
                if k.get("age_days", 0) >= 180:
                    k["age_days"] = 0
                    k["created"] = now_iso()[:10]
                    changes.append("CRM-005  role/%s key %s rotated (age → 0d)"
                                   % (role["id"], k.get("id", "?")))
            if role.get("mfa") == "disabled":
                role["mfa"] = "enforced"
                changes.append("CRM-006  role/%s MFA disabled → enforced" % role["id"])

    return changes


def cmd_remediate(lab_dir, data_dir):
    inv = load_inventory(data_dir)
    before = evaluate(inv)
    before_risk = score(before)
    header("Guided remediation · applying fixes to runtime inventory")
    out(estate_summary(inv))
    out("Baseline risk score: %s" % grade(before_risk))
    out(DIV)

    changes = _apply_remediations(inv)
    save_inventory(data_dir, inv)

    out("Applied %d remediation actions:" % len(changes))
    for c in changes:
        out("  ✓ %s" % c)
        time.sleep(SLEEP)
    out(DIV)

    after = evaluate(inv)
    after_risk = score(after)
    counts = sev_counts(after)
    out("Re-assessing posture after remediation…")
    out("  before : %s" % grade(before_risk))
    out("  after  : %s" % grade(after_risk))
    out("  delta  : -%d points (%d → %d findings)"
        % (before_risk - after_risk, len(before), len(after)))
    out("")
    out("Residual findings by severity: crit=%d high=%d med=%d low=%d"
        % (counts["critical"], counts["high"], counts["medium"], counts["low"]))
    if after:
        out("Remaining items (lower priority — hygiene, not exposure):")
        for f in after:
            out("  [%s] %-8s %s" % (sev_tag(f["severity"]), f["id"], f["resource"]))
    else:
        out("No residual findings — estate is clean.")
    path = write_assessment(lab_dir, inv, after, True)
    out("")
    out("Assessment written: %s" % path)
    out("Attack path status: %s" % build_attack_path(inv, after)[0][:70])
    out(DIV)
    out("Run 'assess' again for the full post-remediation report, or 'reset' to restore the estate.")
    out(DIV)


# ── entry ───────────────────────────────────────────────────────────────────

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
    if mode == "assess":
        cmd_assess(lab_dir, data_dir)
    elif mode == "attack-path":
        cmd_attack_path(lab_dir, data_dir)
    elif mode == "remediate":
        cmd_remediate(lab_dir, data_dir)
    else:
        die("unknown mode %r (expected: assess | attack-path | remediate)" % mode)


if __name__ == "__main__":
    main(sys.argv)
