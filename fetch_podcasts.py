#!/usr/bin/env python3
"""
fetch_podcasts.py - Podcast subscription management and episode fetching
for the liquidsoap radio automation stack.

All data (podcasts, state DBs, logs, playlists) lives under the storage path
defined in config.json ("storage" key), keeping the boot drive clean.

Concurrency model:
  - An exclusive, non-blocking lockfile (state/fetch.lock) guarantees this
    process and update_playlists.py never touch the databases simultaneously.
    If the updater holds the lock, this run logs a skip and exits 0.
  - Both databases run in WAL mode with a busy timeout as a second safety net.

Filters out video podcasts: only shows whose latest enclosure has an
audio/* MIME type are registered.

Archived shows (archived=1) have episodes downloaded to disk; non-archived
shows (archived=0) store only the enclosure URL for live streaming.
"""

import argparse
import fcntl
import json
import logging
import os
import re
import shutil
import socket
import sqlite3
import sys
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import quote

# Force IPv4 resolution so we don't stall on AAAA-first lookups when the box
# has no usable IPv6 route (gpodder.net publishes both A and AAAA records).
try:
    import requests.packages.urllib3.util.connection as _urllib3_conn
    _urllib3_conn.HAS_IPV6 = False
except Exception:
    pass

import feedparser
import requests

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "config.json"

AUDIO_EXTS = {".mp3", ".m4a"}
VIDEO_EXTS = {".mp4", ".mov", ".avi", ".webm", ".mkv"}

STATE_DIR = None
SUBS_DB = None
PLAYED_DB = None
PODCASTS_DIR = None
LOGS_DIR = None
PLAYLISTS_DIR = None
LOCK_FILE = None

def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)

def init_paths():
    """Resolve all data paths from config.json storage key."""
    global STATE_DIR, SUBS_DB, PLAYED_DB, PODCASTS_DIR, LOGS_DIR, PLAYLISTS_DIR, LOCK_FILE
    cfg = load_config()
    storage = Path(cfg["storage"]).expanduser().resolve()
    STATE_DIR = storage / "state"
    SUBS_DB = STATE_DIR / "subscriptions.db"
    PLAYED_DB = STATE_DIR / "played.db"
    PODCASTS_DIR = storage / "podcasts"
    LOGS_DIR = storage / "logs"
    PLAYLISTS_DIR = storage / "playlists"
    LOCK_FILE = STATE_DIR / "radio.lock"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("fetch_podcasts")

def log_error(msg):
    log.error(msg)

def _setup_logging():
    """Add file handler once LOGS_DIR is known."""
    fh = logging.FileHandler(LOGS_DIR / "fetch.log")
    fh.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    log.addHandler(fh)

# ---------------------------------------------------------------------------
# Mutual exclusion: one writer across fetch + update at any moment.
# ---------------------------------------------------------------------------
_lock_fd = None

def acquire_lock():
    """Acquire an exclusive non-blocking lock. Returns True if acquired,
    False if another radio process already holds it."""
    global _lock_fd
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(LOCK_FILE), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return False
    # Record our PID for observability.
    os.ftruncate(fd, 0)
    os.write(fd, str(os.getpid()).encode())
    _lock_fd = fd
    return True

def release_lock():
    global _lock_fd
    if _lock_fd is not None:
        try:
            fcntl.flock(_lock_fd, fcntl.LOCK_UN)
            os.close(_lock_fd)
        finally:
            _lock_fd = None

# ---------------------------------------------------------------------------
# Schema: single source of truth per database, applied idempotently.
# ---------------------------------------------------------------------------
SHOWS_COLUMNS = {
    "slug":        "TEXT PRIMARY KEY",
    "guid":        "TEXT NOT NULL UNIQUE",
    "name":        "TEXT NOT NULL",
    "feed_url":    "TEXT NOT NULL UNIQUE",
    "source":      "TEXT DEFAULT 'manual'",
    "opml_import": "INTEGER DEFAULT 0",
    "archived":    "INTEGER DEFAULT 1",
    "created_at":  "TEXT DEFAULT (datetime('now'))",
}

