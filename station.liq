# station.liq - Cascadia Digital Collective Radio Automation
# Liquidsoap 2.2.4-1+dev compatible
# Run from /srv/radio so relative paths resolve correctly
#
# One queue, one primitive. Both kinds of scheduled content go through a single
# request.dynamic reading current_queue.txt:
#   * "show" entries -> a finite episode file (local path or media URL)
#   * "stream" entries -> a continuous live Icecast/Shoutcast mount URL
# The JRuby scheduler writes whichever URI is due into current_queue.txt at its
# scheduled clock time; liquidsoap polls the file each tick and plays it. When
# the file is empty the source goes DOWN and the mux falls through to the
# looping background music.

settings.log.file.set(false)
# Level 3: normal verbosity. (Level 4 was used while hunting the transition
# bug and reverted once the crossfade fix was confirmed live on 15 Oct.)
settings.log.level.set(3)

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

# --- Silence fallback resource ------------------------------------------------
# The empty-queue branch of read_queue returns a request that RESOLVES (a real
# silent file) instead of one that fails. The file lives beside this script;
# station.rb exports RADIO_DIR (its own resolved directory) before exec'ing
# liquidsoap, so no install path is baked in here and the service works
# wherever it is installed.
radio_dir = environment.get(default="", "RADIO_DIR")
silence_uri = "file://#{radio_dir}/silence.mp3"

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

# Rotate among the four directories. NO transition_length and NO transitions:
# both default to a plain hard cut (transition_length defaults to 5.0, which is
# what the outgoing track's "4.94585034014s remaining" was reporting -- rotate
# was composing a ~5s layer transition while the crossfade above it composed a
# 0.5s blend over the SAME boundary, so the two got out of sync and the
# crossfade's buffer went stale). rotate now hands off with a hard cut;
# crossfade is the only operator that blends.
rotating_bg = rotate([music_pl, jingles_pl, announcements_pl, podcasts_pl])

# Crossfade 0.5 s between consecutive tracks of the rotated stream. This is the
# ONLY operator composing transitions; see the note above.
#
# duration=0.5 is the fix for the buffer-emptied collapse. `duration` is NOT the
# fade length -- it is how much audio crossfade buffers IN ADVANCE from each
# track to compute the blend, and it defaults to 5.0. We were fading for 0.5s
# but buffering 5.0s, and the 2.2.4 release notes say plainly that a track
# shorter than the buffered duration is a programming error: all its data gets
# consumed computing the fade-in and none is left, which is exactly the
# "Buffer emptied, buffering needed" collapse in the journal. Sizing the buffer
# to the fade (0.5) means the crossfade only ever holds half a second of each
# track, so it cannot outrun the data.
# `minimum` is deliberately OMITTED. Per the build's own `-h crossfade`,
# `minimum` is a threshold on the CROSS's own duration ("Minimum duration for a
# cross"), and a cross can never exceed `duration` -- so any minimum above 0.5
# here is a bar nothing can clear, and it vetoed EVERY handoff with
# "Not enough data for crossing". The default (-1.) always tries, which is what
# we want: short-track protection is already delivered by duration=0.5 itself,
# since the fade only ever consumes half a second of each track.
background_music = crossfade(fade_in=0.5, fade_out=0.5, duration=0.5, rotating_bg)

# --- Scheduled-content source (reads current_queue.txt each tick) -------------
# Both kinds of scheduled content go through this single request.dynamic:
#   * "show" entries -> a finite episode file (local path or media URL)
#   * "stream" entries -> a continuous live Icecast/Shoutcast mount URL
# The scheduler writes whichever URI is due into current_queue.txt; an empty
# queue makes this source go DOWN so the mux falls through to background.
#
# last_uri remembers the URI this callback last HANDED OUT, so a poll that
# finds the queue file unchanged does not re-queue the same request. It is a
# string ref on purpose: ref : ('a) -> () -> 'a takes its type from the
# initial value, so ref(null) pins to a bare nullable that == cannot compare
# (orderable-type error). ref("") pins to string and compares cleanly.
last_uri = ref("")

