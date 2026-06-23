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
MILESTONE_INTERVAL_SEC = 30.0
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
        self.downloaded = 0
        self.lock = threading.Lock()
        self.window: collections.deque[tuple[float, int]] = collections.deque()
        self.start = time.monotonic()
        self._last_status_len = 0

    def add_bytes(self, n: int) -> None:
        now = time.monotonic()
        with self.lock:
            self.downloaded += n
            self.window.append((now, n))
            cutoff = now - SPEED_WINDOW_SEC
            while self.window and self.window[0][0] < cutoff:
                self.window.popleft()

    def file_started(self) -> None:
        with self.lock:
            self.active_files += 1

    def file_finished(self, *, error: bool) -> None:
        with self.lock:
            self.active_files = max(0, self.active_files - 1)
            self.completed_files += 1
            if error:
                self.error_files += 1

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
        """Short status line for live TTY updates."""
        elapsed = time.monotonic() - self.start
        pct = 100.0 * self.downloaded / self.total_bytes if self.total_bytes else 0.0
        speed = self.rolling_speed or self.lifetime_speed
        return (
            f"[{render_bar(pct)}] {pct:5.2f}%  "
            f"{fmt_gib(self.downloaded)} / {fmt_gib(self.total_bytes)}  "
            f"| {fmt_speed(speed)}  "
            f"| ETA {fmt_duration(self.eta_seconds)}  "
            f"| finish {fmt_clock(self.eta_seconds)}  "
            f"| {self.completed_files:,}/{self.total_files:,} files  "
            f"| active {self.active_files}  "
            f"| err {self.error_files}  "
            f"| {fmt_duration(elapsed)}"
        )

    def render_milestone(self) -> str:
        """Multi-line checkpoint written to stdout (captured in tee'd logs)."""
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
        clock_now = datetime.now().strftime("%H:%M:%S")
        return (
            f"[{clock_now}] {bold('checkpoint')} "
            f"[{render_bar(pct)}] {pct:5.2f}%\n"
            f"        downloaded : {fmt_gib(self.downloaded)} of {fmt_gib(self.total_bytes)} "
            f"({fmt_gib(remaining)} left)\n"
            f"        files      : {done:,} done / {self.total_files:,} total "
            f"(active {active}, errors {errors})\n"
            f"        speed      : {fmt_speed(rolling)} rolling  |  "
            f"{fmt_speed(speed)} avg since start\n"
            f"        time       : elapsed {fmt_duration(elapsed)}  |  "
            f"ETA {fmt_duration(eta)}  |  finish {fmt_clock(eta)}"
        )


# ---------------------------------------------------------------------------
# Downloading
# ---------------------------------------------------------------------------

def make_session(tor: str | None) -> requests.Session:
    session = requests.Session()
    session.headers.update({"User-Agent": USER_AGENT})
    if tor:
        host, _, port = tor.partition(":")
        if not port:
            port = "9050"
        proxy = f"socks5h://{host}:{port}"
        session.proxies = {"http": proxy, "https": proxy}
    return session


def download_one(
    session: requests.Session,
    url: str,
    dest: Path,
    *,
    stats: Stats,
    retries: int = 3,
    timeout: int = 300,
) -> tuple[str, float, int]:
    """
    Download ``url`` to ``dest``. Returns ``(status, elapsed_seconds, bytes)``.

    ``status`` is one of: ``ok``, ``skip``, ``missing``, or ``error: ...``.
    """
    if dest.exists() and dest.stat().st_size > 0:
        existing = dest.stat().st_size
        stats.add_bytes(existing)
        return "skip", 0.0, existing

    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    if part.exists():
        part.unlink()

    stats.file_started()
    started = time.monotonic()
    last_error = ""
    bytes_received = 0
    try:
        for attempt in range(1, retries + 1):
            try:
                with session.get(url, stream=True, timeout=timeout) as r:
                    if r.status_code == 404:
                        return "missing", time.monotonic() - started, 0
                    r.raise_for_status()
                    with open(part, "wb") as f:
                        for chunk in r.iter_content(chunk_size=CHUNK_SIZE):
                            if chunk:
                                f.write(chunk)
                                stats.add_bytes(len(chunk))
                                bytes_received += len(chunk)
                part.rename(dest)
                return "ok", time.monotonic() - started, bytes_received
            except requests.exceptions.RequestException as exc:
                last_error = f"{type(exc).__name__}: {exc}"[:120]
            except OSError as exc:
                last_error = f"OSError: {exc}"[:120]
            time.sleep(min(2 ** attempt, 30))
    finally:
        stats.file_finished(error=not last_error == "" and bytes_received == 0)

    if part.exists():
        part.unlink()
    return f"error: {last_error}", time.monotonic() - started, bytes_received


