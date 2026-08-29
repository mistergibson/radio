#!/usr/bin/env python3
"""
update_playlists.py - Regenerate per-show .pls playlists based on playback history.
Runs via cron hourly at :30. All data under the storage path from config.json.
"""

import argparse
import json
import logging
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "config.json"

AUDIO_EXTS = {".mp3", ".m4a"}

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
            duration_seconds INTEGER,
            played_at TEXT,
            UNIQUE(show_slug, guid)
        )
    """)
    conn.commit()
    return conn

def find_audio_files(directory):
    results = []
    if not directory.exists():
        return results
    for p in sorted(directory.rglob("*")):
        if p.is_file() and p.suffix.lower() in AUDIO_EXTS:
            results.append(str(p))
    return results

def select_unplayed_episode(slug, played_db):
    files = find_audio_files(PODCASTS_DIR / slug)
    if not files:
        return None
    played_rows = played_db.execute(
        "SELECT file_path, played_at FROM episodes WHERE show_slug = ? AND played_at IS NOT NULL",
        (slug,),
    ).fetchall()
    played_paths = {row["file_path"]: row["played_at"] for row in played_rows}
    unplayed = [f for f in files if f not in played_paths]
    if unplayed:
        return unplayed[0]
    if played_paths:
        return min(played_paths.items(), key=lambda kv: (kv[1] or ""))[0]
    return files[0]

def write_pls(filepath, out_path):
    abs_path = str(Path(filepath).resolve())
    content = f"[playlist]\nFile1={abs_path}\nTitle1=Radio Episode\nLength1=-1\nNumberOfEntries=1\nVersion=2\n"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(content)

def mark_as_played(slug, filepath, played_db):
    played_db.execute(
        "UPDATE episodes SET played_at = datetime('now') WHERE show_slug = ? AND file_path = ?",
        (slug, filepath),
    )
    played_db.commit()

def update_all():
    subs_db = open_subs_db()
    played_db = open_played_db()
    shows = subs_db.execute("SELECT slug, name FROM shows ORDER BY name").fetchall()
    for show in shows:
        slug = show["slug"]
        selected = select_unplayed_episode(slug, played_db)
        if selected is None:
            log.info("%s: no audio files found, skipping.", slug)
            continue
        out_pls = PLAYLISTS_DIR / f"{slug}.pls"
        write_pls(selected, out_pls)
        mark_as_played(slug, selected, played_db)
        log.info("%s: queued %s", slug, Path(selected).name)
    subs_db.close()
    played_db.close()

def json_summary():
    subs_db = open_subs_db()
    played_db = open_played_db()
    shows = subs_db.execute("SELECT slug FROM shows ORDER BY name").fetchall()
    summary = {}
    for show in shows:
        slug = show["slug"]
        files = find_audio_files(PODCASTS_DIR / slug)
        played_count = played_db.execute(
            "SELECT COUNT(*) as c FROM episodes WHERE show_slug = ? AND played_at IS NOT NULL",
            (slug,),
        ).fetchone()["c"]
        summary[slug] = {"total_files": len(files), "played_count": played_count}
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
