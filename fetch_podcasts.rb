#!/usr/bin/env jruby
# frozen_string_literal: true
require "rubygems"
require "net/http"
require "uri"
require "json"
require "digest/sha1"
require "sequel"
require "nokogiri"
require "time"
require "fileutils"
unless defined?(Nokogiri::XML)
  raise Exception.new "Nokogiri did NOT load"
end
SCRIPT_DIR  = File.expand_path(File.dirname(__FILE__))
CONFIG_PATH = File.join(SCRIPT_DIR, "config.json")

def load_config
  JSON.parse(File.read(CONFIG_PATH))
end

CFG         = load_config
STORAGE     = CFG["storage"]
STATE_DIR   = File.join(STORAGE, "state")
LOGS_DIR    = File.join(STORAGE, "logs")
PODCAST_DIR = File.join(STORAGE, "podcasts")
SUBS_DB     = File.join(STATE_DIR, "subscriptions.db")
PLAYED_DB   = File.join(STATE_DIR, "played.db")
LOG_FILE    = File.join(LOGS_DIR, "fetch_podcasts.log")

$global_log_dir = LOGS_DIR

def ensure_dir(path)
  return if Dir.exist?(path)
  parent = File.dirname(path)
  ensure_dir(parent) unless Dir.exist?(parent) && parent != path
  Dir.mkdir(path)
rescue Errno::EEXIST
  nil
end

ensure_dir(STATE_DIR)
ensure_dir(LOGS_DIR)
ensure_dir(PODCAST_DIR)

$db_s = Sequel.connect("jdbc:sqlite:" + SUBS_DB)
$db_p = Sequel.connect("jdbc:sqlite:" + PLAYED_DB)

$db_s.execute("PRAGMA journal_mode=WAL;")
$db_s.execute("PRAGMA busy_timeout=5000;")
$db_p.execute("PRAGMA journal_mode=WAL;")
$db_p.execute("PRAGMA busy_timeout=5000;")

def log(level, msg)
  ts = Time.now.strftime("%Y-%m-%d %H:%M:%S")
  line = "[#{ts}] [#{level}] #{msg}"
  puts line
  begin
    File.open(LOG_FILE, "a") { |f| f.puts(line) }
  rescue StandardError => e
    warn "Log write failed: #{e.class} #{e.message}"
  end
end

FETCH_LOCK = File.join(STATE_DIR, "fetching")
if File.exist?(FETCH_LOCK)
  log("INFO", "Fetch already in progress (#{FETCH_LOCK} exists), exiting")
  exit 0
end
FileUtils.touch(FETCH_LOCK)
at_exit { File.delete(FETCH_LOCK) if File.exist?(FETCH_LOCK) }

def table_count(db, tbl)
  db[:sqlite_master].where(type: 'table', name: tbl).count > 0
end