EPISODES_COLUMNS = {
    "id":            "INTEGER PRIMARY KEY AUTOINCREMENT",
    "show_slug":     "TEXT NOT NULL",
    "guid":          "TEXT NOT NULL",
    "title":         "TEXT",
    "file_path":     "TEXT",
    "enclosure_url": "TEXT",
    "runlength":     "INTEGER",
    "played":        "INTEGER DEFAULT 0",
    "played_at":     "TEXT",
}

def _connect(db_path):
    conn = sqlite3.connect(str(db_path), timeout=5.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    return conn

def _ensure_columns(conn, table, columns):
    """Create the table if absent, else add any missing columns."""
    exists = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone()
    if exists is None:
        defs = ",\n        ".join(f"{name} {spec}" for name, spec in columns.items())
        extra = ""
        if table == "episodes":
            extra = "\n        ,UNIQUE(show_slug, guid)"
        conn.execute(f"CREATE TABLE {table} (\n        {defs}{extra}\n    )")
    else:
        existing = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
        for name, spec in columns.items():
            if name not in existing:
                col_default = spec.split("DEFAULT", 1)[1].strip() if "DEFAULT" in spec else "NULL"
                conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {col_default}")
    conn.commit()

def open_subs_db():
    conn = _connect(SUBS_DB)
    _ensure_columns(conn, "shows", SHOWS_COLUMNS)
    return conn

def open_played_db():
    conn = _connect(PLAYED_DB)
    _ensure_columns(conn, "episodes", EPISODES_COLUMNS)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_episodes_show_played ON episodes (show_slug, played)"
    )
    conn.commit()
    return conn

def slugify(name):
    s = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")
    return s[:60] or "show"

def gen_uuid():
    return str(uuid.uuid4())

def is_audio_feed(parsed):
    """Check whether the feed's latest episode has an audio enclosure.
    Returns True if audio, False if video or unknown.
    """
    if not parsed.entries:
        return True  # No entries yet; let it through, will fail on fetch
    entry = parsed.entries[0]
    enclosures = entry.get("enclosures") or []
    if not enclosures:
        return True  # No enclosure info; assume audio
    mime_type = (enclosures[0].get("type") or "").lower()
    if mime_type.startswith("audio/"):
        return True
    if mime_type.startswith("video/"):
        return False
    url = (enclosures[0].get("href") or "").lower()
    if any(url.endswith(ext) for ext in AUDIO_EXTS):
        return True
    if any(url.endswith(ext) for ext in VIDEO_EXTS):
        return False
    return True

def gpodder_sync(cfg):
    g = cfg["gpodder"]
    base = g["host"].rstrip("/")
    username = g["username"]
    password = g["password"]
    url = f"{base}/subscriptions/{quote(username, safe='')}.opml"

    print(f"--- Syncing subscriptions from {base} ---")
    print(f"Fetching subscriptions for '{username}'...")

    resp = requests.get(
        url,
        auth=(username, password),
        headers={"User-Agent": "radio-automation/1.0"},
        timeout=60,
    )

    if resp.status_code == 200:
        body = resp.text
        if not body.strip():
            log_error("gPodder sync returned an empty body.")
            return []
        return parse_opml(body)
    elif resp.status_code == 401:
        log_error("gPodder sync failed: 401 Unauthorized. Check username/password in config.json.")
    elif resp.status_code == 404:
        log_error("gPodder sync failed: 404 Not Found. User may not exist or has no subscriptions.")
    elif resp.status_code == 400:
        log_error("gPodder sync failed: 400 Bad Request.")
    else:
        log_error(f"gPodder sync failed: unexpected response {resp.status_code}: {resp.text[:200]}")
    return []

def parse_opml(xml_string):
    shows = []
    try:
        root = ET.fromstring(xml_string)
    except ET.ParseError as e:
        log_error(f"Failed to parse OPML XML: {e}")
        return []
    for outline in root.iter("outline"):
        feed_url = (outline.attrib.get("xmlUrl") or "").strip()
        name = (outline.attrib.get("text") or "").strip()
        guid = (outline.attrib.get("guid") or "").strip()
        if not feed_url or not re.match(r"^https?://", feed_url):
            continue
        shows.append({
            "name": name,
            "feed_url": feed_url,
            "guid": guid if guid else None,
        })
    return shows