def read_queue()
  qf = "#{queue_dir}/current_queue.txt"
  if file.exists(qf) and file.contents(qf) != "" then
    let u = string.trim(file.contents(qf))
    # Always hand out the URI the queue file currently names, and remember it.
    # A duplicate is NOT re-queued here: the poller below decides whether to
    # call fetch() at all, and it only does so when this URI changes. Feeding a
    # request on a duplicate poll was the bug -- fetch() APPENDS to the queue
    # (doc: "Try feeding the queue with a new request"), so a poller that fired
    # every 5s on an unchanged file added one silence request per poll, with
    # nothing draining them (prefetch=0 has no consumer). The source stayed UP
    # behind a pile of silence, so fallback never handed off to background
    # music, and the queued show never played.
    last_uri.set(u)
    request.create(u)
  else
    # Empty queue: return a request that RESOLVES, not one that fails.
    # "noshow:" is an unregistered protocol, so request.create("noshow:")
    # never resolves; a request.dynamic whose callback keeps returning
    # failing requests goes permanently DOWN and stops polling the file --
    # which is why the URI written at 12:00:10 was never seen until a
    # restart. A real silent file resolves through the static "file"
    # protocol, keeps the source UP and polling, and is inaudible, so
    # fallback still prefers a real show the moment one appears.
    if radio_dir == "" then
      print("WARNING: RADIO_DIR is unset; start via station.rb or the silence fallback will not resolve")
    end
    request.create(silence_uri)
  end
end

# prefetch=0: the poller below is the ONLY thing that feeds this source, so
# every callback invocation has exactly one cause and the queue cannot be
# filled by two mechanisms at once (prefetch=1 plus a poller is the "played
# twice" bug).
show_source = request.dynamic(prefetch=0, read_queue)

# --- Re-invocation poller -----------------------------------------------------
# Why this exists: a "stream" entry is captured by ffmpeg and the LOCAL capture
# path is queued while ffmpeg is still writing it, so liquidsoap opens a
# growing file and reads it as an open-ended stream. At the writer's EOF it
# wraps back to byte 0 instead of firing request-finished -- and the dynamic
# callback is only re-invoked on request end, so the NEXT queued URI is never
# pulled. That is the 16:00 capture looping instead of handing off to 17:00.
#
# fetch() re-invokes the callback on demand (confirmed on this build), so a
# recurrent thread calls it on a wall clock and the next queued URI cuts in
# regardless of whether the current capture ever ends. fast=false keeps this
# below request resolution in priority, since fetch() can block.
#
# The poller -- not the callback -- owns the fetch decision. It reads the queue
# file itself and calls fetch() ONLY when the file names a URI different from
# the one already handed out. On a duplicate it does nothing, so no request is
# appended and the queue stays bounded. (fetch() appends; calling it on a timer
# without a consumer is what grew the queue to 50 silence requests.)
poll_interval = 5.
def poll_queue()
  qf = "#{queue_dir}/current_queue.txt"
  if file.exists(qf) and file.contents(qf) != "" then
    let u = string.trim(file.contents(qf))
    if u != last_uri() then
      # ignore(): fetch() returns bool, but an if with no else must be unit.
      # Without this the branch's bool becomes the if's value and the type
      # checker rejects it (Error 5: unit vs bool). ignore converts it.
      ignore(show_source.fetch())
    end
  end
  poll_interval
end
thread.run.recurrent(fast=false, delay=0., poll_queue)

# --- Mux: scheduled content first, then background music ----------------------
# fallback picks the first child that is UP. With the queue empty, show_source
# is down and background_music carries the broadcast. track_sensitive=false is
# what makes a queued show cut in live at its appointed time instead of
# waiting for the current background track to finish.
mux = fallback(track_sensitive=false, [show_source, background_music])

# NO crossfade here. The blender lives INSIDE background_music (above), where
# every transition it composes is a track end it controls. A crossfade placed
# above the fallback was asked to blend layer handoffs it could not control:
# expiry kills the running show mid-frame (a skip, not a track end), and the
# docs warn a crossfade whose track "ends without any warning" may not have
# enough data to compose with. Those half-composed frames are the "bad data"
# that stopped clients. Layer handoffs are hard cuts now, which is exactly how
# live radio beds work; the encoder only ever sees complete, valid frames.
main_out = mksafe(mux)

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
