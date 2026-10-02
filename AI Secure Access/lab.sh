#!/bin/bash
# Forge Lab · Trend Vision One — AI Secure Access (slug: ai-access)
# Bash 3.2 compatible. Verbs: setup | status | replay | shadow-report | reset | teardown
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${TREND_LAB_HOME:-$HOME/.trend-lab}"
SLUG="ai-access"
LAB="$ROOT_DIR/labs/$SLUG"
SEED_DIR="$SCRIPT_DIR/data"
export PYTHONUNBUFFERED=1

usage() {
  echo "usage: lab.sh {setup|status|replay|shadow-report|reset|teardown}"
}

copy_seeds() {
  mkdir -p "$LAB/data"
  cp -f "$SEED_DIR/traffic.jsonl" "$LAB/data/traffic.jsonl"
  cp -f "$SEED_DIR/policies.json" "$LAB/data/policies.json"
}

do_setup() {
  echo "Forge Lab · Trend Vision One — AI Secure Access · setup"
  copy_seeds
  EVENTS="$(wc -l < "$LAB/data/traffic.jsonl" | tr -d ' ')"
  echo "Seeded lab state: $LAB"
  echo "  data/traffic.jsonl   ($EVENTS employee→AI events, pristine copy)"
  echo "  data/policies.json   (policy bundle v2026.07: approved services, DLP, injection, uploads)"
  echo "Setup complete. Run 'replay' to stream the day of traffic through the policy engine."
}

ensure_seeded() {
  if [ ! -f "$LAB/data/traffic.jsonl" ] || [ ! -f "$LAB/data/policies.json" ]; then
    do_setup
    echo ""
  fi
}

do_status() {
  echo "Forge Lab · Trend Vision One — AI Secure Access · status"
  if [ -f "$LAB/data/traffic.jsonl" ] && [ -f "$LAB/data/policies.json" ]; then
    echo "state: seeded ($LAB)"
    if [ -f "$LAB/summary.json" ]; then
      python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); t=d["totals"]
print("last run: allow=%d block=%d redact=%d · shadow services=%d · generated %s"
      % (t["allow"], t["block"], t["redact"], len(d["shadow_services"]), d["generated"]))' \
        "$LAB/summary.json" 2>/dev/null || echo "last run: summary.json unreadable"
    else
      echo "last run: none — run 'replay' or 'shadow-report'"
    fi
  else
    echo "state: not seeded — run 'setup' (any run verb will also auto-seed)"
  fi
  exit 0
}

do_reset() {
  echo "Forge Lab · Trend Vision One — AI Secure Access · reset"
  copy_seeds
  rm -f "$LAB/events.jsonl" "$LAB/summary.json"
  echo "Runtime data restored to pristine seed copies; result files cleared."
  echo "  restored: $LAB/data/traffic.jsonl, $LAB/data/policies.json"
  echo "  removed:  events.jsonl, summary.json"
}

do_teardown() {
  echo "Forge Lab · Trend Vision One — AI Secure Access · teardown"
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
  replay)
    ensure_seeded
    python3 "$SCRIPT_DIR/asa.py" replay --lab "$LAB"
    ;;
  shadow-report)
    ensure_seeded
    python3 "$SCRIPT_DIR/asa.py" shadow-report --lab "$LAB"
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
