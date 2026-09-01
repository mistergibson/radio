#!/usr/bin/env python3
"""
update_playlists.py - Select the next unplayed episode per show and write an
annotated URI line for station.liq to consume. Runs via cron hourly at :30.

Selection is driven by the episodes table (keyed on guid + played flag), not
by scanning the filesystem, so it works identically for archived shows
(local file_path) and live shows (remote enclosure_url). All data under the
storage path from config.json.
"""

import argparse
import json
import logging
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "config.json"

STATE_DIR = None
SUBS_DB = None
PLAYED_DB = None
PODCASTS_DIR = None
PLAYLISTS_DIR = None
LOGS_DIR = None

def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)

def init_paths():
    global STATE_DIR, SUBS_DB, PLAYED_DB, PODCASTS_DIR, PLAYLISTS_DIR, LOGS_DIR
    cfg = load_config()
    storage = Path(cfg["storage"]).expanduser().resolve()
    STATE_DIR = storage / "state"
    SUBS_DB = STATE_DIR / "subscriptions.db"
    PLAYED_DB = STATE_DIR / "played.db"
    PODCASTS_DIR = storage / "podcasts"
    PLAYLISTS_DIR = storage / "playlists"
    LOGS_DIR = storage / "logs"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("update_playlists")

def _setup_logging():
    fh = logging.FileHandler(LOGS_DIR / "update.log")
    fh.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    log.addHandler(fh)

def open_subs_db():
    conn = sqlite3.connect(SUBS_DB)
    conn.row_factory = sqlite3.Row
    conn.execute("""
        CREATE TABLE IF NOT EXISTS shows (
            slug TEXT PRIMARY KEY,
            guid TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            feed_url TEXT NOT NULL UNIQUE,
            source TEXT DEFAULT 'manual',
            opml_import INTEGER DEFAULT 0,
            archived INTEGER DEFAULT 1,
            created_at TEXT DEFAULT (datetime('now'))
        )
    """)
    conn.commit()
    return conn

def open_played_db():
    conn = sqlite3.connect(PLAYED_DB)
    conn.row_factory = sqlite3.Row
    conn.execute("""
        CREATE TABLE IF NOT EXISTS episodes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            show_slug TEXT NOT NULL,
            guid TEXT NOT NULL,
            title TEXT,
            file_path TEXT,
            enclosure_url TEXT,
            runlength INTEGER,
            played INTEGER DEFAULT 0,
            played_at TEXT,
            UNIQUE(show_slug, guid)
        )
    """)
    conn.commit()
    return conn

def select_unplayed_episode(slug, played_db):
    """Pick the next unplayed episode for a show, keyed by guid.
    Archived -> local file_path; Live -> remote enclosure_url."""
    row = played_db.execute(
        "SELECT guid, title, file_path, enclosure_url, runlength "
        "FROM episodes WHERE show_slug = ? AND played = 0 ORDER BY id ASC LIMIT 1",
        (slug,),
    ).fetchone()
    return row

def annotated_uri(ep):
    """Build the annotate: URI line station.liq consumes.
    Archived -> local file path; Live -> remote enclosure URL."""
    uri = ep["file_path"] or ep["enclosure_url"]
    if not uri:
        return None
    rl = int(ep["runlength"] or 0)
    title = (ep["title"] or "").replace('"', "'")
    return f'annotate:liq_runlength="{rl}",liq_title="{title}":{uri}'

def write_queue_line(slug, line, out_path):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(line + "\n")

def mark_as_played(slug, guid, played_db):
    played_db.execute(
        "UPDATE episodes SET played = 1, played_at = datetime('now') WHERE show_slug = ? AND guid = ?",
        (slug, guid),
    )
    played_db.commit()

def update_all():
    subs_db = open_subs_db()
    played_db = open_played_db()
    shows = subs_db.execute("SELECT slug, name, archived FROM shows ORDER BY name").fetchall()
    queued = 0
    skipped = 0
    for show in shows:
        slug = show["slug"]
        ep = select_unplayed_episode(slug, played_db)
        if ep is None:
            log.info("%s: no unplayed episodes, skipping.", slug)
            skipped += 1
            continue
        line = annotated_uri(ep)
        if line is None:
            log.info("%s: episode %s has no usable URI, skipping.", slug, ep["guid"])
            skipped += 1
            continue
        out_txt = PLAYLISTS_DIR / f"{slug}.txt"
        write_queue_line(slug, line, out_txt)
        mark_as_played(slug, ep["guid"], played_db)
        kind = "downloaded" if ep["file_path"] else "live"
        log.info("%s: queued %s [%s] runlength=%ss", slug, ep["title"], kind, int(ep["runlength"] or 0))
        queued += 1
    subs_db.close()
    played_db.close()
    log.info("=== Update complete: %d queued, %d skipped ===", queued, skipped)

def json_summary():
    subs_db = open_subs_db()
    played_db = open_played_db()
    shows = subs_db.execute("SELECT slug FROM shows ORDER BY name").fetchall()
    summary = {}
    for show in shows:
        slug = show["slug"]
        total = played_db.execute(
            "SELECT COUNT(*) as c FROM episodes WHERE show_slug = ?", (slug,)
        ).fetchone()["c"]
        played = played_db.execute(
            "SELECT COUNT(*) as c FROM episodes WHERE show_slug = ? AND played = 1", (slug,)
        ).fetchone()["c"]
        summary[slug] = {"total_episodes": total, "played_count": played, "unplayed": total - played}
    subs_db.close()
    played_db.close()
    print(json.dumps(summary, indent=2))

def main():
    parser = argparse.ArgumentParser(description="Playlist updater for radio automation")
    parser.add_argument("--json", action="store_true", help="Emit JSON summary and exit")
    args = parser.parse_args()

    init_paths()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    PLAYLISTS_DIR.mkdir(parents=True, exist_ok=True)
    _setup_logging()

    if args.json:
        json_summary()
    else:
        update_all()

if __name__ == "__main__":
    main()
