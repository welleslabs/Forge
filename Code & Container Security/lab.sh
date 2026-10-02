#!/bin/bash
#
# Forge Lab · Code & Container Security (slug: code-container)
# -----------------------------------------------------------
# Shift-left security for one AI workload (Nimbus AI Chat Service, app/),
# scanned two complementary ways — the two buttons:
#
#   Scan Code & Dependencies  → CODE SECURITY scan of the source tree
#                               (tmas dir: scan → a "Directory" artifact:
#                                vulnerable dependencies + hardcoded secrets).
#   Audit Container Image      → CONTAINER IMAGE scan of the built image
#                               (tmas docker-archive: → OS + dependency CVEs,
#                                malware, secrets).
#
# Both upload to Trend Vision One on a live run (different artifact TYPES, so
# they are distinct entries, not duplicates). Two modes:
#   MOCK (default) — offline engine (ccs.py): deps-vs-CVE-DB + source SAST for the
#                    code scan; Dockerfile hardening lint for the image scan.
#   LIVE (Settings ▸ Lab data mode = Live) — real tmas scans that upload to
#                    Vision One. Falls back to a public image / mock so a demo
#                    never dead-ends.
#
# Verbs: setup | status | scan-code | scan-image | reset | teardown [--all]
# Bash 3.2 compatible (macOS system bash). Stdlib-only Python engine.

set -euo pipefail
export PYTHONUNBUFFERED=1

# ---------- Identity / paths ----------
SLUG="code-container"
PRODUCT="Code & Container Security"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="${TREND_LAB_HOME:-$HOME/.trend-lab}"
LAB="$ROOT_DIR/labs/$SLUG"

ENGINE="$SCRIPT_DIR/ccs.py"
SEED_APP="$SCRIPT_DIR/app"
SEED_DATA="$SCRIPT_DIR/data"

BAR="────────────────────────────────────────────────────────────────────────────────────────"

# ---------- Hybrid mock / live ----------
LAB_MODE="${TREND_LAB_MODE:-mock}"
CCS_KEY="${CCS_API_KEY:-${TMAS_API_KEY:-${V1_API_KEY:-}}}"

# Per-deployment id so the artifacts this lab uploads don't collide when several SEs scan
# into ONE Vision One tenant. The app passes FORGE_DEMO_ID; a standalone run derives it from
# the machine name. Sanitized to alphanumerics so it's a safe artifact-name suffix.
FORGE_ID="${FORGE_DEMO_ID:-$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null || echo demo)}"
FORGE_ID="$(printf '%s' "$FORGE_ID" | tr -cd '[:alnum:]' | cut -c1-20)"; [ -n "$FORGE_ID" ] || FORGE_ID="demo"

# The image we build from the app — the artifact the image scan targets.
LIVE_IMAGE="forge-app:latest"
# Public fallback if a local image / runtime isn't available (tmas pulls it itself).
PUBLIC_TARGET="${CCS_SCAN_TARGET:-registry:python:3.9-slim}"

# tmas binary location.
if command -v tmas >/dev/null 2>&1; then TMAS_BIN="$(command -v tmas)"
elif [ -x "/opt/homebrew/bin/tmas" ]; then TMAS_BIN="/opt/homebrew/bin/tmas"
elif [ -x "/usr/local/bin/tmas" ]; then TMAS_BIN="/usr/local/bin/tmas"
else TMAS_BIN="tmas"; fi

have_tmas() { command -v tmas >/dev/null 2>&1 || [ -x "$TMAS_BIN" ]; }
docker_up() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
image_built() { docker_up && docker image inspect "$LIVE_IMAGE" >/dev/null 2>&1; }

# Map the Forge tenant region (V1_REGION) to tmas's --region enum (default us-east-1).
tmas_region() {
  case "${V1_REGION:-us}" in
    us)  echo "us-east-1" ;;
    eu)  echo "eu-central-1" ;;
    jp)  echo "ap-northeast-1" ;;
    sg)  echo "ap-southeast-1" ;;
    au)  echo "ap-southeast-2" ;;
    in)  echo "ap-south-1" ;;
    mea) echo "me-central-1" ;;
    *)   echo "us-east-1" ;;
  esac
}

