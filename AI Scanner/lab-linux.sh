#!/usr/bin/env bash
#
# TrendAI · Vision One AI Scanner Demo Lab — Ubuntu Linux automation
# ------------------------------------------------------------------
# Wraps the entire lab into one script. Reduces the 2–3 hour first run
# to about 10 minutes of wall time and three prompts. All subsequent
# runs are zero-input.
#
# Usage:
#   ./lab-linux.sh setup              — install tools, start Ollama + ngrok, store API keys
#   ./lab-linux.sh scan               — launch the scan wizard against your Ollama target
#   ./lab-linux.sh paste              — (run in a second terminal) rotate the clipboard
#                                       through the three wizard paste-values in sequence
#   ./lab-linux.sh status             — show what's running and the current ngrok URL
#   ./lab-linux.sh teardown           — stop servers, remove runtime state and ngrok authtoken
#   ./lab-linux.sh teardown --all     — additionally: remove the model, uninstall ollama
#                                       and ngrok, delete configs + TMAS_API_KEY, remove
#                                       the tmas CLI. Confirms with 'nuke' prompt.
#   ./lab-linux.sh teardown --all -y  — same as above, no confirmation prompt
#   ./lab-linux.sh help               — this help text
#
# Requires:
#   • Ubuntu 20.04+ (also tested on 22.04 / 24.04; Debian-derivatives should work)
#   • Internet access
#   • Sudo password (to install apt packages and place tmas on /usr/local/bin)
#
# One-time inputs you will be prompted for on first `setup`:
#   1. ngrok authtoken  — free account at https://ngrok.com
#   2. Vision One API key — created in Module 3 of the lab (role must
#                           include the "Run AI scan" permission)
#
# Not automatable:
#   • The tmas binary must be downloaded from the Vision One console
#     (AI Application Security ▸ AI Scanner ▸ Set Up ▸ TrendAI
#      Artifact Scanner CLI link). Place the .zip in ~/Downloads and
#     this script will find, extract, and install it automatically.
#     (Auto-download from the Trend CDN is also attempted first.)

set -euo pipefail

# If the script exits unexpectedly (set -e), print where and why instead
# of dying silently. Without this trap, a non-zero exit from any command
# causes the user to see only a returned shell prompt with no explanation.
trap 'rc=$?; if [[ $rc -ne 0 ]]; then
  printf "\n\033[0;31m✗ Script aborted\033[0m at line %s: %s (exit code %s)\n" "${BASH_LINENO[0]}" "$BASH_COMMAND" "$rc" >&2
fi' ERR

# ---------- Tunables ----------
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2:3b}"
LAB_DIR="${LAB_DIR:-$HOME/trend-lab}"
ENV_FILE="$HOME/.tmas/.env"
STATE_DIR="$HOME/.trend-lab"
OLLAMA_LOG="$STATE_DIR/ollama.log"
NGROK_LOG="$STATE_DIR/ngrok.log"

# ---------- Pretty output ----------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

say()  { printf "%s→%s %s\n" "$BLUE" "$NC" "$1"; }
ok()   { printf "%s✓%s %s\n" "$GREEN" "$NC" "$1"; }
warn() { printf "%s!%s %s\n" "$YELLOW" "$NC" "$1"; }
err()  { printf "%s✗%s %s\n" "$RED" "$NC" "$1" >&2; }
die()  { err "$1"; exit 1; }

# ---------- Progress ----------
# A numbered phase banner. PHASE_TOTAL is set by each subcommand; each
# call to phase() increments PHASE_CURRENT and prints "[N/TOTAL] title".
PHASE_CURRENT=0
PHASE_TOTAL=0
PHASE_START=0
phase() {
  PHASE_CURRENT=$((PHASE_CURRENT + 1))
  local title="$1"
  local elapsed=""
  if (( PHASE_START > 0 )); then
    local now secs
    now=$(date +%s)
    secs=$((now - PHASE_START))
    elapsed=" (${secs}s elapsed)"
  fi
  echo
  printf "%s[%d/%d]%s %s%s%s%s\n" \
    "$BOLD" "$PHASE_CURRENT" "$PHASE_TOTAL" "$NC" \
    "$BLUE" "$title" "$NC" "$elapsed"
  printf "%s%s%s\n" "$BLUE" "────────────────────────────────────────────────────────────" "$NC"
}

# Spinner for operations that have no native progress display.
# Usage: spin "Starting ngrok" -- some_command with args
spin() {
  local msg="$1"; shift
  [[ "$1" == "--" ]] && shift
  local pid
  ( "$@" ) & pid=$!
  local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r%s%s%s %s" "$BLUE" "${chars:$i:1}" "$NC" "$msg"
    i=$(( (i + 1) % ${#chars} ))
    sleep 0.1
  done
  wait "$pid"
  local rc=$?
  printf "\r\033[K"
  return $rc
}

# ---------- Sanity checks ----------
ensure_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    err "This script uses Linux-only commands (apt, systemctl, /proc, xclip/wl-copy) and is hardcoded for Ubuntu."
    err "Detected OS: $(uname -s) $(uname -r). Aborting."
    err ""
    err "If you are on macOS or Windows, follow the lab guide manually — the per-OS blocks"
    err "in Modules 2, 4, 5, and the Decommission section cover every command you need."
    err "(For macOS specifically, use lab.sh from this same folder.)"
    exit 1
  fi
  # Surface the distro early so user can see what we detected. Don't fail on
  # non-Ubuntu — Debian, Pop!_OS, Mint, etc. all use apt and will work fine.
  if [[ -r /etc/os-release ]]; then
    local id_like id
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-unknown}"
    id_like="${ID_LIKE:-}"
    if [[ "$id" != "ubuntu" && "$id_like" != *debian* && "$id" != "debian" ]]; then
      warn "Detected distro: $id. This script is tested on Ubuntu (apt-based)."
      warn "Continuing anyway — if your distro doesn't have 'apt', it will fail in phase 2."
    fi
  fi
}

# Verify every built-in/common Linux tool we call later actually exists before
# we start installing apt packages. Exits early with a clear message if anything
# is missing. On a fresh Ubuntu most of these are present; the few that aren't
# can be installed via the apt phase later, but curl/sudo MUST be present already.
ensure_required_tools() {
  local missing=()
  local tool
  # awk/grep/sed/curl/sudo/tar/unzip/lsof/pkill/pgrep/nohup/python3 are all
  # either preinstalled on Ubuntu Server/Desktop or trivially apt-installable.
  for tool in curl unzip lsof pkill pgrep nohup sudo python3 awk grep sed tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    warn "Some commonly-preinstalled tools are missing: ${missing[*]}"
    say "Installing them via apt..."
    sudo apt-get update -qq
    # Map command names → package names (most match 1:1 on Ubuntu).
    local pkgs=()
    for tool in "${missing[@]}"; do
      case "$tool" in
        pkill|pgrep) pkgs+=("procps") ;;
        nohup)       pkgs+=("coreutils") ;;
        python3)     pkgs+=("python3") ;;
        *)           pkgs+=("$tool") ;;
      esac
    done
    sudo apt-get install -y "${pkgs[@]}"
  fi
  ok "All required Linux tools present"
}

