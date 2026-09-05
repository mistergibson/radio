#!/usr/bin/env jruby
# frozen_string_literal: true
#
# update_playlists.rb - Select the next unplayed episode per show and write
# annotated-URI queue files for station.liq to consume.
#
# Reads from played.db (episode records with played flag), writes queue files
# under <storage>/playlists/. Cycles archived shows when all episodes are
# already played.
#
# Usage:
#   ./update_playlists.rb [--json]
#
# Options:
#   --json    Emit a JSON summary of each show's episode counts to stdout.

require "json"
require "sequel"

SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
CONFIG_PATH = File.join(SCRIPT_DIR, "config.json")

def load_config
  raw = File.read(CONFIG_PATH)
  cfg = JSON.parse(raw)
  raise "FATAL: storage missing from config.json" unless cfg["storage"] && !cfg["storage"].to_s.empty?
  cfg
end

CFG = load_config
STORAGE_ROOT = CFG["storage"]
STATE_DIR    = File.join(STORAGE_ROOT, "state")
PLAYLISTS_DIR = File.join(STORAGE_ROOT, "playlists")
LOG_DIR      = File.join(STATE_DIR, "logs")
LOCK_FILE    = File.join(STATE_DIR, "radio.lock")
SUBS_DB_PATH = File.join(STATE_DIR, "subscriptions.db")
EPISODES_DB_PATH = File.join(STATE_DIR, "episodes.db")

[DIRS_TO_CREATE].each do |d|
  Dir.mkdir(d) unless Dir.exist?(d)
end

$log_fh = File.open(File.join(LOG_DIR, "update_playlists.log"), "a")
def log(level, msg)
  ts = Time.now.strftime("%Y-%m-%d %H:%M:%S")
  line = "[#{ts}] [#{level}] #{msg}"
  puts(line)
  $log_fh.write("#{line}\n")
  $log_fh.flush
end

db_subs = Sequel.jdbc("sqlite:", SUBS_DB_PATH)
db_eps  = Sequel.jdbc("sqlite:", EPISODES_DB_PATH)

db_subs.execute("PRAGMA journal_mode=WAL;")
db_eps.execute("PRAGMA journal_mode=WAL;")
db_subs.execute("PRAGMA busy_timeout=5000;")
db_eps.execute("PRAGMA busy_timeout=5000;")

def table_exists?(db, name)
  db[:sqlite_master].where(type: "table", name: name).count > 0
end

def ensure_schema(db, path, label)
  if !table_exists?(db, "shows")
    db.execute <<-SQL
CREATE TABLE IF NOT EXISTS shows (
  guid TEXT PRIMARY KEY,
  slug TEXT UNIQUE NOT NULL,
  title TEXT NOT NULL,
  feed_url TEXT NOT NULL,
  audio_only INTEGER DEFAULT 1,
  archive INTEGER DEFAULT 0,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
    SQL
    log("INFO", "Created 'shows' table in #{label}")
  end

  if !table_exists?(db, "episodes")
    db.execute <<-SQL
CREATE TABLE IF NOT EXISTS episodes (
  guid TEXT PRIMARY KEY,
  show_guid TEXT NOT NULL REFERENCES shows(guid),
  title TEXT,
  enclosure_url TEXT,
  runlength INTEGER DEFAULT 0,
  played INTEGER DEFAULT 0,
  downloaded INTEGER DEFAULT 0,
  local_path TEXT,
  fetched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
    SQL
    log("INFO", "Created 'episodes' table in #{label}")
  end
end

ensure_schema(db_subs, SUBS_DB_PATH, "subscriptions.db")
ensure_schema(db_eps, EPISODES_DB_PATH, "episodes.db")

def acquire_lock!
  @lock_fh = File.new(LOCK_FILE, "a+")
  begin
    @lock_fh.flock(File::LOCK_EX | File::LOCK_NB)
  rescue IOError
    log("WARN", "Another radio process holds the lock; skipping this run.")
    exit 0
  end
end

def release_lock!
  @lock_fh.flock(File::LOCK_UN) if @lock_fh
  @lock_fh.close if @lock_fh
  @lock_fh = nil
end

def make_annotated_uri(ep)
  uri = ep[:local_path] || ep[:enclosure_url]
  rl  = ep[:runlength].to_i
  ttl = ep[:title].to_s.gsub('"', '\\"')
  "annotate:liq_runlength=\"#{rl}\",liq_title=\"#{ttl}\":#{uri}"
end

def select_next_episode(show_guid)
  # Try to find an unplayed episode
  ep = db_eps[:episodes].where(show_guid: show_guid, played: 0).order(:fetched_at.asc).first
  
  if ep.nil?
    # All episodes played — reset all to unplayed, then pick the first
    count = db_eps[:episodes].where(show_guid: show_guid).count
    if count > 0
      db_eps[:episodes].where(show_guid: show_guid).update(played: 0)
      log("INFO", "Reset all episodes for show #{show_guid} to played=0 (cycling)")
      ep = db_eps[:episodes].where(show_guid: show_guid).order(:fetched_at.asc).first
    end
  end
  
  ep
end

def update_show_queue(show)
  slug = show[:slug]
  queue_dir = File.join(PLAYLISTS_DIR, slug)
  Dir.mkdir(queue_dir) unless Dir.exist?(queue_dir)
  
  ep = select_next_episode(show[:guid])
  
  if ep.nil?
    log("WARN", "No episodes available for show '#{slug}'")
    return false
  end
  
  annotated = make_annotated_uri(ep)
  queue_file = File.join(queue_dir, "next.uri")
  File.write(queue_file, "#{annotated}\n")
  
  # Mark as played
  db_eps[:episodes].where(guid: ep[:guid]).update(played: 1)
  
  log("INFO", "Queued episode '#{ep[:title]}' for show '#{slug}' (runlength=#{ep[:runlength]}s)")
  true
end

def update_all
  shows = db_subs[:shows].all
  
  if shows.empty?
    log("INFO", "No shows registered; nothing to do.")
    return
  end
  
  queued_count = 0
  failed_count = 0
  
  shows.each do |show|
    begin
      if update_show_queue(show)
        queued_count += 1
      else
        failed_count += 1
      end
    rescue Exception => e
      failed_count += 1
      log("ERROR", "Failed to update queue for show '#{show[:slug]}': #{e.class} #{e.message}")
    end
  end
  
  log("INFO", "Update complete: #{queued_count} queued, #{failed_count} failed out of #{shows.size} shows")
  
  if ARGV.include?("--json")
    summary = {}
    shows.each do |show|
      total = db_eps[:episodes].where(show_guid: show[:guid]).count
      played = db_eps[:episodes].where(show_guid: show[:guid], played: 1).count
      unplayed = total - played
      summary[show[:slug]] = { total: total, played: played, unplayed: unplayed }
    end
    puts(JSON.pretty_generate(summary))
  end
end

begin
  acquire_lock!
  begin
    update_all
  ensure
    release_lock!
  end
rescue Exception => e
  log("ERROR", "Fatal error: #{e.class} #{e.message}")
  log("ERROR", e.backtrace.first(10).join("\n"))
  exit 1
end

db_subs.disconnect
db_eps.disconnect
$log_fh.close

