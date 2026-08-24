#!/usr/bin/env python3
"""Regenerate per-show playlist files based on playback history."""

import os
import sys
import json
import sqlite3
from pathlib import Path
from datetime import datetime

AUDIO_ROOT = Path(__file__).resolve().parent
PLAYLISTS_DIR = AUDIO_ROOT / "playlists"
STATE_DB = AUDIO_ROOT / "state" / "played.db"
SUBS_DB = AUDIO_ROOT / "state" / "subscriptions.db"
SHOWS_DIR = AUDIO_ROOT / "podcasts"


def get_played_db():
    STATE_DB.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(STATE_DB))
    conn.execute("""CREATE TABLE IF NOT EXISTS played (
        filename TEXT PRIMARY KEY,
        show TEXT,
        played_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )""")
    return conn
