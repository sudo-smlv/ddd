#!/usr/bin/env bash
# threeam - bulk .onion downloader
#
# ONE-LINE INSTALL + RUN (interactive):
#   curl -fsSL https://raw.githubusercontent.com/sudo-smlv/ddd/main/run.sh | bash
#
# After install, the script lives at a fixed path so it can be re-run from
# any directory:
#   ~/.threeam/run.sh
#
# Non-interactive (env vars or CLI flags survive both invocations):
#   LISTING_URL=http://xxx.onion/foo.txt TOR_INSTANCES=20 WORKERS=2000 \
#     curl -fsSL https://raw.githubusercontent.com/sudo-smlv/ddd/main/run.sh | bash
#   ~/.threeam/run.sh --instances 20 --workers 2000 --url http://...
#
# What it does:
#   1. Installs run.sh + download.py + bundled files.txt to ~/.threeam/
#   2. Asks for: URL/path to listing, Tor instances, concurrent workers
#   3. Starts that many Tor daemons (each on its own loopback port)
#   4. Fetches the listing (through Tor for .onion URLs)
#   5. Downloads every file in parallel, resumable across runs
#
# Re-running `~/.threeam/run.sh` is safe: it picks up fresh args, reuses
# running Tor instances, and the downloader skips already-done files.

set -euo pipefail

# --------------------------------------------------------------------------
# Helpers (defined early so the bootstrap section can use them)
# --------------------------------------------------------------------------
log() { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[err ]\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# Pretty prompt that works whether stdin is piped or a TTY.
# Args: PROMPT_TEXT DEFAULT_VAR_NAME [DEFAULT_VALUE]
prompt() {
  local text="$1" var="$2" default="${3:-}"
  local answer
  if [[ -r /dev/tty ]]; then
    printf '\n  \033[1;36m▸\033[0m \033[1m%s\033[0m' "$text" > /dev/tty
    if [[ -n "$default" ]]; then
      printf '  \033[2m(default: %s)\033[0m' "$default" > /dev/tty
    fi
    printf '\n  \033[1;32m›\033[0m ' > /dev/tty
    read -r answer < /dev/tty || answer=""
  else
    answer="$default"
  fi
  if [[ -z "$answer" ]]; then answer="$default"; fi
  eval "$var=\"\$answer\""
}

# --------------------------------------------------------------------------
# Repo URL: pin to latest commit SHA so CDN caches can't pin us to old code
# --------------------------------------------------------------------------
REPO_RAW_BASE="https://raw.githubusercontent.com/sudo-smlv/ddd"
REPO_RAW="$REPO_RAW_BASE"
if have curl; then
  _sha=$(curl -fsSL --max-time 8 "https://api.github.com/repos/sudo-smlv/ddd/commits/main" \
         | python3 -c "import json,sys;print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || true)
  [[ -n "$_sha" ]] && REPO_RAW="$REPO_RAW_BASE/$_sha" || REPO_RAW="$REPO_RAW_BASE/HEAD"
fi

# Fixed install location — independent of the caller's working directory.
INSTALL_DIR="${INSTALL_DIR:-$HOME/.threeam}"

# --------------------------------------------------------------------------
# STAGE 1: bootstrap. If we're piped from stdin (curl|bash), download
# run.sh + download.py + files.txt into ~/.threeam/ and re-exec ourselves
# from disk. After this point, $BASH_SOURCE is a real file and stdin can
# be the user's TTY.
# --------------------------------------------------------------------------
_self="${BASH_SOURCE[0]:-}"
if [[ -z "$_self" || "$_self" == "/dev/stdin" || ! -f "$_self" ]]; then
  log "Installing threeam to $INSTALL_DIR (one-time)..."
  mkdir -p "$INSTALL_DIR"
  curl -fsSL "$REPO_RAW/run.sh"      -o "$INSTALL_DIR/run.sh"
  curl -fsSL "$REPO_RAW/download.py" -o "$INSTALL_DIR/download.py"
  if ! curl -fsSL "$REPO_RAW/files.txt" -o "$INSTALL_DIR/files.txt"; then
    err "Failed to fetch files.txt from $REPO_RAW/files.txt"
    err "Re-run when the network is up, or copy your own to $INSTALL_DIR/files.txt"
    exit 1
  fi
  chmod +x "$INSTALL_DIR/run.sh" "$INSTALL_DIR/download.py"

  printf "\n\033[1;32m✓\033[0m Installed to \033[1;36m%s\033[0m\n" "$INSTALL_DIR" > /dev/tty 2>/dev/null || true
  printf "\033[2m  Re-running interactively...\033[0m\n\n" > /dev/tty 2>/dev/null || true

  exec bash "$INSTALL_DIR/run.sh" "$@"
fi

# --------------------------------------------------------------------------
# STAGE 2: running from disk. Parse CLI args, then prompt interactively
# for anything missing.
# --------------------------------------------------------------------------
THREEAM_DIR="$INSTALL_DIR"
LISTING=""              # local path to the listing file
LISTING_URL=""           # optional URL to fetch the listing from
TOR_INSTANCES=""
WORKERS=""
OUT_DIR=""
SHOW_FILES=""
FILE_SAMPLE=""

prev=""
for arg in "$@"; do
  case "$prev" in
    --files|--listing)    LISTING="$arg" ;;
    --url)                LISTING_URL="$arg" ;;
    --instances)          TOR_INSTANCES="$arg" ;;
    --workers|--concurrent) WORKERS="$arg" ;;
    --out)                OUT_DIR="$arg" ;;
    --show-files)         SHOW_FILES="$arg" ;;
    --file-sample)        FILE_SAMPLE="$arg" ;;
  esac
  case "$arg" in
    --files=*|--listing=*)    LISTING="${arg#*=}" ;;
    --url=*)                  LISTING_URL="${arg#*=}" ;;
    --instances=*)            TOR_INSTANCES="${arg#*=}" ;;
    --workers=*|--concurrent=*) WORKERS="${arg#*=}" ;;
    --out=*)                  OUT_DIR="${arg#*=}" ;;
    --show-files=*)           SHOW_FILES="${arg#*=}" ;;
    --file-sample=*)          FILE_SAMPLE="${arg#*=}" ;;
  esac
  prev="$arg"
