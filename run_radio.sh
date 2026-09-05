#!/bin/bash
# run_radio.sh - Self-locating launcher for the JRuby radio automation scripts.
#
# Why a launcher: mutating GEM_HOME/GEM_PATH inside a running JRuby process does
# not reliably affect gem resolution (JRuby #5269). Exporting them BEFORE jruby
# boots is the reliable path. This script derives its own location, points the
# gem env at the co-located .gems dir, passes a bounded JVM heap, and execs
# jruby with the requested script + args. The .rb scripts keep a portable
# "#!/usr/bin/env jruby" shebang and are invoked THROUGH this launcher.
#
# Heap sizing: feed parsing is streamed to disk (constant memory), but episode
# downloads buffer per-file, so we give the JVM a comfortable-but-capped ceiling.
# NOTE: this JRuby build ignores JRUBY_OPTS, so JVM flags must be passed on the
# command line via -J (e.g. -J-Xmx2g), not through an environment variable.
#
# Usage:
#   ./run_radio.sh <script.rb> [args...]
#   sudo -u liquidsoap ./run_radio.sh fetch_podcasts.rb --add-show <url>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEMS_DIR="${SCRIPT_DIR}/.gems"
JRUBY_BIN="/usr/bin/jruby"

export GEM_HOME="${GEMS_DIR}"
export GEM_PATH="${GEMS_DIR}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $(basename "$0") <script.rb> [args...]" >&2
  exit 1
fi

exec "${JRUBY_BIN}" -J-Xms256m -J-Xmx2g "${SCRIPT_DIR}/$@"
