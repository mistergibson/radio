#!/usr/bin/env python3
"""Fetch podcast episodes from RSS feeds, manage subscriptions, and download audio."""

import os
import sys
import json
import shutil
import sqlite3
import hashlib
import xml.etree.ElementTree as ET
from pathlib import Path
from datetime import datetime
from urllib.parse import urlparse

import feedparser
import requests

AUDIO_ROOT = Path(__file__).resolve().parent
DB_PATH = AUDIO_ROOT / "state" / "subscriptions.db"
DOWNLOAD_DIR = AUDIO_ROOT / "podcasts"
CONFIG_PATH = AUDIO_ROOT / "config.json"


def load_config():
    with open(CONFIG_PATH, "r") as f:
        return json.load(f)


def get_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    conn.execute("""CREATE TABLE IF NOT EXISTS shows (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL,
        feed_url TEXT UNIQUE NOT NULL,
        slug TEXT UNIQUE NOT NULL,
        opml_import INTEGER DEFAULT 0
    )""")
    conn.execute("""CREATE TABLE IF NOT EXISTS seen (
        url TEXT PRIMARY KEY,
        title TEXT,
        show_slug TEXT,
        duration_sec INTEGER DEFAULT 0,
        downloaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )""")
    # Migrate existing databases that lack the new column
    cols = [row[1] for row in conn.execute("PRAGMA table_info(shows)").fetchall()]
    if "opml_import" not in cols:
        conn.execute("ALTER TABLE shows ADD COLUMN opml_import INTEGER DEFAULT 0")
    conn.commit()
    return conn


def sanitize_slug(name):
    """Convert a show name to a filesystem-safe slug."""
    slug = name.lower().strip()
    slug = "".join(c if c.isalnum() or c in ("-", "_") else "_" for c in slug)
    slug = "_".join(slug.split("_"))
    return slug[:80]


def register_shows_from_opml_xml(xml_bytes, db, opml_import=False):
    """Register shows from OPML XML data.

    Uses upsert semantics: if a show with the same feed_url already exists,
    no duplicate row is created. Its opml_import flag is upgraded to 1 if
    this import marks it as such (protecting it from gpodder pruning).
    """
    root = ET.fromstring(xml_bytes)
    added = 0
    updated_flag = 0
    skipped = 0

    for outline in root.iter("outline"):
        xml_url = outline.get("xmlUrl", "")
        if not xml_url:
            continue
        otype = outline.get("type", "")
        if otype and otype != "rss":
            continue

        show_name = outline.get("text") or outline.get("title") or "Unknown Show"
        slug = sanitize_slug(show_name)
        flag = 1 if opml_import else 0

        existing = db.execute(
            "SELECT id, opml_import FROM shows WHERE feed_url=?", (xml_url,)
        ).fetchone()

        if existing:
            existing_id, existing_flag = existing
            if flag == 1 and existing_flag == 0:
                db.execute(
                    "UPDATE shows SET opml_import=1 WHERE id=?", (existing_id,)
                )
                updated_flag += 1
                print(f"  Protected existing: {show_name} ({slug})")
            else:
                skipped += 1
        else:
            db.execute(
                "INSERT INTO shows (name, feed_url, slug, opml_import) VALUES (?, ?, ?, ?)",
                (show_name, xml_url, slug, flag)
            )
            added += 1
            print(f"  Registered: {show_name} -> {slug}")

    db.commit()

    if added:
        print(f"  Added {added} new show(s).")
    if updated_flag:
        print(f"  Upgraded {updated_flag} show(s) to protected.")
    if skipped:
        print(f"  Skipped {skipped} duplicate(s).")
    return added


def import_opml_file(filepath):
    """Import shows from a local OPML file."""
    try:
        with open(filepath, "rb") as f:
            xml_data = f.read()
    except FileNotFoundError:
        print(f"ERROR: File not found: {filepath}")
        sys.exit(1)

    db = get_db()
    count = register_shows_from_opml_xml(xml_data, db, opml_import=True)
    total = db.execute("SELECT COUNT(*) FROM shows").fetchone()[0]
    db.close()

    print(f"\nImport complete. {count} new show(s) added. Total registered: {total}")


