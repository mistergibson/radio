#!/usr/bin/env jruby
# frozen_string_literal: true

require 'sequel'
require 'json'
require 'digest/sha1'

SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
CONFIG_PATH = File.join(SCRIPT_DIR, "config.json")

CFG = JSON.parse(File.read(CONFIG_PATH)) rescue {}
STORAGE = CFG["storage"] || "/mnt/storage/radio"
STATE_DIR = File.join(STORAGE, "state")
LOG_DIR = File.join(STORAGE, "logs")

SUBS_DB   = File.join(STATE_DIR, "subscriptions.db")
PLAYED_DB = File.join(STATE_DIR, "played.db")

QUEUE_DIR = File.join(STORAGE, "queue")
SCHEDULE_FILE = File.join(SCRIPT_DIR, "schedule.txt")

$db_s = Sequel.connect("jdbc:sqlite:" + SUBS_DB)
$db_p = Sequel.connect("jdbc:sqlite:" + PLAYED_DB)

def log(msg)
  puts "[INFO] #{msg}"
end

def ensure_dirs
  [STATE_DIR, LOG_DIR, QUEUE_DIR].each do |d|
    Dir.mkdir(d) unless Dir.exist?(d)
  end
end

# def table_exists?(db, tbl)
#   db[:sqlite_master].where(type: 'table', name: tbl).count > 0
# end

# def table_exists?(db, tbl)
#   db[:sqlite_master].where("type = 'table' AND name = ?", tbl.to_s).count > 0
# end
# def table_exists?(db, tbl)
#   result = db.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", [tbl.to_s]).first
#   result && result.values.first.to_s.to_i > 0
# end
# def table_exists?(db, tbl)
#   db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [tbl.to_s]).fetch.first && true || false
# end
# def table_exists?(db, table_name)
#   result = db.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='#{table_name.to_s}'")
#   count = result.first[0] rescue 0
#   count > 0
# end

def table_exists?(db, table_name)
  result = db.fetch("SELECT COUNT(*) as cnt FROM sqlite_master WHERE type='table' AND name='#{table_name.to_s}'").first
  result && result[:cnt].to_i > 0
end



