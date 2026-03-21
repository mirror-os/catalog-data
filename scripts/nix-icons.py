#!/usr/bin/env python3
"""
nix-icons.py — Extract icons from nixpkgs packages for the Mirror OS catalog.

Uses the nix-index-database (prebuilt weekly index of all files in nixpkgs) to
discover which packages contain icon files, then downloads those packages' NARs
from cache.nixos.org and extracts the icons — the exact same icons that ship
with the package when installed.

First run: slow (downloads nix-index DB + many NARs).
Subsequent runs: fast — only packages whose store hash has changed are re-processed.

Usage:
    nix-shell -p nix-index --run "python3 scripts/nix-icons.py"
    nix-shell -p nix-index --run "python3 scripts/nix-icons.py --refresh"
    nix-shell -p nix-index --run "python3 scripts/nix-icons.py --db /path/to/catalog.db"

Options:
    --refresh           Force re-download of nix-index DB even if fresh
    --db PATH           Path to catalog.db (default: ~/.local/share/mirror-os/catalog.db)
    --media-dir PATH    Media directory (default: ~/.local/share/mirror-os/media)
    --max-nar-size N    Skip NARs larger than N bytes (default: 50MB)
    --retry-large       Retry packages previously skipped for being too large
"""

import sys, os, json, sqlite3, time, struct, lzma, shutil
import urllib.request, urllib.error
from pathlib import Path
from datetime import datetime, timezone

# ── Defaults ──────────────────────────────────────────────────────────────────

DEFAULT_CATALOG_DB   = Path.home() / ".local/share/mirror-os/catalog.db"
DEFAULT_MEDIA_DIR    = Path.home() / ".local/share/mirror-os/media"
NIX_INDEX_DB_URL     = "https://github.com/nix-community/nix-index-database/releases/latest/download/index-x86_64-linux"
BINARY_CACHE         = "https://cache.nixos.org"
MAX_NAR_SIZE_DEFAULT = 50 * 1024 * 1024  # 50 MB
NIX_INDEX_MAX_AGE    = 7 * 24 * 3600     # 7 days
UA                   = "mirror-os-nix-icons/1.0"

# ── Argument parsing ──────────────────────────────────────────────────────────

def parse_args():
    import argparse
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--refresh",       action="store_true",                     help="Force re-download of nix-index DB")
    p.add_argument("--db",            type=Path, default=DEFAULT_CATALOG_DB,   help="Path to catalog.db")
    p.add_argument("--media-dir",     type=Path, default=DEFAULT_MEDIA_DIR,    help="Media directory")
    p.add_argument("--max-nar-size",  type=int,  default=MAX_NAR_SIZE_DEFAULT, help="Max NAR size in bytes")
    p.add_argument("--retry-large",   action="store_true",                     help="Retry packages skipped for being too large")
    return p.parse_args()

# ── HTTP helpers ──────────────────────────────────────────────────────────────

def http_get(url: str, timeout: int = 30) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()

def http_get_stream(url: str, timeout: int = 60):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    return urllib.request.urlopen(req, timeout=timeout)

# ── nix-index database ────────────────────────────────────────────────────────

def ensure_nix_index_db(cache_dir: Path, refresh: bool) -> Path:
    """
    Download the prebuilt nix-index-database if missing or older than 7 days.
    The file must be saved as 'files' inside cache_dir for nix-locate to find it.
    Returns cache_dir (the value to set as NIX_INDEX_DATABASE).
    """
    db_file = cache_dir / "files"
    cache_dir.mkdir(parents=True, exist_ok=True)

    if db_file.exists() and not refresh:
        age = time.time() - db_file.stat().st_mtime
        if age < NIX_INDEX_MAX_AGE:
            print(f"nix-index DB: using cached ({age/3600:.0f}h old, {db_file.stat().st_size/1e6:.0f} MB)", flush=True)
            return cache_dir

    print("Downloading nix-index-database from GitHub releases...", flush=True)
    tmp = db_file.with_suffix(".tmp")
    try:
        req = urllib.request.Request(NIX_INDEX_DB_URL, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=300) as r:
            total = int(r.headers.get("Content-Length", 0))
            downloaded = 0
            with open(tmp, "wb") as f:
                while True:
                    chunk = r.read(65536)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)
                    if total:
                        print(f"\r  {downloaded/1e6:.0f} / {total/1e6:.0f} MB ({downloaded/total*100:.0f}%)",
                              end="", flush=True)
        print()
        tmp.rename(db_file)
        print(f"nix-index DB saved: {db_file.stat().st_size/1e6:.0f} MB", flush=True)
    except Exception as e:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"Failed to download nix-index DB: {e}") from e

    return cache_dir