# Detect which clipboard helper is available. Linux is fragmented here:
#   • X11 sessions use xclip (or xsel) to write the X clipboard.
#   • Wayland sessions use wl-copy from wl-clipboard.
#   • Headless / SSH sessions have no clipboard at all — we degrade
#     gracefully and tell the user to triple-click instead.
# Emits the command that should be invoked to write stdin → clipboard,
# or empty string if we can't find one.
clipboard_cmd() {
  if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1; then
    echo "wl-copy"
  elif [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1; then
    echo "xclip -selection clipboard"
  elif [[ -n "${DISPLAY:-}" ]] && command -v xsel >/dev/null 2>&1; then
    echo "xsel --clipboard --input"
  else
    echo ""
  fi
}

# Ensure SOMETHING capable of writing the system clipboard is installed.
# Prefer wl-clipboard on Wayland, xclip on X11. No-op (with friendly note)
# on headless boxes — paste helper just won't be available.
ensure_clipboard_tool() {
  if [[ -n "$(clipboard_cmd)" ]]; then
    return 0
  fi
  if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    warn "No DISPLAY or WAYLAND_DISPLAY — looks like a headless/SSH session."
    warn "The 'paste' helper won't work here; use triple-click in the wizard instead."
    return 0
  fi
  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    say "Installing wl-clipboard (Wayland clipboard helper)..."
    sudo apt-get install -y wl-clipboard
  else
    say "Installing xclip (X11 clipboard helper)..."
    sudo apt-get install -y xclip
  fi
  if [[ -z "$(clipboard_cmd)" ]]; then
    warn "Clipboard helper install reported success but neither xclip/xsel/wl-copy is on PATH."
    warn "The 'paste' subcommand will not work; triple-click in the scan wizard instead."
  else
    ok "Clipboard helper ready ($(clipboard_cmd | awk '{print $1}'))"
  fi
}

# Pre-flight: fail fast on anything we cannot automate later, BEFORE
# we install apt packages or pull a 2 GB model.
# Record a preflight failure with a structured reason + fix block.
# Appends to FAILURES (reason + fix pairs) which is printed as a summary at the end.
FAILURES=()
record_failure() {
  local name="$1"
  local reason="$2"
  local fix="$3"
  err "[$name] FAILED"
  printf "    %sReason:%s %s\n" "$BOLD" "$NC" "$reason"
  printf "    %sFix:%s    %s\n" "$YELLOW" "$NC" "$fix"
  echo
  FAILURES+=("${name}|${reason}|${fix}")
}

preflight_checks() {
  FAILURES=()

  # ──────────────────────────────────────────────────────────────
  # Section A: Auto-detection
  # ──────────────────────────────────────────────────────────────
  # Discover properties of this Linux box and validate each against the
  # minimums the lab needs. Every detected value is printed so the
  # user can see exactly what the script is seeing.
  echo
  printf "%s── Auto-detection ───────────────────────────────────────────%s\n" "$BLUE" "$NC"

  local os os_ok=1
  os=$(uname -s)
  if [[ "$os" == "Linux" ]]; then
    ok "OS:                $os"
  else
    os_ok=0
    record_failure "os" \
      "Detected OS: $os — this script is Linux-only." \
      "Run this on a Linux machine. For macOS use lab.sh; for Windows follow the per-OS blocks in the lab guide manually."
  fi

  if (( os_ok )); then
    local distro_id distro_ver
    if [[ -r /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      distro_id="${ID:-unknown}"
      distro_ver="${VERSION_ID:-unknown}"
    else
      distro_id="unknown"
      distro_ver="unknown"
    fi

    if [[ "$distro_id" == "ubuntu" ]]; then
      # Compare major version numerically; lab tooling needs Ubuntu 20.04+.
      local major
      major=$(echo "$distro_ver" | awk -F. '{print $1}')
      if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 20 )); then
        ok "Distro:            Ubuntu $distro_ver (supported)"
      else
        record_failure "ubuntu-version" \
          "Detected Ubuntu $distro_ver. Lab tooling (current Ollama, ngrok apt repo, modern Python) requires Ubuntu 20.04 or newer." \
          "Upgrade Ubuntu (sudo do-release-upgrade) or run the lab on a newer LTS release. 22.04 or 24.04 are recommended."
      fi
    elif [[ "$distro_id" == "debian" || ",${ID_LIKE:-}," == *",debian,"* ]]; then
      ok "Distro:            $distro_id $distro_ver (Debian-derivative — should work)"
    else
      ok "Distro:            $distro_id $distro_ver (untested; will try anyway if apt is available)"
    fi
  fi

  local arch arch_label
  arch=$(uname -m)
  case "$arch" in
    aarch64|arm64)  arch_label="aarch64 (64-bit ARM — e.g. Raspberry Pi 4/5, Ampere, AWS Graviton)";
                    ok "Architecture:      $arch_label" ;;
    x86_64|amd64)   arch_label="x86_64 (64-bit Intel/AMD)";
                    ok "Architecture:      $arch_label" ;;
    *)              record_failure "arch" \
                      "Detected CPU architecture: $arch. Trend's tmas CLI ships only x86_64 and aarch64 Linux builds." \
                      "Run this on x86_64 (Intel/AMD) or aarch64 (ARM 64-bit) Linux. 32-bit (i686, armv7) and emulated architectures are not supported." ;;
  esac

  # RAM via /proc/meminfo (kB). Convert to GB with simple rounding.
  local ram_kb ram_gb
  ram_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  ram_gb=$((ram_kb / 1024 / 1024))
  if (( ram_gb >= 8 )); then
    ok "RAM:               ${ram_gb} GB"
  else
    record_failure "ram" \
      "Detected ${ram_gb} GB of RAM. Ollama + the llama3.2:3b model needs at least 8 GB to run without swapping (16 GB is comfortable)." \
      "Close memory-hungry apps (browsers, Docker, VMs) and retry; or switch to Path B in the lab guide (OpenAI hosted — no local RAM requirement) by pointing the wizard at https://api.openai.com/v1 instead of ngrok."
  fi

  local cores
  cores=$(nproc 2>/dev/null || echo "unknown")
  ok "CPU cores:         $cores"

  # Disk space in $HOME — df -BG gives integer-GB output.
  local free_gb
  free_gb=$(df -BG --output=avail "$HOME" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $1}')
  if [[ "$free_gb" =~ ^[0-9]+$ ]] && (( free_gb >= 3 )); then
    ok "Free disk ($HOME):  ${free_gb} GB"
  else
    record_failure "disk" \
      "Only ${free_gb:-unknown} GB free in $HOME. The llama3.2:3b model download alone is ~2 GB and tool installs add another ~500 MB; the lab needs 3 GB minimum." \
      "Free space with: sudo apt-get autoremove  ·  sudo apt-get clean  ·  rm -rf ~/.cache/*  ·  docker system prune -a  ·  empty Trash and ~/Downloads. Re-run when ≥ 3 GB is free."
  fi

  # Kernel — sanity surface, not a fail. Modern Ollama needs a 4.x+ kernel,
  # which every supported Ubuntu has.
  ok "Kernel:            $(uname -r)"

  # Surface init system. Ollama's installer creates a systemd unit; if
  # systemd isn't present (rare — minimal containers, WSL1) we'll fall back
  # to running ollama in the foreground without service management.
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    ok "Init system:       systemd (Ollama service unit will be installed)"
  else
    warn "Init system:       not systemd (Ollama will run as a plain background process)"
  fi
  printf "%s──────────────────────────────────────────────────────────────%s\n" "$BLUE" "$NC"
  echo

  # ──────────────────────────────────────────────────────────────
  # Section B: Required Linux built-in/common tools
  # ──────────────────────────────────────────────────────────────
  printf "%s── Required built-in tools ──────────────────────────────────%s\n" "$BLUE" "$NC"
  ensure_required_tools
  printf "%s──────────────────────────────────────────────────────────────%s\n" "$BLUE" "$NC"
  echo

  # ──────────────────────────────────────────────────────────────
  # Section C: Runtime capabilities (network, sudo, ports, tmas reachability)
  # ──────────────────────────────────────────────────────────────
  printf "%s── Runtime capability checks ────────────────────────────────%s\n" "$BLUE" "$NC"

  # 1. Internet reachability — without it nothing later works.
  say "Pre-flight: checking internet reachability..."
  if ! curl -sf --max-time 5 https://www.google.com -o /dev/null; then
    record_failure "internet" \
      "Could not reach https://www.google.com within 5 seconds." \
      "Reconnect your network. If you are behind a corporate proxy, export HTTPS_PROXY / HTTP_PROXY (and add them to /etc/sudoers via 'sudo visudo' with -E so apt sees them too), or ask IT to allowlist ast-cli.xdr.trendmicro.com, ollama.com, and ngrok-agent.s3.amazonaws.com."
  else
    ok "Internet reachable"
  fi

  # 2. tmas — either already installed OR a Linux .tar.gz is in ~/Downloads,
  #    OR we can auto-download from the Trend CDN. The auto-download path
  #    is also covered by the internet check above. (Linux packages are
  #    .tar.gz, unlike macOS which uses .zip.)
  say "Pre-flight: checking for tmas CLI availability..."
  if command -v tmas >/dev/null 2>&1; then
    ok "tmas already on PATH: $(which tmas)"
  else
    local archive arch
    arch=$(detect_arch)
    archive=$(ls -1t "$HOME"/Downloads/tmas*Linux*${arch}*.tar.gz \
                     "$HOME"/Downloads/tmas*linux*${arch}*.tar.gz \
                     "$HOME"/Downloads/tmas*Linux*${arch}*.tgz \
                     "$HOME"/Downloads/tmas*Linux*${arch}*.zip 2>/dev/null | head -1 || true)
    if [[ -n "$archive" ]]; then
      ok "tmas archive found in ~/Downloads: $archive"
    else
      # Not in ~/Downloads. We'll try auto-download at install time.
      # Surface a reachable-CDN check so we know the auto-download will work.
      local url="$(default_download_url "$arch")"
      if curl -sfI --max-time 10 "$url" >/dev/null 2>&1; then
        ok "tmas not yet installed; Trend CDN reachable ($url) — will auto-download"
      else
        record_failure "tmas" \
          "tmas is not installed, no matching .tar.gz is in ~/Downloads, AND the Trend CDN ($url) did not respond to HEAD within 10 seconds." \
          "Choose ONE: (A) download tmas-cli_Linux_${arch}.tar.gz manually from Vision One (AI App Security ▸ AI Scanner ▸ Set Up ▸ TrendAI Artifact Scanner CLI) and leave it in ~/Downloads; (B) export TMAS_DOWNLOAD_URL=<your-direct-url> and rerun; (C) check why the CDN is blocked (firewall, DNS, proxy)."
      fi
    fi
  fi

  # 3. Sudo — we need it for apt installs and to move tmas onto /usr/local/bin.
  #    Validate cached credentials non-interactively; if we can't, ask for
  #    password now.
  say "Pre-flight: checking sudo access..."
  if sudo -n true 2>/dev/null; then
    ok "Sudo cached"
  else
    echo "  Sudo needed for apt installs and to move tmas to /usr/local/bin. Prompting once now:"
    if sudo -v; then
      ok "Sudo authenticated"
    else
      record_failure "sudo" \
        "Could not authenticate with sudo (wrong password, or your account is not in the sudoers/admin group)." \
        "Run this lab on an account with sudo rights, or ask your admin to add you: sudo usermod -aG sudo \$USER  (then log out/in). Re-run the script."
    fi
  fi

  # Disk space was already validated in Section A (auto-detection).

  # 5. Ports — 11434 (Ollama) and 4040 (ngrok web UI). If something else
  #    (not our own prior run, and not the systemd ollama service that we
  #    will manage) is already listening, fail with specifics.
  #
  # IMPORTANT: lsof returns exit code 1 when no matching open file exists —
  # which is the NORMAL case we actually want (port is free). Without the
  # explicit `|| true`, `set -e` would abort the whole script silently right
  # here. The `|| true` tells bash "a non-match is fine; keep going."
  say "Pre-flight: checking ports 11434 and 4040..."
  local p11434_info p4040_info
  p11434_info=$({ lsof -iTCP:11434 -sTCP:LISTEN -n -P 2>/dev/null || true; } | awk 'NR>1 {print $1 " (PID " $2 ")"; exit}')
  if [[ -n "$p11434_info" ]]; then
    if pgrep -f "ollama serve" >/dev/null 2>&1 \
       || systemctl is-active --quiet ollama.service 2>/dev/null; then
      ok "Port 11434 in use by Ollama ($p11434_info) — we will restart it"
    else
      record_failure "port-11434" \
        "Port 11434 (required for Ollama) is already in use by: $p11434_info" \
        "Identify and stop the owning process: sudo lsof -iTCP:11434 -sTCP:LISTEN -n -P  then  kill <PID> (or kill -9 <PID>). If it's an app you need, change its port or run this lab on a different machine."
    fi
  else
    ok "Port 11434 free"
  fi
  p4040_info=$({ lsof -iTCP:4040 -sTCP:LISTEN -n -P 2>/dev/null || true; } | awk 'NR>1 {print $1 " (PID " $2 ")"; exit}')
  if [[ -n "$p4040_info" ]]; then
    if pgrep -f "ngrok" >/dev/null 2>&1; then
      ok "Port 4040 in use by ngrok ($p4040_info) — we will restart it"
    else
      record_failure "port-4040" \
        "Port 4040 (required for ngrok's local web UI) is already in use by: $p4040_info" \
        "Identify and stop the owning process: sudo lsof -iTCP:4040 -sTCP:LISTEN -n -P  then  kill <PID>. Common offenders: other ngrok sessions, localtunnel, development web servers."
    fi
  else
    ok "Port 4040 free"
  fi
  printf "%s──────────────────────────────────────────────────────────────%s\n" "$BLUE" "$NC"
  echo

  if (( ${#FAILURES[@]} > 0 )); then
    echo
    printf "%s════════════════════════════════════════════════════════════%s\n" "$RED" "$NC"
    err "Pre-flight checks failed (${#FAILURES[@]} issue(s)). Summary:"
    printf "%s════════════════════════════════════════════════════════════%s\n" "$RED" "$NC"
    echo
    local entry name reason fix
    for entry in "${FAILURES[@]}"; do
      IFS='|' read -r name reason fix <<< "$entry"
      printf "  %s✗ %s%s\n" "$RED" "$name" "$NC"
      printf "     %sReason:%s %s\n" "$BOLD" "$NC" "$reason"
      printf "     %sFix:%s    %s\n" "$YELLOW" "$NC" "$fix"
      echo
    done
    exit 1
  fi
  ok "All pre-flight checks passed — proceeding with setup."
  echo
}

ensure_apt_updated() {
  # Refresh apt lists once per setup run. Subsequent calls are no-ops.
  if [[ -z "${_APT_UPDATED:-}" ]]; then
    say "Refreshing apt package lists..."
    sudo apt-get update -qq
    _APT_UPDATED=1
    ok "apt cache refreshed"
  fi
}

# ---------- Component install ----------
ensure_ollama() {
  if ! command -v ollama >/dev/null 2>&1; then
    say "Installing Ollama via the official install script..."
    # The official Linux installer creates a systemd unit at
    # /etc/systemd/system/ollama.service, adds an `ollama` system user,
    # places the binary at /usr/local/bin/ollama, and starts the service.
    # That's fine — start_ollama() will stop the service and run our own
    # process so we can set OLLAMA_HOST/OLLAMA_ORIGINS.
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  # Ollama's --version prints BOTH the CLI version (stdout) AND a stderr
  # warning like "could not connect to a running Ollama instance" if the
  # server isn't up yet — which is expected at this phase. Suppress stderr
  # and filter to just the version line so the green ✓ is accurate.
  local ollama_ver
  ollama_ver=$(ollama --version 2>/dev/null | grep -oE 'version is [0-9][^ ]*' | head -1 | sed 's/^version is //')
  if [[ -n "$ollama_ver" ]]; then
    ok "Ollama: $ollama_ver"
  else
    # Fallback: just report that the binary exists if we couldn't parse the version.
    ok "Ollama: installed ($(which ollama))"
  fi
}

ensure_ngrok() {
  if ! command -v ngrok >/dev/null 2>&1; then
    say "Installing ngrok via the official apt repository..."
    ensure_apt_updated
    # Pull the ngrok signing key into the keyring (modern apt prefers
    # /etc/apt/keyrings over the deprecated apt-key add).
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
      | sudo tee /etc/apt/keyrings/ngrok.asc >/dev/null
    sudo chmod a+r /etc/apt/keyrings/ngrok.asc
    # Pin the apt source to the keyring so we don't trigger
    # NO_PUBKEY warnings or trust the global keyring set.
    echo "deb [signed-by=/etc/apt/keyrings/ngrok.asc] https://ngrok-agent.s3.amazonaws.com buster main" \
      | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y ngrok
  fi

  # Linux binaries don't carry a quarantine flag (that's a macOS Gatekeeper
  # thing) — nothing to clear, unlike the macOS lab.sh.

  # Parse 'ngrok version 3.x.x' cleanly; ignore stderr just in case.
  local ngrok_ver
  ngrok_ver=$(ngrok --version 2>/dev/null | grep -oE 'version [0-9][^ ]*' | head -1 | sed 's/^version //')
  if [[ -n "$ngrok_ver" ]]; then
    ok "ngrok: $ngrok_ver"
  else
    ok "ngrok: installed ($(which ngrok))"
  fi
  if ! ngrok config check >/dev/null 2>&1; then
    echo
    echo "  Get a free authtoken at https://dashboard.ngrok.com/get-started/your-authtoken"
    read -rp "  Paste your ngrok authtoken: " NGROK_TOKEN
    [[ -n "$NGROK_TOKEN" ]] || die "Empty authtoken; aborting."
    ngrok config add-authtoken "$NGROK_TOKEN"
  fi
  ok "ngrok authtoken configured"
}

# Detect the Linux architecture label Trend uses in their download file names.
# Trend's CDN uses 'x86_64' for Intel/AMD and 'arm64' for 64-bit ARM (note: the
# CDN names use 'arm64' even though Linux uname -m says 'aarch64'; we map
# accordingly). https://ast-cli.xdr.trendmicro.com/tmas-cli/latest/
detect_arch() {
  case "$(uname -m)" in
    aarch64|arm64) echo "arm64" ;;
    x86_64|amd64)  echo "x86_64" ;;
    *)             die "Unsupported architecture: $(uname -m). This script targets x86_64 and aarch64 (arm64) Linux." ;;
  esac
}

