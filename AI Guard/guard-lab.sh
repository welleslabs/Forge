#!/usr/bin/env bash
# guard-lab.sh — bring up the TrendAI Guard proxy (tmguard) in front of the lab LLM.
#
#   ./guard-lab.sh serve      — install tmguard (if needed), write config, start the proxy
#   ./guard-lab.sh status     — show whether the proxy is running and reachable
#   ./guard-lab.sh teardown   — stop the proxy (and hand off to lab.sh teardown for the LLM)
#
# Inputs (set by the app from the AI Guard credentials):
#   TMGUARD_API_KEY     — Vision One API key with AI Guard permissions   (required)
#   TMGUARD_POLICY_ID   — published AI Guard policy ID from the console   (required)
# The backend URL is read from the shared lab tunnel that `lab.sh setup` publishes.
set -uo pipefail

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi
say()  { printf "%s→%s %s\n" "$BLUE"  "$NC" "$*"; }
ok()   { printf "%s✓%s %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%s!%s %s\n" "$YELLOW" "$NC" "$*"; }
err()  { printf "%s✗%s %s\n" "$RED"   "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

STATE_DIR="$HOME/.trend-lab"            # shared with lab.sh (holds the tmguard log/pid)
GUARD_DIR="${GUARD_DIR:-$HOME/trend-guard-lab}"
CONFIG="$GUARD_DIR/config.yaml"
TMGUARD_LOG="$STATE_DIR/tmguard.log"
LISTEN_PORT="${TMGUARD_PORT:-8443}"
MODEL="${OLLAMA_MODEL:-huihui_ai/llama3.2-abliterate:latest}"
# The proxy sits in front of LOCAL Ollama (Lab Guide §2.3 / §5) — localhost, not ngrok.
BACKEND_URL="${TMGUARD_BACKEND_URL:-http://localhost:11434/v1}"

ensure_macos() { [[ "$(uname -s)" == "Darwin" ]] || die "This lab targets macOS."; }

detect_arch() {
  case "$(uname -m)" in
    arm64)  echo "arm64" ;;
    x86_64) echo "x86_64" ;;
    *) die "Unsupported architecture: $(uname -m)." ;;
  esac
}

ensure_tmguard() {
  if command -v tmguard >/dev/null 2>&1; then
    ok "tmguard: $(tmguard --version 2>/dev/null | head -1 || echo installed)"
    return 0
  fi
  local arch archpat zip tmpdir bin
  arch=$(detect_arch)                                                   # arm64 | x86_64
  archpat=$([[ "$arch" == "x86_64" ]] && echo "x64" || echo "arm64")    # console build label
  say "Installing tmguard (detected macOS architecture: $arch)"

  # tmguard is delivered through the Vision One console — an authenticated, per-tenant
  # download, NOT a public CDN (Lab Guide §4.1 / Appendix C "First-time use"). You download
  # the macOS build into ~/Downloads and this script installs it from there. Power users
  # can point TMGUARD_DOWNLOAD_URL at a direct .zip (pinned version or enterprise mirror).
  zip=""; bin=""
  if [[ -n "${TMGUARD_DOWNLOAD_URL:-}" ]]; then
    say "Downloading from TMGUARD_DOWNLOAD_URL..."
    local dest; dest="$(mktemp -d)/tmguard.zip"
    if curl -fL --progress-bar --max-time 300 -o "$dest" "$TMGUARD_DOWNLOAD_URL"; then
      zip="$dest"
    else
      warn "TMGUARD_DOWNLOAD_URL download failed — looking in ~/Downloads instead."
    fi
  fi
  # Newest tmguard*.zip in ~/Downloads, preferring the arch-matched build
  # (console builds are named like tmguard-<ver>-darwin-arm64.zip / -darwin-x64.zip).
  if [[ -z "$zip" ]]; then
    zip=$(ls -1t "$HOME"/Downloads/tmguard*"$archpat"*.zip 2>/dev/null | head -1 || true)
    [[ -z "$zip" ]] && zip=$(ls -1t "$HOME"/Downloads/tmguard*.zip 2>/dev/null | head -1 || true)
  fi
  # Maybe it was already unzipped in ~/Downloads.
  [[ -z "$zip" ]] && bin=$(find "$HOME/Downloads" -maxdepth 3 -type f -name tmguard 2>/dev/null | head -1 || true)

  if [[ -z "$zip" && -z "$bin" ]]; then
    err "Couldn't find the tmguard download."
    cat >&2 <<EOF

  tmguard ships from the Vision One console (not a public URL). To get it:
    1. Vision One ▸ AI Application Security ▸ AI Guard ▸ Set Up
    2. In the drawer, Set Up step 2 → click the "TrendAI™ Guard proxy" link
    3. Download the macOS darwin-${archpat} build
    4. Leave the .zip in ~/Downloads and run this again
  (Advanced: export TMGUARD_DOWNLOAD_URL=<direct .zip URL> to skip this.)
EOF
    exit 1
  fi

  if [[ -z "$bin" ]]; then
    say "Using $(basename "$zip")"
    tmpdir=$(mktemp -d)
    unzip -q "$zip" -d "$tmpdir" || die "Could not unzip $zip."
    bin=$(find "$tmpdir" -type f -name tmguard 2>/dev/null | head -1)
  fi
  [[ -n "$bin" ]] || die "Download did not contain a 'tmguard' binary."
  chmod +x "$bin"
  sudo mv "$bin" /usr/local/bin/tmguard
  sudo xattr -dr com.apple.quarantine /usr/local/bin/tmguard 2>/dev/null || true
  ok "Installed /usr/local/bin/tmguard ($(tmguard --version 2>&1 | head -1))"
}