# ── nix-locate ────────────────────────────────────────────────────────────────

_STRIP_OUTPUTS = {"out", "lib", "dev", "man", "doc", "info", "locale", "headers", "static", "debug"}

def normalize_attr(raw: str) -> str:
    """Strip output suffix: hello.out → hello, firefox.man → skip → returns ''."""
    if "." not in raw:
        return raw
    base, suffix = raw.rsplit(".", 1)
    if suffix in _STRIP_OUTPUTS:
        if suffix == "out":
            return base   # .out is the main output → keep
        return ""         # .dev .man etc. → not useful for icons → skip
    return raw            # e.g. "python3.11" — no suffix stripping

def query_icon_packages(db_dir: Path) -> dict:
    """
    Run nix-locate for icon paths. Returns:
      {attr: (full_store_path, rel_icon_path, store_hash, is_png)}

    Priority: 128x128 PNG > scalable PNG > pixmaps PNG > scalable SVG (skipped).
    """
    import subprocess

    env = os.environ.copy()
    env["NIX_INDEX_DATABASE"] = str(db_dir)

    # (abs_path_prefix, priority): lower priority number = preferred
    # --at-root: match files whose path starts with prefix (from package root)
    # --no-group: show every matching file, not just one representative per package
    queries = [
        ("/share/icons/hicolor/128x128/apps",   0),
        ("/share/icons/hicolor/256x256/apps",   1),
        ("/share/icons/hicolor/512x512/apps",   1),
        ("/share/icons/hicolor/scalable/apps",  2),
        ("/share/pixmaps",                      3),
    ]

    # attr → (store_path, rel_path, store_hash, priority, is_png)
    results: dict = {}

    for pattern, prio in queries:
        print(f"  nix-locate '{pattern}'...", end=" ", flush=True)
        try:
            r = subprocess.run(
                ["nix-locate", "--at-root", pattern, "-t", "r", "--no-group"],
                env=env, capture_output=True, text=True, timeout=300,
            )
        except FileNotFoundError:
            raise RuntimeError(
                "nix-locate not found — run this script inside:\n"
                "  nix-shell -p nix-index --run 'python3 scripts/nix-icons.py'"
            )
        if r.returncode != 0 and not r.stdout.strip():
            print(f"warning (exit {r.returncode}): {r.stderr[:120]}", flush=True)
            continue

        n = 0
        for line in r.stdout.splitlines():
            parts = line.split()
            # format: attr  size  type  /nix/store/HASH-name-version/rel/path
            if len(parts) < 4:
                continue
            raw_attr  = parts[0]
            full_path = parts[-1]
            if not full_path.startswith("/nix/store/"):
                continue

            # only PNG (and SVG as last resort, handled later)
            is_png = full_path.endswith(".png")
            is_svg = full_path.endswith(".svg")
            if not (is_png or is_svg):
                continue

            attr = normalize_attr(raw_attr)
            if not attr:
                continue

            # extract store entry and relative path
            after_store = full_path[len("/nix/store/"):]
            slash = after_store.find("/")
            if slash < 0:
                continue
            store_entry = after_store[:slash]          # HASH-name-version
            rel_path    = after_store[slash + 1:]      # share/icons/.../name.png
            store_hash  = store_entry.split("-")[0]    # HASH (base32)

            existing = results.get(attr)
            better = (
                existing is None
                or prio < existing[3]
                or (prio == existing[3] and is_png and not existing[4])
            )
            if better:
                results[attr] = (f"/nix/store/{store_entry}", rel_path, store_hash, prio, is_png)
                n += 1

        print(f"{n} new entries", flush=True)

    # drop SVGs (no conversion dependency)
    png_results = {a: v for a, v in results.items() if v[4]}
    print(f"Total icon candidates (PNG only): {len(png_results)}", flush=True)
    return png_results