# ---------- Phase banners ----------
PHASE_CURRENT=0
PHASE_TOTAL=5
phase() {
  PHASE_CURRENT=$((PHASE_CURRENT + 1))
  echo "@@STEP $PHASE_CURRENT $PHASE_TOTAL $1"   # progress-bar marker (filtered out of the console)
  echo
  echo "[$PHASE_CURRENT/$PHASE_TOTAL] $1"
  echo "$BAR"
}

# ---------- Live environment install (idempotent) ----------
ensure_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    echo "✓ Homebrew present: $(command -v brew)"
    return 0
  fi
  echo "→ Installing Homebrew (non-interactive)…"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null
  for p in /opt/homebrew/bin /usr/local/bin; do
    [ -x "$p/brew" ] && eval "$("$p/brew" shellenv)"
  done
  command -v brew >/dev/null 2>&1
}

ensure_runtime() {
  if docker_up; then
    echo "✓ Docker daemon reachable ($(docker --version 2>/dev/null))"
    return 0
  fi
  if ! command -v colima >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then
    echo "→ Installing Colima + docker CLI via Homebrew (no Docker Desktop needed)…"
    brew install colima docker
  else
    echo "✓ Colima + docker CLI present"
  fi
  echo "→ Starting Colima (first start downloads a small Linux VM; this can take a minute)…"
  colima start || true
  if docker_up; then
    echo "✓ Docker daemon reachable via Colima"
    return 0
  fi
  echo "! Could not bring up a Docker daemon — the image scan will use a public image instead."
  return 1
}

ensure_tmas() {
  if have_tmas; then
    echo "✓ tmas present: $("$TMAS_BIN" version 2>/dev/null | head -1 || echo "$TMAS_BIN")"
    return 0
  fi
  local arch bindir url zip
  arch="$(uname -m)"; [ "$arch" = "arm64" ] || arch="x86_64"
  if [ -w "/opt/homebrew/bin" ]; then bindir="/opt/homebrew/bin"
  elif [ -w "/usr/local/bin" ]; then bindir="/usr/local/bin"
  else bindir="$HOME/.local/bin"; mkdir -p "$bindir"; fi
  url="https://ast-cli.xdr.trendmicro.com/tmas-cli/latest/tmas-cli_Darwin_${arch}.zip"
  echo "→ Downloading tmas CLI ($arch) from Trend CDN…"
  zip="$(mktemp -d)/tmas.zip"
  if curl -fsSL "$url" -o "$zip" && unzip -o -q "$zip" -d "$(dirname "$zip")"; then
    mv "$(dirname "$zip")/tmas" "$bindir/tmas" && chmod +x "$bindir/tmas"
    TMAS_BIN="$bindir/tmas"
    echo "✓ tmas installed to $bindir (user-writable — no admin needed)"
    return 0
  fi
  echo "! Could not install tmas automatically — set up the AI Scanner lab (it installs tmas) or add tmas to PATH."
  return 1
}

build_image() {
  if ! docker_up; then
    echo "! No Docker daemon — skipping image build; the image scan will use the public image."
    return 1
  fi
  echo "→ Building $LIVE_IMAGE from the app's Dockerfile…"
  echo "  (pulls a deliberately old, vulnerable base the first time)"
  if docker build -t "$LIVE_IMAGE" "$LAB/app" 2>&1; then
    echo "✓ Built $LIVE_IMAGE — your app, ready to scan"
    return 0
  fi
  echo "! Image build failed — the image scan will use the public image instead."
  return 1
}

# ---------- Live scans ----------
live_ready() {
  [ "$LAB_MODE" = "live" ] || return 1
  have_tmas || return 1
  [ -n "$CCS_KEY" ] || return 1
  return 0
}

