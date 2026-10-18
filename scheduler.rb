#!/usr/bin/env jruby
# scheduler.rb - Clock-driven show/stream scheduler for the radio automation.
#
# Designed to run every minute from cron as the liquidsoap user:
#   * * * * * cd /srv/radio && ./run_radio.sh scheduler.rb >> /mnt/storage/radio/logs/scheduler_cron.log 2>&1
#
# Reads schedule.txt (cron-style: min hour dom mon dow TYPE TARGET [RUNLENGTH]),
# matches entries against the current time, and writes the resolved URI into
# <storage>/queues/current_queue.txt so station.liq picks it up within ~2s.
#
# Resolution rules:
#   stream -> ffmpeg captures the live URL to a finite MP3 in captures/ for
#             RUNLENGTH seconds (default 3600) and that LOCAL path is queued.
#   show   -> look up the slug in subscriptions.db, find the next unplayed
#             episode in played.db (prefer local_path, fall back to url),
#             mark it played, and write that path/url.
#
# Expiry: each queued item gets an end time in queues/current_queue.meta
# (RUNLENGTH for shows, capped at 4h without one; RUNLENGTH+300s for stream
# captures). Every cron tick clears current_queue.txt once its item has
# expired, so background music resumes and nothing loops.
#
# Idempotent: a fire marker prevents re-firing the same entry twice in one
# minute if cron double-runs or the script is invoked manually.

require 'json'
require 'sequel'
require 'fileutils'
require 'time'
require 'uri'

SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
CONFIG_PATH = File.join(SCRIPT_DIR, "config.json")
SCHEDULE_FILE = File.join(SCRIPT_DIR, "schedule.txt")

CFG = JSON.parse(File.read(CONFIG_PATH))
STORAGE = CFG["storage"]
STATE_DIR = File.join(STORAGE, "state")
SUBS_DB = File.join(STATE_DIR, "subscriptions.db")
PLAYED_DB = File.join(STATE_DIR, "played.db")
LOG_DIR = File.join(STORAGE, "logs")

QUEUE_DIR = File.join(STORAGE, "queues")
# Single queue file, consumed by one request.dynamic in station.liq. Both show
# and stream entries write their URI here; whichever is due overwrites it.
QUEUE_FILE      = File.join(QUEUE_DIR, "current_queue.txt")
# Sidecar for QUEUE_FILE: a single epoch integer = the wall-clock second at
# which the queued item stops airing. Written whenever a URI is queued with a
# TTL, deleted whenever the queue is cleared. Each cron tick checks it and
# clears the queue once expired, so a finished episode never replays and
# background music resumes on its own.
QUEUE_META      = File.join(QUEUE_DIR, "current_queue.meta")
FIRE_MARKER_DIR = File.join(STATE_DIR, "fire_markers")
# Live-capture output dir: ffmpeg writes scheduled stream slots here as finite
# MP3s that station.liq plays like any other local file.
CAPTURE_DIR = File.join(STORAGE, "captures")

# Create dirs and make them world-writable-ish (0775) so the cron-run process
# can write into them even though the installer's chown ran before queues/ existed.
FileUtils.mkdir_p(QUEUE_DIR)
FileUtils.mkdir_p(FIRE_MARKER_DIR)
FileUtils.mkdir_p(CAPTURE_DIR)
begin
  FileUtils.chmod(0o775, QUEUE_DIR)
  FileUtils.chmod(0o775, FIRE_MARKER_DIR)
  FileUtils.chmod(0o775, CAPTURE_DIR)
rescue => e
  log("WARN: could not chmod queue/fire-marker/capture dirs: #{e.message}")
end

def log(msg)
  puts "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')} #{msg}"
end

# --- Cron field matching ------------------------------------------------------
# Fields: min (0-59), hour (0-23), dom (1-31), mon (1-12), dow (0-6, Sun=0).
# Supports: "*", "N", "A-B", "*/S", and comma lists of any of those.

