#!/usr/bin/env bash
# Bootstrap and run the full threeam download end-to-end.
#
# Works on macOS and Linux (apt / dnf / pacman / apk / zypper).
#
# Two ways to invoke:
#
#   1. One-liner (recommended):
#        curl -fsSL https://raw.githubusercontent.com/sudo-smlv/ddd/main/run.sh | bash
#      Files are installed to ~/.threeam/{run.sh,download.py} and run from there.
#      The file listing (files.txt) must live next to where you ran the curl
#      command, or be passed via --files PATH.
#
#   2. Local checkout:
#        ./run.sh [--files PATH] [--out DIR] [--tor HOST:PORT] [--workers N]
#
# What it does:
#   1. Detect OS + package manager
#   2. Install Homebrew on macOS if missing; on Linux use the system PM
#   3. Install python3 + pip if missing
#   4. Install Python deps (requests, pysocks)
#   5. Install Tor via the system package manager
#   6. Write an isolated torrc + DataDirectory under ~/.threeam-tor
#   7. Start Tor in the background, listening only on 127.0.0.1
#   8. Run download.py against the listing (resumable on re-run)
#
# Re-running is safe: it skips anything already done and the downloader skips
# files already on disk.

set -euo pipefail

# --------------------------------------------------------------------------
# Helpers (defined up here so the stdin-bootstrap and listing fetch below can use them)
# --------------------------------------------------------------------------
log()      { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
err()      { printf '\033[1;31m[err ]\033[0m %s\n' "$*" >&2; }
have()     { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# Where to install when invoked via `curl | bash`
# Default: a `threeam/` subdirectory of the directory the user is in.
# --------------------------------------------------------------------------
REPO_RAW_BASE="https://raw.githubusercontent.com/sudo-smlv/ddd"
REPO_CDN_BASE="https://cdn.jsdelivr.net/gh/sudo-smlv/ddd@main"

# Resolve a fresh ref at runtime. raw.githubusercontent.com aggressively
# caches /main/, so we resolve HEAD's commit SHA via the API and download
# from a SHA-pinned URL. Falls back to /main/ then jsDelivr.
REPO_RAW="$REPO_RAW_BASE"
if command -v curl >/dev/null 2>&1; then
  _sha=$(curl -fsSL --max-time 8 "https://api.github.com/repos/sudo-smlv/ddd/commits/main" \
         | python3 -c "import json,sys;print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || true)
  if [[ -n "$_sha" ]]; then
    REPO_RAW="$REPO_RAW_BASE/$_sha"
  else
    REPO_RAW="$REPO_RAW_BASE/HEAD"
  fi
fi
: "${INSTALL_DIR:=}"
if [[ -z "$INSTALL_DIR" ]]; then
  if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "/dev/stdin" && -f "${BASH_SOURCE[0]}" ]]; then
    INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  else
    INSTALL_DIR="$PWD/threeam"
  fi
fi

# --------------------------------------------------------------------------
# If we were piped from stdin, materialise ourselves to disk first
# --------------------------------------------------------------------------
_self="${BASH_SOURCE[0]:-}"
if [[ -z "$_self" || "$_self" == "/dev/stdin" || ! -f "$_self" ]]; then
  log "Installing to $INSTALL_DIR ..."
  mkdir -p "$INSTALL_DIR"
  # Always download run.sh + download.py + files.txt. The 24 MB listing is
  # required for the downloader; getting it here means we don't have to
  # re-fetch it later (and avoids races on second runs).
  curl -fsSL "$REPO_RAW/run.sh"      -o "$INSTALL_DIR/run.sh"
  curl -fsSL "$REPO_RAW/download.py" -o "$INSTALL_DIR/download.py"
  if ! curl -fsSL "$REPO_RAW/files.txt" -o "$INSTALL_DIR/files.txt"; then
    err "Failed to fetch files.txt from $REPO_RAW/files.txt"
    err "The .onion server's file listing is needed. Re-run when the network is up,"
    err "or supply your own: curl -fsSL <your-listing-url> -o $INSTALL_DIR/files.txt"
    exit 1
  fi
  chmod +x "$INSTALL_DIR/run.sh" "$INSTALL_DIR/download.py"
  log "Re-executing from $INSTALL_DIR/run.sh"
  exec bash "$INSTALL_DIR/run.sh" "$@"
fi

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
THREEAM_DIR="${THREEAM_DIR:-$INSTALL_DIR}"
LISTING="${LISTING:-${1:-}}"
# Parse CLI args. They can be set as either env vars (before `| bash`) or as
# arguments after `bash -s -- ...` (after the pipe). The argument form
# overrides env vars and is the only one that survives `curl ... | bash`.
prev=""
for arg in "$@"; do
  case "$prev" in
    --files)        LISTING="$arg" ;;
    --instances)    TOR_INSTANCES="$arg" ;;
    --workers|--concurrent) WORKERS="$arg" ;;
    --out)          OUT_DIR="$arg" ;;
  esac
  case "$arg" in
    --files=*)        LISTING="${arg#*=}" ;;
    --instances=*)    TOR_INSTANCES="${arg#*=}" ;;
    --workers=*)      WORKERS="${arg#*=}" ;;
    --concurrent=*)   WORKERS="${arg#*=}" ;;
    --out=*)          OUT_DIR="${arg#*=}" ;;
  esac
  prev="$arg"