def ensure_schema
  unless table_count($db_s, "shows")
    $db_s.execute(%(
      CREATE TABLE IF NOT EXISTS shows (
        guid TEXT PRIMARY KEY,
        slug TEXT UNIQUE NOT NULL,
        title TEXT NOT NULL,
        feed_url TEXT NOT NULL,
        archive INTEGER DEFAULT 0,
        opml_import INTEGER DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    ))
    log("INFO", "Created shows table in subscriptions.db")
  end

  unless table_count($db_p, "episodes")
    $db_p.execute(%(
      CREATE TABLE IF NOT EXISTS episodes (
        guid TEXT PRIMARY KEY,
        show_guid TEXT NOT NULL,
        title TEXT NOT NULL,
        url TEXT NOT NULL,
        duration_seconds INTEGER DEFAULT 0,
        played INTEGER DEFAULT 0,
        local_path TEXT,
        file_size_bytes INTEGER DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    ))
    log("INFO", "Created episodes table in played.db")
  end
end

def gen_guid(seed_str)
  Digest::SHA1.hexdigest(seed_str.to_s)
end

# Dest filenames are built from the episode guid, and some feeds use a
# permalink URL as the guid (e.g. "https://example.com/?p=1871"). Using it
# raw puts / : ? characters into the filename, which crosses directories
# that were never created (Errno::ENOENT). Sanitize: keep filename-safe
# characters, flatten the rest; when the guid needed flattening, prefix a
# short SHA1 of the original so two different URL guids cannot collide.
# Deterministic, so a retried episode regenerates the same name.
def safe_filename(guid)
  g = guid.to_s
  safe = g.gsub(/[^a-zA-Z0-9._-]/, "_")
  safe = "#{Digest::SHA1.hexdigest(g)[0, 8]}_#{safe}" unless safe == g
  safe = safe[0, 150]
  safe.empty? ? "episode" : safe
end

def generate_slug(title)
  title.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_+|_+$/, "")
end

def http_stream_to_file(url, dest_path, user = nil, pass = nil)
  begin
    uri = URI.parse(url)
  rescue URI::InvalidURIError
    begin
      uri = URI.parse(URI::DEFAULT_PARSER.escape(url))
    rescue URI::InvalidURIError
      log("ERROR", "Unparseable URL, skipping: #{url}")
      return false
    end
  end
  success = false
  tmp_dest = "#{dest_path}.downloading"

  begin
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 60
    http.read_timeout = 300

    req = Net::HTTP::Get.new(uri.request_uri)
    req.add_field("User-Agent", "RadioAutomation/1.0 (JRuby)")
    req.basic_auth(user, pass) if user && !user.empty?

    res = nil
    body = nil
    http.start do |conn|
      conn.request(req) do |response|
        res = response
        body = response.read_body
      end
    end

    if res.is_a?(Net::HTTPRedirection)
      loc = res["location"]
      log("WARN", "Redirect to: #{loc}")
      return http_stream_to_file(loc, dest_path, user, pass)
    end

    unless res.is_a?(Net::HTTPSuccess)
      raise "HTTP #{res.code}: #{res.message}"
    end
    File.open(tmp_dest, "wb") do |f|
      f.write(body)
    end
    File.rename(tmp_dest, dest_path)
    success = true
  rescue Exception => error
    log("ERROR", "Download failed for #{url}: #{error.class}: #{error.message}, Backtrace --> #{error.backtrace}")
    begin
      File.delete(tmp_dest) if File.exist?(tmp_dest)
    rescue StandardError
      # ignore cleanup errors
    end
  end
  success
end

def parse_feed(opts)
  result = nil
  file_path = opts[:file_path] || raise("parse_feed: :file_path is required")
  feed_url  = opts[:feed_url]  || ""

  doc = Nokogiri::XML(File.read(file_path), nil)
  channel = doc.at_xpath("//channel")
  if channel
    items = []
    channel.xpath("./item").each do |item|
      enc = item.at_xpath("./enclosure")
      next unless enc

      url_attr = enc.attributes["url"]
      next unless url_attr && url_attr.value && !url_attr.value.empty?

      type_attr = enc.attributes["type"]
      next unless type_attr && type_attr.value =~ /audio/i

      pub_date_raw = item.at_xpath("./pubDate")&.text
      published_at = begin
        Time.parse(pub_date_raw)&.utc&.strftime("%Y-%m-%d %H:%M:%S")
      rescue StandardError
        nil
      end

      dur_el = item.at_xpath(".//media:duration", "media" => "http://search.yahoo.com/mrss/")
      dur_sec = 0
      if dur_el
        d = dur_el.text.strip
        if d.include?(":")
          parts = d.split(":").map(&:to_i)
          dur_sec = parts.last(3).inject(0) { |acc, p| acc * 60 + p }
        else
          dur_sec = d.to_i
        end
      end

      enc_len = enc.attributes["length"]&.value&.to_i || 0
      est_dur = (enc_len / (128 * 1024)).round if enc_len > 0

      g = item.at_xpath("./guid")&.text
      enc_url = url_attr.value
      items << {
        guid: (g && !g.strip.empty? ? g : gen_guid(enc_url)),
        title: item.at_xpath("./title")&.text || "Untitled",
        url: enc_url,
        duration_seconds: dur_sec > 0 ? dur_sec : (est_dur || 0),
        file_size_bytes: enc_len,
        published_at: published_at
      }
    end
    result = {
      title: channel.at_xpath("./title")&.text || "Unknown Show",
      feed_url: feed_url,
      items: items
    }
  else
    # log - skipping - no channel data
  end
  result
end

def register_show(show_title, feed_url, archive: false, opml_import: false)
  title = show_title.to_s.strip
  url   = feed_url.to_s.strip
  return nil if title.empty? || url.empty?

  slug = title.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_+|_+$/, "")
  slug = "show" if slug.empty?

  # Check for slug collision with a different feed URL
  existing_slug = $db_s[:shows].where(slug: slug).first
  if existing_slug && existing_slug[:feed_url] != url
    # Append a short hash of the URL to disambiguate
    suffix = Digest::SHA1.hexdigest(url)[0, 6]
    slug = "#{slug}_#{suffix}"
  end

  guid = gen_guid(url)
  now  = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")

  existing = $db_s[:shows].where(guid: guid).first
  if existing
    $db_s[:shows].where(guid: guid).update(
      title: title,
      slug: slug,
      feed_url: url,
      archive: archive ? 1 : 0,
      opml_import: opml_import ? 1 : 0
    )
  else
    $db_s[:shows].insert(
      guid: guid,
      slug: slug,
      title: title,
      feed_url: url,
      archive: archive ? 1 : 0,
      opml_import: opml_import ? 1 : 0,
      created_at: now
    )
 end

  log("INFO", "Registered: #{title} (#{slug})")
  # Return the stored row, not a bare true: cmd_add_show reads row[:slug] and
  # row[:title] from this return value. Callers that only test truthiness
  # (sync_gpodder's "added += 1 if row") behave identically with a hash.
  $db_s[:shows].where(guid: guid).first
