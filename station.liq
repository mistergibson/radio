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
music_dir = "#{storage}/music"
queue_dir = "#{storage}/queues"

icecast_host = host
icecast_port = port
icecast_mount = mount
icecast_user = source_username
icecast_pass = source_password

print("Config loaded: storage=#{storage_base}, icecast=#{icecast_host}:#{icecast_port}#{icecast_mount}")

# --- Background music playlist (loops forever by default) ---
background_music = playlist(music_dir)

# --- Show queue source (reads current_queue.txt each tick) ---
# In 2.2.x the callback must return a request (type ()->request), not null.
# When the queue is empty we play a short synthesized tone so the source
# stays up without needing an external file.
def read_queue()
  qf = "#{queue_dir}/current_queue.txt"
  if file.exists(qf) and file.contents(qf) != "" then
    request.create(file.contents(qf))
  else
    request.create("synth:shape=sine,frequency=440.,duration=1.")
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