def field_matches?(field, value)
  return true if field == "*"

  field.split(",").any? do |part|
    if (m = part.match(/\A\*\/(\d+)\z/))
      value % m[1].to_i == 0
    elsif (m = part.match(/\A(\d+)-(\d+)\z/))
      lo, hi = m[1].to_i, m[2].to_i
      value >= lo && value <= hi
    elsif part.match?(/\A\d+\z/)
      part.to_i == value
    else
      false
    end
  end
end

def entry_matches_now?(entry, now)
  min_f, hour_f, dom_f, mon_f, dow_f = entry[:fields]
  field_matches?(min_f, now.min) &&
    field_matches?(hour_f, now.hour) &&
    field_matches?(dom_f, now.day) &&
    field_matches?(mon_f, now.month) &&
    field_matches?(dow_f, now.wday)
end

# --- Schedule parsing ---------------------------------------------------------
# Format: min hour dom mon dow TYPE TARGET [RUNLENGTH_SECONDS]
# Lines starting with # and blank lines are ignored.

def parse_schedule(path)
  entries = []
  File.readlines(path).each do |raw|
    line = raw.strip
    next if line.empty? || line.start_with?("#")

    parts = line.split(/\s+/)
    next if parts.length < 6

    fields = parts[0..4]
    type   = parts[5].downcase
    target = parts[6]
    runlength = parts[7]&.to_i

    unless %w[show stream].include?(type)
      log("WARN: unknown TYPE '#{type}' in line: #{line}")
      next
    end

    entries << {
      fields:    fields,
      type:      type,
      target:    target,
      runlength: runlength,
      raw:       line
    }
  end
  entries
end

# --- Fire markers (idempotency) -----------------------------------------------
# Marker filename encodes date + entry index so each entry fires at most once
# per calendar minute. Old markers (>1 day) are pruned on each run.

def fire_marker_key(entry_index, now)
  "#{now.strftime('%Y%m%d%H%M')}_#{entry_index}"
end

def already_fired?(key)
  File.exist?(File.join(FIRE_MARKER_DIR, key))
end

def mark_fired(key)
  File.write(File.join(FIRE_MARKER_DIR, key), Time.now.iso8601)
end

def prune_old_markers(now)
  cutoff = now - 86_400
  Dir.glob(File.join(FIRE_MARKER_DIR, "*")).each do |f|
    begin
      File.delete(f) if File.mtime(f) < cutoff
    rescue => e
      log("WARN: could not prune marker #{f}: #{e.message}")
    end
  end
end

# --- Database helpers ----------------------------------------------------------

# JRuby: Sequel.sqlite() loads the CRuby-only 'sqlite3' gem and raises
# AdapterNotFound. Use the JDBC form exactly as fetch_podcasts.rb does
# (verified-working there), and set PRAGMAs via Database#execute.
def open_subs_db
  db = Sequel.connect("jdbc:sqlite:" + SUBS_DB)
  db.execute("PRAGMA journal_mode=WAL;")
  db.execute("PRAGMA busy_timeout=5000;")
  db.execute("PRAGMA foreign_keys=OFF;")
  db
end

def open_played_db
  db = Sequel.connect("jdbc:sqlite:" + PLAYED_DB)
  db.execute("PRAGMA journal_mode=WAL;")
  db.execute("PRAGMA busy_timeout=5000;")
  db.execute("PRAGMA foreign_keys=OFF;")
  db
end

