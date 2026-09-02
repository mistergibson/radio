#!/usr/bin/env jruby
# frozen_string_literal: true
#
# update_playlists.rb - Select the next unplayed episode per show and write an
# annotated URI queue file for station.liq to consume (JRuby/Sequel variant).
#
# Shares the same exclusive lockfile as fetch_podcasts.rb; skips cleanly if
# the fetcher holds it. Databases run in WAL mode with a busy timeout.

require "sequel"
require "json"
require "logger"
require "time"

ROOT = File.expand_path(File.dirname(__FILE__))
CONFIG_PATH = File.join(ROOT, "config.json")

$state_dir = nil
$subs_db_path = nil
$played_db_path = nil
$podcasts_dir = nil
$logs_dir = nil
$playlists_dir = nil
$lock_file = nil

def load_config
  JSON.parse(File.read(CONFIG_PATH))
end

def init_paths!
  cfg = load_config
  storage = File.realpath(cfg["storage"])
  $state_dir      = File.join(storage, "state")
  $subs_db_path   = File.join($state_dir, "subscriptions.db")
  $played_db_path = File.join($state_dir, "played.db")
  $podcasts_dir   = File.join(storage, "podcasts")
  $logs_dir       = File.join(storage, "logs")
  $playlists_dir  = File.join(storage, "playlists")
  $lock_file      = File.join($state_dir, "radio.lock")
end

$log = Logger.new(STDOUT)
$log.formatter = proc { |msg, _severity, _time, _progname| "#{Time.now} [INFO] #{msg}\n" }

def log_error(msg)
  $log.error(msg)
end

def setup_logging!
  $log.instance_variable_set(:@logdev,
    Logger::LogDevice.new([STDOUT, File.join($logs_dir, "update.log")]))
end

# ---------------------------------------------------------------------------
# Schema: single source of truth, applied idempotently via Sequel.
# ---------------------------------------------------------------------------
SHOWS_COLUMNS = {
  slug:        { type: :string, primary_key: true },
  guid:        { type: :string, null: false, unique: true },
  name:        { type: :string, null: false },
  feed_url:    { type: :string, null: false, unique: true },
  source:      { type: :string, default: "manual" },
  opml_import: { type: :integer, default: 0 },
  archived:    { type: :integer, default: 1 },
  media_class: { type: :string },
  created_at:  { type: :string }
}.freeze

EPISODES_COLUMNS = {
  id:            { type: :integer, primary_key: true, auto_increment: true },
  show_slug:     { type: :string, null: false },
  guid:          { type: :string, null: false },
  title:         { type: :string },
  file_path:     { type: :string },
  enclosure_url: { type: :string },
  runlength:     { type: :integer },
  played:        { type: :integer, default: 0 },
  played_at:     { type: :string }
}.freeze

def tune(db)
  # Plain-SQL pragmas via Database#execute, which works on CRuby and JRuby/JDBC
  # across all modern Sequel versions (the :pragma extension is CRuby-only and
  # db.sql requires Sequel >= 5.42).
  db.execute("PRAGMA journal_mode=WAL;")
  db.execute("PRAGMA busy_timeout=5000;")
end

def connect_subs
  db = Sequel.connect("jdbc:sqlite:#{$subs_db_path}")
  tune(db)
  ensure_schema!(db, :shows, SHOWS_COLUMNS)
  db
end

def connect_played
  db = Sequel.connect("jdbc:sqlite:#{$played_db_path}")
  tune(db)
  ensure_schema!(db, :episodes, EPISODES_COLUMNS)
  unless db.index_exists?(:episodes, [:show_slug, :played])
    db.create_index :episodes, [:show_slug, :played], name: :idx_episodes_show_played
  end
  db
end

def ensure_schema!(db, table, columns)
  unless db.table_exists?(table)
    db.create_table(table) do |t|
      columns.each do |col, opts|
        t.column(col, **opts)
      end
      t.unique_constraint %i[show_slug guid] if table == :episodes
    end
    return
  end
  existing = db.columns(table)
  columns.each do |col, opts|
    next if existing.include?(col)
    db.alter_table(table) { |t| t.add_column(col, **opts) }
  end
