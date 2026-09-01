#!/usr/bin/env jruby
# frozen_string_literal: true

require "json"
require "jdbc/sqlite3"
require "fileutils"
require "optparse"

Jdbc::SQLite3.load_driver

module RadioAutomation
  ROOT          = File.expand_path("..", __dir__)
  CONFIG_PATH   = File.join(ROOT, "config.json")

  STORAGE_DIR   = nil
  STATE_DIR     = nil
  SUBS_DB       = nil
  PLAYED_DB     = nil
  PODCASTS_DIR  = nil
  PLAYLISTS_DIR = nil
  LOGS_DIR      = nil

  def self.init_paths
    cfg = JSON.parse(File.read(CONFIG_PATH))
    @storage = File.expand_path(cfg["storage"])
    self.STORAGE_DIR   = @storage
    self.STATE_DIR     = File.join(@storage, "state")
    self.SUBS_DB       = File.join(STATE_DIR, "subscriptions.db")
    self.PLAYED_DB     = File.join(STATE_DIR, "played.db")
    self.PODCASTS_DIR  = File.join(@storage, "podcasts")
    self.PLAYLISTS_DIR = File.join(@storage, "playlists")
    self.LOGS_DIR      = File.join(@storage, "logs")
  end

  # --- JDBC connection helpers ---------------------------------------------

  def self.jdb_connect(db_file)
    java.sql.DriverManager.getConnection("jdbc:sqlite:#{db_file}")
  end

  def self.jdb_query(conn, sql, params = [])
    stmt = conn.prepareStatement(sql)
    params.each_with_index { |p, i| stmt.setObject(i + 1, p) }
    rs = stmt.executeQuery
    cols = []
    meta = rs.getMetaData
    (1..meta.getColumnCount).each { |i| cols << meta.getColumnName(i) }
    rows = []
    while rs.next
      row = {}
      cols.each { |c| row[c] = rs.getObject(c) }
      rows << row
    end
    rs.close
    stmt.close
    rows
  end

  def self.jdb_exec(conn, sql, params = [])
    stmt = conn.prepareStatement(sql)
    params.each_with_index { |p, i| stmt.setObject(i + 1, p) }
    stmt.executeUpdate
    stmt.close
  end

  def self.log_info(msg)
    puts "#{Time.now.iso8601} [INFO] #{msg}"
    append_log("update.log", msg)
  end

  def self.append_log(filename, msg)
    FileUtils.mkdir_p(LOGS_DIR)
    File.open(File.join(LOGS_DIR, filename), "a") { |f| f.puts msg }
  rescue StandardError
    nil
  end

  def self.open_subs_db
    db = jdb_connect(SUBS_DB)
    jdb_exec(db, <<-SQL)
      CREATE TABLE IF NOT EXISTS shows (
        slug TEXT PRIMARY KEY,
        guid TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        feed_url TEXT NOT NULL UNIQUE,
        source TEXT DEFAULT 'manual',
        opml_import INTEGER DEFAULT 0,
        archived INTEGER DEFAULT 1,
        created_at TEXT DEFAULT (datetime('now'))
      )
    SQL
    db
  end

  def self.open_played_db
    db = jdb_connect(PLAYED_DB)
    jdb_exec(db, <<-SQL)
      CREATE TABLE IF NOT EXISTS episodes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        show_slug TEXT NOT NULL,
        guid TEXT NOT NULL,
        title TEXT,
        file_path TEXT,
        enclosure_url TEXT,
        runlength INTEGER,
        played INTEGER DEFAULT 0,
        played_at TEXT,
        UNIQUE(show_slug, guid)
      )
    SQL
    db
  end

  # Pick the next unplayed episode for a show, keyed by guid.
  # Archived: prefer a local file_path; Live: use enclosure_url.
  def self.select_unplayed_episode(slug, played_db)
    rows = jdb_query(
      played_db,
      "SELECT guid, title, file_path, enclosure_url, runlength FROM episodes WHERE show_slug = ? AND played = 0 ORDER BY id ASC LIMIT 1",
      [slug]
    )
    return nil if rows.empty?
    rows.first
  end

  # Build the annotated URI line station.liq consumes.
  # Archived -> local file path; Live -> remote enclosure URL.
  def self.annotated_uri(ep)
    uri = ep["file_path"] || ep["enclosure_url"]
    return nil if uri.nil? || uri.to_s.empty?
    rl = ep["runlength"].to_i
    title = ep["title"].to_s.gsub('"', "'")
    "annotate:liq_runlength=\"#{rl}\",liq_title=\"#{title}\":#{uri}"
  end

  def self.write_queue_line(slug, line, out_path)
    FileUtils.mkdir_p(File.dirname(out_path))
    File.open(out_path, "w") { |f| f.puts(line) }
  end

  def self.mark_as_played(slug, guid, played_db)
    jdb_exec(
      played_db,
      "UPDATE episodes SET played = 1, played_at = datetime('now') WHERE show_slug = ? AND guid = ?",
      [slug, guid]
    )
  end

  def self.update_all
    subs_db = open_subs_db
    played_db = open_played_db
    shows = jdb_query(subs_db, "SELECT slug, name, archived FROM shows ORDER BY name")

    queued = 0
    skipped = 0
    shows.each do |show|
      slug = show["slug"]
      ep = select_unplayed_episode(slug, played_db)
      if ep.nil?
        log_info("#{slug}: no unplayed episodes, skipping.")
        skipped += 1
        next
      end
      line = annotated_uri(ep)
      if line.nil?
        log_info("#{slug}: episode #{ep['guid']} has no usable URI, skipping.")
        skipped += 1
        next
      end
      out_pls = File.join(PLAYLISTS_DIR, "#{slug}.txt")
      write_queue_line(slug, line, out_pls)
      mark_as_played(slug, ep["guid"], played_db)
      kind = ep["file_path"] ? "downloaded" : "live"
      log_info("#{slug}: queued #{ep['title']} [#{kind}] runlength=#{ep['runlength'].to_i}s")
      queued += 1
    end

    subs_db.close
    played_db.close
    log_info("=== Update complete: #{queued} queued, #{skipped} skipped ===")
  end

  def self.json_summary
    subs_db = open_subs_db
    played_db = open_played_db
    shows = jdb_query(subs_db, "SELECT slug FROM shows ORDER BY name")
    summary = {}
    shows.each do |show|
      slug = show["slug"]
      total = jdb_query(played_db, "SELECT COUNT(*) AS c FROM episodes WHERE show_slug = ?", [slug]).first["c"].to_i
      played = jdb_query(played_db, "SELECT COUNT(*) AS c FROM episodes WHERE show_slug = ? AND played = 1", [slug]).first["c"].to_i
      summary[slug] = { "total_episodes" => total, "played_count" => played, "unplayed" => total - played }
    end
    subs_db.close
    played_db.close
    puts JSON.pretty_generate(summary)
  end

  def self.main
    options = {}
    OptionParser.new do |opts|
      opts.banner = "Usage: update_playlists.rb [options]"
      opts.on("--json", "Emit JSON summary and exit") { options[:json] = true }
    end.parse!

    init_paths
    FileUtils.mkdir_p(STATE_DIR)
    FileUtils.mkdir_p(LOGS_DIR)
    FileUtils.mkdir_p(PLAYLISTS_DIR)

    if options[:json]
      json_summary
    else
      update_all
    end
  end
end

RadioAutomation.main