live_unavailable_reason() {
  [ "$LAB_MODE" = "live" ] || { echo ""; return; }
  if ! have_tmas; then
    echo "Live mode requested, but tmas isn't installed — run Set Up Environment (with Live mode on) to install it. Falling back to mock."
  elif [ -z "$CCS_KEY" ]; then
    echo "Live mode requested, but no Vision One API key is set for this lab — add it in Settings (⌘,). Falling back to mock."
  else
    echo ""
  fi
}

# Print a concise summary of a captured tmas JSON report — counts only, never the raw JSON
# (which is huge). Keeps the live console clean: a progress bar during, a short result after.
# $1 = file holding the tmas output.
print_scan_summary() {
  python3 - "$1" <<'PY' 2>/dev/null || echo "  (scan finished — see Vision One for the full report)"
import json, sys
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
i = raw.find("{")
d = {}
if i >= 0:
    try: d = json.JSONDecoder().raw_decode(raw[i:])[0]
    except Exception: d = {}
v = d.get("vulnerabilities", {}) or {}
s = d.get("secrets", {}) or {}
m = d.get("malware", {}) or {}
def g(x, k): return x.get(k, 0)
print("  Vulnerabilities : %s  (critical %s · high %s · medium %s · low %s)" % (
    g(v,"totalVulnCount"), g(v,"criticalCount"), g(v,"highCount"), g(v,"mediumCount"), g(v,"lowCount")))
mf = m.get("findings") or m.get("detections") or m.get("malwareFindings")
res = m.get("scanResult")
if isinstance(mf, list) and mf:      print("  Malware         : %d detected" % len(mf))
elif "scanResult" not in m:          print("  Malware         : not scanned")
elif res in (0, None):               print("  Malware         : clean")
else:                                print("  Malware         : flagged (%s) — see Vision One" % res)
print("  Secrets         : %s" % g(s,"unmitigatedFindingsCount"))
PY
}

# CODE SECURITY scan: scan the source tree. tmas analyzes a dir: artifact and uploads it to
# Vision One as a "Directory" artifact (source deps + secrets). The verbose JSON is captured
# (not streamed); the app shows a progress bar (driven by @ markers) and we
# print a short summary. No Docker required.
live_scan_code() {
  local region src stage rc=0 out
  region="$(tmas_region)"; src="$LAB/app"; stage="$LAB/forge-app-code-scan-$FORGE_ID"; out="$(mktemp)"
  echo "Forge Lab · $PRODUCT — Code Security scan (LIVE) → Vision One · region ${V1_REGION:-us}"
  echo "@@STATUS Preparing source…"
  rm -rf "$stage" 2>/dev/null || true
  cp -R "$src" "$stage"                    # staged under a clean name for the Vision One artifact
  echo "@@STATUS Scanning & uploading to Code Security…"
  if TMAS_API_KEY="$CCS_KEY" "$TMAS_BIN" scan "dir:$stage" -V -S -r "$region" >"$out" 2>&1; then rc=0; else rc=$?; fi
  rm -rf "$stage" 2>/dev/null || true
  echo "$BAR"
  if [ "$rc" -eq 0 ]; then
    echo "✓ Code scan complete — uploaded as a source (Directory) artifact."
    echo "  View it in Vision One → Code Security → CI/CD Artifacts."
    print_scan_summary "$out"
  else
    echo "✗ Code scan failed (exit $rc). Recent output:"; tail -n 25 "$out"
  fi
  rm -f "$out"
  return $rc
}

