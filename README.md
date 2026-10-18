[![Hippocratic License HL3-FULL](https://img.shields.io/static/v1?label=Hippocratic%20License&message=HL3-FULL&labelColor=5e2751&color=bc8c3d)](https://firstdonoharm.dev/version/3/0/full.html)
# JRuby Radio Automation

Self-hosted internet radio automation: **JRuby** scripts drive a **Liquidsoap 2.2.4** stream into **Icecast**, on a schedule written in cron syntax. One script talks to podcast feeds and SQLite, one script is the clock, one Liquidsoap config plays what the clock queues. The Python implementation that used to live alongside this one has been removed; this stack is JRuby-only.

This README documents the **current architecture**: a single queue file (`current_queue.txt`) read by a single `request.dynamic` in Liquidsoap, with live-stream slots captured locally by ffmpeg before air.

---

## Architecture

```
                       cron (every minute, liquidsoap user)
                                        |
                                        v
   schedule.txt  --->   scheduler.rb  --fire markers (state/fire_markers/)
   config.json  ---/         |
                             | writes ONE bare URI + TTL sidecar
                             v
        <storage>/queues/current_queue.txt      <storage>/queues/current_queue.meta
                             |
        "show"  -> episode local path or media URL (resolved from SQLite, marked played)
        "stream"-> LOCAL capture path: ffmpeg records the live URL into
                   <storage>/captures/*.mp3 and that growing file is queued
                             |
                             v
              station.liq  (liquidsoap, started by station.rb)
              request.dynamic(prefetch=0) reads the queue file every tick;
              a recurrent poller re-invokes fetch() only when the URI changes;
              empty queue -> resolving silence file -> source goes to background
                             |
                fallback(track_sensitive=false) --- blank() safety (mksafe)
                             |                \
                             v                 -> rotating background music
                       output.icecast          (music/jingles/announcements/
                         %mp3 128k              podcasts, 0.5s crossfade)
                             |
                             v
                    Icecast (host:port/mount)

   cron (hourly) ---> fetch_podcasts.rb --fetch-all
                       downloads new episodes of archived shows into
                       <storage>/podcasts/<slug>/ and records them in SQLite
```

The key design decision: **liquidsoap never relays a live Icecast mount directly.** A scheduled `stream` slot is recorded by ffmpeg into a finite, growing MP3 in `captures/`, and that *local path* is queued. Liquidsoap opens the growing file and plays it as an open-ended stream; at the writer's end-of-file the audio simply ends and the queue expires normally. The re-invocation poller in `station.liq` exists precisely for this case: a growing capture never fires request-finished the way a finite file does, so a wall-clock thread re-invokes the source's `fetch()` when the queue file names a new URI, and the next scheduled item cuts in on time regardless.

## Components

| File | Role |
|---|---|
| `station.rb` | 3-line entry point: `cd`s to its own directory (which exports `RADIO_DIR` for the silence fallback) and `exec`s liquidsoap on `station.liq`. This is what the systemd unit runs. |
| `station.liq` | The Liquidsoap config: queue-reading `request.dynamic`, poller, fallback mux, background music, Icecast output. |
| `scheduler.rb` | The clock. Run from cron every minute; matches `schedule.txt` against the current time and writes the due URI into the queue file. Includes two dry-fire dev hooks. |
| `fetch_podcasts.rb` | Podcast ingestion: add/remove/archive shows, import OPML, download new episodes, sync with a gPodder server. |
| `update_playlists.rb` | **Legacy.** Writes per-show playlist files under `storage/queue/`. Superseded by `scheduler.rb`'s direct queue writes; kept for reference and its `--json` inventory report. Not in the air path. |
| `run_radio.sh` | Launcher for every JRuby script: sets the gem environment and JVM heap, then `exec`s jruby. |
| `console.sh` | Interactive `jirb` console with the same gem environment, running as the `liquidsoap` user. |
| `install_for_jruby` | One-shot installer: gems, databases, `config.json`, systemd unit, cron entries. |
| `config.json` | Storage root, Icecast connection, gPodder credentials. |
| `schedule.txt` | The schedule, in cron style. |

## Directory layout

Everything lives under the storage root chosen at install time (default `/mnt/storage/radio`); the install directory (e.g. `/srv/radio`) holds the scripts, `config.json`, `schedule.txt`, and the co-located `.gems/` directory.

```
<storage>/
  music/            background music (read recursively by playlist(dir))
  podcasts/         downloaded episodes, one sub-directory per show slug
  jingles/          station jingles
  announcements/    PSA / announcement audio
  state/
    subscriptions.db   shows table (what we subscribe to)
    played.db          episodes table (what exists and what has aired)
    fire_markers/      scheduler idempotency markers (pruned after 1 day)
  logs/
    fetch_podcasts.log, scheduler_cron.log, fetch_cron.log, update_cron.log, ...
  queues/
    current_queue.txt  THE queue: exactly one bare URI, nothing else
    current_queue.meta THE sidecar: one epoch integer, the second the item stops airing
  captures/
    <host>_<YYYYMMDD_HHMMSS>.mp3   ffmpeg stream captures (pruned after 2 days)
    *.fflog                        each capture's ffmpeg stderr
```

`queues/` and `captures/` are created by `scheduler.rb` on first run if absent; `fire_markers/` likewise.

---

## Installation

Run the installer as root from the directory that will become the service name (a directory named `radio` yields `radio.service`):

```
sudo ./install_for_jruby
```

It detects JRuby (PATH or `/opt/jruby/bin/jruby`), prompts for a storage root and Icecast/gPodder settings, creates the media/state/log directories, drops and recreates the two SQLite databases with their full schemas, installs the gems `sequel`, `jdbc-sqlite3`, `json`, and `nokogiri` into the co-located `.gems/`, writes `config.json` (mode 600), generates and enables the systemd unit (`User=liquidsoap`, `ExecStart=<jruby> station.rb`, `Restart=on-failure`), and adds cron entries to the `liquidsoap` user's crontab for the hourly fetch and the legacy `update_playlists.rb`.

Two things the installer does not do, by design of the current architecture:

1. **The scheduler cron entry.** `scheduler.rb` must run every minute. Add it to the liquidsoap user's crontab:
   ```
   * * * * * cd /srv/radio && ./run_radio.sh scheduler.rb >> /mnt/storage/radio/logs/scheduler_cron.log 2>&1
   ```
   (adjust paths to your install and storage roots)
2. **`silence.mp3`.** The empty-queue fallback in `station.liq` resolves a real silent MP3 living beside the scripts (`<install dir>/silence.mp3`). Generate one, e.g.:
   ```
   ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 60 -codec:a libmp3lame -b:a 128k silence.mp3
   ```
   The path is *not* hard-coded: `station.rb` exports `RADIO_DIR` (its own resolved directory) before exec'ing liquidsoap, and `station.liq` reads it with `environment.get`. The service works wherever it is installed. A WARNING is logged at startup if `RADIO_DIR` is unset.

Then review `config.json` and `systemctl start radio`.

---

## config.json

```json
{
  "storage": "/mnt/storage/radio",
  "icecast": {
    "host": "192.168.0.200",
    "port": 7777,
    "mount": "/data",
    "source_username": "source",
    "source_password": "..."
  },
  "gpodder": {
    "enabled": true,
    "host": "gpodder.net",
    "username": "...",
    "password": "...",
    "device_id": "radio-..."
  }
}
```

`fetch_podcasts.rb` treats gPodder sync as active only when `gpodder.enabled` is exactly `true` **and** `username`, `password`, and `device_id` are all non-empty. The OPML subscription list is read from `https://<host>/subscriptions/<username>/<device_id>.opml`.

Note: the bundled installer writes this block with the key `"enable"` rather than `"enabled"`. The code reads `enabled`. If gPodder sync silently does nothing after an install, check which key your `config.json` actually has and set `"enabled": true`.

---

## schedule.txt

Whitespace-separated fields, cron style:

```
#  min  hour  dom  mon  dow  TYPE    TARGET                    [RUNLENGTH_SECONDS]
     0    7    *    *    1-5  stream  https://streams.kpfa.org:8443/kpfa   3600
    30   12    *    *    *    show    the_history_of_rome
```

Lines starting with `#` and blank lines are ignored. The five time fields support `*`, a single number `N`, a range `A-B`, a step `*/S`, and comma lists of any of those (`0,30`, `9-17/2`). `dow` is 0-6 with Sunday = 0.

`TYPE` is `show` or `stream`.

**`show`**: `TARGET` is a show slug (or feed URL). At fire time the scheduler looks the slug up in `subscriptions.db`, picks the most recent unplayed episode from `played.db`, marks it played, and queues its `local_path` (falling back to its `url`). `RUNLENGTH`, when given, is the number of seconds the item stays on air; without one the slot is capped at 4 hours so background music always resumes. An entry with no playable episode is *deferred*, not marked fired, and retries the next minute.

**`stream`**: `TARGET` is a live media URL. The scheduler starts ffmpeg recording it to `captures/<host>_<timestamp>.mp3` for `RUNLENGTH` seconds (default 3600), waits about 5 seconds, and queues the *local capture path* once the file has real bytes in it. The queue TTL is the capture length plus 300 seconds of slack. If ffmpeg produced nothing within 5 seconds, the queue is cleared instead, so background music carries the slot rather than a stale URI. This is how a finite-length slot of a continuous stream gets played: the capture is a growing MP3 that liquidsoap reads as an open-ended stream until the writer stops.

**Expiry.** Every queued item is stamped with an absolute end time (epoch seconds) in `current_queue.meta`. Each scheduler tick clears the queue file once that time has passed, so a finished episode or capture never replays and background music resumes on its own. Worst-case overshoot is one cron minute.

---

## The scripts and their options

All JRuby scripts are invoked through the launcher (see `run_radio.sh` below), e.g. `./run_radio.sh scheduler.rb --dryfire-show the_history_of_rome`.

### scheduler.rb

Runs every minute from cron. On each tick, in order: expires the queue if its sidecar time has passed, then (unless a dry-fire hook was given) prunes old fire markers and captures, loads `schedule.txt`, and fires every entry matching the current minute. Idempotency: each entry fires at most once per calendar minute, tracked by a marker file named `<YYYYMMDDHHMM>_<entry-index>` in `state/fire_markers/`; markers older than one day are pruned.

Queue writes are atomic (temp file + rename), and the queue file is kept to exactly one bare URI with no trailing annotation, because `station.liq` hands the file's contents straight to `request.create`.

Options:

| Option | Effect |
|---|---|
| *(no arguments)* | Normal cron tick: expire check, then match `schedule.txt` against the current time and fire. |
| `--dryfire-stream <url> [seconds]` | Fire one stream capture immediately, bypassing the clock match. Records `<url>` with ffmpeg for `[seconds]` (default 3600) and queues the local capture exactly as a scheduled `stream` entry would. For testing the capture path without waiting for a scheduled minute. |
| `--dryfire-show <slug>` | Run the exact `show` resolution path a scheduled entry uses (lookup, pick most recent unplayed episode, mark it played, queue it), immediately. Queues nothing (background continues) if the slug has no playable episode. |

Example log lines worth knowing: `RESOLVED:` (episode chosen), `QUEUED show:` / `QUEUED stream capture:` (URI written), `EXPIRED:` (slot over, queue cleared), `SKIP (already fired this minute):`, `DEFERRED: no playable episode yet`, and `STREAM CAPTURE started:` with the ffmpeg pid.

### fetch_podcasts.rb

Podcast ingestion and the show registry. Backed by two SQLite databases (`state/subscriptions.db`, `state/played.db`), opened through Sequel's JDBC adapter (`jdbc:sqlite:`) with WAL and a 5-second busy timeout. Episode GUIDs are SHA-1 digests; slugs are lowercased with non-alphanumeric characters mapped to `_`. Requires `nokogiri` (the script aborts deliberately if it fails to load).

Every invocation first attempts the gPodder OPML sync (see `config.json` above); if gPodder is not enabled or credentials are incomplete, this is a no-op, and the requested command then runs.

Usage:

```
fetch_podcasts.rb [--list|--detail|--add-show <url>|--remove <slug>|--archive <slug>|--unarchive <slug>|--import-opml <file>|--fetch-all]
```

| Option | Effect |
|---|---|
| `--list` | Print all registered shows ordered by slug: slug, title, archive flag. |
| `--list --detail` | `--detail` is a modifier on `--list`, not a standalone command. Adds per-show episode counts: episodes total and unplayed. |
| `--add-show <url>` | Register a podcast feed. Probes the feed (to `/tmp/radio_feed_probe.xml`) to derive its title, then inserts the show with a fresh slug. |
| `--remove <slug>` | Remove a show, matched by case-insensitive substring against slugs or by exact feed URL. Deletes its episodes from `played.db`, then the show itself. |
| `--archive <slug>` | Mark a show archived. Only archived shows are fetched by `--fetch-all` and only archived shows are eligible for scheduled `show` slots' reset cycle. |
| `--unarchive <slug>` | Clear the archive flag. |
| `--import-opml <file>` | Import subscriptions from a local OPML file. Each imported show is marked archived and flagged as OPML-imported. |
| `--fetch-all` | Fetch every **archived** show: read its feed, download new episodes into `<storage>/podcasts/<slug>/`, and record each in `played.db` with duration, size, and local path. Episodes already known (by GUID) are skipped. This is the cron-installed hourly command. |
| *(no arguments)* | Prints the usage line (after the gPodder sync attempt). |

### update_playlists.rb (legacy)

Superseded by `scheduler.rb`, which now reads `schedule.txt` and resolves episodes directly. This script implements the older per-show-playlist design: on each run it reads `schedule.txt`, and for each entry matching the current tick writes an annotated URI (`annotate:liq_runlength="...",liq_title="...":<uri>`) into `<storage>/queue/<name>.txt`, marking the episode played and resetting a show's episodes to unplayed once exhausted. The current `station.liq` does not read these files, so the script is out of the air path.

| Option | Effect |
|---|---|
| *(no arguments)* | Process the current tick and write per-show playlist files. |
| `--json` | Additionally print a JSON summary of every registered show: slug, title, total/played/unplayed episode counts. Useful for monitoring scripts. |

### station.rb

The systemd entry point. Three lines: change directory to the script's own location (this is what makes `RADIO_DIR` resolve for the silence fallback), then `exec liquidsoap station.liq`. No options.

### run_radio.sh

The launcher every JRuby script goes through. It exists because mutating `GEM_HOME`/`GEM_PATH` from inside a running JRuby process does not reliably affect gem resolution (JRuby #5269); exporting them *before* jruby boots is the reliable path. It points the gem environment at the co-located `.gems/` directory and gives the JVM a bounded heap.

```
Usage: ./run_radio.sh <script.rb> [args...]
```

The JVM is started with `-J-Xms256m -J-Xmx2g`. Note this JRuby build ignores `JRUBY_OPTS`, so any JVM flags must go on the command line via `-J`, not through the environment. Typical invocations:

```
sudo -u liquidsoap ./run_radio.sh fetch_podcasts.rb --fetch-all
sudo -u liquidsoap ./run_radio.sh scheduler.rb --dryfire-stream "https://streams.kpfa.org:8443/kpfa" 300
```

### console.sh

Opens an interactive `jirb` console with the same gem environment (`GEM_HOME`/`GEM_PATH` pointed at `.gems/`), running as the `liquidsoap` user via sudo, with native-access JVM options set. An optional argument names a Ruby file to pre-load with `-r`:

```
./console.sh                      # plain console
./console.sh helper.rb            # console with helper.rb pre-loaded
```

---

## station.liq, in brief

The Liquidsoap config is extensively commented in the file itself; the load-bearing design points:

**One queue, one feeder.** A single `request.dynamic(prefetch=0, read_queue)` reads `queues/current_queue.txt` each tick and hands out the URI it names. `prefetch=0` means the poller is the *only* thing that feeds the source, so the queue cannot be filled by two mechanisms at once (prefetch plus a poller was the played-twice bug). The callback remembers the last URI it handed out in a string `ref` and the poller calls `fetch()` only when the queue file names something different; on a duplicate poll it does nothing, so nothing accumulates. (`fetch()` *appends* to the request queue; calling it on a timer without a consumer once grew the queue to fifty silence requests.)

**Empty queue resolves, never fails.** When the queue file is empty or absent, the callback returns a request for `<RADIO_DIR>/silence.mp3` instead of a failing request. A callback that keeps returning unresolvable requests drives a `request.dynamic` permanently DOWN and it stops polling, which is how a queued show once went unseen until a restart. The silent file keeps the source UP and polling, is inaudible, and `fallback` still prefers a real show the moment one appears.

**Cut-in timing.** `fallback(track_sensitive=false, [show_source, background_music])` is what makes a scheduled show cut in live at its appointed time rather than waiting for the current background track to finish. `mksafe` wraps the mux so the encoder never starves.

**Background music.** Four `playlist(dir)` sources (music, jingles, announcements, podcasts) under `rotate`, wrapped in one `crossfade(fade_in=0.5, fade_out=0.5, duration=0.5, ...)`. `duration` is how much audio crossfade buffers *in advance* per track, not the fade length; sizing it to the fade means a track shorter than the buffer cannot empty it (the buffer-emptied collapse). `minimum` is deliberately omitted: on this build it is a threshold on the cross's own duration, and any minimum above 0.5 vetoes every handoff with "Not enough data for crossing". `rotate` carries no `transition_length` and no `transitions`, so it hands off with a hard cut and crossfade is the only operator composing transitions. There is deliberately no crossfade above the `fallback`: layer handoffs (a show expiring mid-frame) are hard cuts, so the encoder only ever sees complete, valid frames.

**Output.** `output.icecast(%mp3(bitrate=128), ...)` to the host/port/mount from `config.json`, connection parameters loaded via `let json.parse` with an explicit type annotation (without it, fields used only in string interpolations default to null).

---

## Operations

**Crontab (liquidsoap user)**, for the current architecture:

```
* * * * * cd /srv/radio && ./run_radio.sh scheduler.rb >> /mnt/storage/radio/logs/scheduler_cron.log 2>&1
0 * * * * cd /srv/radio && ./run_radio.sh fetch_podcasts.rb --fetch-all >> /mnt/storage/radio/logs/fetch_cron.log 2>&1
```

**Monitoring.** The service journal is the primary window: `journalctl -u radio -f`. Useful signatures:

- A queued item starting: `[requests:3] Prepared "<path or uri>" (RID N).`
- A show ending naturally: `[decoder:2] Decoding "<path>" ended: Ffmpeg_decoder.End_of_file` followed within a second by the next request's `Prepared`. That pair is the healthy end-of-slot signature.
- Queue handoff: `[mksafe:3] Switch to ...` lines around a fire.
- Scheduler activity: `RESOLVED` / `QUEUED` / `EXPIRED` / `SKIP` lines in `scheduler_cron.log`.

**Sanity checks.**

- Is anything queued? `cat <storage>/queues/current_queue.txt` (empty means background music is on air) and `cat <storage>/queues/current_queue.meta` (epoch second the slot ends).
- Did a slot fire? `ls <storage>/state/fire_markers/ | tail` and the scheduler log.
- Test a stream slot without waiting for its clock time: `./run_radio.sh scheduler.rb --dryfire-stream "<url>" 300`.
- Test a show slot: `./run_radio.sh scheduler.rb --dryfire-show <slug>`.
- Show inventory: `./run_radio.sh fetch_podcasts.rb --list --detail`.
- Episode inventory as JSON: `./run_radio.sh update_playlists.rb --json`.

**Housekeeping is automatic.** Fire markers older than one day and captures older than two days are pruned each scheduler tick. A capture's `.fflog` is ffmpeg's stderr for that capture, next to the MP3.

**Restarting.** `systemctl restart radio`. On start, `station.liq` prints the loaded config line; if `RADIO_DIR` is unset you will see an explicit WARNING that the silence fallback will not resolve, which means the service was not started via `station.rb`/the systemd unit.