# ── Match to catalog ──────────────────────────────────────────────────────────

def match_to_catalog(candidates: dict, db_path: Path) -> dict:
    """Keep only attrs present in nix_packages. Returns filtered candidates dict."""
    conn = sqlite3.connect(str(db_path))
    known = {row[0] for row in conn.execute("SELECT attr FROM nix_packages")}
    conn.close()

    matched = {a: v for a, v in candidates.items() if a in known}
    print(f"Matched {len(matched)}/{len(candidates)} candidates to catalog attrs", flush=True)
    return matched

# ── Incremental state ─────────────────────────────────────────────────────────

def load_state(path: Path) -> dict:
    if path.exists():
        try:
            return json.loads(path.read_text())
        except Exception:
            pass
    return {}

def save_state(path: Path, state: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, separators=(",", ":")))

# ── Tier 0: local nix store ───────────────────────────────────────────────────

def scan_local_store(matched: dict, icons_dir: Path) -> set:
    """Copy icons directly from already-present nix store paths. Returns resolved attrs."""
    resolved = set()
    for attr, (store_path, rel_path, store_hash, prio, is_png) in matched.items():
        full = Path(store_path) / rel_path
        if full.is_file() and full.stat().st_size > 0 and is_png:
            dst = icons_dir / f"{attr}.png"
            try:
                shutil.copy2(full, dst)
                resolved.add(attr)
            except OSError:
                pass
    if resolved:
        print(f"Tier 0 (local nix store): {len(resolved)} icons copied", flush=True)
    return resolved

# ── narinfo ───────────────────────────────────────────────────────────────────

def fetch_narinfo(store_hash: str) -> dict | None:
    """Fetch and parse cache.nixos.org/{hash}.narinfo. Returns None if missing."""
    try:
        text = http_get(f"{BINARY_CACHE}/{store_hash}.narinfo", timeout=15).decode()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        return None
    except Exception:
        return None

    info = {}
    for line in text.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            info[k.strip()] = v.strip()
    return info

# ── NAR stream parser ─────────────────────────────────────────────────────────

class _NarFound(Exception):
    """Raised when the target file is found in the NAR."""
    def __init__(self, data: bytes):
        self.data = data


def _nar_read_str(f) -> bytes:
    """Read a NAR length-prefixed string (uint64-LE length + data + 8-byte padding)."""
    raw = f.read(8)
    if len(raw) < 8:
        raise EOFError("NAR: truncated length field")
    length = struct.unpack_from("<Q", raw)[0]
    data = f.read(length)
    if len(data) < length:
        raise EOFError("NAR: truncated data field")
    pad = (8 - length % 8) % 8
    if pad:
        f.read(pad)
    return data


def _nar_skip_bytes(f, size: int):
    """Skip `size` bytes of file content plus padding to 8-byte boundary."""
    padded = size + (8 - size % 8) % 8
    remaining = padded
    while remaining > 0:
        chunk = f.read(min(65536, remaining))
        if not chunk:
            raise EOFError("NAR: unexpected EOF while skipping")
        remaining -= len(chunk)