# Resolve a show slug to the next unplayed episode's playable path/url.
# Returns a String (local path or remote URL) or nil if nothing is available.
def resolve_show(slug)
  subs_db = open_subs_db
  played_db = open_played_db

  show = subs_db[:shows].where(slug: slug).first
  if show.nil?
    log("WARN: show slug '#{slug}' not found in subscriptions.db")
    return nil
  end

  total_eps   = played_db[:episodes].where(show_guid: show[:guid]).count
  unplayed_ep = played_db[:episodes]
                   .where(show_guid: show[:guid], played: 0)
                   .order(Sequel.desc(:created_at))
                   .first

  if unplayed_ep.nil?
    # Distinguish the two failure modes so a silent "no audio" is diagnosable:
    #   * zero episodes at all  -> fetch never populated this show's feed
    #   * episodes but all played -> archive-cycle reset isn't running
    if total_eps.zero?
      log("WARN: show '#{slug}' (#{show[:title]}) has ZERO episodes in played.db; run fetch_podcasts.rb --fetch-all to populate it")
    else
      log("WARN: show '#{slug}' (#{show[:title]}) has #{total_eps} episode(s) but ALL are marked played; nothing to queue until new episodes arrive or flags reset")
    end
    return nil
  end

  ep = unplayed_ep

  playable = ep[:local_path] || ep[:url]
  if playable.nil? || playable.to_s.strip.empty?
    log("WARN: episode #{ep[:guid]} for '#{slug}' has neither local_path nor url")
    return nil
  end

  # Mark as played atomically before returning, so a crash mid-fire doesn't
  # cause a double-play on the next run.
  played_db[:episodes].where(guid: ep[:guid]).update(played: 1)
  log("RESOLVED: show '#{slug}' -> #{playable} (episode: #{ep[:title]})")
  playable
ensure
  subs_db&.disconnect
  played_db&.disconnect
end

# --- Queue writer ------------------------------------------------------------
# The single queue file must contain ONLY the bare URI, nothing else. station.liq
# trims whitespace before handing it to request.create, but a second line would
# still corrupt the URI, so we keep it to exactly one token.
# Atomic write: temp file in the same dir, then rename over the target so
# station.liq never reads a partially-written file.

# ttl_sec: when > 0, stamp QUEUE_META with an expiry time (now + ttl_sec) so a
# later cron tick clears the queue once the slot is over. When nil/0, leave any
# existing meta untouched (the queue keeps whatever expiry it already had).
def write_uri_file(path, uri, ttl_sec = nil)
  tmp = "#{path}.tmp"
  begin
    File.write(tmp, uri)
    File.rename(tmp, path)
  rescue Errno::EACCES => e
    log("WARN: atomic write to #{path} blocked (#{e.message}); falling back to direct write")
    File.write(path, uri)
    File.chmod(0o664, path) if File.exist?(path)
  ensure
    File.delete(tmp) if File.exist?(tmp)
  end
  if ttl_sec && ttl_sec.to_i > 0
    write_queue_meta(Time.now.to_i + ttl_sec.to_i)
  end
end

# Best-effort: expiry bookkeeping must never block a fire.
def write_queue_meta(epoch)
  tmp = "#{QUEUE_META}.tmp"
  begin
    File.write(tmp, epoch.to_i.to_s)
    File.rename(tmp, QUEUE_META)
  rescue => e
    log("WARN: could not write queue expiry meta: #{e.message}; queue will persist until next overwrite")
  ensure
    begin
      File.delete(tmp) if File.exist?(tmp)
    rescue StandardError
      nil
    end
  end
end

# Returns the queue expiry as a Time, or nil when no (valid) meta exists.
def queue_expiry
  return nil unless File.exist?(QUEUE_META)
  raw = File.read(QUEUE_META).strip
  if raw.match?(/\A\d+\z/)
    Time.at(raw.to_i)
  else
    Time.parse(raw)
  end
rescue ArgumentError
  nil
end

# Lazy expiry check, run at the top of every cron tick: if the queued item is
# past its end time, clear the queue. station.liq's request.dynamic then goes
# fallible and the fallback drops back to background music within ~2s.
# Worst-case overshoot is one cron minute.
def expire_queue_if_due(now)
  exp = queue_expiry
  return if exp.nil?
  return if now.to_i < exp.to_i
  log("EXPIRED: queued item past its end time (#{exp.strftime('%Y-%m-%d %H:%M:%S')}); clearing queue -> background music")
  clear_uri_file(QUEUE_FILE)
end