def register_remote_shows(remote_shows):
    db = open_subs_db()
    added = 0
    skipped_video = 0
    for show in remote_shows:
        slug = slugify(show["name"])
        existing = db.execute("SELECT slug FROM shows WHERE slug = ?", (slug,)).fetchone()
        if existing is not None:
            continue
        parsed = fetch_feed(show["feed_url"])
        if parsed is None:
            log.warning("Skipping '%s': could not fetch feed.", show["name"])
            continue
        if not is_audio_feed(parsed):
            log.info("Skipping '%s' (%s): video podcast, not audio.", show["name"], slug)
            skipped_video += 1
            continue
        guid = show["guid"] or gen_uuid()
        db.execute(
            "INSERT INTO shows (slug, guid, name, feed_url, source, opml_import, archived) VALUES (?, ?, ?, ?, 'gpodder', 0, 1)",
            (slug, guid, show["name"], show["feed_url"]),
        )
        log.info("Registered new show: %s (%s)", show["name"], slug)
        added += 1
    db.commit()
    db.close()
    if skipped_video:
        log.info("Filtered out %d video podcast(s).", skipped_video)
    return added

def prune_stale_shows(remote_shows):
    db = open_subs_db()
    remote_slugs = {slugify(s["name"]) for s in remote_shows}
    stale = db.execute(
        "SELECT slug, name FROM shows WHERE source = 'gpodder' AND opml_import = 0"
    ).fetchall()
    removed = 0
    for row in stale:
        if row["slug"] not in remote_slugs:
            remove_show_data(row["slug"])
            db.execute("DELETE FROM shows WHERE slug = ?", (row["slug"],))
            log.info("Pruned stale show: %s (%s)", row["name"], row["slug"])
            removed += 1
    db.commit()
    db.close()
    return removed

def extract_duration(entry):
    dur = entry.get("media_duration") or entry.get("duration")
    if dur:
        try:
            return int(float(dur))
        except (ValueError, TypeError):
            pass
    iso = entry.get("iso_8601_duration")
    if iso:
        m = re.match(r"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?", iso)
        if m:
            h, mn, s = (int(g) if g else 0 for g in m.groups())
            return h * 3600 + mn * 60 + s
    enclosures = entry.get("enclosures") or []
    if enclosures:
        length = enclosures[0].get("length")
        if length:
            try:
                return int(int(length) * 8 / 128000)
            except ValueError:
                pass
    return None

def fetch_feed(feed_url):
    try:
        parsed = feedparser.parse(feed_url)
    except Exception as e:
        log_error(f"Feed parse error for {feed_url}: {e}")
        return None
    if parsed.bozo and not parsed.entries:
        log_error(f"Bozo feed (no entries) for {feed_url}: {parsed.bozo_exception}")
        return None
    return parsed

def download_episode(url, dest_dir, filename):
    dest = dest_dir / filename
    if dest.exists():
        return str(dest)
    try:
        with requests.get(url, stream=True, timeout=120) as r:
            r.raise_for_status()
            tmp = dest.with_suffix(dest.suffix + ".part")
            with open(tmp, "wb") as f:
                for chunk in r.iter_content(chunk_size=8192):
                    f.write(chunk)
            tmp.rename(dest)
        return str(dest)
    except requests.RequestException as e:
        log_error(f"Download failed for {url}: {e}")
        return None

def safe_filename(title, fallback):
    name = re.sub(r"[^\w\s.-]", "", title or "").strip().replace(" ", "_")
    return (name[:120] or fallback) + ".mp3"

def show_archived(subs_db, slug):
    row = subs_db.execute("SELECT archived FROM shows WHERE slug = ?", (slug,)).fetchone()
    if row is None:
        return True
    return row["archived"] == 1