def _nar_node(f, current_path: str, target: str):
    """
    Recursively walk a NAR node. Raises _NarFound(data) when target file is reached.
    current_path: path built so far (e.g. "/share/icons/hicolor/128x128/apps")
    target:       expected path of the icon (e.g. "/share/icons/.../htop.png")
    """
    tag = _nar_read_str(f)
    if tag != b"(":
        raise ValueError(f"NAR: expected '(' at '{current_path}', got {tag!r}")

    while True:
        field = _nar_read_str(f)

        if field == b")":
            return

        elif field == b"type":
            node_type = _nar_read_str(f).decode()

            if node_type == "regular":
                while True:
                    sub = _nar_read_str(f)
                    if sub == b")":
                        return
                    elif sub == b"executable":
                        _nar_read_str(f)  # always empty string ""
                    elif sub == b"contents":
                        raw_len = f.read(8)
                        if len(raw_len) < 8:
                            raise EOFError("NAR: truncated contents length")
                        size = struct.unpack_from("<Q", raw_len)[0]
                        if current_path == target:
                            data = f.read(size)
                            raise _NarFound(data)
                        else:
                            _nar_skip_bytes(f, size)
                    else:
                        raise ValueError(f"NAR: unexpected field {sub!r} in regular node at '{current_path}'")

            elif node_type == "directory":
                while True:
                    sub = _nar_read_str(f)
                    if sub == b")":
                        return
                    elif sub == b"entry":
                        open_paren = _nar_read_str(f)
                        if open_paren != b"(":
                            raise ValueError("NAR: expected '(' after 'entry'")
                        entry_name = None
                        while True:
                            ef = _nar_read_str(f)
                            if ef == b")":
                                break
                            elif ef == b"name":
                                entry_name = _nar_read_str(f).decode()
                            elif ef == b"node":
                                child_path = f"{current_path}/{entry_name}" if entry_name else current_path
                                _nar_node(f, child_path, target)
                            else:
                                raise ValueError(f"NAR: unexpected entry field {ef!r}")
                    else:
                        raise ValueError(f"NAR: unexpected directory field {sub!r}")

            elif node_type == "symlink":
                while True:
                    sub = _nar_read_str(f)
                    if sub == b")":
                        return
                    elif sub == b"target":
                        _nar_read_str(f)  # skip target string
                    else:
                        raise ValueError(f"NAR: unexpected symlink field {sub!r}")

            else:
                raise ValueError(f"NAR: unknown node type {node_type!r}")

        else:
            raise ValueError(f"NAR: unexpected top-level field {field!r} at '{current_path}'")


def extract_from_nar_stream(stream, target_path: str) -> bytes | None:
    """
    Stream-parse a decompressed NAR and return the bytes of target_path if found.
    target_path should start with '/' e.g. '/share/icons/hicolor/128x128/apps/htop.png'
    Returns None if the file is not present in the NAR.
    """
    magic = _nar_read_str(stream)
    if magic != b"nix-archive-1":
        raise ValueError(f"NAR: bad magic {magic!r}")
    try:
        _nar_node(stream, "", target_path)
    except _NarFound as e:
        return e.data
    return None

# ── Download NAR and extract icon ─────────────────────────────────────────────

def get_icon_from_nar(nar_url: str, compression: str, rel_path: str) -> bytes | None:
    """
    Download a NAR from cache.nixos.org and extract the icon at rel_path.
    Returns PNG bytes or None.
    """
    full_url = f"{BINARY_CACHE}/{nar_url}"
    target   = f"/{rel_path}"  # NAR paths start with "/"

    try:
        r = http_get_stream(full_url, timeout=120)

        comp = compression.lower()
        if comp in ("xz", ""):
            stream = lzma.open(r)
        else:
            # zstd / gzip / bzip2 — uncommon on cache.nixos.org; skip gracefully
            r.close()
            return None

        return extract_from_nar_stream(stream, target)

    except _NarFound as e:
        return e.data
    except Exception:
        return None

# ── DB helpers ────────────────────────────────────────────────────────────────

def ensure_icon_column(conn: sqlite3.Connection):
    """Add icon_local_path column to nix_packages if not present."""
    try:
        conn.execute("ALTER TABLE nix_packages ADD COLUMN icon_local_path TEXT NOT NULL DEFAULT ''")
        conn.commit()
    except sqlite3.OperationalError:
        pass  # column already exists

