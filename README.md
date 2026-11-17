[![Hippocratic License HL3-FULL](https://img.shields.io/static/v1?label=Hippocratic%20License&message=HL3-FULL&labelColor=5e2751&color=bc8c3d)](https://firstdonoharm.dev/version/3/0/full.html)

Please consider supporting development here: https://ko-fi.com/mistergibson

# JRuby Radio Automation

Self-hosted internet radio automation: **JRuby** scripts drive a **Liquidsoap 2.2.4** stream into **Icecast**, on a schedule written in cron syntax. One script talks to podcast feeds and SQLite, one script is the clock, one script owns the show registry's retention policy, one Liquidsoap config plays what the clock queues. The Python implementation that used to live alongside this one has been removed; this stack is JRuby-only.

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
        "shim"  -> same resolution as "show", but queued ONLY when the item
                   already in the queue has stopped playing (filler)
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
                       output.icecast          (music/jingles/announcements,
                         %mp3 128k, TLS when    0.5s crossfade)
                         configured)
                             |
                             v
                    Icecast (host:port/mount)

   cron (hourly) ---> fetch_podcasts.rb --fetch-all
                       downloads new episodes of archived shows into
                       <storage>/podcasts/<slug>/ and records them in SQLite;
                       a show with an episode_limit admits at most
                       limit - recorded new episodes per run (CAP: lines)

   cron (:30) ------> update_playlists.rb
                       prune pass: trims every show with an episode_limit
                       back to its cap (PRUNE: lines, queue-protected)
```

The key design decision: **liquidsoap never relays a live Icecast mount directly.** A scheduled `stream` slot is recorded by ffmpeg into a finite, growing MP3 in `captures/`, and that *local path* is queued. Liquidsoap opens the growing file and plays it as an open-ended stream; at the writer's end-of-file the audio simply ends and the queue expires normally. The re-invocation poller in `station.liq` exists precisely for this case: a growing capture never fires request-finished the way a finite file does, so a wall-clock thread re-invokes the source's `fetch()` when the queue file names a new URI, and the next scheduled item cuts in on time regardless.

## Components

| File | Role |
|---|---|
| `station.rb` | 3-line entry point: `cd`s to its own directory (which exports `RADIO_DIR` for the silence fallback) and `exec`s liquidsoap on `station.liq`. This is what the systemd unit runs. |
| `station.liq` | The Liquidsoap config: queue-reading `request.dynamic`, poller, fallback mux, background music, Icecast output (plain HTTP or TLS per `config.json`). |
| `scheduler.rb` | The clock. Run from cron every minute; matches `schedule.txt` against the current time and writes the due URI into the queue file. Includes three dry-fire dev hooks. |
| `fetch_podcasts.rb` | Podcast ingestion: add/remove/archive shows, import OPML, download new episodes (bounded by each show's `episode_limit`), sync with a gPodder server. |
| `update_playlists.rb` | Legacy playlist writer (its per-show files under `storage/queue/` are not in the air path) **and** the control panel for per-show episode retention: `--set-limit`, `--prune`, `--prune-dry-run`, plus the `--json` inventory report. Its prune pass runs from cron at :30. |
| `run_radio.sh` | Launcher for every JRuby script: sets the gem environment and JVM heap, then `exec`s jruby. |
| `console.sh` | Interactive `jirb` console with the same gem environment, running as the `liquidsoap` user. |
| `install_for_jruby` | One-shot installer: gems, databases, `config.json`, systemd unit, cron entries. |
| `config.json` | Storage root, Icecast connection (including the optional TLS certificate path), gPodder credentials. |
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
    subscriptions.db   shows table (what we subscribe to; includes episode_limit)
    played.db          episodes table (what exists and what has aired)
    fire_markers/      scheduler idempotency markers (pruned after 1 day)
  logs/
    fetch_podcasts.log, scheduler_cron.log, fetch_cron.log, update_cron.log, ...
  queues/
    current_queue.txt  THE queue: exactly one bare URI, nothing else
    current_queue.meta THE sidecar: two epoch integers -- slot expiry (when the
                       queue clears) and actual end (when the item stops
                       playing; see "Expiry" below)
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

It detects JRuby (PATH or `/opt/jruby/bin/jruby`), prompts for a storage root and Icecast/gPodder settings, creates the media/state/log directories, drops and recreates the two SQLite databases with their full schemas (the `shows` table includes `episode_limit INTEGER DEFAULT 0`), installs the gems `sequel`, `jdbc-sqlite3`, `json`, and `nokogiri` into the co-located `.gems/`, writes `config.json` (mode 600), generates and enables the systemd unit (`User=liquidsoap`, `ExecStart=<jruby> station.rb`, `Restart=on-failure`), and adds cron entries to the `liquidsoap` user's crontab for the hourly fetch (`:00`), the half-hourly `update_playlists.rb` (`:30`), and the every-minute scheduler. Each entry is added only when not already present.

One thing the installer does not do, by design of the current architecture:

1. **`silence.mp3`.** The empty-queue fallback in `station.liq` resolves a real silent MP3 living beside the scripts (`<install dir>/silence.mp3`). Generate one, e.g.:
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
    "source_password": "...",
    "ssl_certificate": "/etc/icecast2/ssl/cdc.pem"
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

**TLS output.** `icecast.ssl_certificate` is optional. When it names a certificate file that exists on disk, `station.liq` connects to Icecast over TLS (`transport=http.transport.ssl()`); when the key is `""` or the file is missing, the output falls back to plain HTTP. `config.json` remains the single source of truth: no separate configuration of the transport exists. At startup the loaded-config line prints which transport was chosen (`Icecast transport: TLS (...)` or `Icecast transport: plain HTTP`).

---

## schedule.txt

Whitespace-separated fields, cron style:

```
#  min  hour  dom  mon  dow  TYPE    TARGET                    [RUNLENGTH_SECONDS]
     0    7    *    *    1-5  stream  https://streams.kpfa.org:8443/kpfa   3600
    30   12    *    *    *    show    the_history_of_rome
    45   12    *    *    *    shim    conservation_news    1800
```

Lines starting with `#` and blank lines are ignored. The five time fields support `*`, a single number `N`, a range `A-B`, a step `*/S`, and comma lists of any of those (`0,30`, `9-17/2`). `dow` is 0-6 with Sunday = 0.

`TYPE` is `show`, `stream`, or `shim`.

**`show`**: `TARGET` is a show slug (or feed URL). At fire time the scheduler looks the slug up in `subscriptions.db`, picks the most recent unplayed episode from `played.db`, marks it played, and queues its `local_path` (falling back to its `url`). `RUNLENGTH`, when given, is the number of seconds the item stays on air; without one the slot is capped at 4 hours so background music always resumes. An entry with no playable episode is *deferred*, not marked fired, and retries the next minute. When the episode's duration is known, the scheduler also stamps the item's real playing end (fire time + the lesser of runlength and duration) into the queue sidecar; see **Expiry** below for what that stamp is used for.

**`stream`**: `TARGET` is a live media URL. The scheduler starts ffmpeg recording it to `captures/<host>_<timestamp>.mp3` for `RUNLENGTH` seconds (default 3600), waits about 5 seconds, and queues the *local capture path* once the file has real bytes in it. The queue TTL is the capture length plus 300 seconds of slack. If ffmpeg produced nothing within 5 seconds, the queue is cleared instead, so background music carries the slot rather than a stale URI. This is how a finite-length slot of a continuous stream gets played: the capture is a growing MP3 that liquidsoap reads as an open-ended stream until the writer stops. The capture length is stamped as the item's playing end in the sidecar.

**`shim`**: `TARGET` is a show slug, resolved exactly like `show` -- but a shim is *filler*, not a program. It queues an episode only when nothing is actually playing. The guard reads the queue sidecar's **actual end** stamp (see **Expiry**): while that stamp is in the future, the queued item is still on air and the shim is skipped (`SKIP shim '<slug>': queued item still playing until ...`), *not* marked fired, and it retries on the next tick. Three cases never block a shim:

- a `show` whose episode duration was known, once its real playing end has passed (a show that ends before its allotment stops blocking filler at its real end, not at the slot end);
- a legacy sidecar holding a single epoch integer (no duration evidence at all -- stale entries left by an older scheduler let the shim cut in);
- an empty queue, where the shim fires like a plain `show` with its own `RUNLENGTH`.

An entry whose duration is unknown is protected conservatively: its playing end is recorded as the slot end, so a shim waits for the slot rather than risk clobbering a show that landed on time. When a shim does fire over a slot that is still open, its `RUNLENGTH` is capped at the remaining slot time, so the filler hands back to background music exactly where the interrupted entry would have -- and chained shim fires stay anchored to that same end.

**Scheduling pattern for shims.** Because a shim must be evaluated every minute during the window a show might end early, give shim lines a `*` in the minute field across the risk window rather than a single minute:

```
*  12    *    *    *    shim    conservation_news    1800
```

On SKIP or DEFER the shim does not write its fire marker, so with `*` it re-evaluates every minute and fires the moment the queue goes quiet. A single-minute line (`45 12 * * ...`) gets exactly one chance per day. Note the known trade-off: a shim-fired episode shorter than its runlength leaves its URI in the queue (liquidsoap replays it) until the runlength expires unless a later shim tick fires the next episode -- which is exactly what the `*` minute field provides.

**Expiry.** Every queued item is stamped in `current_queue.meta` with two absolute epoch times: the **slot expiry** (when the queue file is cleared; runlength, or 4 hours for an unrunlengthed show, capture length + 300 for a stream) and the **actual end** (when the item is expected to STOP PLAYING: fire + min(runlength, episode duration) for a show with known duration, capture length for a stream, or the slot expiry itself when the duration is unknown). Each scheduler tick clears the queue file once the slot expiry has passed, so a finished episode or capture never replays and background music resumes on its own. Worst-case overshoot is one cron minute. The shim guard reads the actual end, not the slot expiry -- a shim may cut in long before the slot expires. A sidecar written by an older version of the scheduler holds a single integer: that is read as slot expiry with *no* duration evidence, and it never blocks a shim.

---

## The scripts and their options

All JRuby scripts are invoked through the launcher (see `run_radio.sh` below), e.g. `./run_radio.sh scheduler.rb --dryfire-show the_history_of_rome`.

### scheduler.rb

Runs every minute from cron. On each tick, in order: expires the queue if its sidecar slot expiry has passed, then (unless a dry-fire hook was given) prunes old fire markers and captures, loads `schedule.txt`, and fires every entry matching the current minute. Idempotency: each entry fires at most once per calendar minute, tracked by a marker file named `<YYYYMMDDHHMM>_<entry-index>` in `state/fire_markers/`; markers older than one day are pruned. A `shim` entry that skips or defers writes no marker, so it retries on the next tick.

Queue writes are atomic (temp file + rename), and the queue file is kept to exactly one bare URI with no trailing annotation, because `station.liq` hands the file's contents straight to `request.create`.

Options:

| Option | Effect |
|---|---|
| *(no arguments)* | Normal cron tick: expire check, then match `schedule.txt` against the current time and fire. |
| `--dryfire-stream <url> [seconds]` | Fire one stream capture immediately, bypassing the clock match. Records `<url>` with ffmpeg for `[seconds]` (default 3600) and queues the local capture exactly as a scheduled `stream` entry would. For testing the capture path without waiting for a scheduled minute. |
| `--dryfire-show <slug>` | Run the exact `show` resolution path a scheduled entry uses (lookup, pick most recent unplayed episode, mark it played, queue it), immediately. Queues nothing (background continues) if the slug has no playable episode. |
| `--dryfire-shim <slug> [seconds]` | Run the exact `shim` path a scheduled entry uses, immediately: guard check against the queue sidecar, remaining-slot runlength cap, resolution, queue write. With an empty queue it fires like a plain show (its own `[seconds]`, default 1800). Useful for testing both outcomes: over a playing item it must SKIP; over a finished or stale entry it must fire. |

Example log lines worth knowing: `RESOLVED:` (episode chosen, with its duration), `QUEUED show:` / `QUEUED stream capture:` (URI written; the show line also states the playing length -- `plays ~Ns` when the duration is known, `unknown length, protected to slot end` otherwise), `SHIM: slot open but item finished; filling remaining Ns` (shim firing over an open slot), `SKIP shim '<slug>': queued item still playing until <time>` (shim guard held), `EXPIRED:` (slot over, queue cleared), `SKIP (already fired this minute):`, `DEFERRED: no playable episode yet`, and `STREAM CAPTURE started:` with the ffmpeg pid.

### fetch_podcasts.rb

Podcast ingestion and the show registry. Backed by two SQLite databases (`state/subscriptions.db`, `state/played.db`), opened through Sequel's JDBC adapter (`jdbc:sqlite:`) with WAL and a 5-second busy timeout. Episode GUIDs are SHA-1 digests; slugs are lowercased with non-alphanumeric characters mapped to `_`. Requires `nokogiri` (the script aborts deliberately if it fails to load).

Every invocation first attempts the gPodder OPML sync (see `config.json` above); if gPodder is not enabled or credentials are incomplete, this is a no-op, and the requested command then runs.

**Per-show episode limits.** The `shows` table carries an `episode_limit` column (default `0`, meaning no limit). Databases created before this feature are migrated automatically: on startup the script adds the column if it is missing. The identical guard runs in `update_playlists.rb`, so deployment order between the two scripts does not matter. A limit is set with `update_playlists.rb --set-limit` (below) and enforced in two places: here at download time (the admission cap) and there on disk (the prune pass).

Usage:

```
fetch_podcasts.rb [--list|--detail|--add-show <url>|--remove <slug>|--archive <slug>|--unarchive <slug>|--import-opml <file>|--fetch-all]
```

| Option | Effect |
|---|---|
| `--list` | Print all registered shows ordered by slug: slug, title, archive flag. |
| `--list --detail` | `--detail` is a modifier on `--list`, not a standalone command. Adds per-show episode counts: episodes total and unplayed. |
| `--add-show <url>` | Register a podcast feed. Probes the feed (to `/tmp/radio_feed_probe.xml`) to derive its title, then inserts the show with a fresh slug. Registering a title that already exists creates a *second* record under a new slug rather than re-pointing the original; to change a feed URL, update the `shows` row directly in `subscriptions.db`. |
| `--remove <slug>` | Remove a show, matched by case-insensitive substring against slugs or by exact feed URL. Deletes its episodes from `played.db`, then the show itself. |
| `--archive <slug>` | Mark a show archived. Only archived shows are fetched by `--fetch-all` and only archived shows are eligible for scheduled `show` slots' reset cycle. |
| `--unarchive <slug>` | Clear the archive flag. |
| `--import-opml <file>` | Import subscriptions from a local OPML file. Each imported show is marked archived and flagged as OPML-imported. |
| `--fetch-all` | Fetch every **archived** show: read its feed, download new episodes into `<storage>/podcasts/<slug>/`, and record each in `played.db` with duration, size, and local path. Episodes already known (by GUID) are skipped. This is the cron-installed hourly command. A show with `episode_limit > 0` is subject to the **admission cap**: each run downloads at most `limit - recorded` new episodes for it, and at the cap it downloads nothing at all (`CAP:` log lines). Feed items arrive newest-first, so a fill takes the newest episodes. Skipped items are not recorded as failures; they are simply re-offered on later runs. After the item loop a backstop prune trims a show already over its limit without downloading anything (for example after the limit was lowered below an existing backfill). |
| *(no arguments)* | Prints the usage line (after the gPodder sync attempt). |

### update_playlists.rb

Two jobs. The legacy one: per-show playlist files. On each run it reads `schedule.txt`, and for each entry matching the current tick writes an annotated URI (`annotate:liq_runlength="...",liq_title="...":<uri>`) into `<storage>/queue/<name>.txt`, marking the episode played and resetting a show's episodes to unplayed once exhausted. The current `station.liq` does not read these files, so this part is out of the air path.

The current job: it owns per-show episode retention. It is where limits are set (`--set-limit`), and its prune pass enforces them on disk -- deleting the oldest-recorded episodes and their files beyond a show's cap, with queued and on-air episodes protected. The installer's cron entry runs the script at :30 every hour, so the prune pass runs whether or not anything is scheduled.

On each invocation, in order: `--prune` (prune only, then exit), `--set-limit` (set and exit), the prune pass for every show with `episode_limit > 0`, then the legacy schedule processing.

| Option | Effect |
|---|---|
| *(no arguments)* | Prune pass, then process the current tick and write per-show playlist files. |
| `--set-limit <slug> <n>` | Set a show's `episode_limit` to `n` and exit without processing the schedule or pruning. `<slug>` may be the show's slug or its feed URL; `0` removes the limit (unlimited). Missing or non-numeric arguments are rejected; exit status is 0 on success, 1 on any failure. Logs the old and new values. |
| `--prune` | Run the retention prune pass only, then exit (no schedule processing). |
| `--prune-dry-run` | Make the prune pass a dry run: logs `would delete` per episode and a summary with the bytes that would be freed, deletes nothing. Combine with `--prune` for a prune-only dry run. |
| `--json` | Additionally print a JSON summary of every registered show: slug, title, total/played/unplayed episode counts, and `limit`. Useful for monitoring scripts. |

The prune pass keeps each capped show's `limit` most recently **recorded** episodes (`created_at` is download/insert order, not publish date, so a backfill inserted newest-first keeps the oldest-published episodes -- worth knowing when a show was backfilled). Every deletion is logged as `PRUNE: <slug> deleted: <title> (<path>)` with a summary line giving the count and bytes freed. A file still referenced by any `*.txt` queue file under either `storage/queue/` or `storage/queues/` is skipped and left for a later pass, so a queued or on-air episode is never deleted underneath liquidsoap (`PRUNE: <slug> keeping queued episode: ...`).

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
sudo -u liquidsoap ./run_radio.sh scheduler.rb --dryfire-shim conservation_news 1800
sudo -u liquidsoap ./run_radio.sh update_playlists.rb --set-limit 21st_century_wire 12
```

### console.sh

Opens an interactive `jirb` console with the same gem environment (`GEM_HOME`/`GEM_PATH` pointed at `.gems/`), running as the `liquidsoap` user via sudo, with native-access JVM options set. An optional argument names a Ruby file to pre-load with `-r`:

```
./console.sh                      # plain console
./console.sh helper.rb            # console with helper.rb pre-loaded
```

---

## Episode retention (per-show limits)

Every show can be capped at N episodes. The limit lives in the database (`shows.episode_limit`, default `0` = no limit), not in a config file, and is enforced in two places:

**At download time** (`fetch_podcasts.rb --fetch-all`): a capped show admits at most `limit - recorded` new episodes per run. Feed items arrive newest-first, so a fill takes the newest episodes; at the cap the show downloads nothing at all. This is deliberate: episodes beyond the cap are never fetched just to be pruned back off. Skipped items are not failures -- they stay unrecorded and are re-offered (and re-skipped) on every later run, which also means episodes deleted by a prune are never re-downloaded while the show sits at its cap.

**On disk** (`update_playlists.rb`, the prune pass): every invocation trims each capped show back to its limit, deleting the oldest-recorded episodes beyond it, both the `played.db` rows and the MP3 files. The pass is queue-aware: a file named in any queue file under `storage/queue/` or `storage/queues/` is protected, so a queued or on-air episode is never deleted underneath liquidsoap; it is left for a later pass.

To cap a show:

```
sudo -u liquidsoap ./run_radio.sh update_playlists.rb --set-limit <slug> 12
```

Setting a limit below what a show already holds does not download anything; the next :30 prune pass (or an immediate `--prune`) brings the show down. Setting it to `0` removes the cap; the show grows again on later fetches, and nothing prunes it.

**Migration.** Databases created before this feature get the column added automatically the first time either script runs after deployment (`ALTER TABLE shows ADD COLUMN episode_limit INTEGER DEFAULT 0`, logged as `Added shows.episode_limit column`). Fresh installs get it from the installer's schema directly. The guard is idempotent and runs in both scripts, so deployment order does not matter.

**Known caveat.** Retention keeps the most recently *recorded* (downloaded) episodes, because `played.db` stores no publish date. For a show backfilled newest-published-first, the surviving episodes are the oldest-published ones. Going forward, with the admission cap in place, every newly admitted episode is among the feed's newest, so the window tracks the feed correctly from here on.

---

## station.liq, in brief

The Liquidsoap config is extensively commented in the file itself; the load-bearing design points:

**One queue, one feeder.** A single `request.dynamic(prefetch=0, read_queue)` reads `queues/current_queue.txt` each tick and hands out the URI it names. `prefetch=0` means the poller is the *only* thing that feeds the source, so the queue cannot be filled by two mechanisms at once (prefetch plus a poller was the played-twice bug). The callback remembers the last URI it handed out in a string `ref` and the poller calls `fetch()` only when the queue file names something different; on a duplicate poll it does nothing, so nothing accumulates. (`fetch()` *appends* to the request queue; calling it on a timer without a consumer once grew the queue to fifty silence requests.)

**Empty queue resolves, never fails.** When the queue file is empty or absent, the callback returns a request for `<RADIO_DIR>/silence.mp3` instead of a failing request. A callback that keeps returning unresolvable requests drives a `request.dynamic` permanently DOWN and it stops polling, which is how a queued show once went unseen until a restart. The silent file keeps the source UP and polling, is inaudible, and `fallback` still prefers a real show the moment one appears.

**Cut-in timing.** `fallback(track_sensitive=false, [show_source, background_music])` is what makes a scheduled show cut in live at its appointed time rather than waiting for the current background track to finish. `mksafe` wraps the mux so the encoder never starves.

**Background music.** Three `playlist(dir)` sources (music, jingles, announcements) under `rotate`, wrapped in one `crossfade(fade_in=0.5, fade_out=0.5, duration=0.5, ...)`. The podcasts directory is deliberately NOT in the rotation: it holds the full downloaded archive (36k+ episodes), and any directory in the rotate pool plays whenever nothing is scheduled, so including it aired unscheduled podcast episodes during every schedule gap. Scheduled podcast episodes still play through the queue; only the background rotation no longer reaches into the archive. `duration` is how much audio crossfade buffers *in advance* per track, not the fade length; sizing it to the fade means a track shorter than the buffer cannot empty it (the buffer-emptied collapse). `minimum` is deliberately omitted: on this build it is a threshold on the cross's own duration, and any minimum above 0.5 vetoes every handoff with "Not enough data for crossing". `rotate` carries no `transition_length` and no `transitions`, so it hands off with a hard cut and crossfade is the only operator composing transitions. There is deliberately no crossfade above the `fallback`: layer handoffs (a show expiring mid-frame) are hard cuts, so the encoder only ever sees complete, valid frames.

**Output.** `output.icecast(%mp3(bitrate=128), ...)` to the host/port/mount from `config.json`, connection parameters loaded via `let json.parse` with an explicit type annotation (without it, fields used only in string interpolations default to null). The transport is chosen at startup: when `icecast.ssl_certificate` names an existing certificate file the output connects over TLS (`transport=http.transport.ssl()`, the form the Icecast documentation prescribes for HTTPS output); otherwise it uses the build's default plain-HTTP transport. Every other argument is identical between the two branches.

---

## Operations

**Crontab (liquidsoap user)**, for the current architecture (all three installed by the installer):

```
* * * * * cd /srv/radio && ./run_radio.sh scheduler.rb >> /mnt/storage/radio/logs/scheduler_cron.log 2>&1
0 * * * * cd /srv/radio && ./run_radio.sh fetch_podcasts.rb --fetch-all >> /mnt/storage/radio/logs/fetch_cron.log 2>&1
30 * * * * cd /srv/radio && ./run_radio.sh update_playlists.rb >> /mnt/storage/radio/logs/update_cron.log 2>&1
```

**Monitoring.** The service journal is the primary window: `journalctl -u radio -f`. Useful signatures:

- A queued item starting: `[requests:3] Prepared "<path or uri>" (RID N).`
- A show ending naturally: `[decoder:2] Decoding "<path>" ended: Ffmpeg_decoder.End_of_file` followed within a second by the next request's `Prepared`. That pair is the healthy end-of-slot signature.
- Queue handoff: `[mksafe:3] Switch to ...` lines around a fire.
- Scheduler activity: `RESOLVED` / `QUEUED` / `SHIM` / `SKIP shim` / `EXPIRED` / `SKIP` lines in `scheduler_cron.log`.
- Retention: `CAP:` lines in `fetch_cron.log` (a capped show at its limit, admitting nothing) and `PRUNE:` lines in `update_cron.log` (deletions with bytes freed, or `keeping queued episode` protections).

**Sanity checks.**

- Is anything queued? `cat <storage>/queues/current_queue.txt` (empty means background music is on air) and `cat <storage>/queues/current_queue.meta` (two epoch integers: slot expiry, then the playing end the shim guard reads).
- Did a slot fire? `ls <storage>/state/fire_markers/ | tail` and the scheduler log.
- Test a stream slot without waiting for its clock time: `./run_radio.sh scheduler.rb --dryfire-stream "<url>" 300`.
- Test a show slot: `./run_radio.sh scheduler.rb --dryfire-show <slug>`.
- Test the shim guard both ways: over a playing item `./run_radio.sh scheduler.rb --dryfire-shim <slug> 1800` must SKIP; over an empty or finished queue it must fire.
- Show inventory: `./run_radio.sh fetch_podcasts.rb --list --detail`.
- Episode inventory as JSON (includes each show's `limit`): `./run_radio.sh update_playlists.rb --json`.
- Cap a show: `./run_radio.sh update_playlists.rb --set-limit <slug> 12` (0 = no limit).
- Preview retention deletions: `./run_radio.sh update_playlists.rb --prune --prune-dry-run`.

**Housekeeping is automatic.** Fire markers older than one day and captures older than two days are pruned each scheduler tick. A capture's `.fflog` is ffmpeg's stderr for that capture, next to the MP3. Episode retention is automatic for capped shows: the hourly fetch admits up to each show's cap and the :30 prune pass trims anything over it.

**Restarting.** `systemctl restart radio`. On start, `station.liq` prints the loaded config line; if `RADIO_DIR` is unset you will see an explicit WARNING that the silence fallback will not resolve, which means the service was not started via `station.rb`/the systemd unit. Note that deploying a new `scheduler.rb` needs no restart at all: cron launches it fresh each minute, and liquidsoap never loads it. The same holds for `fetch_podcasts.rb` and `update_playlists.rb`: both are launched fresh by cron, so deploying new versions takes effect at the next scheduled run.
