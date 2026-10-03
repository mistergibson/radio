# station.liq - Cascadia Digital Collective Radio Automation
# Liquidsoap 2.2.4-1+dev compatible
# Run from /srv/radio so relative paths resolve correctly

settings.log.file.set(false)

# --- Load config ---
# Explicit type annotation required: without it, fields used only in #{...}
# interpolations default to null (see liquidsoap json docs).
let json.parse ({ storage, icecast = { host, port, mount, source_username, source_password } }
                : { storage: string,
                    icecast: { host: string, port: int, mount: string,
                               source_username: string, source_password: string } })
  = file.contents("config.json")

storage_base = storage
music_dir         = "#{storage}/music"
jingles_dir       = "#{storage}/jingles"
announcements_dir = "#{storage}/announcements"
podcasts_dir      = "#{storage}/podcasts"
queue_dir = "#{storage}/queues"

icecast_host = host
icecast_port = port
icecast_mount = mount
icecast_user = source_username
icecast_pass = source_password

print("Config loaded: storage=#{storage_base}, icecast=#{icecast_host}:#{icecast_port}#{icecast_mount}")

# --- Background source: rotate among the featured directories, with 0.5 s
# crossfades between tracks. Each playlist(dir) reads its directory
# recursively, so audio in sub-directories is included automatically.
music_pl         = playlist(music_dir)
jingles_pl       = playlist(jingles_dir)
announcements_pl = playlist(announcements_dir)
podcasts_pl      = playlist(podcasts_dir)

# Rotate among the four directories; transition_length bounds each handoff.
rotating_bg = rotate(transition_length=0.5, [music_pl, jingles_pl, announcements_pl, podcasts_pl])

# Crossfade 0.5 s between consecutive tracks of the rotated stream.
background_music = crossfade(fade_in=0.5, fade_out=0.5, rotating_bg)

# --- Show queue source (reads current_queue.txt each tick) ---
# In 2.2.x the callback must return a request (type ()->request), not null.
# When the queue is empty we return a NON-resolving URI ("noshow:"). Liquidsoap
# fails to resolve it, so this source goes DOWN -- which is exactly what lets
# fallback() drop through to the rotating background music below. (A resolvable
# sentinel like synth: would keep the show source up forever, masking the music.)
def read_queue()
  qf = "#{queue_dir}/current_queue.txt"
  if file.exists(qf) and file.contents(qf) != "" then
    request.create(file.contents(qf))
  else
    request.create("noshow:")
  end
end

show_source = request.dynamic(prefetch=1, read_queue)

# --- Mux: show takes priority, fall back to background music ---
main_out = mksafe(fallback([show_source, background_music]))

# --- Output to Icecast ---
output.icecast(
  %mp3(bitrate=128),
  host=icecast_host,
  port=icecast_port,
  user=icecast_user,
  password=icecast_pass,
  mount=icecast_mount,
  name="Road Unit Radio",
  description="Community radio automation",
  genre="various",
  url="",
  public=true,
  main_out
)