done

OUT_DIR="${OUT_DIR:-$THREEAM_DIR/download}"
LOG_DIR="${LOG_DIR:-$THREEAM_DIR/logs}"

TOR_DIR="${TOR_DIR:-$HOME/.threeam-tor}"
TOR_PORT="${TOR_PORT:-9151}"
TOR_INSTANCES="${TOR_INSTANCES:-50}"
WORKERS="${WORKERS:-5000}"
TOR_START_STAGGER="${TOR_START_STAGGER:-2}"

# File descriptors: 5000 workers + 50 Tor daemons + housekeeping.
ulimit -n 131072 2>/dev/null || true

# Default listing: ./files.txt in cwd, then $THREEAM_DIR, then fetch from repo
if [[ -z "$LISTING" ]]; then
  if [[ -f "./files.txt" ]]; then
    LISTING="./files.txt"
  elif [[ -f "$THREEAM_DIR/files.txt" ]]; then
    LISTING="$THREEAM_DIR/files.txt"
  else
    log "files.txt not found locally, fetching from $REPO_RAW/files.txt ..."
    mkdir -p "$THREEAM_DIR"
    if ! curl -fSL "$REPO_RAW/files.txt" -o "$THREEAM_DIR/files.txt"; then
      err "Failed to download files.txt from $REPO_RAW/files.txt"
      err "Re-run with --files /path/to/files.txt to use a local copy."
      exit 1
    fi
    LISTING="$THREEAM_DIR/files.txt"
  fi
fi

OS="$(uname -s)"
# Skip sudo when already root (containers, CI, etc.) or when sudo is missing.
SUDO=""
if [[ $EUID -ne 0 ]] && have sudo; then SUDO="sudo"; fi
case "$OS" in
  Darwin) PKG_FAMILY="brew" ;;
  Linux)
    if   have apt-get; then PKG_FAMILY="apt"
    elif have dnf;     then PKG_FAMILY="dnf"
    elif have pacman;  then PKG_FAMILY="pacman"
    elif have apk;     then PKG_FAMILY="apk"
    elif have zypper;  then PKG_FAMILY="zypper"
    else err "no supported package manager found (need apt/dnf/pacman/apk/zypper)"; exit 1
    fi
    ;;
  *) err "unsupported OS: $OS"; exit 1 ;;
esac

pkg_update() {
  case "$PKG_FAMILY" in
    apt)    eval "$SUDO apt-get update" >/dev/null 2>&1 || true ;;
    dnf)    eval "$SUDO dnf check-update" >/dev/null 2>&1 || true ;;
    *)      : ;;  # apk/zypper/pacman refresh lazily on install
  esac
}

pkg_install_one() {
  case "$PKG_FAMILY" in
    brew)    brew install "$1" ;;
    apt)     eval "$SUDO apt-get install -y $1" ;;
    dnf)     eval "$SUDO dnf install -y $1" ;;
    pacman)  eval "$SUDO pacman -S --noconfirm $1" ;;
    apk)     eval "$SUDO apk add --no-cache $1" ;;
    zypper)  eval "$SUDO zypper install -y $1" ;;
  esac
}

brew_shellenv() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

