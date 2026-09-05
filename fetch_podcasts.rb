#!/usr/bin/env jruby
# frozen_string_literal: true
#
# fetch_podcasts.rb - Podcast subscription management for the radio automation.
#
# Manages the shows table in subscriptions.db and the episodes table in played.db.
# Automatically syncs with gpodder.net on every invocation (if enabled in config).
#
# Usage:
#   fetch_podcasts.rb --add-show <url>
#   fetch_podcasts.rb --list [--detail]
#   fetch_podcasts.rb --remove <slug-or-url>
#   fetch_podcasts.rb --fetch-all
#   fetch_podcasts.rb --import-opml <file>
#   fetch_podcasts.rb --archive <slug>
#   fetch_podcasts.rb --unarchive <slug>

require "json"
require "net/http"
require "uri"
require "digest/md5"
require "sequel"
require "nokogiri"

SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
CONFIG_PATH = File.join(SCRIPT_DIR, "config.json")

def load_config
  raw = JSON.parse(File.read(CONFIG_PATH))
  storage = raw["storage"] || "/mnt/storage/radio"
  icecast = raw["icecast"] || {}
  gpodder = raw["gpodder"] || {}
  {
    :storage => storage,
    :icecast_host => icecast["host"] || "127.0.0.1",
    :icecast_port => icecast["port"].to_i,
    :icecast_mount => icecast["mount"] || "/data",
    :icecast_source_user => icecast["source_username"] || "source",
    :icecast_source_pass => icecast["source_password"] || "",
    :gpodder_enable => gpodder["enable"] == true,
    :gpodder_host => gpodder["host"] || "https://gpodder.net",
    :gpodder_user => gpodder["username"] || "",
    :gpodder_pass => gpodder["password"] || "",
    :gpodder_device_id => gpodder["device_id"] || ""
  }
end

CFG = load_config
STORAGE_ROOT = CFG[:storage]
STATE_DIR = File.join(STORAGE_ROOT, "state")
LOGS_DIR = File.join(STORAGE_ROOT, "logs")
TMP_DIR = File.join(STATE_DIR, "tmp")
SUBS_DB = File.join(STATE_DIR, "subscriptions.db")
PLAYED_DB = File.join(STATE_DIR, "played.db")
LOG_FILE = File.join(LOGS_DIR, "fetch_cron.log")

def ensure_dir(path)
  return if Dir.exist?(path)
  parent = File.dirname(path)
  unless path.start_with?("/")
    raise ArgumentError, "ensure_dir requires an absolute path, got: #{path}"
  end
  components = path.split("/").reject(&:empty?)
  current = "/"
  components.each do |comp|
    current = File.join(current, comp)
    unless Dir.exist?(current)
      begin
        Dir.mkdir(current)
      rescue Errno::EEXIST
        nil
      end
    end
  end
end

[STORAGE_ROOT, STATE_DIR, LOGS_DIR, TMP_DIR].each { |d| ensure_dir(d) }

$log_fh = File.open(LOG_FILE, "a+")

def log(level, msg)
  ts = Time.now.strftime("%Y-%m-%d %H:%M:%S")
  line = "[#{ts}] [#{level}] #{msg}"
  $log_fh.write(line + "\n")
  $log_fh.flush
  puts line
rescue Exception => e
  puts "LOG ERROR: #{e.class} #{e.message}"
end

$db_s = Sequel.connect("jdbc:sqlite:" + SUBS_DB)
$db_p = Sequel.connect("jdbc:sqlite:" + PLAYED_DB)
def table_count(db, tbl_name, col = :name)
  db[:sqlite_master].where(type: "table", name: tbl_name).count
rescue Exception => e
  log("WARN", "count check failed for #{tbl_name}: #{e.class} #{e.message}")
  0
end

