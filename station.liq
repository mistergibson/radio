#!/usr/bin/env liquidsoap

# ---------------------------------------------------------------
# station.liq - Liquidsoap configuration for radio automation
# Written for Liquidsoap 2.2.x. Run from /srv/radio so that the
# relative config.json path resolves correctly; media lives under
# the storage path read from that file. Directory playlists scan
# recursively for audio files automatically.
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
  playlist("#{storage}/music")

# --- Scheduled content: request queue fed by schedule.txt ------
sched_queue = request.queue(id="scheduler")

# --- Helper: check if a directory contains any audio files -----
def has_audio(dir) =
  try
    let entries = file.ls(dir)
    let audio_count = list.length(
      list.filter(fun(f) -> regexp("\\.(mp3|m4a)$").test(f), entries)
    )
    audio_count > 0
  catch _ do
    false
  end

# --- Jingles / announcements (only active if they have content) ---
jingles_active = has_audio("#{storage}/jingles")
announcements_active = has_audio("#{storage}/announcements")

log("#[info] Jingles directory has audio: #{string(jingles_active)}")
log("#[info] Announcements directory has audio: #{string(announcements_active)}")

# --- Assemble the stream ---------------------------------------
primary = fallback(track_sensitive=false, [sched_queue, music_playlist])

content =
  if jingles_active then
    random(weights=[1, 8], [
      mksafe(playlist("#{storage}/jingles")),
      primary
    ])
  else
    primary
  end

final_content =
  if announcements_active then
    fallback(track_sensitive=false, [
      mksafe(playlist("#{storage}/announcements")),
      content
    ])
  else
    content
  end

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
