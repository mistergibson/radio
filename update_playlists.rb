#!/usr/bin/env jruby
# frozen_string_literal: true
#
# update_playlists.rb - Regenerate per-show playlist files based on playback history.
# JRuby-compatible (Ruby 3.1+ baseline).

require "json"
require "sqlite3"
require "fileutils"
require "time"

AUDIO_ROOT    = Pathname.new(File.expand_path(__dir__))
PLAYLISTS_DIR = AUDIO_ROOT.join("playlists")
STATE_DB      = AUDIO_ROOT.join("state/played.db")
SUBS_DB       = AUDIO_ROOT.join("state/subscriptions.db")
SHOWS_DIR     = AUDIO_ROOT.join("podcasts")

module Radio
  class PlaylistUpdater
    def initialize
      FileUtils.mkdir_p(PLAYLISTS_DIR)
      FileUtils.mkdir_p(STATE_DB.dirname)
      @played_db = connect_played_db
      @subs_db   = connect_subs_db
    end

    attr_reader :played_db, :subs_db

    def connect_played_db
      conn = SQLite3::Database.new(STATE_DB.to_s)
      conn.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS played (
          filename TEXT PRIMARY KEY,
          show TEXT,
          played_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
      SQL
      conn
    end

    def connect_subs_db
      conn = SQLite3::Database.new(SUBS_DB.to_s)
      conn
    end

    # Build a .pls for each show: pick an unplayed episode, mark it played.
    def regenerate_all
      shows = subs_db.execute("SELECT name, slug FROM shows ORDER BY name")
      if shows.empty?
        puts "No shows registered."
        return
      end

      regenerated = 0
      shows.each do |_name, slug|
        if regenerate_show_pls(slug)
          regenerated += 1
        end
      end

      puts "Regenerated #{regenerated} playlist(s)."
    end

    def regenerate_show_pls(slug)
      show_dir = SHOWS_DIR.join(slug)
      return false unless Dir.exist?(show_dir)

      # Gather candidate audio files recursively
      candidates = Dir.glob(show_dir.join("**/*.{mp3,m4a,ogg,flac}")).sort
      return false if candidates.empty?

      # Determine which have already been played
      played_rows = played_db.execute("SELECT filename FROM played WHERE show=?", slug)
      played_set = played_rows.map { |r| File.basename(r[0]) }.to_set

      unplayed = candidates.reject { |path| played_set.include?(File.basename(path)) }

      # Fall back to the least-recently-played (or any) if nothing is unplayed
      chosen = unplayed.first || lru_episode(candidates, slug)
      return false if chosen.nil?

      pls_path = PLAYLISTS_DIR.join("#{slug}.pls")
      File.write(pls_path, "#{chosen}\n")

      # Record playback so the next cycle picks a different episode
      played_db.execute(
        "INSERT OR REPLACE INTO played (filename, show) VALUES (?, ?)",
        [chosen.to_s, slug]
      )
      played_db.commit

      puts "  #{slug}: queued #{File.basename(chosen)}"
      true
    end

    def lru_episode(candidates, slug)
      played_rows = played_db.execute(
        "SELECT filename, played_at FROM played WHERE show=? ORDER BY played_at ASC", slug
      )
      played_map = played_rows.to_h { |fname, ts| [File.basename(fname), ts] }
      candidates.min_by { |c| played_map[File.basename(c)] || Time.at(0) }
    end

    def dump_json
      shows = subs_db.execute("SELECT name, slug FROM shows ORDER BY name")
      out = {}
      shows.each do |_name, slug|
        show_dir = SHOWS_DIR.join(slug)
        next unless Dir.exist?(show_dir)

        files = Dir.glob(show_dir.join("**/*.{mp3,m4a,ogg,flac}")).size
        played = played_db.get_first_row("SELECT COUNT(*) FROM played WHERE show=?", slug)[0]
        out[slug] = { total_files: files, played: played }
      end
      puts JSON.pretty_generate(out)
    end

    def close
      played_db&.close
      subs_db&.close
    end
  end
end

require "set"

def main
  u = Radio::PlaylistUpdater.new
  if ARGV.include?("--json")
    u.dump_json
  else
    u.regenerate_all
  end
ensure
  u&.close
end

main