done

# Fall back to env vars if not set via CLI.
: "${LISTING:=$LISTING_URL}"
[[ -z "$LISTING" ]]      && LISTING="${LISTING_URL:-${LISTING:-}}"
[[ -z "$TOR_INSTANCES" ]] && TOR_INSTANCES="${TOR_INSTANCES:-${THREEAM_INSTANCES:-}}"
[[ -z "$WORKERS" ]]       && WORKERS="${WORKERS:-${THREEAM_WORKERS:-}}"
[[ -z "$OUT_DIR" ]]       && OUT_DIR="${OUT_DIR:-$THREEAM_DIR/download}"

# --------------------------------------------------------------------------
# Interactive prompt: only when /dev/tty is available AND user didn't already
# supply values via flags/env. Non-interactive callers always get defaults.
# --------------------------------------------------------------------------
INTERACTIVE=false
if [[ -r /dev/tty ]] && [[ -z "${LISTING:-}${LISTING_URL:-}" || -z "${TOR_INSTANCES:-}" || -z "${WORKERS:-}" ]]; then
  INTERACTIVE=true
fi

if $INTERACTIVE; then
  printf '\n\033[1;36m╔══════════════════════════════════════════════════════════════════╗\033[0m\n' > /dev/tty
  printf '\033[1;36m║\033[0m           \033[1;37mthreeam\033[0m — bulk \033[1;35m.onion\033[0m downloader                  \033[1;36m║\033[0m\n' > /dev/tty
  printf '\033[1;36m╚══════════════════════════════════════════════════════════════════╝\033[0m\n\n' > /dev/tty

  if [[ -z "${LISTING:-}" && -z "${LISTING_URL:-}" ]]; then
    printf '  Where is files.txt? You can paste:\n' > /dev/tty
    printf '    • a \033[1;35m.onion\033[0m URL  (http://abc...onion/path/files.txt)\n' > /dev/tty
    printf '    • a regular URL (https://example.com/files.txt)\n' > /dev/tty
    printf '    • a local path (/some/where/files.txt)\n' > /dev/tty
    printf '    • or press \033[1;33mEnter\033[0m to use the bundled one\n\n' > /dev/tty

    raw=$(prompt "Listing URL or path" __LISTING "")
    if [[ -z "$raw" ]]; then
      LISTING="$THREEAM_DIR/files.txt"
    elif [[ "$raw" =~ ^https?:// ]]; then
      LISTING_URL="$raw"
      LISTING="$THREEAM_DIR/files.txt"
    elif [[ -f "$raw" ]]; then
      LISTING="$raw"
    else
      err "Not a URL and not a readable file: $raw"
      exit 1
    fi
  fi

  if [[ -z "${TOR_INSTANCES:-}" ]]; then
    raw=$(prompt "Tor instances (one per ~50 workers; loopback only)" __TI "20")
    TOR_INSTANCES="${raw:-20}"
  fi

  if [[ -z "${WORKERS:-}" ]]; then
    raw=$(prompt "Concurrent downloads" __WK "2000")
    WORKERS="${raw:-2000}"
  fi

  printf '\n' > /dev/tty
fi

# Apply defaults if still empty (non-interactive fallback).
: "${TOR_INSTANCES:=20}"
: "${WORKERS:=2000}"
: "${SHOW_FILES:=sampled}"
: "${FILE_SAMPLE:=50}"

LOG_DIR="${LOG_DIR:-$THREEAM_DIR/logs}"
TOR_DIR="${TOR_DIR:-$HOME/.threeam-tor}"

ulimit -n 131072 2>/dev/null || true

# --------------------------------------------------------------------------
# Stage 2 continues — the rest is the same as before
# --------------------------------------------------------------------------

OS="$(uname -s)"
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
    else err "no supported package manager found"; exit 1
    fi
    ;;
  *) err "unsupported OS: $OS"; exit 1 ;;
esac

pkg_update() {
  case "$PKG_FAMILY" in
    apt) eval "$SUDO apt-get update" >/dev/null 2>&1 || true ;;
    dnf) eval "$SUDO dnf check-update" >/dev/null 2>&1 || true ;;
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

