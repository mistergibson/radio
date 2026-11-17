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
#   shim   -> like show, but fires only when nothing is actually playing.
#             Every queued item records its REAL end (episode duration or
#             capture length) in current_queue.meta alongside the slot end;
#             while that real end is in the future the shim is skipped and
#             retried next minute. Filler fired over a still-open slot is
#             TTL-capped at the remaining slot, so it hands back to background
#             music exactly where the interrupted entry would have.
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
# Sidecar for QUEUE_FILE: two epoch integers separated by a space --
# "<slot_expiry> <actual_end>". slot_expiry is the wall-clock second at which
# the queued item stops airing (the queue is cleared and background music
# resumes); actual_end is the second at which it is expected to STOP PLAYING
# (episode duration or capture length), which is what the shim guard reads.
# Written whenever a URI is queued with a TTL, deleted whenever the queue is
# cleared. Each cron tick checks slot_expiry and clears the queue once
# expired. Legacy files holding a single integer are read as
# actual_end == slot_expiry.
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

    unless %w[show stream shim].include?(type)
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
# Returns [playable, duration_seconds] -- playable is a String (local path or
# remote URL) or nil if nothing is available; duration_seconds is the episode's
# real length from played.db (may be nil), consumed by fire_show for the
# actual_end stamp the shim guard reads. The early nil guards below destructure
# safely: a nil return arrives at the caller as [nil, nil].
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
  log("RESOLVED: show '#{slug}' -> #{playable} (episode: #{ep[:title]}, #{ep[:duration_seconds] || '?'}s)")
  [playable, ep[:duration_seconds]]
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

# ttl_sec: when > 0, stamp QUEUE_META with a slot expiry (now + ttl_sec) so a
# later cron tick clears the queue once the slot is over. When nil/0, leave any
# existing meta untouched (the queue keeps whatever expiry it already had).
# actual_sec: when > 0, stamp the item's real playing end (now + actual_sec)
# alongside the slot expiry; nil records actual_end == slot_expiry.
def write_uri_file(path, uri, ttl_sec = nil, actual_sec = nil)
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
    write_queue_meta(Time.now.to_i + ttl_sec.to_i,
                     actual_sec ? Time.now.to_i + actual_sec.to_i : nil)
  end
end

# Best-effort: expiry bookkeeping must never block a fire.
# Writes "<slot_expiry> <actual_end>"; actual_end defaults to slot_expiry.
def write_queue_meta(slot_expiry, actual_end = nil)
  actual_end = slot_expiry if actual_end.nil?
  tmp = "#{QUEUE_META}.tmp"
  begin
    File.write(tmp, "#{slot_expiry.to_i} #{actual_end.to_i}")
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

# Parse one meta token: integer epoch or a parseable time string.
# nil-safe: an empty meta file yields no tokens at all, and the caller passes
# whatever parts[0] holds.
def parse_meta_token(token)
  return nil unless token
  if token.match?(/\A\d+\z/)
    Time.at(token.to_i)
  else
    Time.parse(token)
  end
end

# Returns [slot_expiry Time, actual_end Time], or [nil, nil] when no (valid)
# meta exists. A legacy single-integer file (written by the scheduler before
# the two-value format) carries NO duration evidence: actual_end reads as
# epoch 0, which the shim guard treats as "unknown -- do not block". Every
# fire under the current scheduler rewrites the meta in the two-value form.
def queue_meta_times
  return [nil, nil] unless File.exist?(QUEUE_META)
  parts = File.read(QUEUE_META).strip.split(/\s+/)
  return [nil, nil] if parts.empty?
  slot   = parse_meta_token(parts[0])
  actual = parts[1] ? parse_meta_token(parts[1]) : Time.at(0)
  [slot, actual]
rescue ArgumentError
  [nil, nil]
end

# Returns the queue slot expiry as a Time, or nil when no (valid) meta exists.
def queue_expiry
  queue_meta_times[0]
end

# Returns the queued item's real playing end as a Time, or nil when unknown.
def queue_actual_end
  queue_meta_times[1]
end

# Lazy expiry check, run at the top of every cron tick: if the queued item is
# past its SLOT end, clear the queue. station.liq's request.dynamic then goes
# fallible and the fallback drops back to background music within ~2s.
# Worst-case overshoot is one cron minute. (The shim guard reads actual_end,
# not this -- a shim may cut in long before the slot expires.)
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
# duration_sec (the episode's real duration from played.db, when known) is
# recorded as the item's actual_end in QUEUE_META -- when it is expected to
# STOP PLAYING. The slot end still governs queue clearing; the actual end is
# what the shim guard reads, so a show that ends before its allotment stops
# blocking shims at its real end rather than at the slot end.
def fire_show(playable, runlength_sec = nil, duration_sec = nil)
  ttl = (runlength_sec && runlength_sec > 0) ? runlength_sec : 4 * 3600
  # Known duration: the item stops playing at fire + min(ttl, duration) --
  # capped at the slot because an episode longer than its slot is cut by the
  # runlength clamp there anyway, so the slot end IS its real playing end.
  # Unknown duration: pass nil, so meta records actual_end == slot_expiry --
  # the CONSERVATIVE reading. The shim then protects the entry until its slot
  # ends instead of guessing that nothing is playing (a shim must never
  # clobber a show that landed on time).
  actual = (duration_sec && duration_sec.to_i > 0) ? [ttl, duration_sec.to_i].min : nil
  write_uri_file(QUEUE_FILE, playable, ttl, actual)
  plays = actual ? "~#{actual}s" : "unknown length, protected to slot end"
  log("QUEUED show: #{playable} (expires in #{ttl}s, plays #{plays})")
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
    # actual_end = dur: the capture stops playing when ffmpeg stops writing,
    # so a shim scheduled inside a stream slot can fill from the capture's
    # real end (the 300s slack belongs to the slot, not to playback).
    write_uri_file(QUEUE_FILE, cap, dur + 300, dur)
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