end

# ---------------------------------------------------------------------------
# Mutual exclusion via flock on a shared lockfile.
# ---------------------------------------------------------------------------
$lock_fh = nil

def acquire_lock!
  Dir.mkdir($state_dir) unless Dir.exist?($state_dir)
  fh = File.open($lock_file, File::RDWR | File::CREAT, 0o644)
  begin
    fh.flock(File::LOCK_EX | File::LOCK_NB)
  rescue Errno::EACCES, Errno::EAGAIN
    fh.close
    return false
  end
  fh.truncate(0)
  fh.write(Process.pid.to_s)
  fh.rewind
  $lock_fh = fh
  true
end

def release_lock!
  return if $lock_fh.nil?
  begin
    $lock_fh.flock(File::LOCK_UN)
    $lock_fh.close
  ensure
    $lock_fh = nil
  end
end

# ---------------------------------------------------------------------------
# Queue-file generation
# ---------------------------------------------------------------------------
def annotate_uri(runlength, title, uri)
  def esc(v)
    '"' + v.to_s.gsub('"', '\\"') + '"'
  end
  "annotate:liq_runlength=#{esc(runlength)},liq_title=#{esc(title)}:" + uri
end

def select_next_episode(slug, played_db)
  played_db[:episodes]
    .where(show_slug: slug, played: 0)
    .order(:id.asc)
    .limit(1)
    .first
end

def mark_as_played(slug, guid, played_db)
  played_db[:episodes]
    .where(show_slug: slug, guid: guid)
    .update(played: 1, played_at: Time.now.utc.strftime("%Y-%m-%d %H:%M:%S"))
end

def write_queue_file(slug, ep, archived)
  uri = archived ? ep[:file_path] : ep[:enclosure_url]
  return nil if uri.nil? || uri.empty?
  line = annotate_uri(ep[:runlength], ep[:title], uri)
  out = File.join($playlists_dir, "#{slug}.txt")
  File.write(out, line + "\n")
  out
end

def update_all
  subs_db = connect_subs
  played_db = connect_played
  shows = subs_db[:shows].order(:name).all
  updated = 0
  shows.each do |show|
    slug = show[:slug]
    archived = show[:archived] == 1
    ep = select_next_episode(slug, played_db)
    next if ep.nil?
    out = write_queue_file(slug, ep, archived)
    if out.nil?
      $log.warn("No playable URI for #{show[:name]} (#{slug}); skipping.")
      next
    end
    mark_as_played(slug, ep[:guid], played_db)
    updated += 1
    $log.info("Queued #{slug}: #{ep[:title]} -> #{File.basename(out)}")
  end
  subs_db.disconnect
  played_db.disconnect
  $log.info("=== Update complete: #{updated} show(s) queued ===")
end

def json_summary
  subs_db = connect_subs
  played_db = connect_played
  shows = subs_db[:shows].order(:name).all
  result = {}
  shows.each do |show|
    slug = show[:slug]
    total = played_db[:episodes].where(show_slug: slug).count
    unplayed = played_db[:episodes].where(show_slug: slug, played: 0).count
    result[slug] = {
      name: show[:name],
      total: total,
      unplayed: unplayed,
      played: total - unplayed
    }
  end
  subs_db.disconnect
  played_db.disconnect
  puts JSON.pretty_generate(result)
end

def main
  args = ARGV.dup
  json_mode = args.delete("--json")

  init_paths!
  [$state_dir, $logs_dir, $playlists_dir].each do |dir|
    Dir.mkdir(dir) unless Dir.exist?(dir)
  end
  setup_logging!

  if json_mode
    json_summary
  else
    if !acquire_lock!
      $log.info("Another radio process holds the lock; skipping this run.")
      return
    end
    begin
      update_all
    ensure
      release_lock!
    end
  end
end

main if __FILE__ == $PROGRAM_NAME
