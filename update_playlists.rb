#!/usr/bin/env jruby
# frozen_string_literal: true

require 'sequel'
require 'json'
require 'digest/sha1'
require 'cgi'
require 'time'

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
        episode_limit INTEGER DEFAULT 0,
        opml_import INTEGER DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
    })
    rescue Exception => the_error
    end
  end

  # Migration for databases created before the retention feature: add the
  # per-show episode limit (0 = no limit). ALTER TABLE ... ADD COLUMN with a
  # DEFAULT also sets existing rows to 0.
  unless $db_s[:shows].columns.include?(:episode_limit)
    $db_s.execute(%Q{ALTER TABLE shows ADD COLUMN episode_limit INTEGER DEFAULT 0})
    log("Added shows.episode_limit column (default 0 = no limit)")
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

# Enforce one show's episode limit: keep the `limit` most recently RECORDED
# episodes (created_at descending -- created_at is download/insert time), and
# remove the rest from played.db and from disk. A file still referenced by any
# queue file is skipped and left for a later pass, so a queued or on-air
# episode is never deleted underneath liquidsoap.
def prune_show_episodes(show, limit, dry_run)
  show_guid = show[:guid]
  total = $db_p[:episodes].where(show_guid: show_guid).count
  excess = total - limit
  return 0 if excess <= 0

  keep_guids = $db_p[:episodes]
                 .where(show_guid: show_guid)
                 .order(Sequel.desc(:created_at), :guid)
                 .limit(limit)
                 .select_map(:guid)

  # String.new, not "": the frozen_string_literal pragma freezes string
  # literals, and queued_text is built by mutation (<<).
  queued_text = String.new
  # Guard both queue directories: the active scheduler writes current_queue.txt
  # under "queues", while this script's QUEUE_DIR is "queue". A file referenced
  # by either must not be deleted.
  [QUEUE_DIR, File.join(STORAGE, "queues")].uniq.each do |qdir|
    next unless Dir.exist?(qdir)
    Dir.glob(File.join(qdir, "*.txt")).each do |qf|
      begin
        queued_text << File.read(qf) << "\n"
      rescue Exception => the_error
        log("WARN: prune could not read #{qf}: #{the_error.message}")
      end
    end
  end

  victims = $db_p[:episodes]
              .where(show_guid: show_guid)
              .exclude(guid: keep_guids)
              .order(Sequel.desc(:created_at), :guid)
              .all

  deleted = 0
  freed = 0
  victims.each do |ep|
    lp = ep[:local_path]
    if lp && File.exist?(lp)
      if queued_text.include?(lp)
        log("PRUNE: #{show[:slug]} keeping queued episode: #{ep[:title]}")
        next
      end
      unless dry_run
        begin
          File.delete(lp)
        rescue Exception => the_error
          log("ERROR: prune could not delete #{lp}: #{the_error.message}")
          next
        end
      end
      freed += ep[:file_size_bytes].to_i
    end
    unless dry_run
      $db_p[:episodes].where(guid: ep[:guid]).delete
    end
    deleted += 1
    where = lp ? lp : "(no local file)"
    log("PRUNE: #{show[:slug]} #{dry_run ? 'would delete' : 'deleted'}: #{ep[:title]} (#{where})")
  end

  log("PRUNE: #{show[:slug]} limit=#{limit} total=#{total} #{dry_run ? 'would remove' : 'removed'} #{deleted}, #{freed} bytes #{dry_run ? 'would be ' : ''}freed")
  deleted
end

def prune_all(dry_run)
  pruned = 0
  $db_s[:shows].all.each do |show|
    limit = show[:episode_limit].to_i
    next unless limit > 0
    begin
      pruned += prune_show_episodes(show, limit, dry_run)
    rescue Exception => the_error
      log("ERROR: prune failed for #{show[:slug]}: #{the_error.message}")
    end
  end
  pruned
end