# Public CDN URL pattern for tmas-cli downloads. Confirmed for macOS, Linux, Windows.
# NOTE: Linux uses .tar.gz (gzip-compressed tar), while macOS and Windows use .zip.
# This is Trend's packaging convention, not a typo. Verified live with HEAD against
# https://ast-cli.xdr.trendmicro.com/tmas-cli/latest/tmas-cli_Linux_x86_64.tar.gz.
# Override with TMAS_DOWNLOAD_URL if you have an enterprise mirror or need a pinned version.
default_download_url() {
  local arch="$1"
  echo "https://ast-cli.xdr.trendmicro.com/tmas-cli/latest/tmas-cli_Linux_${arch}.tar.gz"
}

# Download the tmas archive. Returns 0 and writes to $dest on success.
# Uses curl's --progress-bar so the user sees the download advancing.
download_tmas() {
  local arch="$1"
  local dest="$2"
  local url="${TMAS_DOWNLOAD_URL:-$(default_download_url "$arch")}"
  say "Downloading tmas from: $url"
  if curl -fL --progress-bar --max-time 180 -o "$dest" "$url"; then
    local size
    size=$(du -h "$dest" | awk '{print $1}')
    ok "Downloaded $dest ($size)"
    return 0
  fi
  warn "Download failed from $url"
  rm -f "$dest"
  return 1
}