def clear_uri_file(path)
  begin
    File.delete(QUEUE_META) if File.exist?(QUEUE_META)
  rescue => e
    log("WARN: could not delete #{QUEUE_META}: #{e.message}")
  end
  return unless File.exist?(path)
  begin
    File.write("#{path}.empty", "")
    File.rename("#{path}.empty", path)
  rescue => e
    log("WARN: could not clear #{path}: #{e.message}")
  end
end

# Fire a SHOW entry: put the episode path/url into the single queue file.
# runlength_sec (from schedule.txt, when given) becomes the queue TTL so the
# entry self-expires at the end of its slot; without one we cap at 4 hours so
# even an unbounded show eventually hands back to background music.
def fire_show(playable, runlength_sec = nil)
  ttl = (runlength_sec && runlength_sec > 0) ? runlength_sec : 4 * 3600
  write_uri_file(QUEUE_FILE, playable, ttl)
  log("QUEUED show: #{playable} (expires in #{ttl}s)")
end

# Build a deterministic capture path from the stream URL + fire time so we can
# tell captures apart and avoid clobbering a still-playing one.
def capture_path_for(url, now)
  safe_host = URI.parse(url).host.to_s.gsub(/[^a-zA-Z0-9.-]/, "_")
  ts        = now.strftime("%Y%m%d_%H%M%S")
  File.join(CAPTURE_DIR, "#{safe_host}_#{ts}.mp3")
end

# Prune captured MP3s older than 2 days so the dir doesn't grow unbounded.
def prune_old_captures(now)
  cutoff = now - 172_800 # 2 days
  Dir.glob(File.join(CAPTURE_DIR, "*.mp3")).each do |f|
    begin
      File.delete(f) if File.mtime(f) < cutoff
    rescue => e
      log("WARN: could not prune capture #{f}: #{e.message}")
    end
  end
end

