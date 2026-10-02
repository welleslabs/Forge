#!/bin/bash
# Forge Lab · AI Risk Insights — lab entry point.
# Bash 3.2 compatible (macOS system bash). Verbs: setup | status | report | reset | teardown
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLUG="ai-insights"
ROOT_DIR="${TREND_LAB_HOME:-$HOME/.trend-lab}"
LAB="$ROOT_DIR/labs/$SLUG"
SEED_DIR="$SCRIPT_DIR/seed"

export PYTHONUNBUFFERED=1

HR="──────────────────────────────────────────────────────────────────────────────────────"

usage() {
  echo "usage: lab.sh {setup|status|report|reset|teardown}"
}

seed_lab() {
  mkdir -p "$LAB"
  cp -f "$SEED_DIR/asset-registry.json" "$LAB/asset-registry.json"
  cp -f "$SEED_DIR/scoring-config.json" "$LAB/scoring-config.json"
}

do_setup() {
  echo "$HR"
  echo "Forge Lab · AI Risk Insights — setup"
  echo "$HR"
  seed_lab
  echo "✓ AI asset registry seeded     → labs/$SLUG/asset-registry.json"
  echo "✓ Risk scoring config seeded   → labs/$SLUG/scoring-config.json"
  echo "✓ Lab ready · state root: $ROOT_DIR"
}

do_status() {
  echo "Forge Lab · AI Risk Insights — status"
  if [ -f "$LAB/asset-registry.json" ] && [ -f "$LAB/scoring-config.json" ]; then
    echo "✓ seeded · $LAB"
  else
    echo "○ not seeded — run setup"
  fi
  if [ -f "$LAB/report.json" ]; then
    python3 - "$LAB/report.json" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
    src = ", ".join(d.get("sources_present") or []) or "none"
    print("● last report: overall risk %s/100 · lab sources: %s · generated %s"
          % (d.get("overall_score", "?"), src, d.get("generated", "?")))
except Exception:
    print("● last report: present but unreadable — run report to regenerate")
PYEOF
  else
    echo "● no report yet — run the report phase"
  fi
  exit 0
}

do_reset() {
  echo "Forge Lab · AI Risk Insights — reset"
  seed_lab
  rm -f "$LAB/report.json"
  echo "✓ pristine seed data restored"
  echo "✓ result files cleared (report.json)"
}

do_teardown() {
  echo "Forge Lab · AI Risk Insights — teardown"
  rm -rf "$LAB"
  echo "✓ removed $LAB"
  exit 0
}

ensure_setup() {
  if [ ! -f "$LAB/asset-registry.json" ] || [ ! -f "$LAB/scoring-config.json" ]; then
    do_setup
    echo ""
  fi
}

VERB="${1:-}"
case "$VERB" in
  setup)
    do_setup
    ;;
  status)
    do_status
    ;;
  report)
    ensure_setup
    python3 "$SCRIPT_DIR/insights.py" report
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