def ensure_schema
  begin
    if table_count($db_s, "shows").zero?
      $db_s.execute <<-SQL
        CREATE TABLE shows (
          guid TEXT PRIMARY KEY,
          slug TEXT UNIQUE NOT NULL,
          title TEXT NOT NULL,
          feed_url TEXT NOT NULL,
          audio_only INTEGER DEFAULT 1,
          archive INTEGER DEFAULT 0,
          opml_import INTEGER DEFAULT 0,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
      SQL
      log("INFO", "Created 'shows' table")
    end

    if table_count($db_p, "episodes").zero?
      $db_p.execute <<-SQL
        CREATE TABLE episodes (
          guid TEXT PRIMARY KEY,
          show_guid TEXT NOT NULL,
          title TEXT,
          enclosure_url TEXT,
          duration_seconds INTEGER,
          published_date TEXT,
          played INTEGER DEFAULT 0,
          downloaded INTEGER DEFAULT 0,
          local_path TEXT
        )
      SQL
      log("INFO", "Created 'episodes' table")
    end
  rescue Exception => e
    log("ERROR", "Schema setup failed: #{e.class} #{e.message}")
    raise e
  end
end

def table_exists?(db, tbl_name)
  begin
    db.from(:sqlite_master).where(name: tbl_name).count > 0
  rescue Exception => e
    log("WARN", "table_exists? check failed for '#{tbl_name}': #{e.class} #{e.message}")
    false
  end
end

ensure_schema

def make_slug(title_str, feed_url)
  base = title_str.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_+|_+$/, "")
  base = "show" if base.empty?
  suffix = Digest::MD5.hexdigest(feed_url)[0..3]
  candidate = "#{base}_#{suffix}"
  existing = $db_s[:shows].select_map(:slug)
  i = 1
  while existing.include?(candidate)
    i += 1
    candidate = "#{base}_#{suffix}_#{i}"
  end
  candidate
end

def gen_guid(seed_str)
  Digest::MD5.hexdigest(seed_str)
end

def http_stream_to_file(url, dest_path, user = nil, pass = nil)
  uri = URI.parse(url)
  req = Net::HTTP::Get.new(uri.path + (uri.query ? "?#{uri.query}" : ""))
  if user && pass
    req.basic_auth(user, pass)
  end
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = 30
  http.read_timeout = 60
  success = false
  begin
    http.request(req) do |r|
      if r.is_a?(Net::HTTPSuccess)
        File.open(dest_path, "wb") do |f|
          r.read_body { |chunk| f.write(chunk) }
        end
        size = File.size(dest_path)
        log("INFO", "Downloaded #{size} bytes from #{url}")
        success = true
      else
        log("ERROR", "HTTP #{r.code} fetching #{url}")
      end
    end
  rescue Exception => e
    log("ERROR", "Failed to download #{url}: #{e.class} #{e.message}")
  end
  success
end

def parse_feed(data={})
  result = {:title => "Untitled Show", :description => "", :episodes => []}
  unless data.is_a?(::Hash)
    raise "You MUST provide a Hash with file_path and feed_url specified. You passed #{data.inspect}"
  end
  file_path = data[:file_path]
  unless file_path
    raise "You MUST provide a Hash with file_path and feed_url specified. You passed #{data.inspect}"
  end
  feed_url = data[:feed_url]
  unless feed_url
    raise "You MUST provide a Hash with file_path and feed_url specified. You passed #{data.inspect}"
  end
  #
  document = Nokogiri::XML(File.read(file_path))
  unless document
    raise "Failed to import XML document: #{file_path.inspect}"
  end
  channel = document.at_xpath("//channel")
  if channel.nil?
    log("ERROR", "No <channel> found in feed at #{feed_url}")
  else
    title_element = channel.at_xpath("./title")
    description_element = channel.at_xpath("./description")
    show_title = title_element ? title_element.text.strip : "Untitled Show"
    show_description = description_element ? description_element.text.strip : ""
    #
    episodes = []
    channel.elements("item").each do |item|
      #
      episode_title_element = item.at_xpath("./title")
      enclosure_element = item.at_xpath("./enclosure")
      guid_element = item.at_xpath("./guid")
      duration_element = item.at_xpath(".//duration")
      publication_date_element = item.at_xpath("./pubDate")
      #
      episode_title = episode_title_element ? episode_title_element.text.strip : "Untitled"
      enclosure_url = enclosure_element ? enclosure_element.attribute("url").to_s.strip : ""
      enclosure_type = enclosure_element ? enclosure_element.attribute("type").to_s.strip : ""
      enclosure_length = enclosure_element ? enclosure_element.attribute("length").to_s.strip.to_i : 0
      episode_guid = guid_element ? guid_element.text.strip : ""
      episode_duration = duration_element ? duration_element.text.strip.to_i : 0
      episode_publication_date = publication_date_element ? publication_date_element.text.strip : ""
      #
      if enclosure_url.empty? || enclosure_type =~ /video/i
        next
      else
        #
        if episode_guid.empty?
          episode_guid = gen_guid("#{enclosure_url}#{episode_title}")
        end
        if episode_duration <= 0 && enclosure_length > 0
          episode_duration = (enclosure_length / (128 * 1024)).to_i
        end
        #
        episodes << {:guid => episode_guid, :title => episode_title, :url => enclosure_url, :duration_seconds => episode_duration, :published_at => episode_publication_date, :file_size_bytes => enclosure_length}
        #
      end
      #
    end
    #
    result = {:title => show_title, :description => show_description, :episodes => episodes}
    #
  end
  #
  result