def sync_gpoddernet():
    """Sync subscriptions from gpodder.net, register new shows, prune removed ones."""
    cfg = load_config()
    gp = cfg["gpodder"]

    if not gp.get("enable", False):
        print("gpodder.net sync is disabled in config.json.")
        return

    if not gp.get("username") or not gp.get("password"):
        print("ERROR: gpodder.username/gpodder.password not set in config.json")
        sys.exit(1)

    url = f"{gp['host']}/subscriptions/{gp['username']}.opml"
    print(f"Fetching subscriptions from {gp['host']} for '{gp['username']}'...")

    resp = requests.get(url, auth=(gp["username"], gp["password"]), timeout=30)

    if resp.status_code == 401:
        print("ERROR: Authentication failed. Check username/password in config.json.")
        sys.exit(1)
    elif resp.status_code != 200:
        print(f"ERROR: Unexpected response {resp.status_code}: {resp.text[:200]}")
        sys.exit(1)

    db = get_db()

    # Collect all feed URLs from the current subscription list
    root = ET.fromstring(resp.content)
    gp_feed_urls = set()
    for outline in root.iter("outline"):
        fu = outline.get("xmlUrl", "")
        if fu:
            gp_feed_urls.add(fu)

    # Register any new shows
    count = register_shows_from_opml_xml(resp.content, db, opml_import=False)
    total = db.execute("SELECT COUNT(*) FROM shows").fetchone()[0]

    # Prune shows that were unsubscribed
    prune_removed_shows(gp_feed_urls, db)

    db.close()
    print(f"\nSync complete. {count} new, total registered: {total}")


def prune_removed_shows(gp_feed_urls, db):
    """Remove shows not in current gpodder list (unless opml_import=1)."""
    rows = db.execute(
        "SELECT slug, feed_url, name FROM shows WHERE opml_import = 0"
    ).fetchall()

    to_remove = []
    for slug, feed_url, name in rows:
        if feed_url not in gp_feed_urls:
            to_remove.append((slug, name))

    if not to_remove:
        return

    for slug, name in to_remove:
        print(f"  Removing unsubscribed show: {name} ({slug})")
        db.execute("DELETE FROM seen WHERE show_slug=?", (slug,))
        db.execute("DELETE FROM shows WHERE slug=?", (slug))
        show_dir = DOWNLOAD_DIR / slug
        if show_dir.exists():
            shutil.rmtree(show_dir)
            print(f"  Deleted directory: {show_dir}")

    db.commit()
    print(f"  Pruned {len(to_remove)} removed show(s).")


def delete_show(slug):
    """Manually delete a show and all associated data."""
    db = get_db()
    row = db.execute("SELECT name FROM shows WHERE slug=?", (slug,)).fetchone()
    if not row:
        print(f"No show found with slug '{slug}'.")
        db.close()
        return

    name = row[0]
    print(f"Deleting show: {name} ({slug})")
    db.execute("DELETE FROM seen WHERE show_slug=?", (slug,))
    db.execute("DELETE FROM shows WHERE slug=?", (slug))
    db.commit()
    db.close()

    show_dir = DOWNLOAD_DIR / slug
    if show_dir.exists():
        shutil.rmtree(show_dir)
        print(f"Deleted directory: {show_dir}")

    pls_file = AUDIO_ROOT / "playlists" / f"{slug}.pls"
    if pls_file.exists():
        pls_file.unlink()
        print(f"Deleted playlist: {pls_file}")

    print("Done.")


def add_show(feed_url):
    """Register a new show from a feed URL and fetch its initial episodes."""
    print(f"Fetching feed: {feed_url}")
    try:
        d = feedparser.parse(feed_url)
    except Exception as e:
        print(f"ERROR: Failed to parse feed: {e}")
        sys.exit(1)

    if d.bozo and not d.entries:
        print(f"ERROR: Invalid or unreachable feed. Bozo exception: {d.get('bozo_exception', 'unknown')}")
        sys.exit(1)

    show_name = d.feed.get("title", "Unknown Show")
    slug = sanitize_slug(show_name)
    entry_count = len(d.entries)

    print(f"  Title: {show_name}")
    print(f"  Slug:  {slug}")
    print(f"  Entries found: {entry_count}")

    db = get_db()

    existing = db.execute("SELECT name FROM shows WHERE feed_url=?", (feed_url,)).fetchone()
    if existing:
        print(f"NOTE: Feed already registered as '{existing[0]}'. Nothing to do.")
        db.close()
        return

    db.execute(
        "INSERT INTO shows (name, feed_url, slug, opml_import) VALUES (?, ?, ?, 1)",
        (show_name, feed_url, slug)
    )
    db.commit()
    print(f"  Registered: {show_name} -> {slug}")

    print(f"\n--- Fetching episodes ---")
    fetch_feed(show_name, feed_url, slug, db)

    db.close()
    print(f"\nDone. Episodes saved to: {DOWNLOAD_DIR / slug}/")