ensure_tmas() {
  if command -v tmas >/dev/null 2>&1; then
    ok "tmas: $(tmas --version 2>/dev/null | head -1 || echo 'installed')"
    return 0
  fi

  local arch archive tmpdir bin
  arch=$(detect_arch)
  say "Installing tmas (detected Linux architecture: $arch)"

  # 1. Primary: download from Trend's public CDN (or TMAS_DOWNLOAD_URL override).
  #    Linux artifacts are .tar.gz (Mac/Windows are .zip — Trend's convention).
  archive="$(mktemp -d)/tmas-cli_Linux_${arch}.tar.gz"
  if ! download_tmas "$arch" "$archive"; then
    archive=""
  fi

  # 2. Fallback: look for a matching archive already in ~/Downloads (useful for
  #    offline or firewalled environments where the CDN is unreachable). Accept
  #    .tar.gz / .tgz (the official Linux format) and .zip (in case someone
  #    grabbed the macOS or Windows file by mistake — we'll still try to extract).
  if [[ -z "$archive" ]]; then
    say "Falling back to ~/Downloads (useful when the CDN is blocked)..."
    archive=$(ls -1t "$HOME"/Downloads/tmas*Linux*${arch}*.tar.gz \
                     "$HOME"/Downloads/tmas*linux*${arch}*.tar.gz \
                     "$HOME"/Downloads/tmas*Linux*${arch}*.tgz \
                     "$HOME"/Downloads/tmas*Linux*${arch}*.zip 2>/dev/null | head -1 || true)
    if [[ -z "$archive" ]]; then
      err "Could not download tmas from the CDN AND no matching archive is in ~/Downloads."
      cat <<EOF

  Fix options, any one:

  A) Check internet / DNS. The CDN URL is:
       $(default_download_url "$arch")
     Try: curl -I $(default_download_url "$arch")

  B) Pin to a specific version (if 'latest' is blocked by your proxy):
       export TMAS_DOWNLOAD_URL='https://ast-cli.xdr.trendmicro.com/tmas-cli/<version>/tmas-cli_Linux_${arch}.tar.gz'
       $0 setup

  C) Manual download (airgapped or restricted networks):
       Place a tmas-cli_Linux_${arch}.tar.gz archive in ~/Downloads and rerun:  $0 setup

  Reference: https://docs.trendmicro.com/en-us/documentation/article/trend-vision-one-integrating-tmas-ci-cd-pipeline
