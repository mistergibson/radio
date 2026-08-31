#!/usr/bin/env jruby
# frozen_string_literal: true

require "net/http"
require "uri"
require "cgi"
require "json"
require "sqlite3"
require "rexml/document"
require "digest/md5"
require "fileutils"
require "optparse"

module RadioAutomation
  ROOT          = File.expand_path("..", __dir__)
  CONFIG_PATH   = File.join(ROOT, "config.json")
  AUDIO_EXTS    = [".mp3", ".m4a"]
  VIDEO_EXTS    = [".mp4", ".mov", ".avi", ".webm", ".mkv"]

  STORAGE_DIR   = nil
  STATE_DIR     = nil
  SUBS_DB       = nil
  PLAYED_DB     = nil
  PODCASTS_DIR  = nil
  LOGS_DIR      = nil
  PLAYLISTS_DIR = nil

  def self.init_paths
    cfg = JSON.parse(File.read(CONFIG_PATH))
    @storage = File.expand_path(cfg["storage"])
    self.STORAGE_DIR   = @storage
    self.STATE_DIR     = File.join(@storage, "state")
    self.SUBS_DB       = File.join(STATE_DIR, "subscriptions.db")
    self.PLAYED_DB     = File.join(STATE_DIR, "played.db")
    self.PODCASTS_DIR  = File.join(@storage, "podcasts")
    self.LOGS_DIR      = File.join(@storage, "logs")
    self.PLAYLISTS_DIR = File.join(@storage, "playlists")
  end

  def self.log_info(msg)
    puts "#{Time.now.iso8601} [INFO] #{msg}"
    append_log("fetch.log", msg)
  end

  def self.log_warning(msg)
    puts "#{Time.now.iso8601} [WARN] #{msg}"
    append_log("fetch.log", msg)
  end

  def self.log_error(msg)
    puts "#{Time.now.iso8601} [ERROR] #{msg}"
    append_log("fetch.log", msg)
  end

  def self.append_log(filename, msg)
    FileUtils.mkdir_p(LOGS_DIR)
    File.open(File.join(LOGS_DIR, filename), "a") { |f| f.puts msg }
  rescue StandardError
    nil
  end

  def self.load_config
    JSON.parse(File.read(CONFIG_PATH))
  end

  def self.slugify(name)
    s = name.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    s[0, 60] || "show"
  end

  def self.open_subs_db
    db = SQLite3::Database.new(SUBS_DB)
    db.results_as_hash = true
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS shows (
        slug TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        feed_url TEXT NOT NULL UNIQUE,
        source TEXT DEFAULT 'manual',
        opml_import INTEGER DEFAULT 0,
        created_at TEXT DEFAULT (datetime('now'))
      )
    SQL
    db
  end

  def self.open_played_db
    db = SQLite3::Database.new(PLAYED_DB)
    db.results_as_hash = true
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS episodes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        show_slug TEXT NOT NULL,
        guid TEXT NOT NULL,
        title TEXT,
        file_path TEXT,
        duration_seconds INTEGER,
        played_at TEXT,
        UNIQUE(show_slug, guid)
      )
    SQL
    db
  end

  # --- Audio-only filtering -------------------------------------------------

  def self.enclosure_mime_and_url(entry_xml)
    enc_m = entry_xml.match(/enclosure[^>]*type="([^"]*)"[^>]*url="([^"]*)"/i) ||
             entry_xml.match(/enclosure[^>]*url="([^"]*)"[^>]*type="([^"]*)"/i)
    if enc_m
      if enc_m.pre_match.include?("type=") && enc_m.post_match.empty?
        # First pattern matched: group 1 = type, group 2 = url
        return [enc_m[1], enc_m[2]]
      else
        # Second pattern matched: group 1 = url, group 2 = type
        return [enc_m[2], enc_m[1]]
      end
    end
    # Fallback: just grab url without type
    url_only = entry_xml.match(/enclosure[^>]*url="([^"]*)"/i)
    [nil, url_only[1]] if url_only
  end

  def self.is_audio_entry?(entry_xml)
    mime, url = enclosure_mime_and_url(entry_xml)
    return true if mime.nil? && url.nil?  # No enclosure; assume ok
    mime_l = mime.to_s.downcase
    return true if mime_l.start_with?("audio/")
    return false if mime_l.start_with?("video/")
    # Fall back to URL extension
    url_l = url.to_s.downcase
    return true if AUDIO_EXTS.any? { |ext| url_l.end_with?(ext) }
    return false if VIDEO_EXTS.any? { |ext| url_l.end_with?(ext) }
    true  # Undetermined: allow
  end

  def self.is_audio_feed?(raw_xml)
    # Grab the first <item> or <entry> block
    m = raw_xml.match(/<(?:item|entry)[^>]*>(.*?)<\/(?:item|entry)>/mi)
    return true unless m  # No items; let through
    is_audio_entry?(m[1])
  end

  # --- End audio-only filtering ---------------------------------------------

  def self.gpodder_sync(config)
    g = config["gpodder"]
    base = g["host"].chomp("/")
    username = g["username"]
    password = g["password"]
    url = "#{base}/subscriptions/#{CGI.escape(username)}.opml"

    puts "--- Syncing subscriptions from #{base} ---"
    puts "Fetching subscriptions for '#{username}'..."

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 30
    http.read_timeout = 60

    req = Net::HTTP::Get.new(uri)
    req.basic_auth(username, password)
    req["Accept"] = "application/x-opml, text/xml, */*"
    req["User-Agent"] = "radio-automation/1.0"

    resp = http.request(req)

    case resp.code
    when "200"
      body = resp.body
      if body.nil? || body.empty?
        log_error("gPodder sync returned an empty body.")
        return []
      end
      parse_opml(body)
    when "401"
      log_error("gPodder sync failed: 401 Unauthorized. Check username/password in config.json.")
      []
    when "404"
      log_error("gPodder sync failed: 404 Not Found. User may not exist or has no subscriptions.")
      []
    when "400"
      log_error("gPodder sync failed: 400 Bad Request.")
      []
    else
      log_error("gPodder sync failed: unexpected response #{resp.code}: #{resp.body.to_s[0..200]}")
      []
    end
  end

  def self.parse_opml(xml_string)
    doc = REXML::Document.new(xml_string)
    shows = []
    REXML::XPath.each(doc, "//outline[@xmlUrl]") do |node|
      feed_url = node.attributes["xmlUrl"].to_s.strip
      name     = node.attributes["text"].to_s.strip
      next unless feed_url =~ /\Ahttps?:\/\//
      shows << { "name" => name, "feed_url" => feed_url }
    end
    shows
  rescue REXML::ParseException => e
    log_error("Failed to parse OPML XML: #{e.message}")
    []
  end

  def self.register_remote_shows(remote_shows)
    db = open_subs_db
    added = 0
    skipped_video = 0
    remote_shows.each do |show|
      slug = slugify(show["name"])
      existing = db.get_first_value("SELECT slug FROM shows WHERE slug = ?", slug)
      next unless existing.nil?

      raw = fetch_feed(show["feed_url"])
      if raw.nil?
        log_warning("Skipping '#{show['name']}': could not fetch feed.")
        next
      end
      unless is_audio_feed?(raw)
        log_info("Skipping '#{show['name']}' (#{slug}): video podcast, not audio.")
        skipped_video += 1
        next
      end
      db.execute(
        "INSERT INTO shows (slug, name, feed_url, source, opml_import) VALUES (?, ?, ?, 'gpodder', 0)",
        [slug, show["name"], show["feed_url"]]
      )
      log_info("Registered new show: #{show['name']} (#{slug})")
      added += 1
    end
    db.close
    log_info("Filtered out #{skipped_video} video podcast(s).") if skipped_video > 0
    added
  end

  def self.prune_stale_shows(remote_shows)
    db = open_subs_db
    remote_slugs = remote_shows.map { |s| slugify(s["name"]) }
    stale = db.query_all("SELECT slug, name FROM shows WHERE source = 'gpodder' AND opml_import = 0")
    removed = 0
    stale.each do |row|
      next if remote_slugs.include?(row["slug"])
      remove_show_data(row["slug"])
      db.execute("DELETE FROM shows WHERE slug = ?", [row["slug"]])
      log_info("Pruned stale show: #{row['name']} (#{row['slug']})")
      removed += 1
    end
    db.close
    removed
  end

  def self.extract_duration(entry_xml)
    if (m = entry_xml.match(/media:duration[^>]*content="([^"]+)"/))
      val = m[1]
      return val.to_i if val =~ /\A\d+\z/
      if (iso = val.match(/\APT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/))
        h, mn, s = iso.captures.compact.map(&:to_i)
        return (h || 0) * 3600 + (mn || 0) * 60 + (s || 0)
      end
    end
    if (m = entry_xml.match(/enclosure[^>]*length="(\d+)"/))
      bytes = m[1].to_i
      return (bytes * 8 / 128_000) if bytes > 0
    end
    nil
  end

  def self.fetch_feed(feed_url)
    uri = URI.parse(feed_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 30
    http.read_timeout = 60
    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = "radio-automation/1.0"
    resp = http.request(req)
    raise "Feed HTTP #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)
    resp.body
  rescue StandardError => e
    log_error("Feed fetch error for #{feed_url}: #{e.message}")
    nil
  end

  def self.download_episode(url, dest_dir, filename)
    FileUtils.mkdir_p(dest_dir)
    dest = File.join(dest_dir, filename)
    return dest if File.exist?(dest)

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 30
    http.read_timeout = 120
    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = "radio-automation/1.0"

    tmp = "#{dest}.part"
    begin
      http.request(req) do |resp|
        raise "Download HTTP #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)
        File.open(tmp, "wb") do |f|
          resp.read_body { |chunk| f.write(chunk) }
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

  def self.safe_filename(title, fallback)
    name = title.to_s.gsub(/[^\w\s.\-]/, "").strip.tr(" ", "_")[0, 120]
    "#{name || fallback}.mp3"
  end

  def self.fetch_show_episodes(slug, name, feed_url)
    dest_dir = File.join(PODCASTS_DIR, slug)
    raw = fetch_feed(feed_url)
    return 0 if raw.nil?

    played_db = open_played_db
    seen = played_db.query("SELECT guid FROM episodes WHERE show_slug = ?", slug).map { |r| r["guid"] }
    subs_db = open_subs_db
    new_count = 0

    raw.scan(/<(?:item|entry)[^>]*>(.*?)<\/(?:item|entry)>/mi).each do |(entry_xml)|
      guid_m = entry_xml.match(/<guid[^>]*>([^<]*)<\/guid>|<id>([^<]*)<\/id>|<link[^>]*href="([^"]+)"/i)
      guid = guid_m ? (guid_m[1] || guid_m[2] || guid_m[3]).strip : Digest::MD5.hexdigest(entry_xml[0, 200])
      next if seen.include?(guid)

      # Per-episode audio check
      unless is_audio_entry?(entry_xml)
        next
      end

      _, audio_url = enclosure_mime_and_url(entry_xml)
      next if audio_url.nil?

      title_m = entry_xml.match(/<title[^>]*>([^<]*)<\/title>/i)
      title = title_m ? title_m[1].strip : "untitled"
      filename = safe_filename(title, guid[-20..])
      file_path = download_episode(audio_url, dest_dir, filename)
      next if file_path.nil?

      duration = extract_duration(entry_xml)
      played_db.execute(
        "INSERT OR IGNORE INTO episodes (show_slug, guid, title, file_path, duration_seconds, played_at) VALUES (?, ?, ?, ?, ?, NULL)",
        [slug, guid, title, file_path, duration]
      )
      new_count += 1
      log_info("  New episode: #{title} [#{filename}]")
    end

    played_db.close
    subs_db.close
    new_count
  end

  def self.fetch_all_episodes
    db = open_subs_db
    shows = db.query_all("SELECT slug, name, feed_url FROM shows ORDER BY name")
    db.close
    total_new = 0
    shows.each do |show|
      log_info("--- Fetching: #{show['name']} (#{show['slug']}) ---")
      begin
        total_new += fetch_show_episodes(show["slug"], show["name"], show["feed_url"])
      rescue StandardError => e
        log_error("Unexpected error fetching #{show['slug']}: #{e.message}")
      end
    end
    log_info("=== Fetch complete: #{total_new} new episode(s) ===")
  end

  def self.list_shows(detail: false)
    db = open_subs_db
    rows = db.query_all("SELECT slug, name, feed_url, source, opml_import FROM shows ORDER BY name")
    db.close
    if rows.empty?
      puts "No shows registered."
      return
    end
    puts format("%-30s %-10s %s", "SLUG", "PROTECTED", "NAME")
    rows.each do |r|
      prot = r["opml_import"] ? "yes" : "no"
      line = format("%-30s %-10s %s", r["slug"], prot, r["name"])
      line += "\n" + (" " * 50) + r["feed_url"] if detail
      puts line
    end
  end

  def self.add_show(feed_url)
    raw = fetch_feed(feed_url)
    if raw.nil?
      log_error("Could not fetch feed: #{feed_url}")
      return
    end
    unless is_audio_feed?(raw)
      log_error("Refusing to add: video podcast detected at #{feed_url}")
      return
    end
    title_m = raw.match(/<channel[^>]*>\s*<title[^>]*>([^<]*)<\/title>/im) ||
              raw.match(/<feed[^>]*>\s*<title[^>]*>([^<]*)<\/title>/im)
    if title_m.nil?
      log_error("Could not determine show title from #{feed_url}")
      return
    end
    name = title_m[1].strip
    slug = slugify(name)
    db = open_subs_db
    db.execute(
      "INSERT OR IGNORE INTO shows (slug, name, feed_url, source, opml_import) VALUES (?, ?, ?, 'manual', 0)",
      [slug, name, feed_url]
    )
    db.close
    log_info("Added show: #{name} (#{slug})")
    fetch_show_episodes(slug, name, feed_url)
  end

  def self.remove_show_data(slug)
    pod_dir = File.join(PODCASTS_DIR, slug)
    FileUtils.rm_rf(pod_dir) if Dir.exist?(pod_dir)
    pls = File.join(PLAYLISTS_DIR, "#{slug}.pls")
    File.delete(pls) if File.exist?(pls)
  end

  def self.delete_show(slug)
    db = open_subs_db
    row = db.get_first_hash("SELECT name FROM shows WHERE slug = ?", slug)
    if row.nil?
      log_error("No show found with slug '#{slug}'.")
      return
    end
    remove_show_data(slug)
    db.execute("DELETE FROM shows WHERE slug = ?", [slug])
    db.close
    played_db = open_played_db
    played_db.execute("DELETE FROM episodes WHERE show_slug = ?", [slug])
    played_db.close
    log_info("Deleted show: #{row['name']} (#{slug})")
  end

  def self.import_opml(path)
    content = File.read(path)
    shows = parse_opml(content)
    db = open_subs_db
    added = 0
    skipped_video = 0
    shows.each do |show|
      slug = slugify(show["name"])
      existing = db.get_first_value("SELECT slug FROM shows WHERE slug = ?", slug)
      next unless existing.nil?

      raw = fetch_feed(show["feed_url"])
      if raw.nil?
        log_warning("OPML import: skipping '#{show['name']}', could not fetch feed.")
        next
      end
      unless is_audio_feed?(raw)
        log_info("OPML import: skipping '#{show['name']}' (#{slug}): video podcast.")
        skipped_video += 1
        next
      end
      db.execute(
        "INSERT INTO shows (slug, name, feed_url, source, opml_import) VALUES (?, ?, ?, 'opml', 1)",
        [slug, show["name"], show["feed_url"]]
      )
      added += 1
    end
    db.close
    log_info("OPML import: #{added} added, #{skipped_video} video shows filtered out.")
  end

  def self.run_fetch(config)
    g = config["gpodder"]
    if g["enable"] == true
      remote = gpodder_sync(config)
      if remote.empty?
        log_info("No subscriptions retrieved from gPodder; using local registry only.")
      else
        added = register_remote_shows(remote)
        pruned = prune_stale_shows(remote)
        log_info("Sync: #{added} added, #{pruned} pruned.")
      end
    end
    fetch_all_episodes
  end

  def self.main
    options = {}
    OptionParser.new do |opts|
      opts.banner = "Usage: fetch_podcasts.rb [options]"
      opts.on("--list-shows", "List registered shows") { options[:list] = true }
      opts.on("--detail", "With --list-shows, show feed URLs") { options[:detail] = true }
      opts.on("--add-show FEED_URL", "Add a show from a feed URL") { |v| options[:add] = v }
      opts.on("--delete-show SLUG", "Delete a show and its data") { |v| options[:delete] = v }
      opts.on("--import-opml FILE", "Import shows from an OPML file") { |v| options[:import] = v }
    end.parse!

    init_paths
    FileUtils.mkdir_p(STATE_DIR)
    FileUtils.mkdir_p(LOGS_DIR)
    FileUtils.mkdir_p(PODCASTS_DIR)
    FileUtils.mkdir_p(PLAYLISTS_DIR)

    config = load_config

    if options[:list]
      list_shows(detail: options[:detail])
    elsif options[:add]
      add_show(options[:add])
    elsif options[:delete]
      delete_show(options[:delete])
    elsif options[:import]
      import_opml(options[:import])
    else
      run_fetch(config)
    end
  end
end

RadioAutomation.main