def fetch_show_episodes(slug, name, feed_url):
    dest_dir = PODCASTS_DIR / slug
    dest_dir.mkdir(parents=True, exist_ok=True)
    parsed = fetch_feed(feed_url)
    if parsed is None:
        return 0
    played_db = open_played_db()
    seen = {
        row["guid"]
        for row in played_db.execute("SELECT guid FROM episodes WHERE show_slug = ?", (slug,))
    }
    subs_db = open_subs_db()
    archived = show_archived(subs_db, slug)
    new_count = 0
    for entry in parsed.entries:
        guid = entry.get("id") or entry.get("link") or entry.get("title", "")
        if guid in seen:
            continue
        enclosures = entry.get("enclosures") or []
        if not enclosures:
            continue
        mime = (enclosures[0].get("type") or "").lower()
        if mime.startswith("video/"):
            continue
        audio_url = enclosures[0].get("href")
        if not audio_url:
            continue
        title = entry.get("title", "untitled")
        duration = extract_duration(entry)

        if archived:
            filename = safe_filename(title, guid[-20:])
            file_path = download_episode(audio_url, dest_dir, filename)
            if file_path is None:
                continue
            played_db.execute(
                "INSERT OR IGNORE INTO episodes (show_slug, guid, title, file_path, enclosure_url, runlength, played) "
                "VALUES (?, ?, ?, ?, ?, ?, 0)",
                (slug, guid, title, file_path, audio_url, duration),
            )
        else:
            played_db.execute(
                "INSERT OR IGNORE INTO episodes (show_slug, guid, title, file_path, enclosure_url, runlength, played) "
                "VALUES (?, ?, ?, NULL, ?, ?, 0)",
                (slug, guid, title, audio_url, duration),
            )
        new_count += 1
        kind = "downloaded" if archived else "live"
        log.info("  New episode: %s [%s]", title, kind)
    played_db.commit()
    played_db.close()
    subs_db.close()
    return new_count

def fetch_all_episodes():
    db = open_subs_db()
    shows = db.execute("SELECT slug, name, feed_url FROM shows ORDER BY name").fetchall()
    db.close()
    total_new = 0
    for show in shows:
        log.info("--- Fetching: %s (%s) ---", show["name"], show["slug"])
        try:
            n = fetch_show_episodes(show["slug"], show["name"], show["feed_url"])
            total_new += n
        except Exception as e:
            log_error(f"Unexpected error fetching {show['slug']}: {e}")
    log.info("=== Fetch complete: %d new episode(s) ===", total_new)

def list_shows(detail=False):
    db = open_subs_db()
    rows = db.execute(
        "SELECT slug, name, feed_url, source, opml_import, archived FROM shows ORDER BY name"
    ).fetchall()
    db.close()
    if not rows:
        print("No shows registered.")
        return
    print(f"{'SLUG':<30} {'ARCHIVED':<10} {'SOURCE':<10} NAME")
    for r in rows:
        arch = "yes" if r["archived"] == 1 else "no"
        line = f"{r['slug']:<30} {arch:<10} {r['source']:<10} {r['name']}"
        if detail:
            line += f"\n{'':<50} {r['feed_url']}"
        print(line)

def add_show(feed_url):
    parsed = fetch_feed(feed_url)
    if parsed is None or not parsed.feed.get("title"):
        log_error(f"Could not determine show title from {feed_url}")
        return
    if not is_audio_feed(parsed):
        log_error(f"Refusing to add '{parsed.feed['title']}': video podcast detected.")
        return
    name = parsed.feed["title"]
    slug = slugify(name)
    guid = gen_uuid()
    db = open_subs_db()
    db.execute(
        "INSERT OR IGNORE INTO shows (slug, guid, name, feed_url, source, opml_import, archived) VALUES (?, ?, ?, ?, 'manual', 0, 1)",
        (slug, guid, name, feed_url),
    )
    db.commit()
    db.close()
    log.info("Added show: %s (%s)", name, slug)
    fetch_show_episodes(slug, name, feed_url)

def set_archive(slug, value):
    db = open_subs_db()
    row = db.execute("SELECT name FROM shows WHERE slug = ?", (slug,)).fetchone()
    if row is None:
        log_error(f"No show found with slug '{slug}'.")
        db.close()
        return
    db.execute("UPDATE shows SET archived = ? WHERE slug = ?", (value, slug))
    db.commit()
    db.close()
    state = "archived" if value == 1 else "non-archived (live)"
    log.info("Show '%s' (%s) is now %s.", row["name"], slug, state)