EOF
      exit 1
    fi
    ok "Found $archive"
  fi

  say "Extracting and installing..."
  tmpdir=$(mktemp -d)
  # Pick the right extractor by file extension. tar handles .tar.gz/.tgz natively
  # (gzip-aware via -z); unzip handles the .zip fallback.
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$tmpdir" ;;
    *.zip)          unzip -q "$archive" -d "$tmpdir" ;;
    *)              die "Unrecognized archive format: $archive (expected .tar.gz or .zip)" ;;
  esac
  bin=$(find "$tmpdir" -type f -name tmas -perm -u+x 2>/dev/null | head -1)
  [[ -n "$bin" ]] || bin=$(find "$tmpdir" -type f -name tmas 2>/dev/null | head -1)
  [[ -n "$bin" ]] || die "Archive did not contain a 'tmas' binary. Re-download and retry."
  chmod +x "$bin"
  sudo mv "$bin" /usr/local/bin/tmas
  # Linux has no equivalent of macOS's xattr quarantine flag; nothing to clear.
  rm -rf "$tmpdir"
  ok "Installed /usr/local/bin/tmas ($(tmas --version 2>&1 | head -1))"
}

# ---------- Runtime setup ----------
pull_model() {
  # Sanity-check the server is actually reachable before we trust 'ollama list'.
  if ! curl -sf http://localhost:11434/api/version >/dev/null 2>&1; then
    die "Ollama server is not responding on http://localhost:11434. Run '$0 setup' in order, or re-run start_ollama."
  fi
  if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$OLLAMA_MODEL"; then
    ok "Model already present: $OLLAMA_MODEL (skipping ~2 GB download)"
    return 0
  fi
  say "Pulling $OLLAMA_MODEL (~2 GB, one-time download; ollama prints its own progress)..."
  ollama pull "$OLLAMA_MODEL"
  ok "Pulled $OLLAMA_MODEL"
}

start_ollama() {
  mkdir -p "$STATE_DIR"
  # Stop anything that might already be running so we can guarantee
  # OLLAMA_ORIGINS=* is set. Two possible owners on Linux:
  #   1. The systemd ollama.service installed by the official installer,
  #      which binds 127.0.0.1:11434 by default (no OLLAMA_ORIGINS).
  #   2. A prior `ollama serve` we (or the user) started in a terminal.
  local had_any=0
  if systemctl is-active --quiet ollama.service 2>/dev/null; then
    say "Stopping the systemd ollama.service (so we can run with OLLAMA_HOST=0.0.0.0 and OLLAMA_ORIGINS=*)..."
    sudo systemctl stop ollama.service || true
    # Don't disable it permanently — teardown undoes our work and the user
    # may want the service back. We just stop it for this session.
    had_any=1
  fi
  if pgrep -f "ollama serve" >/dev/null 2>&1; then
    say "Stopping existing 'ollama serve' process..."
    pkill -f "ollama serve" 2>/dev/null || true
    had_any=1
  fi
  if (( had_any )); then
    sleep 2
    # If anything is still clinging on, SIGKILL it.
    pkill -9 -f "ollama serve" 2>/dev/null || true
  fi
  say "Starting Ollama (OLLAMA_HOST=0.0.0.0:11434, OLLAMA_ORIGINS=*)..."
  OLLAMA_HOST="0.0.0.0:11434" OLLAMA_ORIGINS="*" \
    nohup ollama serve > "$OLLAMA_LOG" 2>&1 &
  echo $! > "$STATE_DIR/ollama.pid"
  # Wait for Ollama to listen, with visible progress.
  printf "  Waiting for Ollama to accept connections"
  local i
  for i in {1..15}; do
    sleep 1
    printf "."
    if curl -sf http://localhost:11434/api/version >/dev/null 2>&1; then
      printf " up (%ds)\n" "$i"
      ok "Ollama listening on http://localhost:11434"
      return 0
    fi
  done
  printf " timeout\n"
  die "Ollama did not start within 15 seconds. Check $OLLAMA_LOG"
}