pkg_install() {
  local pkg="$1"
  if [[ "$OS" == "Darwin" ]]; then
    if ! have brew; then
      log "Installing Homebrew (one-time, may prompt for sudo)..."
      NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      brew_shellenv
    fi
    brew_shellenv
    brew install "$pkg"
  fi
}

# Backwards-compat alias in case anything still references pkg_install
pkg_install() { pkg_install_one "$@"; }

port_listening() {
  (exec 3<>/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1 && { exec 3<&- 3>&-; return 0; } || return 1
}

# --------------------------------------------------------------------------
# 1. Python 3
# --------------------------------------------------------------------------
if ! have python3; then
  log "Installing python3..."
  if [[ "$PKG_FAMILY" == "brew" ]]; then
    pkg_install_one python@3.12
    brew_shellenv
  else
    pkg_update
    case "$PKG_FAMILY" in
      apt|pacman|zypper) pkg_install_one python3 ; pkg_install_one python3-pip || true ;;
      dnf)               pkg_install_one python3 ; pkg_install_one python3-pip || true ;;
      apk)               pkg_install_one python3 ; pkg_install_one py3-pip     || true ;;
      *)                 pkg_install_one python3 ;;
    esac
  fi
fi
PY="$(command -v python3)"
log "Using python: $($PY --version) ($PY)"

if ! $PY -m pip --version >/dev/null 2>&1; then
  log "Bootstrapping pip..."
  $PY -m ensurepip --user >/dev/null 2>&1 || true
  $PY -m pip --version >/dev/null 2>&1 || {
    err "pip is not available. On Debian/Ubuntu try: sudo apt install python3-pip"
    exit 1
  }
fi

# --------------------------------------------------------------------------
# 2. Python deps
# --------------------------------------------------------------------------
log "Installing Python dependencies (requests, pysocks)..."
$PY -m pip install --user --quiet --upgrade pip
$PY -m pip install --user --quiet requests pysocks

# --------------------------------------------------------------------------
# 3. Tor
# --------------------------------------------------------------------------
if ! have tor; then
  log "Installing Tor..."
  pkg_update
  pkg_install_one tor
fi

# --------------------------------------------------------------------------
# 4. Multiple Tor instances (one per TOR_INSTANCES count, on consecutive ports)
# --------------------------------------------------------------------------
mkdir -p "$TOR_DIR" "$LOG_DIR"
TOR_PORTS=()
for i in $(seq 1 "$TOR_INSTANCES"); do
  port=$((TOR_PORT + i - 1))
  TOR_PORTS+=("$port")
done

for idx in "${!TOR_PORTS[@]}"; do
  i=$((idx + 1))
  port="${TOR_PORTS[$idx]}"
  inst_dir="$TOR_DIR/instance-$i"
  mkdir -p "$inst_dir/data"
  cat > "$inst_dir/torrc" <<EOF
SocksPort 127.0.0.1:${port}
DataDirectory ${inst_dir}/data
Log notice stdout
SocksPolicy accept 127.0.0.1
MaxClientCircuitsPending 128
EOF
done

# --------------------------------------------------------------------------
# 5. Start Tor instances
# --------------------------------------------------------------------------
for idx in "${!TOR_PORTS[@]}"; do
  i=$((idx + 1))
  port="${TOR_PORTS[$idx]}"
  inst_dir="$TOR_DIR/instance-$i"
  log_file="$inst_dir/tor.log"
  pid_file="$inst_dir/tor.pid"

  if port_listening "$port"; then
    log "Tor #$i already listening on 127.0.0.1:${port}, reusing"
    continue
  fi
  if pgrep -f "tor -f ${inst_dir}/torrc" >/dev/null 2>&1; then
    log "Tor #$i already running, waiting for port ${port}..."
    for _ in {1..120}; do
      port_listening "$port" && break
      sleep 1
    done
    continue
  fi

  log "Starting Tor #$i on 127.0.0.1:${port} (logs: $log_file)..."
  nohup tor -f "$inst_dir/torrc" >"$log_file" 2>&1 &
  echo $! > "$pid_file"
  # Stagger so they don't all hammer the Tor directory at once
  sleep "$TOR_START_STAGGER"
done