def ensure_schema
  $db_s.execute("PRAGMA journal_mode=WAL")
  $db_s.execute("PRAGMA busy_timeout=5000")
  $db_p.execute("PRAGMA journal_mode=WAL")
  $db_p.execute("PRAGMA busy_timeout=5000")

  unless table_exists?($db_s, :shows)
    begin
    $db_s.execute(%Q{
      CREATE TABLE shows (
        guid TEXT PRIMARY KEY,
        slug TEXT UNIQUE NOT NULL,
        title TEXT NOT NULL,
        feed_url TEXT NOT NULL,
        archive INTEGER DEFAULT 0,
        opml_import INTEGER DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
    })
    rescue Exception => the_error
    end
  end

  unless table_exists?($db_p, :episodes)
    $db_p.execute(%Q{
      CREATE TABLE episodes (
        guid TEXT PRIMARY KEY,
        show_guid TEXT NOT NULL,
        title TEXT,
        url TEXT,
        duration_seconds REAL DEFAULT 0,
        played INTEGER DEFAULT 0,
        local_path TEXT,
        file_size_bytes INTEGER DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
    })
  end
end

def load_schedule
  return [] unless File.exist?(SCHEDULE_FILE)
  lines = File.readlines(SCHEDULE_FILE)
  entries = []
  lines.each do |raw_line|
    line = raw_line.strip
    next if line.empty? || line.start_with?('#')
    parts = line.split(/\s+/)
    min, hour, dom, mon, dow, type, target = parts[0..6]
    runlength = parts[7] ? parts[7].to_i : nil
    entries << {min: min, hour: hour, dom: dom, mon: mon, dow: dow, type: type, target: target, runlength: runlength}
  end
  entries
end

def find_next_episode(show_guid)
  row = $db_p[:episodes].where(show_guid: show_guid, played: 0).order(:created_at).first
  row
end

def mark_played(ep_guid)
  $db_p[:episodes].where(guid: ep_guid).update(played: 1)
end

def reset_show_episodes(show_guid)
  $db_p[:episodes].where(show_guid: show_guid).update(played: 0)
end

def write_queue_file(filename, uris)
  path = File.join(QUEUE_DIR, filename)
  File.open(path, 'w') do |f|
    uris.each do |uri|
      f.puts(uri)
    end
  end
  log("Queue written: #{path} (#{uris.length} entries)")
end

def build_annotated_uri(duration_seconds, title, uri)
  dur = duration_seconds.to_s
  ttl = title.gsub('"', '\\"').gsub(',', '\\,')
  "annotate:liq_runlength=\"#{dur}\",liq_title=\"#{ttl}\":#{uri}"
end

def process_show(target)
  show = $db_s[:shows].where(slug: target).first
  if show.nil?
    show = $db_s[:shows].where(feed_url: target).first
  end
  if show.nil?
    log("WARN: Show not found: #{target}")
    return
  end

  total = $db_p[:episodes].where(show_guid: show[:guid]).count
  played_count = $db_p[:episodes].where(show_guid: show[:guid], played: 1).count
  unplayed = total - played_count

  if unplayed <= 0
    if total > 0
      log("Resetting exhausted show: #{show[:title]}")
      reset_show_episodes(show[:guid])
      first_ep = $db_p[:episodes].where(show_guid: show[:guid]).order(:created_at).first
      if first_ep
        mark_played(first_ep[:guid])
        uri = first_ep[:local_path] || first_ep[:url]
        annotated = build_annotated_uri(first_ep[:duration_seconds], first_ep[:title], uri)
        write_queue_file("#{show[:slug]}.txt", [annotated])
      else
        log("WARN: No episodes after reset for #{show[:title]}")
      end
    else
      log("WARN: No episodes for show: #{show[:title]}")
    end
    return
  end

  ep = find_next_episode(show[:guid])
  if ep.nil?
    log("WARN: No unplayed episode found for: #{show[:title]}")
    return
  end

  mark_played(ep[:guid])
  uri = ep[:local_path] || ep[:url]
  annotated = build_annotated_uri(ep[:duration_seconds], ep[:title], uri)
  write_queue_file("#{show[:slug]}.txt", [annotated])
  log("Selected: #{show[:title]} -> #{ep[:title]}")
end

def process_stream(target, runlength)
  log("Stream entry: #{target} (runlength=#{runlength})")
  if runlength && runlength > 0
    annotated = "annotate:liq_runlength=\"#{runlength}\":#{target}"
    write_queue_file("#{target.gsub(/[^a-zA-Z0-9]/, '_')}.stream.txt", [annotated])
  else
    log("WARN: Stream entry missing runlength: #{target}")
  end
end

def main
  ensure_dirs
  ensure_schema

  schedule = load_schedule
  if schedule.empty?
    log("No schedule entries found in #{SCHEDULE_FILE}")
    return
  end

  now = Time.now
  processed_shows = {}
  processed_streams = {}

  schedule.each do |entry|
    matches_now = false
    m_min = entry[:min] == '*' || entry[:min].to_i == now.min
    m_hour = entry[:hour] == '*' || entry[:hour].to_i == now.hour
    m_dom = entry[:dom] == '*' || entry[:dom].to_i == now.day
    m_mon = entry[:mon] == '*' || entry[:mon].to_i == now.month
    m_dow = entry[:dow] == '*' || entry[:dow].to_i == now.wday % 7
    matches_now = m_min && m_hour && m_dom && m_mon && m_dow

    next unless matches_now

    case entry[:type]
    when 'show'
      if processed_shows.key?(entry[:target])
        log("Skipping duplicate show: #{entry[:target]}")
        next
      end
      processed_shows[entry[:target]] = true
      process_show(entry[:target])
    when 'stream'
      key = "#{entry[:target]}_#{now.strftime('%Y%m%d%H%M')}"
      if processed_streams.key?(key)
        log("Skipping duplicate stream: #{entry[:target]}")
        next
      end
      processed_streams[key] = true
      process_stream(entry[:target], entry[:runlength])
    else
      log("Unknown schedule type: #{entry[:type]}")
    end
  end

  if ARGV.include?('--json')
    summary = []
    $db_s[:shows].all.each do |show|
      total = $db_p[:episodes].where(show_guid: show[:guid]).count
      played = $db_p[:episodes].where(show_guid: show[:guid], played: 1).count
      summary << {slug: show[:slug], title: show[:title], total: total, played: played, unplayed: total - played}
    end
    puts JSON.pretty_generate(summary)
  end
end

main if $PROGRAM_NAME == __FILE__