port_listening() {
  (exec 3<>/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1 && { exec 3<&- 3>&-; return 0; } || return 1
}

# Python
if ! have python3; then
  log "Installing python3..."
  if [[ "$PKG_FAMILY" == "brew" ]]; then
    pkg_install_one python@3.12; eval "$(brew shellenv)"
  else
    pkg_update
    case "$PKG_FAMILY" in
      apt|pacman|zypper) pkg_install_one python3; pkg_install_one python3-pip || true ;;
      dnf)               pkg_install_one python3; pkg_install_one python3-pip || true ;;
      apk)               pkg_install_one python3; pkg_install_one py3-pip     || true ;;
      *)                 pkg_install_one python3 ;;
    esac
  fi
fi
PY="$(command -v python3)"
log "Using python: $($PY --version) ($PY)"
if ! $PY -m pip --version >/dev/null 2>&1; then
  $PY -m ensurepip --user >/dev/null 2>&1 || true
  $PY -m pip --version >/dev/null 2>&1 || { err "pip not available"; exit 1; }
fi
log "Installing Python deps (requests, pysocks)..."
$PY -m pip install --user --quiet --upgrade pip
$PY -m pip install --user --quiet requests pysocks

# Tor
if ! have tor; then
  log "Installing Tor..."
  pkg_update; pkg_install_one tor
fi

# --------------------------------------------------------------------------
# Tor instances: N daemons on consecutive loopback ports
# --------------------------------------------------------------------------
TOR_START_STAGGER="${TOR_START_STAGGER:-2}"
TOR_PORT="${TOR_PORT:-9151}"
mkdir -p "$TOR_DIR" "$LOG_DIR"
TOR_PORTS=()
for i in $(seq 1 "$TOR_INSTANCES"); do
  TOR_PORTS+=($((TOR_PORT + i - 1)))
done

for idx in "${!TOR_PORTS[@]}"; do
  i=$((idx + 1)); port="${TOR_PORTS[$idx]}"
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

for idx in "${!TOR_PORTS[@]}"; do
  i=$((idx + 1)); port="${TOR_PORTS[$idx]}"
  inst_dir="$TOR_DIR/instance-$i"; log_file="$inst_dir/tor.log"; pid_file="$inst_dir/tor.pid"
  if port_listening "$port"; then log "Tor #$i already on :$port"; continue; fi
  if pgrep -f "tor -f ${inst_dir}/torrc" >/dev/null 2>&1; then
    log "Tor #$i already running, waiting for :$port..."
    for _ in {1..120}; do port_listening "$port" && break; sleep 1; done
    continue
  fi
  log "Starting Tor #$i on 127.0.0.1:$port ..."
  nohup tor -f "$inst_dir/torrc" >"$log_file" 2>&1 &
  echo $! > "$pid_file"
  sleep "$TOR_START_STAGGER"
done