end


def parse_feed_from_file(file_path="", feed_url="")
  doc = Nokogiri::XML(File.read(file_path))
  channel = doc.at_xpath("//channel")
  if channel.nil?
    log("ERROR", "No <channel> found in feed at #{feed_url}")
    return nil
  end

  title_el = channel.at_xpath("./title")
  desc_el = channel.at_xpath("./description")
  show_title = title_el ? title_el.text.strip : "Unknown Show"
  show_desc = desc_el ? desc_el.text.strip : ""

  episodes = []
  channel.elements("item").each do |item|
    ep_title_el = item.at_xpath("./title")
    enc_el = item.at_xpath("./enclosure")
    guid_el = item.at_xpath("./guid")
    dur_el = item.at_xpath(".//duration")
    pub_el = item.at_xpath("./pubDate")

    ep_title = ep_title_el ? ep_title_el.text.strip : "Untitled"
    enc_url = enc_el ? enc_el.attribute("url").to_s.strip : ""
    enc_type = enc_el ? enc_el.attribute("type").to_s.strip : ""
    enc_len = enc_el ? enc_el.attribute("length").to_s.strip.to_i : 0
    ep_guid = guid_el ? guid_el.text.strip : ""
    ep_dur = dur_el ? dur_el.text.strip.to_i : 0
    ep_pub = pub_el ? pub_el.text.strip : ""

    next if enc_url.empty?

    if enc_type =~ /video/i
      next
    end

    if ep_guid.empty?
      ep_guid = gen_guid("#{enc_url}#{ep_title}")
    end

    if ep_dur <= 0 && enc_len > 0
      ep_dur = (enc_len / (128 * 1024)).to_i
    end

    episodes << {
      :guid => ep_guid,
      :title => ep_title,
      :url => enc_url,
      :duration_seconds => ep_dur,
      :published_at => ep_pub,
      :file_size_bytes => enc_len
    }
  end

  {
    :title => show_title,
    :description => show_desc,
    :episodes => episodes
  }
end

def register_show(parsed, feed_url)
  slug = make_slug(parsed[:title], feed_url)
  show_guid = gen_guid(feed_url)
  existing = $db_s[:shows].where(slug: slug).first
  if existing
    log("INFO", "Show already registered: #{parsed[:title]} (#{slug})")
    return existing[:guid]
  end

  $db_s[:shows].insert(guid: show_guid, slug: slug, title: parsed[:title], feed_url: feed_url, audio_only: 1, archive: 0)
  log("INFO", "Registered show: #{parsed[:title]} (#{slug})")

  parsed[:episodes].each do |ep|
    $db_p[:episodes].insert(
      guid: ep[:guid],
      show_guid: show_guid,
      title: ep[:title],
      url: ep[:url],
      duration_seconds: ep[:duration_seconds],
      published_at: ep[:published_at],
      played: 0,
      downloaded: 0,
      file_size_bytes: ep[:file_size_bytes]
    )
  end

  log("INFO", "Stored #{parsed[:episodes].size} episodes for #{slug}")
  show_guid
end