write_env() {
  [[ -n "${TMGUARD_API_KEY:-}" ]] || die "TMGUARD_API_KEY is not set — add your AI Guard Vision One API Key in Settings (⌘,)."
  mkdir -p "$HOME/.tmguard"
  printf 'TMGUARD_API_KEY=%s\n' "$TMGUARD_API_KEY" > "$HOME/.tmguard/.env"
  chmod 600 "$HOME/.tmguard/.env"
  ok "Wrote ~/.tmguard/.env"
}

write_config() {
  [[ -n "${TMGUARD_POLICY_ID:-}" ]] || die "TMGUARD_POLICY_ID is not set — publish a policy in Vision One ▸ AI Guard ▸ Policies and paste its ID into the AI Guard credentials in Settings (⌘,)."
  mkdir -p "$GUARD_DIR"
  cat > "$CONFIG" <<YAML
listen:
  address: 127.0.0.1
  port: ${LISTEN_PORT}

backend:
  url: ${BACKEND_URL}
  api_key: ollama
  model: ${MODEL}

policy:
  id: ${TMGUARD_POLICY_ID}
  mode: enforce
YAML
  ok "Wrote $CONFIG"
  say "  backend: ${BACKEND_URL}   policy: ${TMGUARD_POLICY_ID}   listen: 127.0.0.1:${LISTEN_PORT}"
}

cmd_serve() {
  ensure_macos
  ensure_tmguard
  write_env
  write_config

  # The proxy forwards to local Ollama — warn early if it isn't up (Setup Environment starts it).
  if ! curl -sf http://localhost:11434/api/version >/dev/null 2>&1; then
    warn "Ollama isn't responding on localhost:11434 — run \"Setup Environment\" first (it installs Ollama and pulls the model)."
  fi

  if pgrep -f "tmguard serve" >/dev/null 2>&1; then
    say "Stopping the existing tmguard session..."
    pkill -f "tmguard serve" 2>/dev/null || true
    sleep 1
  fi

  say "Starting the TrendAI Guard proxy on 127.0.0.1:${LISTEN_PORT}..."
  mkdir -p "$STATE_DIR"
  nohup tmguard serve --config "$CONFIG" > "$TMGUARD_LOG" 2>&1 &
  echo $! > "$STATE_DIR/tmguard.pid"

  printf "  Waiting for the proxy to report healthy"
  local i
  for i in {1..20}; do
    sleep 1; printf "."
    if curl -sf "http://127.0.0.1:${LISTEN_PORT}/healthz" >/dev/null 2>&1; then
      printf " up (%ds)\n" "$i"
      ok "AI Guard proxy is live on http://127.0.0.1:${LISTEN_PORT}"
      ok "Fire payloads from the app's Attack Library."
      return 0
    fi
  done
  printf " timeout\n"
  warn "The proxy did not report healthy. Most common causes: wrong policy ID, an API key without the Use AI Guard permission, or the policy isn't Published."
  say "Last lines of $TMGUARD_LOG:"
  tail -n 6 "$TMGUARD_LOG" 2>/dev/null || true
  return 1
}

cmd_status() {
  if pgrep -f "tmguard serve" >/dev/null 2>&1; then
    ok "tmguard running (PID $(pgrep -f 'tmguard serve' | head -1))"
  else
    warn "tmguard is not running — run '$0 serve'."
  fi
  if curl -sf "http://127.0.0.1:${LISTEN_PORT}/healthz" >/dev/null 2>&1; then
    ok "Proxy reachable: http://127.0.0.1:${LISTEN_PORT}/healthz"
  else
    warn "Proxy not reachable on 127.0.0.1:${LISTEN_PORT}."
  fi
  if curl -sf http://localhost:11434/api/version >/dev/null 2>&1; then
    ok "Backend Ollama reachable: ${BACKEND_URL}"
  else
    warn "Backend Ollama not reachable on localhost:11434 — run \"Setup Environment\"."
  fi
}

cmd_teardown() {
  if pgrep -f "tmguard serve" >/dev/null 2>&1; then
    pkill -f "tmguard serve" 2>/dev/null || true
    rm -f "$STATE_DIR/tmguard.pid"
    ok "Stopped the TrendAI Guard proxy."
  else
    say "tmguard proxy not running."
  fi
  # Hand the LLM teardown off to the shared lab.sh (passes through any extra flags).
  local labsh="$(cd "$(dirname "$0")/../AI Scanner" 2>/dev/null && pwd)/lab.sh"
  if [[ -f "$labsh" ]]; then
    say "Tearing down the shared LLM via lab.sh..."
    bash "$labsh" teardown "$@"
  fi
}

case "${1:-}" in
  serve|setup) cmd_serve ;;
  status)      cmd_status ;;
  teardown)    shift || true; cmd_teardown "$@" ;;
  *) echo "Usage: $0 {serve|status|teardown}"; exit 1 ;;
esac