# CONTAINER IMAGE scan: build → export → scan the image artifact. Uploads to Vision One →
# Container Security. tmas ignores DOCKER_HOST (which Colima uses), so we export the image
# with `docker save` and scan the archive. The export is cached (keyed by image id) so repeat
# scans skip it. Verbose JSON is captured; the app shows a progress bar via @ markers.
live_scan_image() {
  local target="" tar="" idfile="" cur_id="" rc=0 region flags scanned_malware out
  region="$(tmas_region)"; out="$(mktemp)"

  # Full scan by default (vulns + malware + secrets): the image carries a planted EICAR test
  # file so malware returns a real detection. Malware (-M) uploads the layers and is the
  # slowest step — set CCS_FAST=1 to skip it (-V -S only) for a quicker run.
  flags="-V -M -S"; scanned_malware="yes"
  [ -n "${CCS_FAST:-}" ] && { flags="-V -S"; scanned_malware="no"; }

  tar="$LAB/forge-app-container-image-$FORGE_ID.tar"; idfile="$LAB/.forge-app-image-id"

  echo "Forge Lab · $PRODUCT — Container Image scan (LIVE) → Vision One · region ${V1_REGION:-us}"
  echo "@@STATUS Preparing…"

  if image_built; then
    cur_id="$(docker image inspect --format '{{.Id}}' "$LIVE_IMAGE" 2>/dev/null)"
    if [ -f "$tar" ] && [ -n "$cur_id" ] && [ "$cur_id" = "$(cat "$idfile" 2>/dev/null)" ]; then
      target="docker-archive:$tar"          # reuse cached export — image unchanged
    else
      echo "@@STATUS Exporting image…"
      if docker save "$LIVE_IMAGE" -o "$tar" 2>/dev/null; then
        printf '%s' "$cur_id" > "$idfile" 2>/dev/null || true
        target="docker-archive:$tar"
      else
        rm -f "$tar" "$idfile" 2>/dev/null || true; target="$PUBLIC_TARGET"
      fi
    fi
  else
    target="$PUBLIC_TARGET"
  fi

  if [ "$scanned_malware" = "yes" ]; then
    echo "@@STATUS Scanning & uploading (incl. malware — the longest step)…"
  else
    echo "@@STATUS Scanning & uploading…"
  fi
  # shellcheck disable=SC2086  # $flags is an intentional multi-word flag list
  if TMAS_API_KEY="$CCS_KEY" "$TMAS_BIN" scan "$target" $flags -r "$region" >"$out" 2>&1; then rc=0; else rc=$?; fi

  echo "$BAR"
  if [ "$rc" -eq 0 ]; then
    echo "✓ Image scan complete — uploaded to Vision One →"
    echo "  Cloud Security → Container Security → Log → Container Image Scanning."
    print_scan_summary "$out"
  else
    echo "✗ Image scan failed (exit $rc). Recent output:"; tail -n 25 "$out"
  fi
  rm -f "$out"
  return $rc
}

run_scan() {
  local mock_verb="$1" kind="$2"
  ensure_setup
  if live_ready; then
    # live_scan_code / live_scan_image each print their own completion line + findings summary
    # and point to the right Vision One location, so just run and return on success — no second
    # (duplicate) completion message here.
    if [ "$kind" = "code" ]; then
      live_scan_code && return 0
    else
      live_scan_image && return 0
    fi
    echo; echo "! Live scan did not complete — falling back to the offline mock scan."; echo
  else
    local reason; reason="$(live_unavailable_reason)"
    [ -n "$reason" ] && { echo "! $reason"; echo; }
  fi
  LAB="$LAB" python3 "$ENGINE" "$mock_verb"
}

# ---------- Mock helpers ----------
usage() { echo "usage: lab.sh {setup|status|scan-code|scan-image|reset|teardown}"; }

seed_lab() {
  mkdir -p "$LAB"
  rm -rf "$LAB/app" "$LAB/data"
  cp -R "$SEED_APP" "$LAB/app"
  cp -R "$SEED_DATA" "$LAB/data"
}

ensure_setup() {
  if [ ! -d "$LAB/app" ] || [ ! -f "$LAB/data/cve-db.json" ]; then
    seed_lab
  fi
}