WAIT_TIMEOUT=180
for idx in "${!TOR_PORTS[@]}"; do
  port="${TOR_PORTS[$idx]}"; i=$((idx + 1))
  log "Waiting for Tor #$i (port $port)..."
  last_pct=0
  for s in $(seq 1 $WAIT_TIMEOUT); do
    if port_listening "$port"; then log "Tor #$i up on :$port (after ${s}s)"; break; fi
    if [[ $((s % 10)) -eq 0 ]]; then
      ready=0
      for p in "${TOR_PORTS[@]}"; do port_listening "$p" && ready=$((ready+1)); done
      log "  ... ${s}s elapsed, $ready/${#TOR_PORTS[@]} instances ready"
    fi
    sleep 1
    if [[ $s -eq $WAIT_TIMEOUT ]]; then
      err "Tor #$i (port $port) not ready in ${WAIT_TIMEOUT}s"; tail -n 15 "$TOR_DIR/instance-$i/tor.log" >&2 || true
      TOR_PORTS=("${TOR_PORTS[@]:0:$idx}" "${TOR_PORTS[@]:$((idx+1))}")
      idx=$((idx - 1))
    fi
  done
done

if [[ ${#TOR_PORTS[@]} -eq 0 ]]; then err "No Tor instances ready"; exit 1; fi
log "${#TOR_PORTS[@]}/$TOR_INSTANCES Tor instances up on ports ${TOR_PORTS[*]}"

TOR_SPEC=$(IFS=,; echo "${TOR_PORTS[*]/#/127.0.0.1:}")

# --------------------------------------------------------------------------
# Fetch the listing from LISTING_URL (if user pasted one) — through Tor if
# it's an .onion URL, direct otherwise.
# --------------------------------------------------------------------------
if [[ -n "${LISTING_URL:-}" && "$LISTING_URL" =~ \.onion ]]; then
  log "Fetching listing from $LISTING_URL (via Tor)..."
  if ! curl --socks5-hostname 127.0.0.1:"${TOR_PORTS[0]}" -fsSL "$LISTING_URL" -o "$LISTING"; then
    err "Failed to fetch $LISTING_URL through Tor"
    exit 1
  fi
elif [[ -n "${LISTING_URL:-}" ]]; then
  log "Fetching listing from $LISTING_URL ..."
  if ! curl -fsSL "$LISTING_URL" -o "$LISTING"; then
    err "Failed to fetch $LISTING_URL"; exit 1
  fi
fi

# Refresh download.py + ensure files.txt present
mkdir -p "$THREEAM_DIR"
curl -fsSL "$REPO_RAW/download.py" -o "$THREEAM_DIR/download.py"
chmod +x "$THREEAM_DIR/download.py"
if [[ ! -f "$LISTING" && -f "$THREEAM_DIR/files.txt" ]]; then
  LISTING="$THREEAM_DIR/files.txt"
fi
if [[ ! -f "$LISTING" ]]; then
  log "files.txt not present, fetching..."
  curl -fsSL "$REPO_RAW/files.txt" -o "$LISTING"
fi

if [[ -z "$LISTING" || ! -f "$LISTING" ]]; then
  err "Listing not found. Pass --files PATH or --url URL."
  exit 1
fi

mkdir -p "$OUT_DIR"
log "Starting full download -> $OUT_DIR"
log "  listing    : $LISTING"
log "  workers    : $WORKERS"
log "  tor insts  : ${#TOR_PORTS[@]} (ports ${TOR_PORTS[*]})"
log "  show-files : $SHOW_FILES (sampling every ${FILE_SAMPLE}th)"
log "(Ctrl-C to pause; re-run ~/.threeam/run.sh to resume)"
echo

EXTRA_ARGS=()
[[ -n "$SHOW_FILES"  ]] && EXTRA_ARGS+=(--show-files "$SHOW_FILES")
[[ -n "$FILE_SAMPLE" ]] && EXTRA_ARGS+=(--file-sample "$FILE_SAMPLE")

$PY "$THREEAM_DIR/download.py" \
  --list  "$LISTING" \
  --out   "$OUT_DIR" \
  --tor   "$TOR_SPEC" \
  --workers "$WORKERS" \
  "${EXTRA_ARGS[@]}" \
  2>&1 | tee -a "$LOG_DIR/download.log"

log "Done. Stop all Tor instances with: pkill -f 'tor -f $TOR_DIR'"
log "Re-run anytime: $INSTALL_DIR/run.sh"