start_ngrok() {
  mkdir -p "$STATE_DIR"
  if pgrep -f "ngrok http" >/dev/null 2>&1; then
    say "Stopping existing ngrok session..."
    pkill -f "ngrok http" 2>/dev/null || true
    sleep 2
  fi
  say "Starting ngrok tunnel on port 11434..."
  nohup ngrok http 11434 --log=stdout > "$NGROK_LOG" 2>&1 &
  echo $! > "$STATE_DIR/ngrok.pid"
  # Poll ngrok's local API for the tunnel URL, with visible progress.
  printf "  Waiting for ngrok to publish a tunnel URL"
  local url="" i
  for i in {1..20}; do
    sleep 1
    printf "."
    url=$(curl -sf http://localhost:4040/api/tunnels 2>/dev/null \
      | python3 -c 'import sys,json
try:
    t=json.load(sys.stdin).get("tunnels",[])
    print(t[0]["public_url"] if t else "")
except Exception:
    print("")' 2>/dev/null || true)
    [[ -n "$url" ]] && { printf " up (%ds)\n" "$i"; break; }
  done
  if [[ -z "$url" ]]; then
    printf " timeout\n"
    die "ngrok did not produce a tunnel URL. Check $NGROK_LOG"
  fi
  echo "$url" > "$STATE_DIR/tunnel-url"
  ok "ngrok tunnel: $url"
  ok "tmas endpoint URL: ${url}/v1"
}

write_env_file() {
  mkdir -p "$(dirname "$ENV_FILE")"
  if [[ -f "$ENV_FILE" ]] && grep -q "^TMAS_API_KEY=" "$ENV_FILE" 2>/dev/null; then
    ok "TMAS_API_KEY already stored in $ENV_FILE (delete that file to re-enter)"
    return 0
  fi
  echo
  echo "  Your Vision One API key:"
  echo "    • Created in Vision One ▸ Administration ▸ API Keys"
  echo "    • The role on the key MUST include 'Run AI scan' permission"
  echo "    • Shown once at creation time; if you lost it, create a new one"
  echo

  # Read the key with a length-aware loop so a dropped-paste or newline-
  # in-the-middle doesn't silently write a truncated value. Vision One
  # API keys are long alphanumeric strings (typically 50–80 characters),
  # so reject anything under 20 chars as almost certainly a partial paste.
  local VO_KEY="" preview retry
  while :; do
    read -rsp "  Paste your Vision One API key, then press Enter (input is hidden): " VO_KEY
    echo
    # Strip any whitespace that might have ridden along (CR/LF from the
    # clipboard, tabs from rich-text paste, leading/trailing spaces).
    VO_KEY="${VO_KEY//[[:space:]]/}"

    if [[ -z "$VO_KEY" ]]; then
      warn "Nothing was captured. This usually means the paste didn't register."
    elif (( ${#VO_KEY} < 20 )); then
      warn "Only ${#VO_KEY} characters captured — Vision One API keys are normally 50+ characters."
      warn "Your terminal probably dropped part of the paste (common with rich-text sources or auto-typers)."
    else
      # Show a first-4 / last-4 preview so the user can verify the capture
      # without the full key ever appearing on screen.
      preview="${VO_KEY:0:4}…${VO_KEY: -4}"
      ok "Captured ${#VO_KEY}-character key: $preview"
      read -rp "  Does that first-4 / last-4 match what you copied? [y/N] " retry
      if [[ "$retry" =~ ^[Yy] ]]; then
        break
      fi
      warn "OK, let's try again."
    fi
    echo
    read -rp "  Paste again? [Y/n] " retry
    if [[ "$retry" =~ ^[Nn] ]]; then
      die "Aborted. Re-run '$0 setup' when you're ready to paste the key."
    fi
    VO_KEY=""
  done

  umask 077
  # printf, not echo — echo can interpret backslash escapes on some shells
  # and would mangle keys that happen to contain them.
  printf 'TMAS_API_KEY=%s\n' "$VO_KEY" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "TMAS_API_KEY stored in $ENV_FILE (permissions 600, ${#VO_KEY} chars)"
}

# ---------- Subcommands ----------
cmd_setup() {
  ensure_linux

  PHASE_TOTAL=10
  PHASE_CURRENT=0
  PHASE_START=$(date +%s)

  phase "Pre-flight checks"
  preflight_checks

  phase "Refresh apt cache"
  ensure_apt_updated

  phase "Install Ollama (skips if already installed)"
  ensure_ollama

  phase "Install ngrok and configure authtoken"
  ensure_ngrok

  phase "Install clipboard helper (xclip / wl-clipboard)"
  ensure_clipboard_tool

  phase "Download and install the tmas CLI"
  ensure_tmas

  phase "Start the Ollama server with ngrok-friendly env vars"
  start_ollama

  phase "Pull the $OLLAMA_MODEL model (~2 GB; ollama shows its own progress)"
  pull_model

  phase "Start the ngrok tunnel and capture its public URL"
  start_ngrok

  phase "Store your Vision One API key in $ENV_FILE"
  write_env_file
  mkdir -p "$LAB_DIR"

  local url total_secs mins
  url=$(cat "$STATE_DIR/tunnel-url")
  total_secs=$(( $(date +%s) - PHASE_START ))
  mins=$((total_secs / 60))
  echo
  printf "%s════════════════════════════════════════════════════════════%s\n" "$GREEN" "$NC"
  ok "Setup complete in ${mins}m$((total_secs % 60))s."
  printf "%s════════════════════════════════════════════════════════════%s\n" "$GREEN" "$NC"
  echo
  echo "  Endpoint for the wizard:  ${BOLD}${url}/v1${NC}"
  echo "  Endpoint API key:         ${BOLD}ollama${NC}"
  echo "  Model group name ideas:   ${BOLD}Ollama Llama3 Lab${NC} (letters, numbers, spaces only)"
  echo
  echo "  Next:  ${BOLD}$0 scan${NC}"
}

cmd_scan() {
  ensure_linux
  [[ -f "$STATE_DIR/tunnel-url" ]] || die "Run '$0 setup' first."
  [[ -x /usr/local/bin/tmas ]] || die "tmas not installed. Run '$0 setup' first."
  local url
  url=$(cat "$STATE_DIR/tunnel-url")
  # Keep both Ollama and ngrok alive
  if ! pgrep -f "ollama serve" >/dev/null 2>&1; then
    warn "Ollama is not running — restarting..."
    start_ollama
  fi
  if ! pgrep -f "ngrok http" >/dev/null 2>&1; then
    warn "ngrok is not running — restarting..."
    start_ngrok
    url=$(cat "$STATE_DIR/tunnel-url")
  fi
  cd "$LAB_DIR"

  # Record the 3 paste-values so the optional '$0 paste' helper can find them.
  # We intentionally do NOT touch your clipboard — copy the values you need
  # from the display below with triple-click or manual select.
  local name="Ollama Llama3 Lab"
  local endpoint="${url}/v1"
  local key="ollama"
  printf '%s' "$name"     > "$STATE_DIR/paste-1-name"
  printf '%s' "$endpoint" > "$STATE_DIR/paste-2-endpoint"
  printf '%s' "$key"      > "$STATE_DIR/paste-3-key"

  # Visual separators — a thick double line for the outer frame, a thin
  # dashed line between prompt sections. Each paste-value sits ALONE on
  # its own unindented line between rules, with blank lines above and
  # below for breathing room. Triple-click selects exactly the value.
  local rule_thick="════════════════════════════════════════════════════════════"
  local rule_thin="────────────────────────────────────────────────────────────"

  echo
  printf "%s%s%s\n" "$BLUE" "$rule_thick" "$NC"
  printf "  %sWIZARD ANSWERS%s   (triple-click a value line to select it)\n" "$BOLD" "$NC"
  printf "  Your clipboard is not touched by this script.\n"
  printf "%s%s%s\n" "$BLUE" "$rule_thick" "$NC"
  echo

  # ── First prompt: target-type selection (no paste — arrow keys) ──
  printf "  %s▸ First prompt — arrow keys + Enter to pick:%s\n" "$BOLD" "$NC"
  printf "    Model Endpoint (OpenAI-compliant)\n"
  echo
  printf "%s%s%s\n" "$BLUE" "$rule_thin" "$NC"
  echo

  # ── Prompt 1/3: Model group name ──
  printf "  %s▸ Prompt 1 of 3 — %sEnter the target model group name%s\n" "$BOLD" "$BOLD" "$NC"
  echo
  printf "%s\n" "$name"
  echo
  printf "%s%s%s\n" "$BLUE" "$rule_thin" "$NC"
  echo

  # ── Prompt 2/3: Endpoint URL ──
  printf "  %s▸ Prompt 2 of 3 — %sEnter the target OpenAI API endpoint%s\n" "$BOLD" "$BOLD" "$NC"
  echo
  printf "%s\n" "$endpoint"
  echo
  printf "%s%s%s\n" "$BLUE" "$rule_thin" "$NC"
  echo

  # ── Prompt 3/3: API key ──
  printf "  %s▸ Prompt 3 of 3 — %sEnter the target API key%s\n" "$BOLD" "$BOLD" "$NC"
  echo
  printf "%s\n" "$key"
  echo
  printf "%s%s%s\n" "$BLUE" "$rule_thin" "$NC"
  echo

  # ── Multi-select guidance ──
  printf "  %s▸ Multi-select lists that follow the three prompts:%s\n" "$BOLD" "$NC"
  printf "    Objectives:  %sselect ALL 6%s  (x toggles, Enter confirms)\n" "$BOLD" "$NC"
  printf "    Techniques:  %suncheck 'None' first%s, then toggle everything else\n" "$BOLD" "$NC"
  printf "    Modifiers:   %spick 2–4%s\n" "$BOLD" "$NC"
  echo

  # ── Opt-in clipboard helper ──
  printf "  %sOpt-in:%s if you'd rather not triple-click, run '%s%s paste%s' in a\n" "$YELLOW" "$NC" "$BOLD" "$0" "$NC"
  printf "  SECOND terminal — it cycles your clipboard through all three values.\n"
  printf "%s%s%s\n" "$BLUE" "$rule_thick" "$NC"
  echo
  say "Launching: tmas aiscan llm --interactive"
  echo
  tmas aiscan llm --interactive
}

# Interactive helper: rotates the system clipboard through the three paste-values.
# Run in a second terminal alongside `$0 scan`. Hit Enter between prompts
# to advance the clipboard to the next value.
cmd_paste() {
  ensure_linux
  [[ -f "$STATE_DIR/paste-1-name" ]] || die "Run '$0 scan' in another terminal first (it stashes the paste values)."

  # Pick whatever clipboard helper this session has. On a headless box this
  # comes back empty and we degrade gracefully (display the values; tell the
  # user to paste them manually).
  local clip
  clip="$(clipboard_cmd)"
  if [[ -z "$clip" ]]; then
    warn "No clipboard tool available (no DISPLAY/WAYLAND_DISPLAY, or xclip/wl-copy not installed)."
    warn "Showing values for manual copy instead — triple-click each one in the OTHER terminal:"
    echo
  fi

  local name endpoint key
  name=$(cat "$STATE_DIR/paste-1-name")
  endpoint=$(cat "$STATE_DIR/paste-2-endpoint")
  key=$(cat "$STATE_DIR/paste-3-key")

  echo
  echo "  ${BOLD}Paste-rotation helper${NC}"
  if [[ -n "$clip" ]]; then
    echo "  I'll load each of the three values to your clipboard in order ($clip)."
    echo "  Hit Enter in THIS terminal after you've pasted in the wizard terminal."
  else
    echo "  No clipboard available — values shown below for manual copy."
  fi
  echo

  # 1. Model group name
  if [[ -n "$clip" ]]; then
    printf '%s' "$name" | $clip
    ok "Clipboard: ${BOLD}$name${NC}  (paste at prompt 1 'Enter the target model group name')"
  else
    printf "  Prompt 1 (model group name): ${BOLD}%s${NC}\n" "$name"
  fi
  read -rp "     Press Enter when you've pasted it and moved to prompt 2... " _

  # 2. Endpoint URL
  if [[ -n "$clip" ]]; then
    printf '%s' "$endpoint" | $clip
    ok "Clipboard: ${BOLD}$endpoint${NC}  (paste at prompt 2 'Enter the target OpenAI API endpoint')"
  else
    printf "  Prompt 2 (endpoint URL): ${BOLD}%s${NC}\n" "$endpoint"
  fi
  read -rp "     Press Enter when you've pasted it and moved to prompt 3... " _

  # 3. API key
  if [[ -n "$clip" ]]; then
    printf '%s' "$key" | $clip
    ok "Clipboard: ${BOLD}$key${NC}  (paste at prompt 3 'Enter the target API key')"
  else
    printf "  Prompt 3 (API key): ${BOLD}%s${NC}\n" "$key"
  fi
  echo
  if [[ -n "$clip" ]]; then
    ok "All three values have been placed on the clipboard in sequence. You can close this terminal."
  else
    ok "All three values displayed. You can close this terminal once you've pasted them all."
  fi
}

cmd_status() {
  ensure_linux
  echo
  if pgrep -f "ollama serve" >/dev/null 2>&1; then
    ok "Ollama running (PID $(pgrep -f 'ollama serve' | head -1))"
  elif systemctl is-active --quiet ollama.service 2>/dev/null; then
    warn "Ollama is running via systemd, NOT via this lab script"
    warn "(it's bound to 127.0.0.1:11434 and won't accept ngrok requests — re-run '$0 setup')"
  else
    warn "Ollama is NOT running"
  fi
  if pgrep -f "ngrok http" >/dev/null 2>&1; then
    ok "ngrok running (PID $(pgrep -f 'ngrok http' | head -1))"
    [[ -f "$STATE_DIR/tunnel-url" ]] && ok "Tunnel URL: $(cat "$STATE_DIR/tunnel-url")"
  else
    warn "ngrok is NOT running"
  fi
  if [[ -f "$ENV_FILE" ]]; then
    ok "TMAS_API_KEY env file: $ENV_FILE"
  else
    warn "No TMAS_API_KEY env file at $ENV_FILE"
  fi
  if command -v tmas >/dev/null 2>&1; then
    local tmas_ver
    tmas_ver=$(tmas --version 2>/dev/null | head -1 || true)
    ok "tmas at $(which tmas)${tmas_ver:+: $tmas_ver}"
  else
    warn "tmas not on PATH"
  fi
  if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$OLLAMA_MODEL"; then
    ok "Model present: $OLLAMA_MODEL"
  else
    warn "Model $OLLAMA_MODEL not pulled"
  fi
  local clip
  clip="$(clipboard_cmd)"
  if [[ -n "$clip" ]]; then
    ok "Clipboard helper available: $clip"
  else
    warn "No clipboard helper available (paste subcommand will show values for manual copy)"
  fi
  echo
}

cmd_teardown() {
  # Parse teardown-specific flags first so that --help works even on the
  # wrong OS. ensure_linux is called AFTER parsing so we only fail the
  # OS check when the user actually wants to run teardown work.
  local full=0 yes=0
  while (( $# > 0 )); do
    case "$1" in
      --all|--nuke) full=1 ;;
      -y|--yes)     yes=1 ;;
      -h|--help)
        cat <<EOF
Usage: $0 teardown [--all] [-y]

  (no flags)   Stop Ollama + ngrok, remove runtime state, wipe the local
               ngrok authtoken config. Suggests further cleanup.
  --all        Additionally remove the Ollama model, uninstall Ollama and
               ngrok (Ollama via its uninstall steps; ngrok via apt),
               delete ~/.ollama, the lab working folder, and the
               TMAS_API_KEY env file, and remove the tmas CLI.
               PROMPTS (type 'nuke' to confirm) unless -y is given.
  -y, --yes    Skip the confirmation prompt when combined with --all.
EOF
        exit 0 ;;
      *) err "Unknown teardown option: $1"; err "Try: $0 teardown --help"; exit 1 ;;
    esac
    shift
  done

  ensure_linux

  say "Stopping ngrok..."
  pkill -f "ngrok http" 2>/dev/null || true
  say "Stopping Ollama (foreground process)..."
  pkill -f "ollama serve" 2>/dev/null || true
  # If the systemd service was stopped earlier in setup, leave it stopped
  # for now — basic teardown shouldn't re-enable services the user might
  # not want. (--all path will uninstall the service entirely.)
  sleep 1
  say "Removing runtime state ($STATE_DIR)..."
  rm -rf "$STATE_DIR"

  # Automatically remove the local ngrok authtoken config so nothing is
  # left on the machine that could reuse the token. ngrok v3 stores
  # config at ~/.config/ngrok/ngrok.yml on Linux (per XDG); older v2
  # used ~/.ngrok2/ngrok.yml.
  local removed_any=0
  for ngrok_config in "$HOME/.config/ngrok" "$HOME/.ngrok2"; do
    if [[ -d "$ngrok_config" ]]; then
      say "Removing local ngrok config at: $ngrok_config"
      rm -rf "$ngrok_config"
      removed_any=1
    fi
  done
  if (( removed_any )); then
    ok "ngrok local config wiped"
  else
    ok "No ngrok config found (already clean)"
  fi

  # ── --all: confirm, then run every "suggested" cleanup ──────────
  if (( full )); then
    echo
    printf "%s════════════════════════════════════════════════════════════%s\n" "$RED" "$NC"
    printf "  %s--all / --nuke WILL PERMANENTLY REMOVE:%s\n" "$BOLD" "$NC"
    printf "%s════════════════════════════════════════════════════════════%s\n" "$RED" "$NC"
    echo "  • The Ollama model:       $OLLAMA_MODEL (reclaims ~2 GB)"
    echo "  • The Ollama install:     systemd service, /usr/local/bin/ollama,"
    echo "                            and the 'ollama' system user"
    echo "  • The ngrok package:      apt purge ngrok"
    echo "  • Local configs:          ~/.ollama, $LAB_DIR, $ENV_FILE"
    echo "                            (this includes your TMAS_API_KEY)"
    echo "  • The tmas CLI binary:    /usr/local/bin/tmas"
    echo
    echo "  Not removed (use them for other projects):"
    echo "  • apt itself, Python, build tools, xclip/wl-clipboard"
    echo
    if (( ! yes )); then
      read -rp "  Type 'nuke' to confirm, anything else to abort: " confirm
      [[ "$confirm" == "nuke" ]] || die "Aborted. No extra cleanup performed."
    else
      warn "Skipping confirmation (-y passed)"
    fi

    echo
    say "Removing Ollama model $OLLAMA_MODEL..."
    # Model removal requires Ollama server running; start it briefly if needed.
    if ! curl -sf http://localhost:11434/api/version >/dev/null 2>&1; then
      nohup ollama serve > /dev/null 2>&1 &
      local spin_pid=$!
      sleep 2
      ollama rm "$OLLAMA_MODEL" 2>/dev/null && ok "Model removed" || warn "Model not present (already clean)"
      kill "$spin_pid" 2>/dev/null || true
    else
      ollama rm "$OLLAMA_MODEL" 2>/dev/null && ok "Model removed" || warn "Model not present (already clean)"
    fi

    say "Uninstalling Ollama (systemd service + binary + system user)..."
    # Mirror the official Ollama Linux uninstall recipe documented at
    # https://github.com/ollama/ollama/blob/main/docs/linux.md#uninstall
    if systemctl list-unit-files 2>/dev/null | grep -q '^ollama\.service'; then
      sudo systemctl stop ollama 2>/dev/null || true
      sudo systemctl disable ollama 2>/dev/null || true
      sudo rm -f /etc/systemd/system/ollama.service
      sudo systemctl daemon-reload 2>/dev/null || true
    fi
    sudo rm -f /usr/local/bin/ollama
    if id ollama &>/dev/null; then
      sudo userdel ollama 2>/dev/null || true
    fi
    if getent group ollama &>/dev/null; then
      sudo groupdel ollama 2>/dev/null || true
    fi
    sudo rm -rf /usr/share/ollama 2>/dev/null || true
    ok "Ollama uninstalled"

    say "Removing ngrok via apt and clearing its repository..."
    sudo apt-get purge -y ngrok 2>/dev/null && ok "ngrok purged" || warn "apt purge reported issues (package may already be gone)"
    sudo rm -f /etc/apt/sources.list.d/ngrok.list /etc/apt/keyrings/ngrok.asc
    sudo apt-get update -qq 2>/dev/null || true
    ok "ngrok apt source removed"

    say "Removing local configs ~/.ollama, $LAB_DIR, $ENV_FILE..."
    rm -rf "$HOME/.ollama" "$LAB_DIR" "$ENV_FILE"
    ok "Local configs wiped"

    if [[ -x /usr/local/bin/tmas ]]; then
      say "Removing /usr/local/bin/tmas (sudo may prompt)..."
      sudo rm -f /usr/local/bin/tmas
      ok "tmas CLI removed"
    else
      ok "tmas CLI already gone"
    fi

    echo
    printf "%s════════════════════════════════════════════════════════════%s\n" "$GREEN" "$NC"
    ok "Full nuke complete. This machine has no lab artifacts remaining."
    printf "%s════════════════════════════════════════════════════════════%s\n" "$GREEN" "$NC"
    echo
    printf "  %sStill needed — web-console only, cannot be automated:%s\n" "$BOLD" "$NC"
    echo
    printf "  %s▸ Rotate the ngrok authtoken%s\n" "$BOLD" "$NC"
    echo "  https://dashboard.ngrok.com/authtokens"
    echo
    printf "  %s▸ Revoke the Vision One TMAS_API_KEY%s\n" "$BOLD" "$NC"
    echo "  Administration ▸ API Keys (revoke the key named 'trend-ai-scanner-lab')"
    echo
    printf "  %s▸ Delete lab scans (optional; otherwise kept for audit)%s\n" "$BOLD" "$NC"
    echo "  AI Application Security ▸ AI Scanner"
    echo
    return 0
  fi

  echo
  ok "Background servers stopped. Local ngrok authtoken removed."
  echo

  local rule_thick="════════════════════════════════════════════════════════════"
  local rule_thin="────────────────────────────────────────────────────────────"

  printf "%s%s%s\n" "$BLUE" "$rule_thick" "$NC"
  printf "  %sREMAINING OPTIONAL MANUAL CLEANUP%s\n" "$BOLD" "$NC"
  printf "  Run when you are done with the lab entirely.\n"
  printf "%s%s%s\n" "$BLUE" "$rule_thick" "$NC"
  echo

  printf "  %s▸ Rotate the ngrok authtoken at the dashboard%s\n" "$BOLD" "$NC"
  printf "  (the local copy is already wiped; rotating invalidates it everywhere\n"
  printf "  it may have leaked):\n"
  echo
  printf "  https://dashboard.ngrok.com/authtokens\n"
  echo
  printf "%s%s%s\n" "$BLUE" "$rule_thin" "$NC"
  echo

  printf "  %s▸ Remove the Ollama model%s (reclaims ~2 GB of disk):\n" "$BOLD" "$NC"
  echo
  printf "  ollama rm %s\n" "$OLLAMA_MODEL"
  echo
  printf "%s%s%s\n" "$BLUE" "$rule_thin" "$NC"
  echo

  printf "  %s▸ Uninstall the tools%s (skip if you use them for other projects):\n" "$BOLD" "$NC"
  echo
  printf "  sudo systemctl disable --now ollama && sudo rm -f /etc/systemd/system/ollama.service /usr/local/bin/ollama\n"
  printf "  sudo userdel ollama 2>/dev/null; sudo groupdel ollama 2>/dev/null; sudo rm -rf /usr/share/ollama\n"
  printf "  sudo apt-get purge -y ngrok && sudo rm -f /etc/apt/sources.list.d/ngrok.list /etc/apt/keyrings/ngrok.asc\n"
  echo
  printf "%s%s%s\n" "$BLUE" "$rule_thin" "$NC"
  echo

  printf "  %s▸ Remove local configs and saved credentials%s (includes TMAS_API_KEY):\n" "$BOLD" "$NC"
  echo
  printf "  rm -rf ~/.ollama \"%s\" \"%s\"\n" "$LAB_DIR" "$ENV_FILE"
  echo
  printf "%s%s%s\n" "$BLUE" "$rule_thin" "$NC"
  echo

  printf "  %s▸ Remove the tmas CLI from PATH:%s\n" "$BOLD" "$NC"
  echo
  printf "  sudo rm /usr/local/bin/tmas\n"
  echo
  printf "%s%s%s\n" "$BLUE" "$rule_thick" "$NC"
  echo
  printf "  %sVISION ONE SIDE%s (web console):\n" "$BOLD" "$NC"
  printf "%s%s%s\n" "$BLUE" "$rule_thick" "$NC"
  echo

  printf "  %s▸ Administration ▸ API Keys%s\n" "$BOLD" "$NC"
  printf "    Revoke the TMAS_API_KEY issued for this lab.\n"
  echo
  printf "%s%s%s\n" "$BLUE" "$rule_thin" "$NC"
  echo

  printf "  %s▸ AI Application Security ▸ AI Scanner%s\n" "$BOLD" "$NC"
  printf "    Optionally delete your lab scans (or keep them for audit).\n"
  echo
  printf "%s%s%s\n" "$BLUE" "$rule_thick" "$NC"
}

cmd_help() {
  sed -n '1,/^set -euo pipefail$/p' "$0" | sed 's/^# \?//' | head -n -1
}

# ---------- Dispatch ----------
subcommand="${1:-help}"
# Drop the subcommand name from the positional args so cmd_* functions
# see only their own flags in "$@".
[[ $# -gt 0 ]] && shift || true
case "$subcommand" in
  setup)    cmd_setup "$@" ;;
  scan)     cmd_scan "$@" ;;
  paste)    cmd_paste "$@" ;;
  status)   cmd_status "$@" ;;
  teardown) cmd_teardown "$@" ;;
  help|-h|--help) cmd_help ;;
  *)        err "Unknown command: $subcommand"; cmd_help; exit 1 ;;
esac
