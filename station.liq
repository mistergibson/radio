# station.liq - Main liquidsoap configuration
# All paths are resolved relative to this file's location.
# Move the whole directory tree and nothing else needs changing.

# -------------------------------------------------------
# Resolve root directory from script location
# -------------------------------------------------------
let ROOT = configure.bindir()

let MUSIC_DIR   = ROOT ^ "/music"
let PODCASTS_DIR = ROOT ^ "/podcasts"
let PLAYLISTS_DIR = ROOT ^ "/playlists"
let SCHEDULE_FILE = ROOT ^ "/schedule.txt"
let CONFIG_FILE   = ROOT ^ "/config.json"

# -------------------------------------------------------
# Load Icecast credentials from config.json
# -------------------------------------------------------
let cfg = json.from_file(CONFIG_FILE)
let ic_host = json.(cfg.icecast.host)
let ic_port = int_of_string(json.(cfg.icecast.port))
let ic_mount = json.(cfg.icecast.mount)
let ic_user  = json.(cfg.icecast.username)
let ic_pass  = json.(cfg.icecast.password)

# -------------------------------------------------------
# Background music source
# -------------------------------------------------------
let music =
  playlist.recursive(
    mode="random",
    duration=3600,
    path=MUSIC_DIR,
    extensions=["mp3", "m4a", "ogg", "flac"]
  )

# -------------------------------------------------------
# Scheduled content via request queue
# -------------------------------------------------------
def q = ref []

def push_request(req) =
  q := req :: (!q)

# Build a show source from its .pls file (written by update_playlists.py)
def show_source(slug) =
  let pls_path = PLAYLISTS_DIR ^ "/" ^ slug ^ ".pls"
  if file.test(pls_path) then
    log("# Playing scheduled show: #{slug}")
    Some(request.create(pls_path))
  else
    log("! No playlist found for show: #{slug}, skipping")
    None
  end

# Parse schedule.txt and register cron-triggered tasks
def load_schedule() =
  try
    if not(file.test(SCHEDULE_FILE)) then
      log("WARNING: schedule.txt not found at #{SCHEDULE_FILE}")
    else
      let lines = file.lines(SCHEDULE_FILE)
      List.iter(fun line ->
        let t = String.strip(line)
        if t != "" && not(String.starts_with(t, "#")) then
          let p = String.split(t, sep=" ")
                     |> List.filter(fun x -> String.strip(x) != "")
          if List.length(p) >= 7 then
            let cron_expr = String.concat(sep=" ", List.take(p, 5))
            let stype     = List.nth(p, 5)
            let target    = List.nth(p, 6)
            match stype with
              | "show" ->
                  cron.add(id=target, cron_expr, fun () ->
                    match show_source(target) with
                      | Some(r) -> push_request r
                      | None    -> ()
                  )
              | "stream" ->
                  let runlen_str =
                    if List.length(p) > 7 then List.nth(p, 7) else "3600"
                  let runlen = int_of_string(runlen_str)
                  cron.add(id=target, cron_expr, fun () ->
                    log("Triggering stream: #{target} (#{runlen}s)")
                    # For external streams, create a request with duration cap
                    let s = single.file(fallback=false, target)
                    push_request(request.create(target))
                  )
              | _ ->
                  log("Unknown schedule type '#{stype}' for target '#{target}', ignoring")
            end
          else
            log("Malformed schedule line (need at least 7 fields): #{t}")
          end
        end
      ) lines
      log("Schedule loaded from #{SCHEDULE_FILE}")
  with e ->
    log("ERROR loading schedule: #{e}")

# Load schedule once at startup
thread.run(at=now(), fun () -> load_schedule())

# -------------------------------------------------------
# Output: scheduled content over background music fallback
# -------------------------------------------------------
output.icecast(
  %mp3(bitrate=128),
  host=ic_host,
  port=ic_port,
  user=ic_user,
  password=ic_pass,
  mount=ic_mount,
  fallback=music,
  request.queue(q)
)
