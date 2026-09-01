#!/usr/bin/env liquidsoap

# ---------------------------------------------------------------
# station.liq - Liquidsoap configuration for radio automation
# Written for Liquidsoap 2.2.x. Run from /srv/radio so that the
# relative config.json path resolves correctly; media lives under
# the storage path read from that file. Directory playlists scan
# recursively for audio files automatically.
#
# JINGLE/ANNOUNCEMENT NOTE:
# random() stalls when one branch is permanently down (empty dir).
# Until jingles/announcements directories contain audio files,
# they are excluded from the graph. Uncomment the relevant lines
# below once you've added content to those folders.
# ---------------------------------------------------------------

set("log.stdout", true)
set("log.level", 3)

# --- Step 1: path to config.json (relative to working directory) ---
let config_path = "config.json"

# --- Step 2: read and parse the whole file with explicit types --
let json.parse (cfg : {
  storage: string,
  icecast: {
    host: string,
    port: int,
    mount: string,
    username: string,
    password: string
  }
}) = file.contents(config_path)

# --- Step 3: pull out the values we need ------------------------
let storage     = cfg.storage
let ic_host     = cfg.icecast.host
let ic_port     = cfg.icecast.port
let ic_mount    = cfg.icecast.mount
let ic_username = cfg.icecast.username
let ic_password = cfg.icecast.password

set("log.file.path", "#{storage}/logs/liquidsoap.log")

# --- Background music library (directory scanned recursively) --
music_playlist =
  mksafe(playlist("#{storage}/music"))

# --- Scheduled content: request queue fed by schedule.txt ------
sched_queue = request.queue(id="scheduler")

# --- Jingles / announcements (uncomment when dirs have content) ---
# jingles_src =
#   mksafe(playlist("#{storage}/jingles"))
#
# announcements_src =
#   mksafe(playlist("#{storage}/announcements"))

# --- Assemble the stream ---------------------------------------
primary = fallback(track_sensitive=false, [sched_queue, music_playlist])

# When jingles are active, uncomment this and comment out the line below:
# content = random(weights=[1, 8], [jingles_src, primary])
content = primary

# When announcements are active, uncomment this and comment out the line below:
# final_content = fallback(track_sensitive=false, [announcements_src, content])
final_content = content

radio = normalize(final_content)

# --- Output to Icecast -----------------------------------------
output.icecast(
  %mp3(bitrate=128, samplerate=44100, stereo=true),
  host=ic_host,
  port=ic_port,
  user=ic_username,
  password=ic_password,
  mount=ic_mount,
  name="Radio Station",
  description="Automated internet radio",
  genre="Various",
  public=true,
  radio
)
