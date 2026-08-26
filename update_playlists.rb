#!/usr/bin/env jruby
# frozen_string_literal: true

require "json"
require "sqlite3"
require "fileutils"
require "optparse"

module RadioAutomation
  ROOT          = File.expand_path("..", __dir__)
  STATE_DIR     = File.join(ROOT, "state")
  SUBS_DB       = File.join(STATE_DIR, "subscriptions.db")
  PLAYED_DB     = File.join(STATE_DIR, "played.db")
  PODCASTS_DIR  = File.join(ROOT, "podcasts")
  PLAYLISTS_DIR = File.join(ROOT, "playlists")
  LOGS_DIR      = File.join(ROOT, "logs")
  AUDIO_EXTS    = [".mp3", ".m4a"]

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
    db = SQLite3::Database.new(SUBS_DB)
    db.results_as_hash = true
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

  def self.find_audio_files(directory)
    return [] unless Dir.exist?(directory)
    Dir.glob(File.join(directory, "**", "*")).select do |f|
      File.file?(f) && AUDIO_EXTS.any? { |ext| f.end_with?(ext) }
    end.sort
  end

  def self.select_unplayed_episode(slug, played_db)
    files = find_audio_files(File.join(PODCASTS_DIR, slug))
    return nil if files.empty?

    played_rows = played_db.query_all(
      "SELECT file_path, played_at FROM episodes WHERE show_slug = ? AND played_at IS NOT NULL", slug
    )
    played_map = played_rows.each_with_object({}) { |r, h| h[r["file_path"]] = r["played_at"] }

    unplayed = files.reject { |f| played_map.key?(f) }
    return unplayed.first if unplayed.any?

    if played_map.any?
      played_map.min_by { |_path, ts| ts.to_s }[0]
    else
      files.first
    end
  end

  def self.write_pls(filepath, out_path)
    abs = File.absolute_path(filepath)
    content = "[playlist]\nFile1=#{abs}\nTitle1=Radio Episode\nLength1=-1\nNumberOfEntries=1\nVersion=2\n"
    FileUtils.mkdir_p(File.dirname(out_path))
    File.write(out_path, content)
  end

  def self.mark_as_played(slug, filepath, played_db)
    played_db.execute(
      "UPDATE episodes SET played_at = datetime('now') WHERE show_slug = ? AND file_path = ?",
      [slug, filepath]
    )
  end

  def self.update_all
    subs_db = open_subs_db
    played_db = open_played_db
    shows = subs_db.query_all("SELECT slug, name FROM shows ORDER BY name")

    shows.each do |show|
      slug = show["slug"]
      selected = select_unplayed_episode(slug, played_db)
      if selected.nil?
        log_info("#{slug}: no audio files found, skipping.")
        next
      end
      out_pls = File.join(PLAYLISTS_DIR, "#{slug}.pls")
      write_pls(selected, out_pls)
      mark_as_played(slug, selected, played_db)
      log_info("#{slug}: queued #{File.basename(selected)}")
    end

    subs_db.close
    played_db.close
  end

  def self.json_summary
    subs_db = open_subs_db
    played_db = open_played_db
    shows = subs_db.query_all("SELECT slug FROM shows ORDER BY name")
    summary = {}
    shows.each do |show|
      slug = show["slug"]
      files = find_audio_files(File.join(PODCASTS_DIR, slug))
      played_count = played_db.get_first_value(
        "SELECT COUNT(*) FROM episodes WHERE show_slug = ? AND played_at IS NOT NULL", slug
      )
      summary[slug] = { "total_files" => files.size, "played_count" => played_count }
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
