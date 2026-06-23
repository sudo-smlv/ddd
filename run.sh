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
# Where to install when invoked via `curl | bash`
# --------------------------------------------------------------------------
REPO_RAW="https://raw.githubusercontent.com/sudo-smlv/ddd/main"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.threeam}"

# --------------------------------------------------------------------------
# If we were piped from stdin, materialise ourselves to disk first
# --------------------------------------------------------------------------
_self="${BASH_SOURCE[0]:-}"
if [[ -z "$_self" || "$_self" == "/dev/stdin" || ! -f "$_self" ]]; then
  log_step() { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
  log_step "Installing to $INSTALL_DIR ..."
  mkdir -p "$INSTALL_DIR"
  curl -fsSL "$REPO_RAW/run.sh"       -o "$INSTALL_DIR/run.sh"
  curl -fsSL "$REPO_RAW/download.py"  -o "$INSTALL_DIR/download.py"
  chmod +x "$INSTALL_DIR/run.sh" "$INSTALL_DIR/download.py"
  log_step "Re-executing from $INSTALL_DIR/run.sh"
  exec bash "$INSTALL_DIR/run.sh" "$@"
fi

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
THREEAM_DIR="${THREEAM_DIR:-$INSTALL_DIR}"
LISTING="${LISTING:-${1:-}}"
# Allow --files=... / --files ... anywhere
for arg in "$@"; do
  case "$arg" in
    --files=*) LISTING="${arg#*=}" ;;
    --files)
      # handled in second pass
      :
      ;;
  esac
done
i=1
for arg in "$@"; do
  if [[ "$arg" == "--files" ]]; then
    next="${!i}" 2>/dev/null || true
    if [[ -n "${next:-}" ]]; then LISTING="$next"; fi
  fi
  i=$((i + 1))
done

OUT_DIR="${OUT_DIR:-$THREEAM_DIR/download}"
LOG_DIR="${LOG_DIR:-$THREEAM_DIR/logs}"

TOR_DIR="${TOR_DIR:-$HOME/.threeam-tor}"
TOR_PORT="${TOR_PORT:-9151}"
TORRC="${TORRC:-$TOR_DIR/torrc}"
TOR_PIDFILE="${TOR_PIDFILE:-$TOR_DIR/tor.pid}"
TOR_LOG="${TOR_LOG:-$TOR_DIR/tor.log}"

WORKERS="${WORKERS:-4}"

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

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
log()      { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
err()      { printf '\033[1;31m[err ]\033[0m %s\n' "$*" >&2; }
have()     { command -v "$1" >/dev/null 2>&1; }

OS="$(uname -s)"
case "$OS" in
  Darwin) PKG_INSTALL="brew install" ;;
  Linux)
    if have apt-get;     then PKG_INSTALL="sudo apt-get update >/dev/null && sudo apt-get install -y"
    elif have dnf;       then PKG_INSTALL="sudo dnf install -y"
    elif have pacman;    then PKG_INSTALL="sudo pacman -S --noconfirm"
    elif have apk;       then PKG_INSTALL="sudo apk add --no-cache"
    elif have zypper;    then PKG_INSTALL="sudo zypper install -y"
    else err "no supported package manager found (need apt/dnf/pacman/apk/zypper)"; exit 1
    fi
    ;;
  *) err "unsupported OS: $OS"; exit 1 ;;
esac

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
  else
    # shellcheck disable=SC2086
    $PKG_INSTALL "$pkg"
  fi
}

port_listening() {
  (exec 3<>/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1 && { exec 3<&- 3>&-; return 0; } || return 1
}

# --------------------------------------------------------------------------
# 1. Python 3
# --------------------------------------------------------------------------
if ! have python3; then
  log "Installing python3..."
  if [[ "$OS" == "Darwin" ]]; then
    pkg_install python@3.12
    brew_shellenv
  else
    case "$PKG_INSTALL" in
      *apt-get*) pkg_install python3 python3-pip ;;
      *dnf*)     pkg_install python3 python3-pip ;;
      *pacman*)  pkg_install python python-pip ;;
      *apk*)     pkg_install python3 py3-pip ;;
      *)         pkg_install python3 ;;
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
  pkg_install tor
fi

# --------------------------------------------------------------------------
# 4. Isolated torrc
# --------------------------------------------------------------------------
mkdir -p "$TOR_DIR/data" "$LOG_DIR"
cat > "$TORRC" <<EOF
SocksPort 127.0.0.1:${TOR_PORT}
DataDirectory ${TOR_DIR}/data
Log notice stdout
EOF

# --------------------------------------------------------------------------
# 5. Start Tor
# --------------------------------------------------------------------------
if port_listening "$TOR_PORT"; then
  log "Tor already listening on 127.0.0.1:${TOR_PORT}, reusing it"
elif pgrep -f "tor -f ${TORRC}" >/dev/null 2>&1; then
  log "Tor already running with our config, waiting for port ${TOR_PORT}..."
  for _ in {1..90}; do
    port_listening "$TOR_PORT" && break
    sleep 1
  done
else
  log "Starting Tor (logs: $TOR_LOG)..."
  nohup tor -f "$TORRC" >"$TOR_LOG" 2>&1 &
  echo $! > "$TOR_PIDFILE"
  for i in {1..90}; do
    if port_listening "$TOR_PORT"; then
      log "Tor is up on 127.0.0.1:${TOR_PORT} (pid $(cat "$TOR_PIDFILE"))"
      break
    fi
    sleep 1
    if [[ $i -eq 90 ]]; then
      err "Tor did not become ready in 90s. Last 30 lines of $TOR_LOG:"
      tail -n 30 "$TOR_LOG" >&2 || true
      exit 1
    fi
  done
fi

# --------------------------------------------------------------------------
# 6. Ensure download.py is present (refresh from GitHub if stale)
# --------------------------------------------------------------------------
mkdir -p "$THREEAM_DIR"
if [[ ! -f "$THREEAM_DIR/download.py" ]]; then
  log "Fetching download.py from GitHub..."
  curl -fsSL "$REPO_RAW/download.py" -o "$THREEAM_DIR/download.py"
  chmod +x "$THREEAM_DIR/download.py"
fi

# --------------------------------------------------------------------------
# 7. Download
# --------------------------------------------------------------------------
if [[ -z "$LISTING" || ! -f "$LISTING" ]]; then
  err "Listing not found. Pass --files /path/to/files.txt or place files.txt next to where you invoked curl."
  err "Current directory: $(pwd)"
  exit 1
fi

mkdir -p "$OUT_DIR"
log "Starting full download -> $OUT_DIR"
log "  listing: $LISTING"
log "  workers: $WORKERS   tor: 127.0.0.1:${TOR_PORT}"
log "(Ctrl-C to pause; re-run to resume)"
echo

$PY "$THREEAM_DIR/download.py" \
  --list  "$LISTING" \
  --out   "$OUT_DIR" \
  --tor   "127.0.0.1:${TOR_PORT}" \
  --workers "$WORKERS" \
  2>&1 | tee -a "$LOG_DIR/download.log"

log "Done. To stop Tor: kill \$(cat $TOR_PIDFILE)"