#!/usr/bin/env liquidsoap

# ---------------------------------------------------------------
# station.liq - Liquidsoap configuration for radio automation
# Auto-detects its own location so all paths are relative.
# ---------------------------------------------------------------

configure.bindir()

set("log.file.path", "#{bindir()}/logs/liquidsoap.log")
set("log.stdout", true)
set("log.level", 3)

# --- Load Icecast credentials from config.json ---
let json.parse (cfg : {
  icecast: {
    host: string,
    port: int,
    mount: string,
    username: string,
    password: string
  },
  gpodder: {
    enable: bool,
    host: string,
    username: string,
    password: string
  }
}) = file.contents("#{bindir()}/config.json")

let ic_host     = cfg.icecast.host
let ic_port     = cfg.icecast.port
let ic_mount    = cfg.icecast.mount
let ic_username = cfg.icecast.username
let ic_password = cfg.icecast.password

# --- Background music library (recursive scan for mp3/m4a) ---
music_dir = "#{bindir()}/music"
music_playlist =
  request.cue(
    playlist(
      recurse=true,
      pattern="\\.(mp3|m4a)$",
      "#{music_dir}"
    )
  )

# --- Scheduled content: request queue fed by schedule.txt ---
sched_queue = request.queue(id="scheduler")

# --- Jingles / announcements (optional) ---
jingle_dir = "#{bindir()}/jingles"
announce_dir = "#{bindir()}/announcements"

def has_audio(dir) =
  try
    let l = list.filter(fun(f) -> regexp("\\.(mp3|m4a)$").test(f), ls.dir(dir))
    list.length(l) > 0
  catch _ do
    false
  end
end

jingles_src =
  if has_audio(jingle_dir) then
    mksafe(request.cue(playlist(recurse=true, pattern="\\.(mp3|m4a)$", jingle_dir)))
  else
    null()
  end

announcements_src =
  if has_audio(announce_dir) then
    mksafe(request.cue(playlist(recurse=true, pattern="\\.(mp3|m4a)$", announce_dir)))
  else
    null()
  end

# --- Assemble the stream ---
primary = fallback(track_sensitive=false, [sched_queue, music_playlist])

content =
  match jingles_src with
  | null() => primary
  | src => random(weights=[1, 8], [src, primary])
  end

final_content =
  match announcements_src with
  | null() => content
  | src => fallback(track_sensitive=false, [src, content])
  end

radio = normalize(final_content)

# --- Output to Icecast ---
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
