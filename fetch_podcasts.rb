#!/usr/bin/env jruby
# frozen_string_literal: true
#
# fetch_podcasts.rb - Fetch podcast episodes from RSS feeds, manage subscriptions,
# and download audio. JRuby-compatible (Ruby 3.1+ baseline).

require "nokogiri"
require "net/http"
require "uri"
require "json"
require "sqlite3"
require "fileutils"
require "time"

AUDIO_ROOT    = Pathname.new(File.expand_path(__dir__))
DB_PATH       = AUDIO_ROOT.join("state/subscriptions.db")
DOWNLOAD_DIR  = AUDIO_ROOT.join("podcasts")
CONFIG_PATH   = AUDIO_ROOT.join("config.json")

module Radio
  class Fetcher
    def initialize
      @db = get_db
    end

    attr_reader :db

    def load_config
      JSON.parse(File.read(CONFIG_PATH))
    end

    def get_db
      FileUtils.mkdir_p(DB_PATH.dirname)
      conn = SQLite3::Database.new(DB_PATH.to_s)
      conn.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS shows (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT UNIQUE NOT NULL,
          feed_url TEXT UNIQUE NOT NULL,
          slug TEXT UNIQUE NOT NULL,
          opml_import INTEGER DEFAULT 0
        );
      SQL
      conn.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS seen (
          url TEXT PRIMARY KEY,
          title TEXT,
          show_slug TEXT,
          duration_sec INTEGER DEFAULT 0,
          downloaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
      SQL
      # Migrate older databases lacking the new column
      cols = conn.execute("PRAGMA table_info(shows)").map { |r| r[1] }
      unless cols.include?("opml_import")
        conn.execute("ALTER TABLE shows ADD COLUMN opml_import INTEGER DEFAULT 0")
      end
      conn.commit rescue nil
      conn
    end

    def sanitize_slug(name)
      slug = name.downcase.strip
      slug = slug.gsub(/[^a-z0-9\-_]/, "_")
      slug = slug.split("_").reject(&:empty?).join("_")
      slug[0, 80]
    end

    # ---- Registration from OPML --------------------------------------------
    def register_shows_from_opml_xml(xml_bytes, opml_import: false)
      doc = Nokogiri::XML(xml_bytes)
      added = updated_flag = skipped = 0

      doc.xpath("//outline").each do |node|
        xml_url = node["xmlUrl"].to_s
        next if xml_url.empty?
        otype = node["type"].to_s
        next unless otype.empty? || otype == "rss"

        show_name = node["text"] || node["title"] || "Unknown Show"
        slug = sanitize_slug(show_name)
        flag = opml_import ? 1 : 0

        existing = db.get_first_row("SELECT id, opml_import FROM shows WHERE feed_url=?", xml_url)
        if existing
          existing_id, existing_flag = existing
          if flag == 1 && existing_flag.to_i == 0
            db.execute("UPDATE shows SET opml_import=1 WHERE id=?", existing_id)
            updated_flag += 1
            puts "  Protected existing: #{show_name} (#{slug})"
          else
            skipped += 1
          end
        else
          db.execute(
            "INSERT INTO shows (name, feed_url, slug, opml_import) VALUES (?, ?, ?, ?)",
            [show_name, xml_url, slug, flag]
          )
          added += 1
          puts "  Registered: #{show_name} -> #{slug}"
        end
      end

      db.commit
      puts "  Added #{added} new show(s)." if added.positive?
      puts "  Upgraded #{updated_flag} show(s) to protected." if updated_flag.positive?
      puts "  Skipped #{skipped} duplicate(s)." if skipped.positive?
      added
    end

    def import_opml_file(filepath)
      unless File.exist?(filepath)
        puts "ERROR: File not found: #{filepath}"
        exit 1
      end
      xml_data = File.binread(filepath)
      count = register_shows_from_opml_xml(xml_data, opml_import: true)
      total = db.get_first_row("SELECT COUNT(*) FROM shows")[0]
      puts "\nImport complete. #{count} new show(s) added. Total registered: #{total}"
    ensure
      db&.close
    end

    # ---- gPodder.net sync ----------------------------------------------------
    def sync_gpoddernet
      cfg = load_config
      gp = cfg.fetch("gpodder", {})

      unless gp.fetch("enable", false)
        puts "gpodder.net sync is disabled in config.json."
        return
      end

      unless gp["username"] && gp["password"]
        puts "ERROR: gpodder.username/gpodder.password not set in config.json"
        exit 1
      end

      url = "#{gp['host']}/subscriptions/#{gp['username']}.opml"
      puts "Fetching subscriptions from #{gp['host']} for '#{gp['username']}'..."

      uri = URI(url)
      resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        req = Net::HTTP::Get.new(uri)
        req.basic_auth(gp["username"], gp["password"])
        http.request(req)
      end

      if resp.code == "401"
        puts "ERROR: Authentication failed. Check username/password in config.json."
        exit 1
      elsif resp.code != "200"
        puts "ERROR: Unexpected response #{resp.code}: #{resp.body[0, 200]}"
        exit 1
      end

      # Collect all feed URLs from the current subscription list
      root_doc = Nokogiri::XML(resp.body)
      gp_feed_urls = Set.new
      root_doc.xpath("//outline").each do |node|
        fu = node["xmlUrl"].to_s
        gp_feed_urls.add(fu) unless fu.empty?
      end

      count = register_shows_from_opml_xml(resp.body, opml_import: false)
      total = db.get_first_row("SELECT COUNT(*) FROM shows")[0]

      prune_removed_shows(gp_feed_urls)

      puts "\nSync complete. #{count} new, total registered: #{total}"
    end

    def prune_removed_shows(gp_feed_urls)
      rows = db.execute("SELECT slug, feed_url, name FROM shows WHERE opml_import = 0")
      to_remove = rows.select { |_slug, feed_url, _name| !gp_feed_urls.include?(feed_url) }
      return if to_remove.empty?

      to_remove.each do |slug, _feed_url, name|
        puts "  Removing unsubscribed show: #{name} (#{slug})"
        db.execute("DELETE FROM seen WHERE show_slug=?", slug)
        db.execute("DELETE FROM shows WHERE slug=?", slug)
        show_dir = DOWNLOAD_DIR.join(slug)
        if Dir.exist?(show_dir)
          FileUtils.rm_rf(show_dir)
          puts "  Deleted directory: #{show_dir}"
        end
      end

      db.commit
      puts "  Pruned #{to_remove.size} removed show(s)."
    end

    # ---- Manual management ---------------------------------------------------
    def delete_show(slug)
      row = db.get_first_row("SELECT name FROM shows WHERE slug=?", slug)
      if row.nil?
        puts "No show found with slug '#{slug}'."
        return
      end
      name = row[0]
      puts "Deleting show: #{name} (#{slug})"
      db.execute("DELETE FROM seen WHERE show_slug=?", slug)
      db.execute("DELETE FROM shows WHERE slug=?", slug)
      db.commit

      show_dir = DOWNLOAD_DIR.join(slug)
      if Dir.exist?(show_dir)
        FileUtils.rm_rf(show_dir)
        puts "Deleted directory: #{show_dir}"
      end

      pls_file = AUDIO_ROOT.join("playlists", "#{slug}.pls")
      if File.exist?(pls_file)
        File.delete(pls_file)
        puts "Deleted playlist: #{pls_file}"
      end

      puts "Done."
    end

    def add_show(feed_url)
      puts "Fetching feed: #{feed_url}"
      parsed = parse_feed(feed_url)
      if parsed.nil?
        puts "ERROR: Invalid or unreachable feed."
        exit 1
      end

      show_name, entries = parsed
      slug = sanitize_slug(show_name)
      puts "  Title: #{show_name}"
      puts "  Slug:  #{slug}"
      puts "  Entries found: #{entries.size}"

      existing = db.get_first_row("SELECT name FROM shows WHERE feed_url=?", feed_url)
      if existing
        puts "NOTE: Feed already registered as '#{existing[0]}'. Nothing to do."
        return
      end

      db.execute(
        "INSERT INTO shows (name, feed_url, slug, opml_import) VALUES (?, ?, ?, 1)",
        [show_name, feed_url, slug]
      )
      db.commit
      puts "  Registered: #{show_name} -> #{slug}"

      puts "\n--- Fetching episodes ---"
      fetch_feed(show_name, feed_url, slug)

      puts "\nDone. Episodes saved to: #{DOWNLOAD_DIR.join(slug)}/"
    end

    # ---- Core fetching ---------------------------------------------------------
    def parse_feed(feed_url)
      body = http_get(feed_url)
      return nil if body.nil?

      doc = Nokogiri::XML(body)
      doc.remove_namespaces!

      # Support both RSS (<channel>) and Atom (<feed>)
      channel = doc.at_xpath("//channel") || doc.at_xpath("//feed")
      return nil if channel.nil?

      title = (channel.at_xpath("./title")&.text.presence || "Unknown Show")

      entries = []
      if doc.root.name == "rss"
        doc.xpath("//item").each do |item|
          enc = item.at_xpath(".//enclosure")
          next if enc.nil?
          entries << {
            url: enc["url"].to_s,
            type: enc["type"].to_s,
            length: enc["length"].to_s,
            title: (item.at_xpath("./title")&.text.presence || "untitled")
          }
        end
      else
        doc.xpath("//entry").each do |entry|
          link = entry.at_xpath("./link[@rel='enclosure']") ||
                 entry.at_xpath("./link")
          next if link.nil?
          dur = entry.at_xpath(".//media:duration")
          entries << {
            url: link["href"].to_s,
            type: link["type"].to_s,
            length: dur ? dur.text : "",
            title: (entry.at_xpath("./title")&.text.presence || "untitled")
          }
        end
      end

      [title, entries]
    rescue StandardError => e
      warn "Feed parse error for #{feed_url}: #{e.message}"
      nil
    end

    def http_get(url, timeout: 120)
      uri = URI(url)
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
                       open_timeout: 30, read_timeout: timeout) do |http|
        res = http.request(Net::HTTP::Get.new(uri))
        res.code == "200" ? res.body : nil
      end
    end

    def fetch_feed(show_name, feed_url, slug)
      parsed = parse_feed(feed_url)
      if parsed.nil?
        puts "[#{show_name}] ERROR: Could not parse feed."
        return
      end

      _title, entries = parsed
      show_dir = DOWNLOAD_DIR.join(slug)
      FileUtils.mkdir_p(show_dir)

      new_count = 0
      entries.each do |ep|
        ep_url = ep[:url]
        title = ep[:title]
        next if ep_url.empty?

        row = db.get_first_row("SELECT 1 FROM seen WHERE url=?", ep_url)
        next if row

        duration_sec = parse_duration(ep[:length])

        safe_title = title.gsub(/[^\w\- ]/, "_").strip[0, 120]
        ext = extension_for_type(ep[:type])
        filepath = show_dir.join("#{safe_title}#{ext}")

        if File.exist?(filepath)
          db.execute(
            "INSERT OR IGNORE INTO seen (url, title, show_slug, duration_sec) VALUES (?, ?, ?, ?)",
            [ep_url, title, slug, duration_sec]
          )
          db.commit
          next
        end

        begin
          puts "[#{show_name}] Downloading: #{title}"
          data = http_get(ep_url)
          if data.nil?
            raise "download returned non-200"
          end
          File.binwrite(filepath, data)

          db.execute(
            "INSERT OR IGNORE INTO seen (url, title, show_slug, duration_sec) VALUES (?, ?, ?, ?)",
            [ep_url, title, slug, duration_sec]
          )
          db.commit
          new_count += 1
        rescue StandardError => e
          puts "[#{show_name}] FAILED to download '#{title}': #{e.message}"
        end
      end

      if new_count.positive?
        puts "[#{show_name}] Downloaded #{new_count} new episode(s)."
      else
        puts "[#{show_name}] No new episodes."
      end
    end

    def parse_duration(raw)
      raw = raw.to_s.strip
      return 0 if raw.empty?
      if raw.include?(":")
        raw.split(":").last.to_i
      else
        raw.to_i
      end
    rescue StandardError
      0
    end

    def extension_for_type(type_str)
      t = type_str.to_s.downcase
      ".ogg" if t.include?("ogg")
      ".m4a" if t.include?("m4a") || t.include?("aac")
      ".mp3"
    end

    def list_shows(detail: false)
      rows = db.execute("SELECT name, slug, feed_url, opml_import FROM shows ORDER BY name")
      if rows.empty?
        puts "No shows registered."
        return
      end

      puts format("%-40s %-30s %-10s", "Show Name", "Slug", "Protected")
      puts "-" * 80
      rows.each do |name, slug, _feed_url, prot|
        puts format("%-40s %-30s %-10s", name, slug, prot.to_i == 1 ? "yes" : "no")
      end

      if detail
        puts "\nFeed URLs:"
        rows.each do |_name, slug, feed_url, _prot|
          puts "  #{slug}: #{feed_url}"
        end
      end
    end

    def close
      db&.close
    end
  end