def flush_db_updates(conn: sqlite3.Connection, updates: list):
    if updates:
        with conn:
            conn.executemany("UPDATE nix_packages SET icon_local_path=? WHERE attr=?", updates)
        updates.clear()

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    args = parse_args()

    db_path   = args.db
    media_dir = args.media_dir
    cache_dir = media_dir / ".nix-icon-cache"
    icons_dir = media_dir / "icons"
    state_file = cache_dir / "state.json"

    icons_dir.mkdir(parents=True, exist_ok=True)
    cache_dir.mkdir(parents=True, exist_ok=True)

    if not db_path.exists():
        print(f"ERROR: catalog.db not found at {db_path}", file=sys.stderr)
        print("Hint: run build-local.sh --source nix first", file=sys.stderr)
        sys.exit(1)

    print("=== Mirror OS nix-icons ===", flush=True)
    print(f"  catalog.db : {db_path}", flush=True)
    print(f"  icons dir  : {icons_dir}", flush=True)
    print(f"  cache dir  : {cache_dir}", flush=True)
    print(f"  max NAR    : {args.max_nar_size // 1024 // 1024} MB", flush=True)
    print()

    # ── Step 1: nix-index DB ──────────────────────────────────────────────────
    print("Step 1: nix-index database", flush=True)
    nix_db_dir = ensure_nix_index_db(cache_dir, args.refresh)
    print()

    # ── Step 2: query ─────────────────────────────────────────────────────────
    print("Step 2: querying nix-locate for icon-bearing packages", flush=True)
    candidates = query_icon_packages(nix_db_dir)
    print()

    if not candidates:
        print("No icon candidates found. Ensure nix-index DB is fresh (--refresh).")
        return

    # ── Step 3: filter to catalog attrs ───────────────────────────────────────
    print("Step 3: matching candidates to catalog", flush=True)
    matched = match_to_catalog(candidates, db_path)
    print()

    if not matched:
        print("No candidates matched catalog attrs. Exiting.")
        return

    # ── Step 4: state ─────────────────────────────────────────────────────────
    state = load_state(state_file)

    # ── Step 5: Tier 0 — local nix store (zero network) ──────────────────────
    print("Step 4 (Tier 0): scanning local nix store...", flush=True)
    resolved = scan_local_store(matched, icons_dir)
    for attr in resolved:
        state[attr] = {"store_hash": matched[attr][2], "done": True, "source": "local_store"}
    save_state(state_file, state)
    print()

    # ── Step 6: Tier 1 — NAR download for remaining ──────────────────────────
    todo: dict = {}
    for attr, v in matched.items():
        if attr in resolved:
            continue
        store_hash = v[2]
        s = state.get(attr, {})
        if s.get("done") and s.get("store_hash") == store_hash:
            continue  # already done, same version
        if not s.get("done") and s.get("reason") == "too_large" and s.get("store_hash") == store_hash:
            if not args.retry_large:
                continue  # skip unless --retry-large
        todo[attr] = v

    # also update icon_local_path in DB for already-done packages (in case DB was reset)
    conn = sqlite3.connect(str(db_path), timeout=30)
    ensure_icon_column(conn)
    existing_db = {
        row[0]: row[1]
        for row in conn.execute("SELECT attr, icon_local_path FROM nix_packages WHERE icon_local_path != ''")
    }

    print(f"Step 5 (Tier 1): NAR download — {len(todo)} packages to process", flush=True)
    if not todo:
        print("  All packages already up to date.", flush=True)

    db_updates = []
    skipped_large   = 0
    skipped_missing = 0
    fetched         = 0
    failed          = 0
    already_done    = 0

    t_start = time.monotonic()
    todo_list = sorted(todo.items())
    total = len(todo_list)

    for i, (attr, (store_path, rel_path, store_hash, prio, is_png)) in enumerate(todo_list, 1):
        # progress line every 50 or on first few
        if i == 1 or i % 50 == 0:
            elapsed = time.monotonic() - t_start
            if i > 1 and elapsed > 0:
                rate = i / elapsed
                eta  = (total - i) / rate
                print(f"  [{i}/{total}] {elapsed/60:.0f}m elapsed, ETA {eta/60:.0f}m", flush=True)
            else:
                print(f"  [{i}/{total}]", flush=True)

        dst = icons_dir / f"{attr}.png"

        # already have icon on disk + same hash → just update DB if needed
        if dst.exists() and dst.stat().st_size > 0:
            s = state.get(attr, {})
            if s.get("store_hash") == store_hash:
                if attr not in existing_db:
                    db_updates.append((str(dst), attr))
                state[attr] = {"store_hash": store_hash, "done": True, "source": s.get("source", "nar")}
                already_done += 1
                continue

        # fetch narinfo
        narinfo = fetch_narinfo(store_hash)
        if not narinfo:
            skipped_missing += 1
            state[attr] = {"store_hash": store_hash, "done": False, "reason": "not_in_cache"}
            continue

        nar_size = int(narinfo.get("NarSize", narinfo.get("FileSize", "0")))
        if nar_size > args.max_nar_size:
            skipped_large += 1
            state[attr] = {"store_hash": store_hash, "done": False, "reason": "too_large",
                           "nar_size": nar_size}
            continue

        nar_url     = narinfo.get("URL", "")
        compression = narinfo.get("Compression", "xz")
        if not nar_url:
            state[attr] = {"store_hash": store_hash, "done": False, "reason": "no_url"}
            continue

        # download NAR and extract icon
        icon_data = get_icon_from_nar(nar_url, compression, rel_path)

        if icon_data and len(icon_data) > 100:  # sanity: >100 bytes
            dst.write_bytes(icon_data)
            db_updates.append((str(dst), attr))
            state[attr] = {"store_hash": store_hash, "done": True, "source": "nar"}
            fetched += 1
        else:
            failed += 1
            state[attr] = {"store_hash": store_hash, "done": False, "reason": "not_found_in_nar"}

        # periodic saves every 100 packages
        if i % 100 == 0:
            flush_db_updates(conn, db_updates)
            save_state(state_file, state)

    # ── Final writes ──────────────────────────────────────────────────────────
    flush_db_updates(conn, db_updates)
    save_state(state_file, state)

    # also sync Tier 0 icons to DB (store scan results)
    tier0_updates = [
        (str(icons_dir / f"{attr}.png"), attr)
        for attr in resolved
        if attr not in existing_db
        and (icons_dir / f"{attr}.png").exists()
    ]
    if tier0_updates:
        with conn:
            conn.executemany("UPDATE nix_packages SET icon_local_path=? WHERE attr=?", tier0_updates)

    # update catalog_meta
    total_with_icons = conn.execute(
        "SELECT count(*) FROM nix_packages WHERE icon_local_path != ''"
    ).fetchone()[0]
    now = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with conn:
        conn.execute(
            "INSERT OR REPLACE INTO catalog_meta(source,updated_at,row_count) VALUES ('nix-icons',?,?)",
            (now, total_with_icons),
        )
    conn.close()

    # ── Summary ───────────────────────────────────────────────────────────────
    elapsed_total = time.monotonic() - t_start
    print(f"\n=== Done in {elapsed_total/60:.1f} min ===", flush=True)
    print(f"  Local store  : {len(resolved)}", flush=True)
    print(f"  NAR download : {fetched}", flush=True)
    print(f"  Already done : {already_done}", flush=True)
    print(f"  Skipped (>NAR limit)   : {skipped_large}", flush=True)
    print(f"  Skipped (not in cache) : {skipped_missing}", flush=True)
    print(f"  Not found in NAR       : {failed}", flush=True)
    print(f"  Total nix icons in DB  : {total_with_icons}", flush=True)


if __name__ == "__main__":
    main()
