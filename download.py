#!/usr/bin/env python3
"""
Download every file listed in a Windows ``dir`` listing via a .onion URL.

The listing in ``files.txt`` is the output of::

    dir /s "C:\\Users\\Administrator\\Desktop\\jetproducts.corp" > files.txt

For every file entry the script builds the URL documented in ``example.txt``::

    http://<host>.onion/detail/<id>?sub=<URL-encoded-relative-path>

and saves the body to ``<out>/<relative-path>``.

Usage
-----
    python download.py                      # defaults: Tor on 127.0.0.1:9050, 4 workers
    python download.py --list files.txt --out download --workers 8
    python download.py --filter "ACCOUNTING"   # only paths containing this substring
    python download.py --limit 5               # smoke test on the first five files
    python download.py --no-progress           # disable the live status line

The script is resumable: files that already exist on disk with a non-zero size
are skipped. Downloads are streamed to ``<name>.part`` files and atomically
renamed on success.

Live UI
-------
While running, a single status line is updated on stderr roughly once per second
(only when stderr is a TTY)::

    [  127/171736 files]  2.31 GiB / 97.73 GiB ( 2.4%) |  438 KB/s | ETA  62h 14m | active 4 | err 0 | elapsed  1h 25m

Each completed file gets its own line on stdout with elapsed time and average
speed::

    [   127/171736] OK         4,096 B in 812 ms (   5 KB/s)  ACCOUNTING/.../Deposits.xls

ETA is computed from a 60-second rolling-average throughput, so the estimate
stabilises after the first minute rather than being skewed by warm-up.
"""

from __future__ import annotations

import argparse
import collections
import itertools
import json
import random
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import quote

import requests

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BASE_URL = "http://threeamkelxicjsaf2czjyz2lc4q3ngqkxhhlexyfcp2o6raw4rphyad.onion"
DETAIL_PATH = "/detail/sn4jgn4a8h6tor8jcw4holx08szr1v"
ROOT_PREFIX = r"C:\Users\Administrator\Desktop\jetproducts.corp"
USER_AGENT = "Mozilla/5.0 (threeam-downloader/1.0)"

CHUNK_SIZE = 64 * 1024
SPEED_WINDOW_SEC = 60.0
STATUS_INTERVAL_SEC = 1.0
MILESTONE_INTERVAL_SEC = 10.0
BAR_WIDTH = 28

# ---------------------------------------------------------------------------
# Terminal colours (auto-disabled when not a TTY)
# ---------------------------------------------------------------------------

_IS_TTY = sys.stdout.isatty()


