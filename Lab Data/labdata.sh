#!/bin/bash
# Forge — shared demo-lab data orchestrator.
#
# Seeds / reports / wipes the runtime state for every self-contained lab
# (Code & Container Security, Cloud Risk Management, AI Secure Access,
# AI Risk Insights) so the Environment screen can spin the whole set up and
# down with one click. The individual labs remain fully usable on their own —
# each lab.sh auto-seeds on first run.
#
# Verbs: setup | status | teardown   (extra args, e.g. --products/-y, are ignored)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # the projects folder
ROOT_DIR="${TREND_LAB_HOME:-$HOME/.trend-lab}"
LABS_DIR="$ROOT_DIR/labs"

# Active self-contained labs. Cloud Risk Management, AI Secure Access, and AI Risk
# Insights are previews right now, so they're not seeded; add them back here when a
# lab is re-activated in the catalog.
LAB_FOLDERS=(
  "Code & Container Security"
)

verb="${1:-status}"

# Run one sub-verb across every lab, reporting per-lab success. Returns the
# number of failures so callers can decide how loudly to fail.
run_each() {
  local sub="$1"
  local failures=0
  local f script
  for f in "${LAB_FOLDERS[@]}"; do
    script="$HERE/$f/lab.sh"
    echo "── $f ──────────────────────────────────────────"
    if [[ -f "$script" ]]; then
      if ! bash "$script" "$sub"; then
        echo "✗ $f: '$sub' failed"
        failures=$((failures + 1))
      fi
    else
      echo "✗ $f: lab.sh not found at $script"
      failures=$((failures + 1))
    fi
  done
  return $failures
}

case "$verb" in
  setup)
    echo "Forge · Demo lab data — seeding all self-contained labs"
    if run_each setup; then
      echo "✓ Demo lab data ready under $LABS_DIR"
    else
      echo "✗ One or more labs failed to seed — see output above."
      exit 1
    fi
    ;;
  status)
    echo "Forge · Demo lab data — status"
    run_each status || true
    ;;
  teardown)
    echo "Forge · Demo lab data — removing $LABS_DIR"
    rm -rf "$LABS_DIR"
    echo "✓ All demo lab data removed."
    ;;
  *)
    echo "Usage: $0 setup|status|teardown" >&2
    exit 1
    ;;
esac
