#!/usr/bin/env python3
"""
update_playlists.py - Select the next unplayed episode per show and write an
annotated URI queue file for station.liq to consume.

Concurrency model mirrors fetch_podcasts.py:
  - Shares the same exclusive lockfile (state/radio.lock). If the fetcher is
    still running, this run logs a skip and exits 0 instead of hitting a
    locked database.
  - Databases run in WAL mode with a busy timeout as a second safety net.

Selection: for each show, pick the earliest episode with played=0, write
playlists/<slug>.txt as a single annotated URI line, then mark it played.
Works identically for archived (local file_path) and live (enclosure_url)
shows because both store their episodes in the same table.
"""

import argparse
import fcntl
import json
import logging
import os
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "config.json"

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
log = logging.getLogger("update_playlists")

def log_error(msg):
    log.error(msg)

def _setup_logging():
    fh = logging.FileHandler(LOGS_DIR / "update.log")
    fh.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    log.addHandler(fh)

# ---------------------------------------------------------------------------
# Shared schema definitions (must match fetch_podcasts.py).
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

# ---------------------------------------------------------------------------
# Mutual exclusion (shared with fetch_podcasts.py via the same lockfile).
# ---------------------------------------------------------------------------
_lock_fd = None

def acquire_lock():
    global _lock_fd
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(LOCK_FILE), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return False
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
# Core logic
# ---------------------------------------------------------------------------
def _annotate_uri(runlength, title, uri):
    """Build a liquidsoap annotated URI line. Values must be double-quoted
    and separated by commas; the whole annotation precedes a colon before
    the URI. Escapes embedded double quotes minimally."""
    def q(v):
        return '"' + str(v).replace('"', '\\"') + '"'
    ann = f"annotate:liq_runlength={q(runlength)},liq_title={q(title)}:"
    return ann + uri

def select_next_episode(slug, played_db):
    row = played_db.execute(
        "SELECT guid, title, file_path, enclosure_url, runlength "
        "FROM episodes WHERE show_slug=? AND played=0 ORDER BY id ASC LIMIT 1",
        (slug,),
    ).fetchone()
    return row

def mark_as_played(slug, guid, played_db):
    played_db.execute(
        "UPDATE episodes SET played=1, played_at=datetime('now') "
        "WHERE show_slug=? AND guid=?",
        (slug, guid),
    )
    played_db.commit()

def write_queue_file(slug, ep, archived):
    if archived:
        uri = ep["file_path"]
    else:
        uri = ep["enclosure_url"]
    if not uri:
        return None
    line = _annotate_uri(ep["runlength"], ep["title"], uri)
    out = PLAYLISTS_DIR / f"{slug}.txt"
    out.write_text(line + "\n")
    return out

def update_all():
    subs_db = open_subs_db()
    played_db = open_played_db()
    shows = subs_db.execute("SELECT slug, name, archived FROM shows ORDER BY name").fetchall()
    updated = 0
    for show in shows:
        slug = show["slug"]
        archived = show["archived"] == 1
        ep = select_next_episode(slug, played_db)
        if ep is None:
            continue
        out = write_queue_file(slug, ep, archived)
        if out is None:
            log.warning("No playable URI for %s (%s); skipping.", show["name"], slug)
            continue
        mark_as_played(slug, ep["guid"], played_db)
        updated += 1
        log.info("Queued %s: %s -> %s", slug, ep["title"], out.name)
    subs_db.close()
    played_db.close()
    log.info("=== Update complete: %d show(s) queued ===", updated)

def json_summary():
    subs_db = open_subs_db()
    played_db = open_played_db()
    shows = subs_db.execute("SELECT slug, name FROM shows ORDER BY name").fetchall()
    result = {}
    for show in shows:
        slug = show["slug"]
        counts = played_db.execute(
            "SELECT COUNT(*) AS total, SUM(CASE WHEN played=0 THEN 1 ELSE 0 END) AS unplayed "
            "FROM episodes WHERE show_slug=?",
            (slug,),
        ).fetchone()
        total = counts["total"] or 0
        unplayed = counts["unplayed"] or 0
        result[slug] = {"name": show["name"], "total": total, "unplayed": unplayed, "played": total - unplayed}
    subs_db.close()
    played_db.close()
    print(json.dumps(result, indent=2))

def main():
    parser = argparse.ArgumentParser(description="Playlist updater for radio automation")
    parser.add_argument("--json", action="store_true", help="Emit JSON summary and exit")
    args = parser.parse_args()

    init_paths()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    PLAYLISTS_DIR.mkdir(parents=True, exist_ok=True)
    _setup_logging()

    # --json is read-only and doesn't need the write lock.
    needs_lock = not args.json

    if needs_lock and not acquire_lock():
        log.info("Another radio process holds the lock; skipping this run.")
        return

    try:
        if args.json:
            json_summary()
        else:
            update_all()
    finally:
        if needs_lock:
            release_lock()

if __name__ == "__main__":
    main()