# --set-limit <slug> <n>: set a show's episode_limit. 0 (or any non-positive)
# means no limit. Resolves the show by exact slug first, then by feed_url,
# the same lookup process_show uses. Returns true when the update was made.
def cmd_set_limit(target, raw)
  unless target && raw
    log("ERROR: Usage: update_playlists.rb --set-limit <slug> <n>   (0 = no limit)")
    return false
  end
  unless raw.match?(/\A\d+\z/)
    log("ERROR: episode limit must be a non-negative integer, got: #{raw}")
    return false
  end
  val = raw.to_i

  show = $db_s[:shows].where(slug: target).first
  show ||= $db_s[:shows].where(feed_url: target).first
  if show.nil?
    log("ERROR: Show not found: #{target}")
    return false
  end

  $db_s[:shows].where(guid: show[:guid]).update(episode_limit: val)
  if val > 0
    log("Episode limit for #{show[:slug]} set to #{val} (was #{show[:episode_limit]})")
  else
    log("Episode limit for #{show[:slug]} removed (0 = no limit, was #{show[:episode_limit]})")
  end
  true
end

# --export <file.opml>: write every registered show as a standard OPML 2.0
# subscription list, ordered by slug. The outline format is the one gPodder
# and fetch_podcasts.rb --import-opml read: type="rss" with text, title, and
# xmlUrl, so an export re-imports without surprises. Titles and feed URLs
# are XML-attribute-escaped (CGI.escapeHTML covers &, <, >, and quotes).
# Returns true when the file was written.
def cmd_export(path)
  unless path
    log("ERROR: Usage: update_playlists.rb --export <file.opml>")
    return false
  end

  shows = $db_s[:shows].order(:slug).all
  if shows.empty?
    log("ERROR: No shows registered, nothing to export")
    return false
  end

  begin
    File.open(path, "w") do |f|
      f.puts('<?xml version="1.0" encoding="UTF-8"?>')
      f.puts('<opml version="2.0">')
      f.puts('  <head>')
      f.puts('    <title>Radio show subscriptions</title>')
      f.puts("    <dateCreated>#{Time.now.rfc2822}</dateCreated>")
      f.puts('  </head>')
      f.puts('  <body>')
      shows.each do |show|
        title = CGI.escapeHTML(show[:title].to_s)
        url = CGI.escapeHTML(show[:feed_url].to_s)
        f.puts("    <outline type=\"rss\" text=\"#{title}\" title=\"#{title}\" xmlUrl=\"#{url}\"/>")
      end
      f.puts('  </body>')
      f.puts('</opml>')
    end
  rescue Exception => the_error
    log("ERROR: could not write #{path}: #{the_error.class}: #{the_error.message}")
    return false
  end

  log("Exported #{shows.length} shows to #{path}")
  true
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

  # Episode retention. Runs on every invocation for any show with a configured
  # limit, so the cap holds without anyone remembering to run it. Flags:
  #   --prune          prune only, then exit (no schedule processing)
  #   --prune-dry-run  log what would be deleted, delete nothing
  dry_run = ARGV.delete("--prune-dry-run") ? true : false
  if ARGV.include?("--prune")
    ARGV.delete("--prune")
    prune_all(dry_run)
    return
  end

  # --set-limit <slug> <n>: set a show's episode_limit (0 = no limit) and
  # exit without processing the schedule or running the prune pass. Exit
  # status 0 on success, 1 on any failure, so shell chains can detect errors.
  if ARGV.include?("--set-limit")
    idx = ARGV.index("--set-limit")
    ok = cmd_set_limit(ARGV[idx + 1], ARGV[idx + 2])
    exit(ok ? 0 : 1)
  end

  # --export <file.opml>: write every registered show as a standard OPML 2.0
  # subscription list and exit. Exit status 0 on success, 1 on any failure,
  # matching --set-limit's convention so shell chains can detect errors.
  if ARGV.include?("--export")
    idx = ARGV.index("--export")
    ok = cmd_export(ARGV[idx + 1])
    exit(ok ? 0 : 1)
  end

  prune_all(dry_run)

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
      summary << {slug: show[:slug], title: show[:title], total: total, played: played, unplayed: total - played, limit: show[:episode_limit].to_i}
    end
    puts JSON.pretty_generate(summary)
  end
end

main if $PROGRAM_NAME == __FILE__