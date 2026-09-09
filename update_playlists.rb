#!/usr/bin/env jruby
# frozen_string_literal: true
#
# update_playlists.rb - Select next unplayed episode per show and write queue files
#
# For each show in subscriptions.db:
#   1. Count total/unplayed episodes in played.db
#   2. If all played (and archive=0): reset all to played=0, pick first, mark played=1
#   3. If unplayed > 0: pick one at random, mark played=1
#   4. Write <storage>/queue/<slug>.txt with annotated URI or "SKIP"
#
# Usage:
#   ./update_playlists.rb [--json]

require "sequel"
require "jdbc/sqlite3"
require "digest/sha1"
require "fileutils"
require "json"

SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
CONFIG_PATH = File.join(SCRIPT_DIR, "config.json")

def load_config
  raw = File.read(CONFIG_PATH)
  cfg = JSON.parse(raw)
  storage = cfg["storage"].to_s.strip
  raise "Missing 'storage' in config.json" if storage.empty?
  {
    storage:        storage,
    icecast_port:   cfg.dig("icecast", "port").to_i,
    mount_point:    cfg.dig("icecast", "mount_point").to_s,
    source_user:    cfg.dig("icecast", "source_username").to_s,
    source_pass:    cfg.dig("icecast", "source_password").to_s,
    gpodder_host:   cfg.dig("gpodder", "host").to_s,
    gpodder_user:   cfg.dig("gpodder", "username").to_s,
    gpodder_pass:   cfg.dig("gpodder", "password").to_s,
    gpodder_device: cfg.dig("gpodder", "device_id").to_s,
    gpodder_enable: cfg.dig("gpodder", "enable") == true
  }
end

CFG       = load_config
STATE_DIR = File.join(CFG[:storage], "state")
QUEUE_DIR = File.join(CFG[:storage], "queue")
LOG_DIR   = File.join(CFG[:storage], "logs")
SUBS_DB   = File.join(STATE_DIR, "subscriptions.db")
PLAYED_DB = File.join(STATE_DIR, "played.db")

MEDIA_DIRS = %w[music podcasts jingles announcements]
MEDIA_DIRS.each do |d|
  FileUtils.mkdir_p(File.join(CFG[:storage], d))
end
FileUtils.mkdir_p(STATE_DIR)
FileUtils.mkdir_p(QUEUE_DIR)
FileUtils.mkdir_p(LOG_DIR)

LOG_FILE = File.join(LOG_DIR, "update_playlists.log")
$log_fh = File.open(LOG_FILE, "a+")

def log(level, msg)
  ts = Time.now.strftime("%Y-%m-%d %H:%M:%S")
  line = "[#{ts}] [#{level}] #{msg}"
  $stdout.puts(line)
  $log_fh.write(line + "\n")
  $log_fh.flush
rescue Exception => e
  # Log file may be unavailable; fall back to stdout only
  $stdout.puts("[WARN] Could not write log: #{e.message}")
end

def table_exists?(db, tbl)
  db[:sqlite_master].where(type: "table", name: tbl).count > 0
rescue Exception => e
  false
end

def ensure_schema(db_subs, db_eps)
  unless table_exists?(db_subs, :shows)
    db_subs.execute <<-SQL
      CREATE TABLE IF NOT EXISTS shows (
        guid TEXT PRIMARY KEY,
        slug TEXT UNIQUE NOT NULL,
        title TEXT NOT NULL,
        feed_url TEXT NOT NULL,
        description TEXT DEFAULT '',
        category TEXT DEFAULT '',
        audio_only INTEGER DEFAULT 1,
        archive INTEGER DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    SQL
  end
  unless table_exists?(db_eps, :episodes)
    db_eps.execute <<-SQL
      CREATE TABLE IF NOT EXISTS episodes (
        guid TEXT PRIMARY KEY,
        show_guid TEXT NOT NULL,
        title TEXT NOT NULL,
        enclosure_url TEXT NOT NULL,
        enclosure_type TEXT DEFAULT '',
        duration_sec INTEGER DEFAULT 0,
        pub_date TEXT DEFAULT '',
        local_path TEXT DEFAULT '',
        played INTEGER DEFAULT 0,
        downloaded INTEGER DEFAULT 0,
        fetched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    SQL
  end
end

$stdout.sync = true

begin
  db_subs = Sequel.connect("jdbc:sqlite:" + SUBS_DB)
  db_eps  = Sequel.connect("jdbc:sqlite:" + PLAYED_DB)
ensure_schema(db_subs, db_eps)

  json_output = ARGV.include?("--json")
  results = []

  shows = db_subs[:shows].all
  if shows.empty?
    log("INFO", "No shows registered.")
  else
    shows.each do |show|
      slug     = show[:slug]
      show_g   = show[:guid]
      archive  = show[:archive] || 0

      total    = db_eps[:episodes].where(show_guid: show_g).count
      unplayed = db_eps[:episodes].where(show_guid: show_g, played: 0).count

      chosen = nil

      if total == 0
        log("INFO", "#{slug}: no episodes yet, SKIP")
      elsif unplayed == 0 && archive == 0
        # Cycle: reset all to unplayed, pick first, mark played
        db_eps[:episodes].where(show_guid: show_g).update(played: 0)
        ep = db_eps[:episodes].where(show_guid: show_g).order(:pub_date.asc).first
        if ep
          db_eps[:episodes].where(guid: ep[:guid]).update(played: 1)
          chosen = ep
          log("INFO", "#{slug}: cycled, picked '#{ep[:title]}'")
        end
      elsif unplayed > 0
        eps = db_eps[:episodes].where(show_guid: show_g, played: 0).all
        ep  = eps.sample
        db_eps[:episodes].where(guid: ep[:guid]).update(played: 1)
        chosen = ep
        log("INFO", "#{slug}: picked '#{ep[:title]}' (#{unplayed} unplayed)")
      end

      qf = File.join(QUEUE_DIR, "#{slug}.txt")
      if chosen
        dur   = chosen[:duration_sec].to_i
        annot = "annotate:liq_runlength=\"#{dur}\",liq_title=\"#{chosen[:title]}\""
        uri   = chosen[:enclosure_url]
        File.write(qf, "#{annot}:#{uri}\n")
      else
        File.write(qf, "SKIP\n")
      end

      results << {
        "slug"     => slug,
        "total"    => total,
        "unplayed" => unplayed,
        "picked"   => chosen ? chosen[:title] : nil
      }
    end
  end

  if json_output
    puts JSON.pretty_generate(results)
  end

  log("INFO", "Done. Processed #{results.size} shows.")

  begin
    db_subs.disconnect
  rescue Exception => e
    log("WARN", "Error disconnecting subs: #{e.message}")
  end
  begin
    db_eps.disconnect
  rescue Exception => e
    log("WARN", "Error disconnecting eps: #{e.message}")
  end
  $log_fh.close

rescue Interrupt
  log("INFO", "Interrupted.")
  exit 1
rescue Exception => e
  log("ERROR", "#{e.class}: #{e.message}")
  log("ERROR", e.backtrace.first(5).join("\n"))
  exit 1
end

main if __FILE__ == $PROGRAM_NAME

