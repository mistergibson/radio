#!/usr/bin/env ruby
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
#   stream -> the URL is written verbatim. RUNLENGTH (seconds) is carried in a
#             comment line; liquidsoap plays the live stream until the next
#             scheduled event overwrites the file.
#   show   -> look up the slug in subscriptions.db, find the next unplayed
#             episode in played.db (prefer local_path, fall back to url),
#             mark it played, and write that path/url.
#
# Idempotent: a fire marker prevents re-firing the same entry twice in one
# minute if cron double-runs or the script is invoked manually.

require 'json'
require 'sequel'
require 'fileutils'
require 'time'

SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
CONFIG_PATH = File.join(SCRIPT_DIR, "config.json")
SCHEDULE_FILE = File.join(SCRIPT_DIR, "schedule.txt")
QUEUE_DIR = nil   # derived below
QUEUE_FILE = nil  # derived below
FIRE_MARKER_DIR = nil

CFG = JSON.parse(File.read(CONFIG_PATH))
STORAGE = CFG["storage"]
STATE_DIR = File.join(STORAGE, "state")
SUBS_DB = File.join(STATE_DIR, "subscriptions.db")
PLAYED_DB = File.join(STATE_DIR, "played.db")
LOG_DIR = File.join(STORAGE, "logs")

QUEUE_DIR = File.join(STORAGE, "queues")
QUEUE_FILE = File.join(QUEUE_DIR, "current_queue.txt")
FIRE_MARKER_DIR = File.join(STATE_DIR, "fire_markers")

FileUtils.mkdir_p(QUEUE_DIR)
FileUtils.mkdir_p(FIRE_MARKER_DIR)

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

def open_subs_db
  Sequel.sqlite(SUBS_DB, database_options: { timeout: 5 })
end

def open_played_db
  Sequel.sqlite(PLAYED_DB, database_options: { timeout: 5 })
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

  ep = played_db[:episodes]
        .where(show_guid: show[:guid], played: 0)
        .order(Sequel.desc(:created_at))
        .first

  if ep.nil?
    log("INFO: no unplayed episodes for show '#{slug}' (#{show[:title]})")
    return nil
  end

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

# --- Queue writer --------------------------------------------------------------
# Writes the URI (and optionally a runlength hint) atomically: write to a temp
# file in the same directory, then rename over the target. This prevents
# station.liq from reading a partially-written file.

def write_queue(uri, runlength_sec = nil)
  tmp = "#{QUEUE_FILE}.tmp"
  content = uri
  if runlength_sec && runlength_sec > 0
    content += "\n# runlength=#{runlength_sec}"
  end
  File.write(tmp, content)
  File.rename(tmp, QUEUE_FILE)
  log("QUEUED: #{uri}#{runlength_sec ? " (runlength=#{runlength_sec}s)" : ''}")
end

# --- Main ----------------------------------------------------------------------

def main
  now = Time.now
  log("--- scheduler tick #{now.strftime('%Y-%m-%d %H:%M:%S')} ---")

  unless File.exist?(SCHEDULE_FILE)
    log("ERROR: schedule.txt not found at #{SCHEDULE_FILE}")
    return
  end

  prune_old_markers(now)
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
      write_queue(entry[:target], entry[:runlength])
      mark_fired(key)
      fired_any = true

    when "show"
      uri = resolve_show(entry[:target])
      if uri
        write_queue(uri)
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