# ---------------------------------------------------------------------------
# Live status reporter
# ---------------------------------------------------------------------------

class Reporter(threading.Thread):
    """Two outputs:

    * Every STATUS_INTERVAL_SEC: rewrite a one-line status on stderr (if TTY).
    * Every MILESTONE_INTERVAL_SEC: append a multi-line checkpoint to stdout
      so it shows up in `tee`'d log files even when stderr isn't a terminal.
    """

    def __init__(
        self,
        stats: Stats,
        interval: float = STATUS_INTERVAL_SEC,
        milestone_interval: float = MILESTONE_INTERVAL_SEC,
    ):
        super().__init__(daemon=True, name="status-reporter")
        self.stats = stats
        self.interval = interval
        self.milestone_interval = milestone_interval
        self._stop = threading.Event()
        self._stderr_tty = sys.stderr.isatty()
        self._last_milestone = 0.0

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        next_milestone = self.milestone_interval
        while not self._stop.wait(self.interval):
            elapsed = time.monotonic() - self.stats.start
            if elapsed >= next_milestone:
                sys.stdout.write("\n" + self.stats.render_milestone() + "\n")
                sys.stdout.flush()
                next_milestone = elapsed + self.milestone_interval
            if self._stderr_tty:
                line = self.stats.render_status_line()
                sys.stderr.write("\r" + line + "\033[K")
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
    ap.add_argument("--workers", type=int, default=10,
                    help="Number of concurrent downloads (default: 10)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--filter", default="")
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--no-progress", action="store_true",
                    help="Disable the live status line (also auto-disabled when stderr is not a TTY)")
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
    print(
        f"{bold('Planning')} {total_files:,} downloads "
        f"({fmt_gib(total_bytes)}) into {cyan(args.out)}",
        flush=True,
    )
    print(f"  workers : {args.workers}   tor : {args.tor}   started : {started_wall:%Y-%m-%d %H:%M:%S}",
          flush=True)
    print(flush=True)

    args.out.mkdir(parents=True, exist_ok=True)
    session = make_session(args.tor or None)
    stats = Stats(total_bytes=total_bytes, total_files=total_files)

    reporter = Reporter(stats)
    if not args.no_progress:
        reporter.start()

    counts: dict[str, int] = {"ok": 0, "skip": 0, "missing": 0, "error": 0}

    def task(rel: str, size: int) -> tuple[str, int, float, str, int]:
        dest = args.out / rel.replace("\\", "/")
        status, elapsed, received = download_one(
            session, build_url(rel), dest,
            stats=stats, retries=args.retries, timeout=args.timeout,
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
                    tag = green("OK  ")
                elif status == "skip":
                    tag = grey("SKIP")
                elif status == "missing":
                    tag = yellow("404 ")
                else:
                    tag = red("ERR ")

                if status == "ok" and size > 0:
                    speed_bps = received / elapsed if elapsed > 0 else 0
                    timing = f"in {fmt_duration(elapsed):>5} ({fmt_speed(speed_bps)})"
                elif status == "skip":
                    timing = grey("already present     ")
                else:
                    timing = f"{elapsed:>5.1f}s              "
                print(
                    f"[{i:>6}/{total_files}] {tag} {size:>14,}  {timing}  {rel}",
                    flush=True,
                )
    finally:
        reporter.stop()
        if reporter.is_alive():
            reporter.join(timeout=2)
        if reporter._stderr_tty:
            sys.stderr.write("\n")
            sys.stderr.flush()

    elapsed_total = time.monotonic() - stats.start
    print()
    print(bold("─── Summary ───────────────────────────────────────────────"))
    print(f"  {green('ok'):>10}: {counts['ok']:>9,}")
    print(f"  {grey('skip'):>10}: {counts['skip']:>9,}")
    print(f"  {yellow('404'):>10}: {counts['missing']:>9,}")
    print(f"  {red('error'):>10}: {counts['error']:>9,}")
    print(f"  {'bytes':>10}: {fmt_gib(stats.downloaded).strip()} "
          f"({fmt_speed(stats.lifetime_speed)} avg over {fmt_duration(elapsed_total)})")
    print(f"  {'started':>10}: {started_wall:%Y-%m-%d %H:%M:%S}")
    print(f"  {'finished':>10}: {datetime.now():%Y-%m-%d %H:%M:%S}")
    print(f"  {'wall time':>10}: {fmt_duration(elapsed_total)}")
    print("──────────────────────────────────────────────────────────")
    return 0 if counts["error"] == 0 else 2


if __name__ == "__main__":
    sys.exit(main())