# Wait for instances to be ready. Tolerate partial failures: if some
# instances don't bootstrap, drop them from TOR_PORTS and continue.
WAIT_TIMEOUT=180
for idx in "${!TOR_PORTS[@]}"; do
  port="${TOR_PORTS[$idx]}"
  i=$((idx + 1))
  log "Waiting for Tor #$i (port $port)..."
  last_pct=0
  for s in $(seq 1 $WAIT_TIMEOUT); do
    if port_listening "$port"; then
      log "Tor #$i up on 127.0.0.1:$port (after ${s}s)"
      break
    fi
    if [[ $((s % 10)) -eq 0 ]]; then
      ready_count=0
      for p in "${TOR_PORTS[@]}"; do
        port_listening "$p" && ready_count=$((ready_count + 1))
      done
      log "  ... ${s}s elapsed, $ready_count/${#TOR_PORTS[@]} instances ready"
    fi
    sleep 1
    if [[ $s -eq $WAIT_TIMEOUT ]]; then
      err "Tor #$i (port $port) did not become ready in ${WAIT_TIMEOUT}s. Last lines of $TOR_DIR/instance-$i/tor.log:"
      tail -n 15 "$TOR_DIR/instance-$i/tor.log" >&2 || true
      # Drop this instance from the list
      TOR_PORTS=("${TOR_PORTS[@]:0:$idx}" "${TOR_PORTS[@]:$((idx+1))}")
      idx=$((idx - 1))
    fi
  done
done

if [[ ${#TOR_PORTS[@]} -eq 0 ]]; then
  err "No Tor instances became ready. Check $TOR_DIR/instance-1/tor.log"
  exit 1
fi

log "${#TOR_PORTS[@]}/$TOR_INSTANCES Tor instances up on ports ${TOR_PORTS[*]}"

# Comma-separated host:port list for download.py
TOR_SPEC=$(IFS=,; echo "${TOR_PORTS[*]/#/127.0.0.1:}")

# --------------------------------------------------------------------------
# 6. Always refresh download.py + files.txt from GitHub
# --------------------------------------------------------------------------
mkdir -p "$THREEAM_DIR"
log "Refreshing download.py + files.txt from GitHub..."
curl -fsSL "$REPO_RAW/download.py" -o "$THREEAM_DIR/download.py"
chmod +x "$THREEAM_DIR/download.py"
# Refresh files.txt only if missing locally (avoid re-downloading 24 MB on every run)
if [[ ! -f "$THREEAM_DIR/files.txt" ]]; then
  log "files.txt not present, fetching..."
  if ! curl -fsSL "$REPO_RAW/files.txt" -o "$THREEAM_DIR/files.txt"; then
    err "Failed to fetch files.txt from $REPO_RAW/files.txt"
    err "Re-run when the network is up, or supply your own with --files PATH."
    exit 1
  fi
fi

# --------------------------------------------------------------------------
# 7. Download
# --------------------------------------------------------------------------
# Resolve LISTING: explicit --files wins; else prefer ./files.txt in cwd;
# else fall back to the one we just (re)fetched in $THREEAM_DIR.
if [[ -z "${LISTING:-}" ]]; then
  if   [[ -f "./files.txt" ]];            then LISTING="./files.txt"
  elif [[ -f "$THREEAM_DIR/files.txt" ]]; then LISTING="$THREEAM_DIR/files.txt"
  fi
fi
if [[ -z "$LISTING" || ! -f "$LISTING" ]]; then
  err "Listing not found. Pass --files /path/to/files.txt or place files.txt next to where you invoked curl."
  err "Current directory: $(pwd)"
  exit 1
fi

mkdir -p "$OUT_DIR"
log "Starting full download -> $OUT_DIR"
log "  listing    : $LISTING"
log "  workers    : $WORKERS"
log "  tor insts  : $TOR_INSTANCES (ports ${TOR_PORTS[*]})"
log "(Ctrl-C to pause; re-run to resume)"
echo

$PY "$THREEAM_DIR/download.py" \
  --list  "$LISTING" \
  --out   "$OUT_DIR" \
  --tor   "$TOR_SPEC" \
  --workers "$WORKERS" \
  2>&1 | tee -a "$LOG_DIR/download.log"

log "Done. To stop all Tor instances:"
for idx in "${!TOR_PORTS[@]}"; do
  echo "    kill \$(cat $TOR_DIR/instance-$((idx+1))/tor.pid)" >&2
done