# Fire a SHIM entry: like a show, but only when nothing is actually playing.
# The guard reads the queue's actual_end (episode duration / capture length),
# NOT the slot expiry: a show or stream inside its slot but already finished
# does NOT block the shim -- that is the whole point (filler when a show ends
# before its allotment). While the item is still actually playing the shim is
# skipped and retried next minute (the caller does not mark the fire marker).
#
# Trust is decided at WRITE time, not read time. A trusted playing-end stamp
# exists whenever the fired item's length was known (episode duration capped
# at the slot, or capture length); the shim blocks while that stamp is in the
# future. A stamp of epoch 0 means NO evidence -- only legacy single-integer
# meta parses that way -- and never blocks, so pre-swap stale entries (e.g. a
# dead URI with background music already airing) let the shim cut in. An
# entry with unknown length records actual_end == slot_expiry, which the
# guard honours: conservative protection, a shim must never clobber a show
# that landed on time.
#
# When the shim fires over an entry whose slot is still open, its TTL is
# capped at the remaining slot, so filler hands back to background music
# exactly where the interrupted entry would have -- and chained shim fires
# stay anchored to that same end, because each reads the already-capped meta.
# With an empty queue the shim fires like a plain show (its own RUNLENGTH, or
# the 4h cap when none is given).
def fire_shim(entry)
  queued = File.exist?(QUEUE_FILE) && !File.read(QUEUE_FILE).strip.empty?
  if queued
    act = queue_actual_end
    if act && act.to_i > 0 && Time.now.to_i < act.to_i
      log("SKIP shim '#{entry[:target]}': queued item still playing until #{act.strftime('%Y-%m-%d %H:%M:%S')}")
      return false
    end
    exp = queue_expiry
    remaining = exp && exp.to_i > Time.now.to_i ? exp.to_i - Time.now.to_i : nil
    eff_runlength = entry[:runlength]
    if remaining
      eff_runlength = remaining if eff_runlength.nil? || eff_runlength <= 0 || eff_runlength > remaining
    end
    log("SHIM: slot open but item finished; filling remaining #{remaining.inspect}s")
    uri, ep_dur = resolve_show(entry[:target])
    if uri
      fire_show(uri, eff_runlength, ep_dur)
      return true
    end
    false
  else
    uri, ep_dur = resolve_show(entry[:target])
    if uri
      fire_show(uri, entry[:runlength], ep_dur)
      true
    else
      false
    end
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
    uri, ep_dur = resolve_show(slug)
    if uri
      fire_show(uri, nil, ep_dur)
      log("[dryfire] queued -- station.liq should pick it up on its next poll")
    else
      log("[dryfire] nothing queued (see WARN above); background music continues")
    end
    return
  end

  # Dev hook: --dryfire-shim SLUG [SECS] runs the exact fire_shim path a
  # scheduled "shim" entry uses, but immediately. Run it with an empty queue to
  # see the fire path; run it while a show is live to see the SKIP guard.
  #   ./run_radio.sh scheduler.rb --dryfire-shim conservation_news 1800
  if ARGV[0] == "--dryfire-shim"
    slug = ARGV[1]
    raise ArgumentError, "--dryfire-shim requires a slug" if slug.nil? || slug.empty?
    log("[dryfire] running shim path now: #{slug}")
    ok = fire_shim({ target: slug, runlength: ARGV[2]&.to_i, raw: "(dryfire-shim #{slug})" })
    if ok
      log("[dryfire] shim queued -- station.liq should pick it up on its next poll")
    else
      log("[dryfire] shim did not fire (see SKIP/WARN above)")
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
      uri, ep_dur = resolve_show(entry[:target])
      if uri
        fire_show(uri, entry[:runlength], ep_dur)
        mark_fired(key)
        fired_any = true
      else
        # No playable episode right now; don't mark fired so we retry next
        # minute (fetch_podcasts may populate new episodes shortly).
        log("DEFERRED: no playable episode yet for '#{entry[:target]}', will retry next minute")
      end

    when "shim"
      if fire_shim(entry)
        mark_fired(key)
        fired_any = true
      else
        # Not fired (queued item still actually playing, or nothing playable
        # yet): don't mark, so the shim is re-evaluated on the next tick.
        log("DEFERRED: shim '#{entry[:target]}' did not fire this tick, will retry next minute")
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