def cmd_add_show(url)
  log("INFO", "Adding show: #{url}")
  tmp_file = File.join(TMP_DIR, "feed_#{Process.pid}.xml")
  ok = http_stream_to_file(url, tmp_file)
  unless ok
    log("ERROR", "Could not download feed: #{url}")
    exit 1
  end
  # ???
  parsed = parse_feed({:file_path => tmp_file, :feed_url => url})
  # parsed = parse_feed_from_file(tmp_file, url)
  begin
    File.delete(tmp_file)
  rescue Errno::ENOENT
    nil
  end

  if parsed.nil?
    log("ERROR", "Could not parse feed: #{url}")
    exit 1
  end

  register_show(parsed, url)
  log("INFO", "Done adding show: #{parsed[:title]}")
end

def cmd_list(detail)
  rows = $db_s[:shows].all
  if rows.empty?
    puts "No shows registered."
    return
  end
  rows.each do |r|
    line = "%-30s %-40s arch=%d" % [r[:slug], r[:title], r[:archive]]
    if detail
      ep_count = $db_p[:episodes].where(show_guid: r[:guid]).count
      played_count = $db_p[:episodes].where(show_guid: r[:guid], played: 1).count
      line += " eps=#{ep_count} played=#{played_count}"
    end
    puts line
  end
end

def cmd_remove(slug_or_url)
  row = $db_s[:shows].where(Sequel.or({slug: slug_or_url}, {feed_url: slug_or_url})).first
  if row.nil?
    log("ERROR", "Show not found: #{slug_or_url}")
    exit 1
  end
  $db_p[:episodes].where(show_guid: row[:guid]).delete
  $db_s[:shows].where(guid: row[:guid]).delete
  log("INFO", "Removed show #{row[:slug]} and its episodes")
end

def cmd_fetch_all
  rows = $db_s[:shows].all
  if rows.empty?
    log("INFO", "No shows to fetch.")
    return
  end
  rows.each do |show|
    log("INFO", "Fetching: #{show[:title]} (#{show[:slug]})")
    tmp_file = File.join(TMP_DIR, "feed_#{show[:slug]}_#{Process.pid}.xml")
    ok = http_stream_to_file(show[:feed_url], tmp_file)
    unless ok
      log("ERROR", "Could not download feed: #{show[:feed_url]}")
      next
    end
    # ???
    parsed = parse_feed({:file_path => tmp_file, :feed_url => show[:feed_url]})
    # parsed = parse_feed_from_file(tmp_file, show[:feed_url])
    begin
      File.delete(tmp_file)
    rescue Errno::ENOENT
      nil
    end
    if parsed.nil?
      log("ERROR", "Could not parse feed: #{show[:feed_url]}")
      next
    end
    new_eps = 0
    parsed[:episodes].each do |ep|
      existing = $db_p[:episodes].where(guid: ep[:guid]).first
      if existing.nil?
        $db_p[:episodes].insert(
          guid: ep[:guid],
          show_guid: show[:guid],
          title: ep[:title],
          url: ep[:url],
          duration_seconds: ep[:duration_seconds],
          published_at: ep[:published_at],
          played: 0,
          downloaded: 0,
          file_size_bytes: ep[:file_size_bytes]
        )
        new_eps += 1
      end
    end
    log("INFO", "#{new_eps} new episodes for #{show[:slug]}")
  end
end

def cmd_import_opml(opml_file)
  doc = Nokogiri::XML(File.read(opml_file))
  outlines = doc.xpath("//outline[@type='rss']")
  count = 0
  outlines.each do |o|
    url = o.attribute("xmlUrl").to_s.strip
    next if url.empty?
    cmd_add_show(url)
    count += 1
  end
  log("INFO", "Imported #{count} shows from OPML")
end

def cmd_archive(slug)
  row = $db_s[:shows].where(slug: slug).first
  if row.nil?
    log("ERROR", "Show not found: #{slug}")
    exit 1
  end
  $db_s[:shows].where(guid: row[:guid]).update(archive: 1)
  log("INFO", "Archived show: #{slug}")
end

def cmd_unarchive(slug)
  row = $db_s[:shows].where(slug: slug).first
  if row.nil?
    log("ERROR", "Show not found: #{slug}")
    exit 1
  end
  $db_s[:shows].where(guid: row[:guid]).update(archive: 0)
  log("INFO", "Unarchived show: #{slug}")
end