def _ansi(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _IS_TTY else text


def green(text: str)  -> str: return _ansi("32", text)
def red(text: str)    -> str: return _ansi("31", text)
def yellow(text: str) -> str: return _ansi("33", text)
def grey(text: str)   -> str: return _ansi("90", text)
def cyan(text: str)   -> str: return _ansi("36", text)
def bold(text: str)   -> str: return _ansi("1", text)

_RE_ANSI = re.compile(r"\033\[[0-9;]*m")


def strip_ansi(text: str) -> str:
    return _RE_ANSI.sub("", text)


def vlen(text: str) -> int:
    """Visible width: ignore ANSI colour codes when measuring for padding."""
    return len(strip_ansi(text))

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

_DIR_HEADER_RE = re.compile(r"^\s*Directory of\s+(?P<path>.+?)\s*$")
_FILE_LINE_RE = re.compile(
    r"^\s*\d{2}/\d{2}/\d{4}\s+\d{1,2}:\d{2}\s+(?:AM|PM)\s+"
    r"(?P<size>[\d,]+|<DIR>)\s+(?P<name>.+?)\s*$"
)


def _norm(path: str) -> str:
    return path.replace("/", "\\").lower()


def parse_listing(listing: Path):
    root_norm = _norm(ROOT_PREFIX)
    current_dir: str | None = None
    for raw in listing.read_text(encoding="utf-8", errors="replace").splitlines():
        m = _DIR_HEADER_RE.match(raw)
        if m:
            current_dir = m.group("path").strip()
            continue
        if current_dir is None:
            continue
        m = _FILE_LINE_RE.match(raw)
        if not m or m.group("size") == "<DIR>":
            continue
        name = m.group("name").strip()
        norm = _norm(current_dir)
        if not norm.startswith(root_norm):
            continue
        rel_dir = current_dir.replace("/", "\\")[len(ROOT_PREFIX):].lstrip("\\")
        rel_path = f"{rel_dir}\\{name}" if rel_dir else name
        size = int(m.group("size").replace(",", ""))
        yield rel_path, size


def build_url(rel_path: str) -> str:
    forward = rel_path.replace("\\", "/")
    encoded = quote(forward, safe="/")
    return f"{BASE_URL}{DETAIL_PATH}?sub={encoded}"


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

def fmt_bytes(n: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:6.2f} {unit}" if unit != "B" else f"{n:6.0f} B"
        n /= 1024
    return f"{n:6.2f} TiB"


def fmt_speed(bps: float) -> str:
    if bps < 1024:
        return f"{bps:5.0f} B/s"
    for unit, div in (("KB/s", 1024), ("MB/s", 1024 ** 2), ("GB/s", 1024 ** 3)):
        if bps < div * 1024 or unit == "GB/s":
            return f"{bps / div:5.1f} {unit}"
    return f"{bps / (1024 ** 3):5.1f} GB/s"


def fmt_duration(seconds: float) -> str:
    if seconds < 0 or seconds == float("inf"):
        return "  --  "
    s = int(seconds)
    h, rem = divmod(s, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m:02d}m"
    if m:
        return f"{m}m {s:02d}s"
    return f"{s}s"


def fmt_clock(seconds_from_now: float) -> str:
    """Format ETA as a wall-clock string in local time, e.g. 'Sat 27 Jun 03:14'."""
    if seconds_from_now == float("inf") or seconds_from_now < 0:
        return "       --        "
    return (datetime.now() + timedelta(seconds=seconds_from_now)).strftime("%a %d %b %H:%M")


def render_bar(pct: float, width: int = BAR_WIDTH) -> str:
    pct = max(0.0, min(100.0, pct))
    filled = int(width * pct / 100)
    return "█" * filled + "░" * (width - filled)


def fmt_gib(n: float) -> str:
    return f"{n / (1024 ** 3):6.2f} GiB"


# ---------------------------------------------------------------------------
# Shared download stats
# ---------------------------------------------------------------------------

class Stats:
    """Thread-safe throughput and progress tracker."""

    def __init__(self, total_bytes: int, total_files: int):
        self.total_bytes = total_bytes
        self.total_files = total_files
        self.completed_files = 0
        self.active_files = 0
        self.error_files = 0
        self.ok_files = 0
        self.downloaded = 0
        self.lock = threading.Lock()
        self.window: collections.deque[tuple[float, int]] = collections.deque()
        self.speed_history: collections.deque[float] = collections.deque(maxlen=60)
        self.start = time.monotonic()
        # rel -> [received_bytes, total_size, started_monotonic]
        self.active_map: dict[str, list] = {}

    def add_bytes(self, n: int, rel: str | None = None) -> None:
        now = time.monotonic()
        with self.lock:
            self.downloaded += n
            self.window.append((now, n))
            cutoff = now - SPEED_WINDOW_SEC
            while self.window and self.window[0][0] < cutoff:
                self.window.popleft()
            if rel is not None:
                entry = self.active_map.get(rel)
                if entry is not None:
                    entry[0] += n

    def file_started(self, rel: str, size: int) -> None:
        with self.lock:
            self.active_files += 1
            self.active_map[rel] = [0, size, time.monotonic()]

    def file_finished(self, rel: str, *, error: bool) -> None:
        with self.lock:
            self.active_files = max(0, self.active_files - 1)
            self.completed_files += 1
            if error:
                self.error_files += 1
            else:
                self.ok_files += 1
            self.active_map.pop(rel, None)

    @property
    def rolling_speed(self) -> float:
        with self.lock:
            if len(self.window) < 2:
                return 0.0
            t0 = self.window[0][0]
            t1 = self.window[-1][0]
            if t1 - t0 < 0.5:
                return 0.0
            return sum(b for _, b in self.window) / (t1 - t0)

    @property
    def lifetime_speed(self) -> float:
        elapsed = time.monotonic() - self.start
        with self.lock:
            done = self.downloaded
        return done / elapsed if elapsed > 0 else 0.0

    @property
    def eta_seconds(self) -> float:
        speed = self.rolling_speed or self.lifetime_speed
        if speed <= 0:
            return float("inf")
        remaining = max(0, self.total_bytes - self.downloaded)
        return remaining / speed

    def render_status_line(self) -> str:
        """Single-line live status for TTY stderr."""
        elapsed = time.monotonic() - self.start
        pct = 100.0 * self.downloaded / self.total_bytes if self.total_bytes else 0.0
        speed = self.rolling_speed or self.lifetime_speed
        eta = self.eta_seconds
        done = self.completed_files
        return (
            f"[{render_bar(pct)}] {pct:5.2f}%   "
            f"{fmt_gib(self.downloaded)} / {fmt_gib(self.total_bytes)}   "
            f"↑ {fmt_speed(speed)}   "
            f"⏱  ETA {fmt_duration(eta)}   "
            f"🕒 finish {fmt_clock(eta)}   "
            f"⚡ {done:,}/{self.total_files:,} done   "
            f"workers {self.active_files}   "
            f"errors {self.error_files}   "
            f"elapsed {fmt_duration(elapsed)}"
        )

    def _active_rows(self, limit: int = 6) -> list[str]:
        """Compact one-line-per-file view of in-flight downloads (oldest first).

        Each returned string has visible width <= 66 so it fits the 72-wide box.
        """
        now = time.monotonic()
        with self.lock:
            items = sorted(self.active_map.items(), key=lambda kv: kv[1][2])
            snap = [(rel, recv, size, now - t0) for rel, (recv, size, t0) in items]
        rows: list[str] = []
        for rel, recv, size, age in snap[:limit]:
            name = rel.replace("\\", "/").rsplit("/", 1)[-1]
            if len(name) > 30:
                name = name[:29] + "…"
            pdone = (100.0 * recv / size) if size else 0.0
            sizes = f"{fmt_bytes(recv).strip():>10} / {fmt_bytes(size).strip():<10}"
            rows.append(f"{name:<30} {grey(sizes)} {pdone:5.1f}%")
        extra = len(snap) - len(rows)
        if extra > 0:
            rows.append(grey(f"+{extra} more downloading…"))
        return rows

    def render_panel(self) -> str:
        """Boxed multi-line live panel (also used for non-TTY checkpoints)."""
        elapsed = time.monotonic() - self.start
        pct = 100.0 * self.downloaded / self.total_bytes if self.total_bytes else 0.0
        speed = self.lifetime_speed
        rolling = self.rolling_speed
        eta = self.eta_seconds
        remaining = max(0, self.total_bytes - self.downloaded)
        with self.lock:
            active = self.active_files
            done = self.completed_files
            errors = self.error_files
            ok = self.ok_files
        clock_now = datetime.now().strftime("%H:%M:%S")
        bar = render_bar(pct, width=44)
        sparkline = self._sparkline()
        W = 72
        top    = cyan("╔" + "═" * (W - 2) + "╗")
        sep    = cyan("╟" + "─" * (W - 2) + "╢")
        bottom = cyan("╚" + "═" * (W - 2) + "╝")

        def line(content: str) -> str:
            pad = max(1, W - 2 - vlen(content))
            return cyan("║") + content + (" " * pad) + cyan("║")

        def row(k: str, v: str) -> str:
            return line(f" {bold(k)}{' ' * max(1, 12 - vlen(k))}{v}")

        lines = [
            top,
            line(f" {bold('threeam downloader')}    {grey(clock_now)}"),
            sep,
            line(f" {bar}  {pct:6.2f}%"),
            sep,
            row("Files",      f"{done:,} / {self.total_files:,}   "
                              f"({green(str(ok) + ' ok')}, {red(str(errors) + ' err')}, {active} active)"),
            row("Downloaded", f"{fmt_gib(self.downloaded).strip()} / {fmt_gib(self.total_bytes).strip()}   "
                               f"({fmt_gib(remaining).strip()} left)"),
            row("Speed",      f"{fmt_speed(rolling)} rolling (60s)   {fmt_speed(speed)} avg"),
            row("History",    sparkline),
            row("Elapsed",    f"{fmt_duration(elapsed)}   ETA {fmt_duration(eta)}   finish {fmt_clock(eta)}"),
        ]
        active_rows = self._active_rows()
        if active_rows:
            lines.append(sep)
            lines.append(line(f" {bold('downloading now')}"))
            for info in active_rows:
                lines.append(line(f"   {grey('•')} {info}"))
        lines.append(bottom)
        return "\n".join(lines)

    # Back-compat alias (non-TTY checkpoint path).
    def render_milestone(self) -> str:
        return "\n" + self.render_panel()

    def _sparkline(self) -> str:
        """Render last 30 speed samples as unicode sparkline."""
        if len(self.speed_history) < 2:
            return "(collecting samples...)"
        bars = "▁▂▃▄▅▆▇█"
        samples = list(self.speed_history)[-30:]
        mx = max(samples) or 1
        return "".join(bars[min(len(bars) - 1, int(s / mx * (len(bars) - 1)))] for s in samples) + \
               f"  (now {fmt_speed(samples[-1])})"

    def record_checkpoint_speed(self) -> None:
        # NB: rolling_speed / lifetime_speed each acquire self.lock themselves,
        # so compute them *before* taking the lock here. threading.Lock is not
        # reentrant — doing this inside `with self.lock` self-deadlocks the
        # reporter thread on the very first checkpoint and freezes all output.
        speed = self.rolling_speed or self.lifetime_speed
        with self.lock:
            self.speed_history.append(speed)


# ---------------------------------------------------------------------------
# Console: owns the screen so the live panel and scrolling log never collide
# ---------------------------------------------------------------------------

class Console:
    """Single writer for stdout.

    On a TTY it keeps a multi-line status panel pinned at the bottom and
    redraws it *in place* (no duplicate boxes). Scrolling lines (per-file
    results) are printed above the panel: erase panel → print line → redraw.

    When stdout is not a TTY (piped/redirected) it falls back to plain
    scrolling output with an occasional checkpoint box. A separate plain-text
    log file (``--log``) always receives un-coloured lines.
    """

    def __init__(self, stats: Stats, logfile=None):
        self.stats = stats
        self.lock = threading.RLock()
        self.tty = sys.stdout.isatty()
        self.logfile = logfile
        self.panel_height = 0  # lines currently occupied by the pinned panel

    # -- internal (call with lock held) --------------------------------------
    def _erase_panel(self) -> None:
        if self.panel_height:
            sys.stdout.write(f"\033[{self.panel_height}A\033[J")
            self.panel_height = 0

    def _draw_panel(self) -> None:
        text = self.stats.render_panel()
        sys.stdout.write(text + "\n")
        self.panel_height = text.count("\n") + 1
        sys.stdout.flush()

    def _to_logfile(self, line: str) -> None:
        if self.logfile:
            try:
                self.logfile.write(strip_ansi(line) + "\n")
                self.logfile.flush()
            except (OSError, ValueError):
                pass

    # -- public --------------------------------------------------------------
    def log(self, line: str) -> None:
        """Emit a scrolling line above the live panel."""
        with self.lock:
            if self.tty:
                self._erase_panel()
                sys.stdout.write(line + "\n")
                self._draw_panel()
            else:
                sys.stdout.write(line + "\n")
                sys.stdout.flush()
            self._to_logfile(line)

    def refresh(self) -> None:
        """Redraw the live panel in place (TTY only)."""
        if not self.tty:
            return
        with self.lock:
            self._erase_panel()
            self._draw_panel()

    def checkpoint_box(self) -> None:
        """Non-TTY periodic checkpoint: append a box to stdout + logfile."""
        box = self.stats.render_panel()
        if not self.tty:
            sys.stdout.write("\n" + box + "\n")
            sys.stdout.flush()
        self._to_logfile(strip_ansi(box))

    def print_banner(self, text: str) -> None:
        with self.lock:
            sys.stdout.write(text + "\n")
            sys.stdout.flush()
            self._to_logfile(text)

    def close(self) -> None:
        with self.lock:
            if self.tty:
                self._erase_panel()
                self._draw_panel()  # leave a final, complete panel on screen


# ---------------------------------------------------------------------------
# Downloading
# ---------------------------------------------------------------------------

def parse_proxies(tor_spec: str | None) -> list[str | None]:
    """Parse --tor into a list of SOCKS5h proxy URLs (or [None] for direct)."""
    if not tor_spec:
        return [None]
    out: list[str | None] = []
    for raw in tor_spec.split(","):
        p = raw.strip()
        if not p:
            continue
        host, _, port = p.partition(":")
        if not port:
            port = "9050"
        out.append(f"socks5h://{host}:{port}")
    return out or [None]


def make_session(proxy: str | None) -> requests.Session:
    session = requests.Session()
    session.headers.update({"User-Agent": USER_AGENT})
    if proxy:
        session.proxies = {"http": proxy, "https": proxy}
    return session


# Thread-local session: each worker thread sticks to one Tor instance so its
# circuit stays warm. requests.Session is not generally thread-safe but each
# thread uses its own, sequentially.
_tls = threading.local()
_session_counter = itertools.count()


def _get_session(proxies: list[str | None]) -> requests.Session:
    sess = getattr(_tls, "session", None)
    if sess is not None:
        return sess
    idx = next(_session_counter)
    proxy = proxies[idx % len(proxies)] if proxies else None
    sess = make_session(proxy)
    _tls.session = sess
    return sess


def download_one(
    session: requests.Session,
    url: str,
    dest: Path,
    *,
    rel: str,
    size: int,
    stats: Stats,
    history: History,
    retries: int = 3,
    timeout: int = 300,
    connect_timeout: int = 60,
    retry_all: bool = False,
    rate_limit_retries: int = 8,
) -> tuple[str, float, int]:
    """
    Download ``url`` to ``dest``. Returns ``(status, elapsed_seconds, bytes)``.

    ``status`` is one of: ``ok``, ``skip``, ``missing``, or ``error: ...``.

    Skips the file (returns ``skip``) only when its prior history entry is
    ``ok`` AND the file still exists on disk with non-zero size. Otherwise
    (error/404/never seen) the download is attempted again.
    """
    on_disk = dest.exists() and dest.stat().st_size > 0
    if not retry_all and on_disk and history.is_done(rel):
        existing = dest.stat().st_size
        stats.add_bytes(existing)
        history.record(rel, "ok", existing)  # refresh timestamp
        return "skip", 0.0, existing

    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    if part.exists():
        part.unlink()

    stats.file_started(rel, size)
    started = time.monotonic()
    last_error = ""
    bytes_received = 0
    net_attempt = 0      # network/transport errors (small budget: `retries`)
    rl_attempt = 0       # 429/503 rate-limit hits (larger budget: `rate_limit_retries`)
    try:
        while True:
            backoff = 0.0
            try:
                bytes_received = 0  # reset per attempt; previous .part is rewritten
                with session.get(url, stream=True, timeout=(connect_timeout, timeout)) as r:
                    if r.status_code == 404:
                        elapsed = time.monotonic() - started
                        history.record(rel, "missing", 0)
                        return "missing", elapsed, 0
                    if r.status_code in (429, 503):
                        # Server is overloaded / rate-limiting. This is transient,
                        # not a real failure — back off (honouring Retry-After)
                        # and keep trying on a generous budget.
                        rl_attempt += 1
                        last_error = f"HTTP {r.status_code} (rate-limited x{rl_attempt})"
                        if rl_attempt > rate_limit_retries:
                            break
                        ra = r.headers.get("Retry-After", "").strip()
                        if ra.isdigit():
                            backoff = min(float(ra), 60.0)
                        else:
                            backoff = min(3.0 * (2 ** min(rl_attempt - 1, 4)), 60.0)
                        backoff += random.uniform(0, max(1.0, backoff * 0.3))
                        time.sleep(backoff)
                        continue
                    r.raise_for_status()
                    with open(part, "wb") as f:
                        for chunk in r.iter_content(chunk_size=CHUNK_SIZE):
                            if chunk:
                                f.write(chunk)
                                stats.add_bytes(len(chunk), rel)
                                bytes_received += len(chunk)
                part.rename(dest)
                elapsed = time.monotonic() - started
                history.record(rel, "ok", bytes_received)
                return "ok", elapsed, bytes_received
            except requests.exceptions.RequestException as exc:
                last_error = f"{type(exc).__name__}: {exc}"[:120]
            except OSError as exc:
                last_error = f"OSError: {exc}"[:120]
            net_attempt += 1
            if net_attempt >= retries:
                break
            time.sleep(min(2 ** net_attempt, 30))
    finally:
        stats.file_finished(rel, error=last_error != "" and bytes_received == 0)

    if part.exists():
        part.unlink()
    elapsed = time.monotonic() - started
    history.record(rel, "error", bytes_received, last_error)
    return f"error: {last_error}", elapsed, bytes_received


# ---------------------------------------------------------------------------
# Persistent history: skip previously-completed files, retry everything else
# ---------------------------------------------------------------------------

class History:
    """JSON-backed per-file status log kept in the output directory.

    Only files whose previous status is ``ok`` (and still present on disk)
    are skipped on the next run. Errors and 404s are retried automatically.
    """

    FLUSH_EVERY_RECORDS = 200
    FLUSH_EVERY_SECONDS = 15.0

    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()
        self.data: dict[str, dict] = {}
        self.pending = 0
        self.last_flush = time.monotonic()
        if path.exists():
            try:
                self.data = json.loads(path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                self.data = {}

    def loaded_count(self) -> int:
        return len(self.data)

    def is_done(self, rel: str) -> bool:
        return self.data.get(rel, {}).get("status") == "ok"

    def record(self, rel: str, status: str, size: int = 0, error: str = "") -> None:
        with self.lock:
            self.data[rel] = {
                "status": status,
                "ts": datetime.now().isoformat(timespec="seconds"),
                "size": size,
                "error": error[:200] if error else "",
            }
            self.pending += 1
            if (self.pending >= self.FLUSH_EVERY_RECORDS or
                    time.monotonic() - self.last_flush >= self.FLUSH_EVERY_SECONDS):
                self._flush_locked()

    def flush(self) -> None:
        with self.lock:
            self._flush_locked()

    def _flush_locked(self) -> None:
        if not self.data and not self.pending:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(self.path.suffix + ".tmp")
            tmp.write_text(json.dumps(self.data, ensure_ascii=False), encoding="utf-8")
            tmp.replace(self.path)
            self.pending = 0
            self.last_flush = time.monotonic()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Live status reporter
# ---------------------------------------------------------------------------

class Reporter(threading.Thread):
    """Drives the live display through the Console.

    * TTY: redraw the pinned panel in place every ``interval`` seconds.
    * non-TTY: append a checkpoint box every ``milestone_interval`` seconds.
    """

    def __init__(
        self,
        stats: Stats,
        console: Console,
        interval: float = STATUS_INTERVAL_SEC,
        milestone_interval: float = MILESTONE_INTERVAL_SEC,
    ):
        super().__init__(daemon=True, name="status-reporter")
        self.stats = stats
        self.console = console
        self.interval = interval
        self.milestone_interval = milestone_interval
        self._stop = threading.Event()

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        next_milestone = 3.0
        next_sample = 3.0
        try:
            while not self._stop.wait(self.interval):
                elapsed = time.monotonic() - self.stats.start
                if elapsed >= next_sample:
                    self.stats.record_checkpoint_speed()
                    next_sample = elapsed + self.milestone_interval
                try:
                    if self.console.tty:
                        self.console.refresh()
                    elif elapsed >= next_milestone:
                        self.console.checkpoint_box()
                        next_milestone = elapsed + self.milestone_interval
                except Exception as e:
                    sys.stderr.write(f"[reporter] error: {e}\n")
                    sys.stderr.flush()
        except Exception as e:
            sys.stderr.write(f"[reporter] fatal: {e}\n")
            sys.stderr.flush()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--list", default="files.txt", type=Path)
    ap.add_argument("--out", default="download", type=Path)
    ap.add_argument("--tor", default="127.0.0.1:9050",
                    help="Tor SOCKS5 proxy as host:port, or empty string to disable")
    ap.add_argument("--workers", type=int, default=500,
                    help="Number of concurrent downloads (default: 500). "
                         "Pair with multiple Tor instances via --tor h1:p1,h2:p2 for max throughput.")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--filter", default="")
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--rate-limit-retries", type=int, default=8,
                    help="How many times to retry a 429/503 (server overloaded) "
                         "with exponential backoff before giving up. Default: 8")
    ap.add_argument("--timeout", type=int, default=300,
                    help="Read timeout per file in seconds")
    ap.add_argument("--connect-timeout", type=int, default=60,
                    help="Connect timeout in seconds. Fails fast when the onion is "
                         "unreachable instead of blocking the full read timeout.")
    ap.add_argument("--no-progress", action="store_true",
                    help="Disable the live status line (also auto-disabled when stderr is not a TTY)")
    ap.add_argument("--retry-all", action="store_true",
                    help="Ignore history: re-download every file even if previously OK")
    ap.add_argument("--no-history", action="store_true",
                    help="Don't persist or load .history.json (always retry everything except on-disk files)")
    ap.add_argument("--show-files", choices=["always", "sampled", "errors"], default="sampled",
                    help="Print per-file lines: 'always', 'sampled' (errors + >=1MiB + every Nth), "
                         "or 'errors' (errors only). Default: sampled.")
    ap.add_argument("--file-sample", type=int, default=50,
                    help="When --show-files=sampled, print one per-file line every N completions. Default: 50")
    ap.add_argument("--log", default="", type=str,
                    help="Append a plain-text (un-coloured) copy of all output to this file. "
                         "Lets the live panel own the terminal instead of being piped through tee.")
    args = ap.parse_args()

    if not args.list.exists():
        print(f"error: listing not found: {args.list}", file=sys.stderr)
        return 1

    files = list(parse_listing(args.list))
    if args.filter:
        needle = args.filter.lower()
        files = [(p, s) for p, s in files if needle in p.lower()]
    if args.limit:
        files = files[: args.limit]

    total_bytes = sum(s for _, s in files)
    total_files = len(files)
    started_wall = datetime.now()
    args.out.mkdir(parents=True, exist_ok=True)
    proxies = parse_proxies(args.tor or None)

    stats = Stats(total_bytes=total_bytes, total_files=total_files)

    logfile = None
    if args.log:
        try:
            logfile = open(args.log, "a", encoding="utf-8")
        except OSError as exc:
            print(f"warning: cannot open --log {args.log}: {exc}", file=sys.stderr)
    console = Console(stats, logfile=logfile)

    banner = (
        f"{cyan('╔══════════════════════════════════════════════════════════════════╗')}\n"
        f"{cyan('║')}                  {bold('threeam downloader')}                                {cyan('║')}\n"
        f"{cyan('╚══════════════════════════════════════════════════════════════════╝')}"
    )
    console.print_banner(banner)
    info_lines = [
        ("Files",       f"{total_files:,}"),
        ("Total size",  fmt_gib(total_bytes).strip()),
        ("Output",      str(args.out)),
        ("Workers",     str(args.workers)),
        ("Tor proxies", f"{len(proxies)} ({', '.join(p.split('://')[-1] for p in proxies if p) or 'direct'})"),
        ("Started",     started_wall.strftime("%Y-%m-%d %H:%M:%S")),
    ]
    label_w = max(len(k) for k, _ in info_lines)
    for k, v in info_lines:
        console.print_banner(f"  {grey(k + ':').ljust(label_w + 1)} {v}")

    history_path = args.out / ".history.json"
    history = History(history_path)
    if args.no_history:
        history.path.unlink(missing_ok=True)
        history.data.clear()
    loaded = history.loaded_count()
    console.print_banner(
        f"  history     : {grey(str(history_path))}  ({loaded:,} prior records)" if loaded else
        f"  history     : {grey(str(history_path))}  (new)")
    console.print_banner(
        f"{cyan('▶')} Starting {args.workers} workers across {len(proxies)} Tor instance(s)...   "
        f"{grey('Ctrl-C to pause; re-run to resume.')}")

    reporter = Reporter(stats, console)
    if not args.no_progress:
        reporter.start()

    counts: dict[str, int] = {"ok": 0, "skip": 0, "missing": 0, "error": 0}

    def task(rel: str, size: int) -> tuple[str, int, float, str, int]:
        session = _get_session(proxies)
        dest = args.out / rel.replace("\\", "/")
        status, elapsed, received = download_one(
            session, build_url(rel), dest,
            rel=rel, size=size, stats=stats, history=history,
            retries=args.retries, timeout=args.timeout,
            connect_timeout=args.connect_timeout,
            retry_all=args.retry_all,
            rate_limit_retries=args.rate_limit_retries,
        )
        return rel, size, elapsed, status, received

    try:
        with ThreadPoolExecutor(max_workers=max(1, args.workers)) as ex:
            futures = [ex.submit(task, rel, size) for rel, size in files]
            for i, fut in enumerate(as_completed(futures), 1):
                rel, size, elapsed, status, received = fut.result()
                bucket = status if status in counts else "error"
                counts[bucket] += 1

                if status == "ok":
                    icon = green("✓")
                    tag = green("OK  ")
                elif status == "skip":
                    icon = grey("⊘")
                    tag = grey("SKIP")
                elif status == "missing":
                    icon = yellow("⚠")
                    tag = yellow("404 ")
                else:
                    icon = red("✗")
                    tag = red("ERR ")

                if status == "ok" and size > 0:
                    speed_bps = received / elapsed if elapsed > 0 else 0
                    timing = f"{fmt_duration(elapsed):>5} {fmt_speed(speed_bps):>9}"
                elif status == "skip":
                    timing = grey("already present            ")
                elif status == "missing":
                    timing = grey("not on server              ")
                else:
                    detail = status.split(":", 1)[-1].strip()[:30]
                    timing = f"{elapsed:>4.0f}s {grey(detail):<29}"
                rel_display = rel.replace("\\", "/")
                if len(rel_display) > 80:
                    rel_display = "…" + rel_display[-79:]

                # Decide whether to print this line. With 2000+ workers files
                # complete so fast that per-file lines flood stdout and drown
                # the checkpoint summary. Default mode shows only:
                #   * every error / 404 / skip
                #   * files >= 1 MiB
                #   * every Nth small OK (sampled)
                # --show-files=always shows all, =none shows nothing.
                print_line = (
                    args.show_files == "always"
                    or status not in ("ok",)
                    or size >= 1_048_576
                    or (args.show_files == "sampled" and i % args.file_sample == 0)
                )
                if print_line:
                    console.log(
                        f"  {icon} [{i:>6}/{total_files}]  {tag}  "
                        f"{size:>12,}  {timing}   {rel_display}")
    finally:
        reporter.stop()
        if reporter.is_alive():
            reporter.join(timeout=2)
        console.close()
        if not args.no_history:
            history.flush()

    elapsed_total = time.monotonic() - stats.start
    finished_wall = datetime.now()
    w = 70
    out = console.print_banner
    out("")
    out(cyan("═" * w))
    out(cyan("  ") + bold("COMPLETED" if counts["error"] == 0 else "FINISHED WITH ERRORS"))
    out(cyan("═" * w))
    summary_rows = [
        (green("✓ ok"),      counts["ok"]),
        (grey("⊘ skipped"), counts["skip"]),
        (yellow("⚠ 404"),     counts["missing"]),
        (red("✗ errors"),  counts["error"]),
    ]
    for label, count in summary_rows:
        out(f"  {label:<14}  {count:>9,}")
    out("")
    metric_rows = [
        ("Total",        fmt_gib(stats.downloaded).strip()),
        ("Avg speed",    f"{fmt_speed(stats.lifetime_speed)}"),
        ("Wall time",    fmt_duration(elapsed_total)),
        ("Started",      started_wall.strftime("%Y-%m-%d %H:%M:%S")),
        ("Finished",     finished_wall.strftime("%Y-%m-%d %H:%M:%S")),
    ]
    label_w = max(len(k) for k, _ in metric_rows)
    for k, v in metric_rows:
        out(f"  {grey((k + ':')).ljust(label_w + 1)} {v}")
    if not args.no_history:
        out(f"  {grey('History:').ljust(label_w + 1)} {grey(str(history.path))}  ({len(history.data):,} records)")
    out(cyan("─" * w))
    if logfile:
        logfile.close()
    return 0 if counts["error"] == 0 else 2


if __name__ == "__main__":
    sys.exit(main())