end

require "set"

def main
  args = ARGV.dup
  f = Radio::Fetcher.new

  if args.include?("--delete-show")
    idx = args.index("--delete-show")
    val = args[idx + 1]
    if val.nil?
      puts "Usage: fetch_podcasts.rb --delete-show <slug>"
      exit 1
    end
    f.delete_show(val)
  elsif args.include?("--add-show")
    idx = args.index("--add-show")
    val = args[idx + 1]
    if val.nil?
      puts "Usage: fetch_podcasts.rb --add-show <feed-url>"
      exit 1
    end
    f.add_show(val)
  elsif args.include?("--import-opml")
    idx = args.index("--import-opml")
    val = args[idx + 1]
    if val.nil?
      puts "Usage: fetch_podcasts.rb --import-opml <path-to-file.opml>"
      exit 1
    end
    f.import_opml_file(val)
  elsif args.include?("--list-shows")
    f.list_shows(detail: args.include?("--detail"))
  else
    cfg = f.load_config
    gp = cfg.fetch("gpodder", {})

    if gp.fetch("enable", false)
      puts "--- Syncing subscriptions from gpodder.net ---"
      begin
        f.sync_gpoddernet
      rescue SystemExit
        raise
      rescue StandardError => e
        puts "! gpodder sync failed (continuing with existing shows): #{e.message}"
      end
    end

    shows = f.db.execute("SELECT name, feed_url, slug FROM shows")
    if shows.empty?
      puts "No shows registered. Import an OPML file, add a show, or enable gpodder sync."
    else
      puts "--- Fetching episodes for #{shows.size} show(s) ---"
      shows.each do |show_name, feed_url, slug|
        begin
          f.fetch_feed(show_name, feed_url, slug)
        rescue StandardError => e
          puts "[#{show_name}] FAILED: #{e.message}"
        end
      end
    end
  end
ensure
  f&.close
end

main