def sync_gpodder
  unless CFG[:gpodder_enable]
    return
  end
  
  log("DEBUG", "Sync check: enable=#{CFG[:gpodder_enable]}, user=#{CFG[:gpodder_user]}, device=#{CFG[:gpodder_device_id]}")
  
  device_id = CFG[:gpodder_device_id].to_s.strip
  if device_id.empty?
    log("WARN", "gPodder sync enabled but no device_id configured; skipping.")
    return
  end
  
  host = CFG[:gpodder_host].to_s.strip
  user = CFG[:gpodder_user].to_s.strip
  pass = CFG[:gpodder_pass].to_s
  full_host = host.start_with?("http") ? host : "https://#{host}"
  api_url   = "#{full_host}/subscriptions/#{user}/#{device_id}.opml"
  tmp_file  = File.join(TMP_DIR, "gpodder_sync_#{Process.pid}.opml")
  
  ok = http_stream_to_file(api_url, tmp_file, user, pass)
  unless ok
    log("WARN", "gPodder sync failed to download: #{api_url}")
    return
  end
  
  begin
    doc = Nokogiri::XML(File.read(tmp_file))
  rescue Exception => e
    log("WARN", "gPodder sync: failed to parse OPML: #{e.message}")
    return
  ensure
    begin
      File.delete(tmp_file)
    rescue Errno::ENOENT
      nil
    end
  end
  
  outlines = doc.xpath("//outline[@xmlUrl]").map do |o|
    {
      url:   o.attr("xmlUrl").to_s.strip,
      title: o.attr("title").to_s.strip
    }
  end
  
  remote_urls = outlines.map { |o| o[:url] }.select { |u| !u.empty? }
  added = 0
  
  outlines.each do |o|
    next if o[:url].empty?
    
    existing = $db_s[:shows].where(feed_url: o[:url]).first
    if existing.nil?
      log("INFO", "gPodder sync: registering new show #{o[:title]}")
      tmp_feed = File.join(TMP_DIR, "gpodder_feed_#{Process.pid}.xml")
      fok = http_stream_to_file(o[:url], tmp_feed)
      
      if fok
        # ???
        parsed = parse_feed({:file_path => tmp_feed, :feed_url => o[:url]})
        # parsed = parse_feed_from_file(tmp_feed, o[:url])
        
        begin
          File.delete(tmp_feed)
        rescue Errno::ENOENT
          nil
        end
        
        if parsed
          register_show(parsed, o[:url])
          added += 1
        end
      end
    end
  end
  
  pruned = 0
  $db_s[:shows].all.each do |row|
    if row[:opml_import].to_i == 0 && !remote_urls.include?(row[:feed_url].to_s)
      $db_p[:episodes].where(show_guid: row[:guid]).delete
      $db_s[:shows].where(guid: row[:guid]).delete
      pruned += 1
      log("INFO", "gPodder sync: pruned '#{row[:slug]}'")
    end
  end
  
  log("INFO", "gPodder sync complete: #{added} added, #{pruned} removed")
end

def main
  args = ARGV.dup
  command = args.shift
  sync_gpodder
  case command
  when "--add-show"
    url = args.shift
    if url.nil?
      puts "Usage: fetch_podcasts.rb --add-show <url>"
      exit 1
    end
    cmd_add_show(url)
  when "--list"
    detail = args.include?("--detail")
    cmd_list(detail)
  when "--remove"
    slug = args.shift
    if slug.nil?
      puts "Usage: fetch_podcasts.rb --remove <slug-or-url>"
      exit 1
    end
    cmd_remove(slug)
  when "--fetch-all"
    cmd_fetch_all
  when "--import-opml"
    opml_file = args.shift
    if opml_file.nil?
      puts "Usage: fetch_podcasts.rb --import-opml <file>"
      exit 1
    end
    cmd_import_opml(opml_file)
  when "--archive"
    slug = args.shift
    if slug.nil?
      puts "Usage: fetch_podcasts.rb --archive <slug>"
      exit 1
    end
    cmd_archive(slug)
  when "--unarchive"
    slug = args.shift
    if slug.nil?
      puts "Usage: fetch_podcasts.rb --unarchive <slug>"
      exit 1
    end
    cmd_unarchive(slug)
  else
    puts "Usage: fetch_podcasts.rb [--add-show <url>|--list|--remove <slug>|--fetch-all|--import-opml <file>|--archive <slug>|--unarchive <slug>]"
  end
end

main if __FILE__ == $PROGRAM_NAME