# ---------- Verbs ----------
cmd_setup() {
  seed_lab
  if [ "$LAB_MODE" != "live" ]; then
    echo "Forge Lab · $PRODUCT · setup (mock)"
    echo "$BAR"
    echo "✓ Seeded lab home: $LAB"
    echo "  → app/  (Nimbus AI Chat Service — app.py, requirements.txt, Dockerfile)"
    echo "  → data/cve-db.json"
    echo "Ready. Run: scan-code  (code security)  then  scan-image  (container image)"
    echo "Tip: switch Lab data mode to Live in Settings and re-run Set Up Environment to"
    echo "     scan into your Vision One tenant."
    return 0
  fi

  echo "Forge Lab · $PRODUCT · setup (LIVE)"
  echo "Provisioning a real scan environment on this Mac, then it's ready to scan into"
  echo "your Vision One tenant. Already-installed pieces are detected and skipped."

  phase "Pre-flight checks"
  echo "✓ macOS $(sw_vers -productVersion 2>/dev/null || echo '?') · arch $(uname -m)"
  echo "✓ App seeded at $LAB/app"
  [ -n "$CCS_KEY" ] && echo "✓ Vision One API key present" || echo "! No Vision One API key set (add it in Settings) — scans will fall back to mock"

  phase "Homebrew"
  ensure_homebrew || echo "! Homebrew unavailable — runtime/tmas install may be limited."

  phase "Container runtime (Colima + docker)"
  ensure_runtime || true

  phase "Trend Micro Artifact Scanner (tmas)"
  ensure_tmas || true

  phase "Build the app image"
  build_image || true

  echo
  echo "$BAR"
  echo "✓ Live environment ready."
  echo "  • Code scan   → tmas scans app/ (source) → Code Security"
  if image_built; then
    echo "  • Image scan  → $LIVE_IMAGE (built) → Container Image Scanning"
  else
    echo "  • Image scan  → public fallback image (local build unavailable)"
  fi
  echo "  Run Scan Code & Dependencies and Audit Container Image to upload both."
  echo "$BAR"
}

cmd_status() {
  echo "Forge Lab · $PRODUCT · status"
  echo "$BAR"
  if [ -d "$LAB/app" ] && [ -f "$LAB/data/cve-db.json" ]; then
    echo "● seeded        : yes  ($LAB)"
  else
    echo "● seeded        : no   (run: setup)"
  fi
  echo "● mode          : $LAB_MODE"
  echo "● tmas          : $(have_tmas && echo yes || echo no)"
  echo "● docker daemon : $(docker_up && echo up || echo down)"
  echo "● app image  : $(image_built && echo "built ($LIVE_IMAGE)" || echo "not built")"
  echo "● vision one key: $([ -n "$CCS_KEY" ] && echo set || echo "not set")"
  exit 0
}

cmd_scan_code()  { run_scan "scan-code"  "code"; }
cmd_scan_image() { run_scan "scan-image" "image"; }

cmd_reset() {
  seed_lab
  rm -f "$LAB"/findings-*.json "$LAB"/forge-app-container-image*.tar "$LAB/.forge-app-image-id"
  rm -rf "$LAB"/forge-app-code-scan*
  echo "Forge Lab · $PRODUCT · reset"
  echo "$BAR"
  echo "✓ Restored pristine app and cleared mock results."
  echo "  (The built image and installed tools are left in place — use teardown to remove them.)"
}

cmd_teardown() {
  local deep=0
  for a in "$@"; do [ "$a" = "--all" ] && deep=1; done
  echo "Forge Lab · $PRODUCT · teardown"
  echo "$BAR"
  rm -rf "$LAB"
  echo "✓ Removed lab state: $LAB"
  if docker_up && docker image inspect "$LIVE_IMAGE" >/dev/null 2>&1; then
    docker rmi -f "$LIVE_IMAGE" >/dev/null 2>&1 && echo "✓ Removed built image: $LIVE_IMAGE" || true
  fi
  if [ "$deep" = "1" ] && command -v colima >/dev/null 2>&1; then
    echo "→ Stopping Colima (full teardown)…"
    colima stop >/dev/null 2>&1 && echo "✓ Colima stopped" || true
  fi
  exit 0
}

# ---------- Dispatch ----------
if [ "$#" -lt 1 ]; then
  usage
  exit 1
fi

VERB="$1"; shift || true

case "$VERB" in
  setup)      cmd_setup ;;
  status)     cmd_status ;;
  scan-code)  cmd_scan_code ;;
  scan-image) cmd_scan_image ;;
  reset)      cmd_reset ;;
  teardown)   cmd_teardown "$@" ;;
  *)          usage; exit 1 ;;
esac