# Fire a STREAM entry by capturing it locally with ffmpeg, then queuing the
# LOCAL PATH (not the live URL). This sidesteps liquidsoap's inability to relay
# an infinite Icecast mount: station.liq just plays a finite MP3 like any show.
#   * ffmpeg runs in the background, stops after RUNLENGTH seconds (-t).
#   * If no runlength is given, default to 3600s (1h) so the capture is bounded.
#   * We wait ~5s for ffmpeg to actually start writing before queuing, so
#     station.liq picks up a real (non-empty) file. If ffmpeg fails to start,
#     we fall back to queuing nothing (background music carries the slot).
def fire_stream(url, runlength_sec = nil)
  dur = (runlength_sec && runlength_sec > 0) ? runlength_sec : 3600
  cap = capture_path_for(url, Time.now)

  # JRuby's native spawn launcher does NOT accept an Array command combined
  # with a redirect hash (raises "wrong first argument"), and it does not
  # reliably accept open IO objects as redirect values ("wrong exec redirect").
  # The documented-working form on JRuby is: a SINGLE shell String for the
  # command, plus plain FILENAME strings for :out/:err. We quote every path
  # and the URL so shell word-splitting can't break them.
  sh_cmd = %(ffmpeg -hide_banner -loglevel error -i "#{url}" -t #{dur} -acodec libmp3lame -b:a 128k -y "#{cap}")
  fflog  = "#{cap}.fflog"
  pid    = spawn(sh_cmd, out: fflog, err: fflog)
  log("STREAM CAPTURE started: #{url} -> #{cap} (pid=#{pid}, dur=#{dur}s)")

  # Give ffmpeg a moment to open the input and start writing. We judge success
  # purely by whether the capture file has real bytes in it -- that's the actual
  # signal station.liq needs. (Process.waitpid2 with WNOHANG returns nil on
  # JRuby for a freshly spawned child, so we don't use it for liveness.)
  sleep 5
  size = File.exist?(cap) ? File.size(cap) : 0

  if size > 0
    # TTL = capture length + 5 min slack: ffmpeg stops writing after dur, and
    # the queue self-clears shortly after the capture has finished playing.
    write_uri_file(QUEUE_FILE, cap, dur + 300)
    log("QUEUED stream capture: #{cap} (size=#{size} bytes so far, expires in #{dur + 300}s)")
  else
    # ffmpeg wrote nothing within 5s -- clear the queue so background music
    # carries the slot instead of liquidsoap replaying a stale/broken URI.
    log("WARN: capture not ready (size=#{size}); clearing queue -> background music")
    clear_uri_file(QUEUE_FILE)
    ff_err = File.read("#{cap}.fflog") rescue "<no log>"
    log("ffmpeg stderr: #{ff_err.strip[0, 400]}")
  end
end

# --- Main ----------------------------------------------------------------------

def main
  now = Time.now

  # Lazy expiry first: whatever was queued earlier stops airing at its slot
  # end (or the 4h show cap / capture+5min stream cap) without needing a new
  # scheduled event to overwrite it.
  expire_queue_if_due(now)

  # Dev hook: --dryfire-stream URL [SECS] fires one stream capture immediately,
  # bypassing the clock match. Lets us test the ffmpeg-capture path on demand
  # instead of waiting for a scheduled minute. Example:
  #   ./run_radio.sh scheduler.rb --dryfire-stream "https://streams.kpfa.org:8443/kpfa" 300
  if ARGV[0] == "--dryfire-stream"
    url = ARGV[1]
    secs = ARGV[2]&.to_i
    raise ArgumentError, "--dryfire-stream requires a URL" if url.nil? || url.empty?
    log("[dryfire] triggering stream capture now: #{url} (#{secs || 3600}s)")
    fire_stream(url, secs)
    log("[dryfire] done.")
    return
  end

  # Dev hook: --dryfire-show SLUG runs the exact same resolve_show -> fire_show
  # path a scheduled "show" entry uses, but immediately, without waiting for the
  # clock match. Marks the chosen episode played=1 just like a real fire.
  #   ./run_radio.sh scheduler.rb --dryfire-show the_history_of_rome
  if ARGV[0] == "--dryfire-show"
    slug = ARGV[1]
    raise ArgumentError, "--dryfire-show requires a slug" if slug.nil? || slug.empty?
    log("[dryfire] resolving show now: #{slug}")
    uri = resolve_show(slug)
    if uri
      fire_show(uri)
      log("[dryfire] queued -- station.liq should pick it up on its next poll")
    else
      log("[dryfire] nothing queued (see WARN above); background music continues")
    end
    return
  end

  log("--- scheduler tick #{now.strftime('%Y-%m-%d %H:%M:%S')} ---")

  unless File.exist?(SCHEDULE_FILE)
    log("ERROR: schedule.txt not found at #{SCHEDULE_FILE}")
    return
  end

  prune_old_markers(now)
  prune_old_captures(now)
  entries = parse_schedule(SCHEDULE_FILE)
  log("Loaded #{entries.length} schedule entries")

  fired_any = false
  entries.each_with_index do |entry, idx|
    unless entry_matches_now?(entry, now)
      next
    end

    key = fire_marker_key(idx, now)
    if already_fired?(key)
      log("SKIP (already fired this minute): #{entry[:raw]}")
      next
    end

    log("MATCH: #{entry[:raw]}")

    case entry[:type]
    when "stream"
      fire_stream(entry[:target], entry[:runlength])
      mark_fired(key)
      fired_any = true

    when "show"
      uri = resolve_show(entry[:target])
      if uri
        fire_show(uri, entry[:runlength])
        mark_fired(key)
        fired_any = true
      else
        # No playable episode right now; don't mark fired so we retry next
        # minute (fetch_podcasts may populate new episodes shortly).
        log("DEFERRED: no playable episode yet for '#{entry[:target]}', will retry next minute")
      end
    end
  end

  log(fired_any ? "--- tick complete (fired) ---" : "--- tick complete (no matches) ---")
end

begin
  main
rescue => e
  log("ERROR: #{e.class}: #{e.message}")
  log(e.backtrace.first(5).join("\n"))
  exit 1
end
