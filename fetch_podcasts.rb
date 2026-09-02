#!/usr/bin/env jruby
# frozen_string_literal: true
#
# fetch_podcasts.rb - Podcast subscription management and episode fetching
# for the liquidsoap radio automation stack (JRuby/Sequel variant).
#
# Concurrency: exclusive non-blocking File.lock (state/radio.lock) shared with
# update_playlists.rb; skips cleanly if the sibling holds it. Databases run in
# WAL mode with a busy timeout as a second safety net.
#
# Politeness: audio/video verdict cached in shows.media_class; gpodder OPML
# pull uses bounded retry with exponential backoff + jitter.

require "sequel"
require "net/http"
require "openssl"
require "json"
require "logger"
require "time"
require "fileutils"
require "cgi"
require "base64"
require "securerandom"
require "rexml/document"

ROOT = File.expand_path(File.dirname(__FILE__))
CONFIG_PATH = File.join(ROOT, "config.json")

AUDIO_EXTS = [".mp3", ".m4a"].freeze
VIDEO_EXTS = [".mp4", ".mov", ".avi", ".webm", ".mkv"].freeze

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
    Logger::LogDevice.new([STDOUT, File.join($logs_dir, "fetch.log")]))
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
# Helpers
# ---------------------------------------------------------------------------
def slugify(name)
  s = name.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
  s = "show" if s.empty?
  s[0, 60]
end

def gen_uuid
  SecureRandom.uuid
end

def classify_feed(entries)
  return "unknown" if entries.nil? || entries.empty?
  entry = entries.first
  enclosures = entry[:enclosures] || []
  return "unknown" if enclosures.empty?
  mime = (enclosures.first[:type] || "").downcase
  return "audio" if mime.start_with?("audio/")
  return "video" if mime.start_with?("video/")
  url = (enclosures.first[:href] || "").downcase
  AUDIO_EXTS.any? { |ext| url.end_with?(ext) } && return "audio"
  VIDEO_EXTS.any? { |ext| url.end_with?(ext) } && return "video"
  "unknown"
end

def get_media_class(db, slug)
  row = db[:shows].where(slug: slug).first
  row ? row[:media_class] : nil
end

def set_media_class(db, slug, cls)
  db[:shows].where(slug: slug).update(media_class: cls)
end