def fetch_feed(show_name, feed_url, slug, db):
    """Parse a feed and download any new episodes."""
    d = feedparser.parse(feed_url)

    if d.bozo and not d.entries:
        print(f"[{show_name}] ERROR: Could not parse feed.")
        return

    show_dir = DOWNLOAD_DIR / slug
    show_dir.mkdir(parents=True, exist_ok=True)

    new_count = 0
    for entry in d.entries:
        link = entry.get("link", "")
        title = entry.get("title", "untitled")

        # Find the enclosure (audio file)
        enclosure = None
        if hasattr(entry, "enclosures") and entry.enclosures:
            enc = entry.enclosures[0]
            enclosure = {"url": enc.href, "type": enc.type, "length": getattr(enc, "length", "0")}
        elif "media_content" in entry:
            mc = entry.media_content[0]
            enclosure = {"url": mc.url, "type": mc.type, "length": getattr(mc, "duration", "0")}

        if not enclosure:
            continue

        ep_url = enclosure["url"]

        # Check if already downloaded
        row = db.execute("SELECT 1 FROM seen WHERE url=?", (ep_url,)).fetchone()
        if row:
            continue

        # Extract duration from enclosure length (seconds) or media:duration
        duration_sec = 0
        try:
            raw_len = str(enclosure.get("length", "0"))
            if ":" in raw_len:
                parts = raw_len.split(":")
                duration_sec = int(parts[-1])
            else:
                duration_sec = int(raw_len)
        except (ValueError, IndexError):
            pass

        # Sanitize filename
        safe_title = "".join(c if c.isalnum() or c in ("-", "_", " ") else "_" for c in title)
        safe_title = safe_title.strip()[:120]
        ext = ".mp3"
        if "ogg" in enclosure.get("type", "").lower():
            ext = ".ogg"
        elif "m4a" in enclosure.get("type", "").lower() or "aac" in enclosure.get("type", "").lower():
            ext = ".m4a"

        filepath = show_dir / f"{safe_title}{ext}"

        if filepath.exists():
            db.execute(
                "INSERT OR IGNORE INTO seen (url, title, show_slug, duration_sec) VALUES (?, ?, ?, ?)",
                (ep_url, title, slug, duration_sec)
            )
            db.commit()
            continue

        # Download
        try:
            print(f"[{show_name}] Downloading: {title}")
            resp = requests.get(ep_url, stream=True, timeout=120)
            resp.raise_for_status()
            with open(filepath, "wb") as f:
                for chunk in resp.iter_content(chunk_size=8192):
                    f.write(chunk)

            db.execute(
                "INSERT OR IGNORE INTO seen (url, title, show_slug, duration_sec) VALUES (?, ?, ?, ?)",
                (ep_url, title, slug, duration_sec)
            )
            db.commit()
            new_count += 1
        except Exception as e:
            print(f"[{show_name}] FAILED to download '{title}': {e}")

    if new_count:
        print(f"[{show_name}] Downloaded {new_count} new episode(s).")
    else:
        print(f"[{show_name}] No new episodes.")


def list_shows(detail=False):
    """List all registered shows."""
    db = get_db()
    rows = db.execute("SELECT name, slug, feed_url, opml_import FROM shows ORDER BY name").fetchall()

    if not rows:
        print("No shows registered.")
        db.close()
        return

    print(f"{'Show Name':<40} {'Slug':<30} {'Protected':<10}")
    print("-" * 80)
    for name, slug, feed_url, prot in rows:
        prot_str = "yes" if prot else "no"
        print(f"{name:<40} {slug:<30} {prot_str:<10}")

    if detail:
        print("\nFeed URLs:")
        for name, slug, feed_url, prot in rows:
            print(f"  {slug}: {feed_url}")

    db.close()


def main():
    if "--delete-show" in sys.argv:
        idx = sys.argv.index("--delete-show")
        if idx + 1 < len(sys.argv):
            delete_show(sys.argv[idx + 1])
        else:
            print("Usage: fetch_podcasts.py --delete-show <slug>")
            sys.exit(1)
        return

    if "--add-show" in sys.argv:
        idx = sys.argv.index("--add-show")
        if idx + 1 < len(sys.argv):
            add_show(sys.argv[idx + 1])
        else:
            print("Usage: fetch_podcasts.py --add-show <feed-url>")
            sys.exit(1)
        return

    if "--import-opml" in sys.argv:
        idx = sys.argv.index("--import-opml")
        if idx + 1 < len(sys.argv):
            import_opml_file(sys.argv[idx + 1])
        else:
            print("Usage: fetch_podcasts.py --import-opml <path-to-file.opml>")
            sys.exit(1)
        return

    if "--list-shows" in sys.argv:
        list_shows(detail="--detail" in sys.argv)
        return

    # Normal run: optionally sync gpodder, then fetch all registered shows
    cfg = load_config()
    gp = cfg.get("gpodder", {})

    if gp.get("enable", False):
        print("--- Syncing subscriptions from gpodder.net ---")
        try:
            sync_gpoddernet()
        except SystemExit:
            raise
        except Exception as e:
            print(f"! gpodder sync failed (continuing with existing shows): {e}")

    db = get_db()
    shows = db.execute("SELECT name, feed_url, slug FROM shows").fetchall()

    if not shows:
        print("No shows registered. Import an OPML file, add a show, or enable gpodder sync.")
        db.close()
        return

    print(f"--- Fetching episodes for {len(shows)} show(s) ---")
    for show_name, feed_url, slug in shows:
        try:
            fetch_feed(show_name, feed_url, slug, db)
        except Exception as e:
            print(f"[{show_name}] FAILED: {e}")

    db.close()


if __name__ == "__main__":
    main()