end

def sync_gpodder
  gpodder_cfg = CFG["gpodder"] || {}
  unless gpodder_cfg["enabled"] == true
    # The previous silent `return unless` made this case indistinguishable
    # from a successful no-op: --fetch-all then reported "No archived shows
    # to fetch." with zero gPodder lines in the log. Say why we skipped.
    log("WARN", "gPodder sync: skipped -- config.json has no \"gpodder\" block with \"enabled\": true")
    return
  end

  host = gpodder_cfg["host"].to_s.sub(/\Ahttps?:\/\//, "").sub(/\/.*\z/, "")
  username = gpodder_cfg["username"].to_s
  password = gpodder_cfg["password"].to_s
  device_id = gpodder_cfg["device_id"].to_s
  if username.empty? || password.empty? || device_id.empty?
    log("WARN", "gPodder sync: skipped -- gpodder.username, gpodder.password and gpodder.device_id must all be non-empty in config.json")
    return
  end

  full_host = "https://#{host}"
  opml_url = "#{full_host}/subscriptions/#{username}/#{device_id}.opml"
  log("INFO", "gPodder sync: fetching OPML from #{opml_url}")

  tmp_opml = "/tmp/radio_gp_odder_sync.opml"
  ok = http_stream_to_file(opml_url, tmp_opml, username, password)
  unless ok
    log("ERROR", "gPodder sync: failed to download #{opml_url}")
    return
  end

  # nonet via the block form, the same verified pattern cmd_import_opml uses.
  # The previous form passed XML::NO_NETWORK -- an undefined constant -- as the
  # encoding argument, so every sync raised NameError before parsing anything.
  opml_doc = Nokogiri::XML(File.read(tmp_opml)) { |config| config.nonet }
  remote_shows = []
  outlines_seen = 0
  opml_doc.xpath("//outline[@xmlUrl]").each do |o|
    xml_url = o.attr("xmlUrl").to_s.strip
    next if xml_url.empty?
    outlines_seen += 1
    # No extension filter: gPodder feed URLs end in .xml, .rss, or nothing at
    # all, and cmd_import_opml (the verified import path in this file) accepts
    # any outline with an xmlUrl. Requiring a .rss/.atom ending here rejected
    # every outline in a real gPodder OPML, leaving "0 added, 0 removed".
    # Titles: OPML outlines may carry title, text, or both.
    title = (o.attr("title") || o.attr("text")).to_s.strip
    remote_shows << { url: xml_url, title: title }
  end
  log("INFO", "gPodder sync: OPML contained #{outlines_seen} outline(s) with xmlUrl")

  added = 0
  removed = 0

  # archive: true is the design correction: cmd_fetch_all fetches only shows
  # with archive = 1, and the gPodder subscription list IS the fetch list.
  # The elsif flips already-registered rows that are not yet archived, so the
  # correction also repairs rows created before this change.
  remote_shows.each do |rs|
    existing = $db_s[:shows].where(feed_url: rs[:url]).first
    if existing.nil?
      # Keyword form matching register_show's signature
      # (show_title, feed_url, archive: false, opml_import: false). The old
      # positional call passed 0, 0 against two keyword parameters, which
      # raises ArgumentError on the first new show and aborts the sync.
      # opml_import: true because these rows originate from the gPodder OPML;
      # the prune block below only manages rows it can attribute to the sync.
      row = register_show(rs[:title], rs[:url], archive: true, opml_import: true)
      added += 1 if row
    elsif existing[:archive] != 1
      $db_s[:shows].where(guid: existing[:guid]).update(archive: 1)
      log("INFO", "gPodder sync: archived '#{existing[:slug]}'")
    end
  end

  all_local = $db_s[:shows].all
  all_local.each do |row|
    # Prune only rows the gPodder sync owns (opml_import = 1): they came from
    # the OPML and are removed when the subscription vanishes from it. The
    # previous condition (== 0) was inverted -- it deleted manually added
    # shows not present in the gPodder list and never pruned synced ones.
    if row[:opml_import] == 1
      still_remote = remote_shows.any? { |rs| rs[:url] == row[:feed_url] }
      unless still_remote
        $db_p[:episodes].where(show_guid: row[:guid]).delete
        $db_s[:shows].where(guid: row[:guid]).delete
        log("INFO", "gPodder sync: pruned '#{row[:slug]}'")
        removed += 1
      end
    end
  end

  log("INFO", "gPodder sync: #{added} added, #{removed} removed")
  begin
    File.delete(tmp_opml)
  rescue StandardError
    # ignore cleanup errors
  end
end

def cmd_add_show(args)
  if args.size < 1
    log("ERROR", "Usage: fetch_podcasts.rb --add-show <url>")
    exit 1
  end
  url = args.first
  title = url
  parsed = nil

  tmp_feed = "/tmp/radio_feed_probe.xml"
  if http_stream_to_file(url, tmp_feed)
    parsed = parse_feed({:file_path => tmp_feed, :feed_url => url})
    title = parsed[:title] if parsed && !parsed[:title].empty?
    begin
      File.delete(tmp_feed)
    rescue StandardError
      # ignore cleanup errors
    end
  end

  # archive: true because cmd_fetch_all fetches only archive = 1 rows, and a
  # show added by hand is by definition one the station wants. This also
  # re-archives a previously wiped row on re-registration.
  row = register_show(title, url, archive: true)
  if row
    log("INFO", "Added show: #{row[:slug]} (#{row[:title]})")
  else
    log("ERROR", "Failed to add show: #{url}")
    exit 1
  end
end

def cmd_remove_show(slug_or_url)
  row = $db_s[:shows].where(Sequel.lit("lower(slug) LIKE ?", "%#{slug_or_url}%")).first
  row ||= $db_s[:shows].where(feed_url: slug_or_url).first
  if row.nil?
    log("ERROR", "Show not found: #{slug_or_url}")
    exit 1
  end

  removed_files = 0
  $db_p[:episodes].where(show_guid: row[:guid]).each do |ep|
    lp = ep[:local_path]
    next if lp.nil? || lp.empty?
    begin
      File.delete(lp) if File.exist?(lp)
      removed_files += 1
    rescue StandardError => e
      log("WARN", "Could not delete #{lp}: #{e.class}: #{e.message}")
    end
  end

  show_dir = File.join(PODCAST_DIR, row[:slug])
  if Dir.exist?(show_dir)
    begin
      Dir.rmdir(show_dir)
      log("INFO", "Removed empty show directory: #{show_dir}")
    rescue StandardError
      # directory not empty (stray files); leave it in place
    end
  end

  $db_p[:episodes].where(show_guid: row[:guid]).delete
  $db_s[:shows].where(guid: row[:guid]).delete
  log("INFO", "Removed show: #{row[:slug]} (#{removed_files} episode files deleted) and its episodes")
end

def cmd_archive(slug_or_url, flag)
  row = $db_s[:shows].where(slug: slug_or_url).first
  row ||= $db_s[:shows].where(feed_url: slug_or_url).first
  if row.nil?
    log("ERROR", "Show not found: #{slug_or_url}")
    exit 1
  end
  val = flag ? 1 : 0
  $db_s[:shows].where(guid: row[:guid]).update(archive: val)
  log("INFO", "#{flag ? 'Archived' : 'Unarchived'}: #{row[:slug]}")
end

def cmd_import_opml(path)
  opml_file = path
  raise "File not found: #{opml_file}" unless File.exist?(opml_file)

  doc = Nokogiri::XML(File.read(opml_file)) { |config| config.nonet }

  outlines = doc.xpath("//outline")
  count = 0
  outlines.each do |ol|
    url = ol.attr("xmlUrl") || ol.attr("url")
    title = ol.attr("title") || "Unknown"
    next if url.nil? || url.empty?

    existing = $db_s[:shows].where(feed_url: url).first
    if existing
      log("info", "OPML: '#{existing[:slug]}' already registered, skipping")
      next
    end

    slug = generate_slug(title)
    guid = gen_guid(url)
    $db_s[:shows].insert(
      guid: guid,
      slug: slug,
      title: title,
      feed_url: url,
      archive: 1,
      opml_import: 1,
      created_at: Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")
    )
    count += 1
    log("info", "OPML: registered '#{slug}' (#{title})")
  end

  log("info", "Imported #{count} shows from OPML")
end

def cmd_list(detail)
  rows = $db_s[:shows].order(:slug).all
  if rows.empty?
    puts "No shows registered."
    return
  end
  if detail
    rows.each do |r|
      ep_count = $db_p[:episodes].where(show_guid: r[:guid]).count
      unplayed = $db_p[:episodes].where(show_guid: r[:guid], played: 0).count
      printf("%-40s %-60s arch=%d eps=%d unplayed=%d\n",
             r[:slug][0,40], r[:title][0,60], r[:archive], ep_count, unplayed)
    end
  else
    rows.each do |r|
      printf("%-40s %-60s arch=%d\n", r[:slug][0,40], r[:title][0,60], r[:archive])
    end
  end
end

def cmd_fetch_all
  shows = $db_s[:shows].where(archive: 1).all
  if shows.empty?
    log("INFO", "No archived shows to fetch.")
    return
  end
  shows.each do |show|
    log("INFO", "Fetching: #{show[:title]}")
    tmp_feed = "/tmp/radio_fetch_#{show[:slug]}.xml"
    unless http_stream_to_file(show[:feed_url], tmp_feed)
      log("WARN", "Feed download failed for #{show[:slug]}, skipping")
      next
    end

    parsed = parse_feed({:file_path => tmp_feed, :feed_url => show[:feed_url]})
    begin
      File.delete(tmp_feed)
    rescue StandardError
      # ignore cleanup errors
    end

    next unless parsed

    show_dir = File.join(PODCAST_DIR, show[:slug])
    ensure_dir(show_dir)

    new_eps = 0
    parsed[:items].each do |ep|
      existing = $db_p[:episodes].where(guid: ep[:guid]).first
      if existing
        next
      end

      filename = "#{safe_filename(ep[:guid])}.mp3"
      dest = File.join(show_dir, filename)
      dl_ok = http_stream_to_file(ep[:url], dest)
      unless dl_ok
        log("WARN", "Episode download failed for #{show[:slug]}: #{ep[:guid]}, not recorded -- will retry next fetch")
        next
      end
      size = File.size(dest)

      now = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")
      $db_p[:episodes].insert(
        guid: ep[:guid],
        show_guid: show[:guid],
        title: ep[:title],
        url: ep[:url],
        duration_seconds: ep[:duration_seconds],
        played: 0,
        local_path: dest,
        file_size_bytes: size,
        created_at: now
      )
      new_eps += 1
    end
    log("INFO", "#{show[:slug]}: #{new_eps} new episodes downloaded")
  end
end

begin
  ensure_schema
  sync_gpodder

  command = ARGV.shift
  case command
  when "--list"
    detail = ARGV.include?("--detail")
    cmd_list(detail)
  when "--add-show"
    cmd_add_show(ARGV)
  when "--remove"
    cmd_remove_show(ARGV.first)
  when "--archive"
    cmd_archive(ARGV.first, true)
  when "--unarchive"
    cmd_archive(ARGV.first, false)
  when "--import-opml"
    cmd_import_opml(ARGV.first)
  when "--fetch-all"
    cmd_fetch_all
  else
    puts "Usage: fetch_podcasts.rb [--list|--detail|--add-show <url>|--remove <slug>|--archive <slug>|--unarchive <slug>|--import-opml <file>|--fetch-all]"
  end
rescue SystemExit
  raise
rescue Exception => e
  log("ERROR", "Unhandled exception: #{e.class}: #{e.message}, Backtrace --> #{e.backtrace}")
  raise
ensure
  File.delete(FETCH_LOCK) if File.exist?(FETCH_LOCK)
end