# ---------------------------------------------------------------------------
# Feed parsing (Net::HTTP + REXML)
# ---------------------------------------------------------------------------
def fetch_feed(feed_url)
  uri = URI.parse(feed_url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.timeout = 60
  resp = http.request(Net::HTTP::Get.new(uri.request_uri))
  return nil unless resp.is_a?(Net::HTTPSuccess)

  doc = REXML::Document.new(resp.body)
  channel = doc.elements["//channel"]
  return nil if channel.nil?

  title = channel.elements["title"]&.text
  entries = []
  channel.get_elements("./item").each do |item|
    link_el  = item.elements["link"]
    title_el = item.elements["title"]
    guid_el  = item.elements["guid"]
    dur_el   = item.elements["media:duration"] || item.elements["itunes:duration"]
    enc_el   = item.elements["enclosure"]

    enclosures = []
    if enc_el
      enclosures << {
        href:   enc_el.attributes["url"],
        type:   enc_el.attributes["type"],
        length: enc_el.attributes["length"]
      }
    end

    entries << {
      link:   link_el&.text,
      title:  title_el&.text,
      guid:   guid_el&.text,
      enclosures: enclosures,
      duration: dur_el&.text
    }
  end

  { title: title, entries: entries }
rescue StandardError => e
  log_error("Feed parse error for #{feed_url}: #{e.message}")
  nil
end

# ---------------------------------------------------------------------------
# gPodder sync with bounded retry + exponential backoff + jitter
# ---------------------------------------------------------------------------
def gpodder_sync(cfg)
  g = cfg["gpodder"]
  base = g["host"].chomp("/")
  username = g["username"]
  password = g["password"]
  path = "/subscriptions/#{CGI.escape(username)}.opml"

  puts "--- Syncing subscriptions from #{base} ---"
  puts "Fetching subscriptions for '#{username}'..."

  max_attempts = 4
  backoff_base = 2.0
  resp = nil

  max_attempts.times do |attempt|
    begin
      uri = URI.parse("#{base}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.timeout = 60
      req = Net::HTTP::Get.new(uri.request_uri)
      credentials = Base64.strict_encode64("#{username}:#{password}")
      req["Authorization"] = "Basic #{credentials}"
      req["User-Agent"] = "radio-automation/1.0"
      resp = http.request(req)
      break
    rescue StandardError => e
      if attempt == max_attempts - 1
        log_error("gPodder sync failed after #{attempt + 1} attempts: #{e.class.name}")
        return []
      end
      delay = (backoff_base ** (attempt + 1)) + rand
      $log.warn("gPodder request error (#{e.class.name}); retrying in #{delay.round(1)}s")
      sleep(delay)
    end
  end

  return [] if resp.nil?

  case resp.code.to_i
  when 200
    body = resp.body
    return [] if body.strip.empty?
    parse_opml(body)
  when 401
    log_error("gPodder sync failed: 401 Unauthorized. Check username/password in config.json.")
  when 404
    log_error("gPodder sync failed: 404 Not Found. User may not exist or has no subscriptions.")
  when 429
    log_error("gPodder sync throttled (429). Will retry next cycle.")
  else
    code = resp.code.to_i
    if code >= 500
      log_error("gPodder sync server error (#{code}). Will retry next cycle.")
    else
      log_error("gPodder sync failed: unexpected response #{code}: #{resp.body[0, 200]}")
    end
  end
  []
end

def parse_opml(xml_string)
  shows = []
  doc = REXML::Document.new(xml_string)
  doc.elements.each("//outline") do |outline|
    feed_url = (outline.attributes["xmlUrl"] || "").strip
    name     = (outline.attributes["text"] || "").strip
    guid     = (outline.attributes["guid"] || "").strip
    next unless feed_url.match?(/\Ahttps?:\/\//)
    shows << { name: name, feed_url: feed_url, guid: guid.empty? ? nil : guid }
  end
  shows
rescue REXML::ParseException => e
  log_error("Failed to parse OPML XML: #{e.message}")
  []
end

# ---------------------------------------------------------------------------
# Show registration / pruning
# ---------------------------------------------------------------------------
def register_remote_shows(remote_shows)
  db = connect_subs
  added = 0
  skipped_video = 0
  remote_shows.each do |show|
    slug = slugify(show[:name])
    next if db[:shows].where(slug: slug).count > 0

    parsed = fetch_feed(show[:feed_url])
    if parsed.nil?
      $log.warn("Skipping '#{show[:name]}': could not fetch feed.")
      next
    end
    cls = classify_feed(parsed[:entries])
    if cls == "video"
      $log.info("Skipping '#{show[:name]}' (#{slug}): video podcast, not audio.")
      skipped_video += 1
      next
    end
    guid = show[:guid] || gen_uuid
    db[:shows].insert(
      slug: slug, guid: guid, name: show[:name], feed_url: show[:feed_url],
      source: "gpodder", opml_import: 0, archived: 1, media_class: cls
    )
    $log.info("Registered new show: #{show[:name]} (#{slug}) [#{cls}]")
    added += 1
  end
  db.disconnect
  $log.info("Filtered out #{skipped_video} video podcast(s).") if skipped_video > 0
  added
end

def prune_stale_shows(remote_shows)
  db = connect_subs
  remote_slugs = remote_shows.map { |s| slugify(s[:name]) }.to_set
  stale = db[:shows].where(source: "gpodder", opml_import: 0).all
  removed = 0
  stale.each do |row|
    next if remote_slugs.include?(row[:slug])
    remove_show_data(row[:slug])
    db[:shows].where(slug: row[:slug]).delete
    $log.info("Pruned stale show: #{row[:name]} (#{row[:slug]})")
    removed += 1
  end
  db.disconnect
  removed
end

# ---------------------------------------------------------------------------
# Episode extraction / download
# ---------------------------------------------------------------------------
def extract_duration(entry)
  dur = entry[:duration]
  if dur
    return dur.to_i if dur.match?(/\A\d+\z/)
    m = dur.match(/\APT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?\z/i)
    if m
      h  = m[1] ? m[1].to_i : 0
      mn = m[2] ? m[2].to_i : 0
      s  = m[3] ? m[3].to_i : 0
      return h * 3600 + mn * 60 + s
    end
  end
  enc = entry[:enclosures]&.first
  if enc && enc[:length]
    bytes = enc[:length].to_i
    return (bytes * 8 / 128_000) if bytes > 0
  end
  nil
end

def download_episode(url, dest_dir, filename)
  dest = File.join(dest_dir, filename)
  return dest if File.exist?(dest)
  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.timeout = 120
  tmp = "#{dest}.part"
  begin
    http.request_get(uri.request_uri) do |response|
      raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      File.open(tmp, "wb") do |f|
        response.read_body { |chunk| f.write(chunk) }
      end
    end
    File.rename(tmp, dest)
    dest
  rescue StandardError => e
    log_error("Download failed for #{url}: #{e.message}")
    File.delete(tmp) if File.exist?(tmp)
    nil
  end
end

def safe_filename(title, fallback)
  name = (title || "").gsub(/[^\w\s.\-]/, "").strip.tr(" ", "_")
  name = fallback if name.empty?
  "#{name[0, 120]}.mp3"
end

def show_archived?(db, slug)
  row = db[:shows].where(slug: slug).first
  row.nil? ? true : row[:archived] == 1
end

# ---------------------------------------------------------------------------
# Per-show episode fetch
# ---------------------------------------------------------------------------
def fetch_show_episodes(slug, name, feed_url)
  dest_dir = File.join($podcasts_dir, slug)
  Dir.mkdir(dest_dir) unless Dir.exist?(dest_dir)

  subs_db = connect_subs

  cached_cls = get_media_class(subs_db, slug)
  if cached_cls == "video"
    subs_db.disconnect
    return 0
  end

  parsed = fetch_feed(feed_url)
  if parsed.nil?
    subs_db.disconnect
    return 0
  end

  if cached_cls.nil?
    cls = classify_feed(parsed[:entries])
    set_media_class(subs_db, slug, cls)
    if cls == "video"
      $log.info("'#{name}' (#{slug}) classified as video; skipping.")
      subs_db.disconnect
      return 0
    end
  end

  played_db = connect_played
  seen = played_db[:episodes].where(show_slug: slug).select_map(:guid).to_set
  archived = show_archived?(subs_db, slug)
  new_count = 0

  parsed[:entries].each do |entry|
    guid = entry[:guid] || entry[:link] || entry[:title] || ""
    next if seen.include?(guid)
    enclosures = entry[:enclosures] || []
    next if enclosures.empty?
    mime = (enclosures.first[:type] || "").downcase
    next if mime.start_with?("video/")
    audio_url = enclosures.first[:href]
    next if audio_url.nil? || audio_url.empty?

    title = entry[:title] || "untitled"
    duration = extract_duration(entry)

    if archived
      filename = safe_filename(title, guid[-20..])
      file_path = download_episode(audio_url, dest_dir, filename)
      next if file_path.nil?
      insert_episode(played_db, slug, guid, title, file_path, audio_url, duration)
    else
      insert_episode(played_db, slug, guid, title, nil, audio_url, duration)
    end
    new_count += 1
    kind = archived ? "downloaded" : "live"
    $log.info("  New episode: #{title} [#{kind}]")
  end

  played_db.disconnect
  subs_db.disconnect
  new_count
end

def insert_episode(db, slug, guid, title, file_path, enclosure_url, duration)
  # INSERT OR IGNORE semantics via the UNIQUE(show_slug, guid) constraint.
  db.transaction do
    db[:episodes].insert(
      show_slug: slug, guid: guid, title: title,
      file_path: file_path, enclosure_url: enclosure_url,
      runlength: duration, played: 0
    )
  end
rescue Sequel::UniqueConstraintViolation
  # Already recorded; ignore.
end

def fetch_all_episodes
  db = connect_subs
  shows = db[:shows].order(:name).all
  db.disconnect
  total_new = 0
  shows.each do |show|
    $log.info("--- Fetching: #{show[:name]} (#{show[:slug]}) ---")
    begin
      n = fetch_show_episodes(show[:slug], show[:name], show[:feed_url])
      total_new += n
    rescue StandardError => e
      log_error("Unexpected error fetching #{show[:slug]}: #{e.message}")
    end
  end
  $log.info("=== Fetch complete: #{total_new} new episode(s) ===")
end

# ---------------------------------------------------------------------------
# Administrative commands
# ---------------------------------------------------------------------------
def list_shows(detail: false)
  db = connect_subs
  rows = db[:shows].order(:name).all
  db.disconnect
  if rows.empty?
    puts "No shows registered."
    return
  end
  puts format("%-30s %-10s %-8s %-10s %s", "SLUG", "ARCHIVED", "MEDIA", "SOURCE", "NAME")
  rows.each do |r|
    arch = r[:archived] == 1 ? "yes" : "no"
    media = r[:media_class] || "?"
    line = format("%-30s %-10s %-8s %-10s %s", r[:slug], arch, media, r[:source], r[:name])
    line += "\n" + (" " * 50) + r[:feed_url] if detail
    puts line
  end
end

def add_show(feed_url)
  parsed = fetch_feed(feed_url)
  if parsed.nil? || parsed[:title].nil?
    log_error("Could not determine show title from #{feed_url}")
    return
  end
  cls = classify_feed(parsed[:entries])
  if cls == "video"
    log_error("Refusing to add '#{parsed[:title]}': video podcast detected.")
    return
  end
  name = parsed[:title]
  slug = slugify(name)
  guid = gen_uuid
  db = connect_subs
  begin
    db[:shows].insert(
      slug: slug, guid: guid, name: name, feed_url: feed_url,
      source: "manual", opml_import: 0, archived: 1, media_class: cls
    )
  rescue Sequel::UniqueConstraintViolation
    # already present
  end
  db.disconnect
  $log.info("Added show: #{name} (#{slug}) [#{cls}]")
  fetch_show_episodes(slug, name, feed_url)
end

def set_archive(slug, value)
  db = connect_subs
  row = db[:shows].where(slug: slug).first
  if row.nil?
    log_error("No show found with slug '#{slug}'.")
    db.disconnect
    return
  end
  db[:shows].where(slug: slug).update(archived: value)
  db.disconnect
  state = value == 1 ? "archived" : "non-archived (live)"
  $log.info("Show '#{row[:name]}' (#{slug}) is now #{state}.")
end

def remove_show_data(slug)
  pod_dir = File.join($podcasts_dir, slug)
  FileUtils.rm_rf(pod_dir) if Dir.exist?(pod_dir)
  txt = File.join($playlists_dir, "#{slug}.txt")
  File.delete(txt) if File.exist?(txt)
end

def delete_show(slug)
  db = connect_subs
  row = db[:shows].where(slug: slug).first
  if row.nil?
    log_error("No show found with slug '#{slug}'.")
    db.disconnect
    return
  end
  remove_show_data(slug)
  db[:shows].where(slug: slug).delete
  db.disconnect
  played_db = connect_played
  played_db[:episodes].where(show_slug: slug).delete
  played_db.disconnect
  $log.info("Deleted show: #{row[:name]} (#{slug})")
end

def import_opml(path)
  content = File.read(path)
  shows = parse_opml(content)
  db = connect_subs
  added = 0
  skipped_video = 0
  shows.each do |show|
    slug = slugify(show[:name])
    next if db[:shows].where(slug: slug).count > 0
    parsed = fetch_feed(show[:feed_url])
    if parsed.nil?
      $log.warn("OPML import: skipping '#{show[:name]}', could not fetch feed.")
      next
    end
    cls = classify_feed(parsed[:entries])
    if cls == "video"
      $log.info("OPML import: skipping '#{show[:name]}' (#{slug}): video podcast.")
      skipped_video += 1
      next
    end
    guid = show[:guid] || gen_uuid
    db[:shows].insert(
      slug: slug, guid: guid, name: show[:name], feed_url: show[:feed_url],
      source: "opml", opml_import: 1, archived: 1, media_class: cls
    )
    added += 1
  end
  db.disconnect
  $log.info("OPML import: #{added} added, #{skipped_video} video shows filtered out.")
end

def run_fetch(config)
  g = config["gpodder"]
  if g["enable"] == true
    remote = gpodder_sync(config)
    if remote.empty?
      $log.warn("No subscriptions retrieved from gPodder; using local registry only.")
    else
      added = register_remote_shows(remote)
      pruned = prune_stale_shows(remote)
      $log.info("Sync: #{added} added, #{pruned} pruned.")
    end
  end
  fetch_all_episodes
end

def main
  args = ARGV.dup
  option = args.shift

  init_paths!
  [$state_dir, $logs_dir, $podcasts_dir, $playlists_dir].each do |dir|
    Dir.mkdir(dir) unless Dir.exist?(dir)
  end
  setup_logging!

  config = load_config

  case option
  when "--list-shows"
    list_shows(detail: args.include?("--detail"))
  when "--add-show"
    add_show(args.first)
  when "--delete-show"
    delete_show(args.first)
  when "--archive"
    set_archive(args.first, 1)
  when "--unarchive"
    set_archive(args.first, 0)
  when "--import-opml"
    import_opml(args.first)
  else
    if !acquire_lock!
      $log.info("Another radio process holds the lock; skipping this run.")
      return
    end
    begin
      run_fetch(config)
    ensure
      release_lock!
    end
  end
end

main if __FILE__ == $PROGRAM_NAME