def remove_show_data(slug):
    pod_dir = PODCASTS_DIR / slug
    if pod_dir.exists():
        shutil.rmtree(pod_dir)
    txt = PLAYLISTS_DIR / f"{slug}.txt"
    if txt.exists():
        txt.unlink()

def delete_show(slug):
    db = open_subs_db()
    row = db.execute("SELECT name FROM shows WHERE slug = ?", (slug,)).fetchone()
    if row is None:
        log_error(f"No show found with slug '{slug}'.")
        db.close()
        return
    remove_show_data(slug)
    db.execute("DELETE FROM shows WHERE slug = ?", (slug,))
    db.commit()
    db.close()
    played_db = open_played_db()
    played_db.execute("DELETE FROM episodes WHERE show_slug = ?", (slug,))
    played_db.commit()
    played_db.close()
    log.info("Deleted show: %s (%s)", row["name"], slug)

def import_opml(path):
    try:
        with open(path) as f:
            content = f.read()
    except OSError as e:
        log_error(f"Cannot read OPML file: {e}")
        return
    shows = parse_opml(content)
    db = open_subs_db()
    added = 0
    skipped_video = 0
    for show in shows:
        slug = slugify(show["name"])
        existing = db.execute("SELECT slug FROM shows WHERE slug = ?", (slug,)).fetchone()
        if existing is not None:
            continue
        parsed = fetch_feed(show["feed_url"])
        if parsed is None:
            log.warning("OPML import: skipping '%s', could not fetch feed.", show["name"])
            continue
        if not is_audio_feed(parsed):
            log.info("OPML import: skipping '%s' (%s): video podcast.", show["name"], slug)
            skipped_video += 1
            continue
        guid = show["guid"] or gen_uuid()
        db.execute(
            "INSERT INTO shows (slug, guid, name, feed_url, source, opml_import, archived) VALUES (?, ?, ?, ?, 'opml', 1, 1)",
            (slug, guid, show["name"], show["feed_url"]),
        )
        added += 1
    db.commit()
    db.close()
    log.info("OPML import: %d added, %d video shows filtered out.", added, skipped_video)

def run_fetch(config):
    g = config["gpodder"]
    if g.get("enable") is True:
        remote = gpodder_sync(config)
        if not remote:
            log.warning("No subscriptions retrieved from gPodder; using local registry only.")
        else:
            added = register_remote_shows(remote)
            pruned = prune_stale_shows(remote)
            log.info("Sync: %d added, %d pruned.", added, pruned)
    fetch_all_episodes()

def main():
    parser = argparse.ArgumentParser(description="Podcast fetcher for radio automation")
    parser.add_argument("--list-shows", action="store_true", help="List registered shows")
    parser.add_argument("--detail", action="store_true", help="With --list-shows, show feed URLs")
    parser.add_argument("--add-show", metavar="FEED_URL", help="Add a show from a feed URL")
    parser.add_argument("--delete-show", metavar="SLUG", help="Delete a show and its data")
    parser.add_argument("--archive", metavar="SLUG", help="Mark a show as archived (download episodes)")
    parser.add_argument("--unarchive", metavar="SLUG", help="Mark a show as non-archived (stream live)")
    parser.add_argument("--import-opml", metavar="FILE", help="Import shows from an OPML file")
    args = parser.parse_args()

    init_paths()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    PODCASTS_DIR.mkdir(parents=True, exist_ok=True)
    PLAYLISTS_DIR.mkdir(parents=True, exist_ok=True)
    _setup_logging()

    config = load_config()

    # Read-only administrative commands don't need the write lock.
    needs_lock = not args.list_shows

    if needs_lock and not acquire_lock():
        log.info("Another radio process holds the lock; skipping this run.")
        return

    try:
        if args.archive:
            set_archive(args.archive, 1)
        elif args.unarchive:
            set_archive(args.unarchive, 0)
        elif args.list_shows:
            list_shows(detail=args.detail)
        elif args.add_show:
            add_show(args.add_show)
        elif args.delete_show:
            delete_show(args.delete_show)
        elif args.import_opml:
            import_opml(args.import_opml)
        else:
            run_fetch(config)
    finally:
        if needs_lock:
            release_lock()

if __name__ == "__main__":
    main()

