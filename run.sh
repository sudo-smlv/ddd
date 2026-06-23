#!/usr/bin/env bash
# Bootstrap and run the full threeam download end-to-end.
#
# Works on macOS and Linux (apt / dnf / pacman / apk).
#
# Steps:
#   1. Detect OS + package manager
#   2. Install Homebrew on macOS if missing; on Linux assume the system PM exists
#   3. Install python3 if missing and ensure pip works
#   4. Install Python deps (requests, pysocks)
#   5. Install Tor via the system package manager
#   6. Write an isolated torrc + DataDirectory under ~/.threeam-tor
#   7. Start Tor in the background, listening only on 127.0.0.1
#   8. Run download.py against the full listing (resumable on re-run)
#
# Re-running this script is safe: it skips anything already done and the
# downloader skips files already on disk.
#
# Override defaults via env vars, e.g.:
#     TOR_PORT=9155 WORKERS=8 ./run.sh

set -euo pipefail

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
THREEAM_DIR="${THREEAM_DIR:-$HOME/Developer/P/Python/threeam}"
LISTING="${LISTING:-$THREEAM_DIR/files.txt}"
OUT_DIR="${OUT_DIR:-$THREEAM_DIR/download}"
LOG_DIR="${LOG_DIR:-$THREEAM_DIR/logs}"

TOR_DIR="${TOR_DIR:-$HOME/.threeam-tor}"
TOR_PORT="${TOR_PORT:-9151}"
TORRC="${TORRC:-$TOR_DIR/torrc}"
TOR_PIDFILE="${TOR_PIDFILE:-$TOR_DIR/tor.pid}"
TOR_LOG="${TOR_LOG:-$TOR_DIR/tor.log}"

WORKERS="${WORKERS:-4}"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
log() { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[err ]\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

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
  # pkg_install <brew-formula | apt-name>  (same name on both is fine for tor/python)
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
  # bash builtin, no external tools required
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
# 6. Download
# --------------------------------------------------------------------------
if [[ ! -f "$LISTING" ]]; then
  err "Listing not found: $LISTING"
  exit 1
fi
if [[ ! -f "$THREEAM_DIR/download.py" ]]; then
  err "download.py not found in $THREEAM_DIR"
  exit 1
fi

mkdir -p "$OUT_DIR"
log "Starting full download -> $OUT_DIR"
log "(Ctrl-C to pause; re-run this script to resume)"
echo

$PY "$THREEAM_DIR/download.py" \
  --list  "$LISTING" \
  --out   "$OUT_DIR" \
  --tor   "127.0.0.1:${TOR_PORT}" \
  --workers "$WORKERS" \
  2>&1 | tee -a "$LOG_DIR/download.log"

log "Done. To stop Tor: kill \$(cat $TOR_PIDFILE)"