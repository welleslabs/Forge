#!/bin/bash
# Forge Lab · Trend Vision One — Cloud Risk Management (slug: cloud-risk)
# Bash 3.2 compatible. Verbs: setup | status | assess | attack-path | remediate | reset | teardown
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${TREND_LAB_HOME:-$HOME/.trend-lab}"
SLUG="cloud-risk"
LAB="$ROOT_DIR/labs/$SLUG"
SEED_DIR="$SCRIPT_DIR/data"
export PYTHONUNBUFFERED=1

usage() {
  echo "usage: lab.sh {setup|status|assess|attack-path|remediate|reset|teardown}"
}

# ---------- Hybrid mock / live ----------
# TREND_LAB_MODE=live (set by Forge ▸ Settings ▸ Lab data mode) makes 'assess' pull
# the real Cloud Risk Management posture from your Trend Vision One tenant. Any
# failure (no key, HTTP error, unexpected shape) falls back to the offline mock, so
# the demo never dead-ends. attack-path and remediate remain the mock narrative —
# they model a demo arc that has no direct read-API equivalent.
LAB_MODE="${TREND_LAB_MODE:-mock}"

live_ready() {
  [ "$LAB_MODE" = "live" ] || return 1
  [ -n "${V1_API_KEY:-}${TMAS_API_KEY:-}" ] || return 1
  return 0
}

copy_seeds() {
  mkdir -p "$LAB/data"
  cp -f "$SEED_DIR/inventory.json" "$LAB/data/inventory.json"
}

do_setup() {
  echo "Forge Lab · Trend Vision One — Cloud Risk Management · setup"
  copy_seeds
  BUCKETS="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["storage_buckets"]))' "$LAB/data/inventory.json" 2>/dev/null || echo '?')"
  ROLES="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["iam_roles"]))' "$LAB/data/inventory.json" 2>/dev/null || echo '?')"
  SVCS="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["ai_services"]))' "$LAB/data/inventory.json" 2>/dev/null || echo '?')"
  echo "Seeded lab state: $LAB"
  echo "  data/inventory.json   (mock estate: acme-ai-prod / us-east-1)"
  echo "  resources: $BUCKETS storage buckets · $ROLES IAM roles · $SVCS AI services (pristine copy)"
  echo "Setup complete. Run 'assess' to evaluate the estate against the posture rule pack."
}

ensure_seeded() {
  if [ ! -f "$LAB/data/inventory.json" ]; then
    do_setup
    echo ""
  fi
}

do_status() {
  echo "Forge Lab · Trend Vision One — Cloud Risk Management · status"
  if [ -f "$LAB/data/inventory.json" ]; then
    echo "state: seeded ($LAB)"
    if [ -f "$LAB/assessment.json" ]; then
      python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); s=d["summary"]
print("last run: risk=%d/100 · crit=%d high=%d med=%d low=%d · remediated=%s · generated %s"
      % (d["risk_score"], s["critical"], s["high"], s["medium"], s["low"],
         d["remediated"], d["generated"]))' \
        "$LAB/assessment.json" 2>/dev/null || echo "last run: assessment.json unreadable"
    else
      echo "last run: none — run 'assess', 'attack-path', or 'remediate'"
    fi
  else
    echo "state: not seeded — run 'setup' (any run verb will also auto-seed)"
  fi
  exit 0
}

do_reset() {
  echo "Forge Lab · Trend Vision One — Cloud Risk Management · reset"
  copy_seeds
  rm -f "$LAB/assessment.json"
  echo "Runtime inventory restored to pristine seed (remediation undone); result files cleared."
  echo "  restored: $LAB/data/inventory.json"
  echo "  removed:  assessment.json"
}

do_teardown() {
  echo "Forge Lab · Trend Vision One — Cloud Risk Management · teardown"
  rm -rf "$LAB"
  echo "Removed lab state: $LAB"
  exit 0
}

VERB="${1:-}"
case "$VERB" in
  setup)
    do_setup
    ;;
  status)
    do_status
    ;;
  assess)
    if live_ready; then
      if python3 "$SCRIPT_DIR/crm_live.py"; then
        exit 0
      fi
      echo ""
      echo "! Live assessment unavailable — falling back to the offline mock estate."
      echo ""
    elif [ "$LAB_MODE" = "live" ]; then
      echo "! Live mode requested, but no Trend Vision One API key is set — add one in Settings (⌘,). Falling back to mock."
      echo ""
    fi
    ensure_seeded
    python3 "$SCRIPT_DIR/crm.py" assess --lab "$LAB"
    ;;
  attack-path)
    ensure_seeded
    python3 "$SCRIPT_DIR/crm.py" attack-path --lab "$LAB"
    ;;
  remediate)
    ensure_seeded
    python3 "$SCRIPT_DIR/crm.py" remediate --lab "$LAB"
    ;;
  reset)
    do_reset
    ;;
  teardown)
    do_teardown
    ;;
  *)
    usage
    exit 1
    ;;
esac
