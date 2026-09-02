#!/usr/bin/env bash
# run_radio.sh - Launcher for the radio automation JRuby scripts.
#
# Sets GEM_HOME/GEM_PATH in the environment BEFORE jruby boots, because
# mutating those variables inside a running JRuby process does not reliably
# affect gem resolution (JRuby issue #5269). Setting them pre-boot lets
# RubyGems pick them up natively. Self-locating, so the whole tree can be
# relocated without editing anything.
#
# Usage:  ./run_radio.sh <script.rb> [args...]
#   e.g.  ./run_radio.sh fetch_podcasts.rb --list-shows

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEMS_DIR="${SCRIPT_DIR}/.gems"

export GEM_HOME="${GEM_HOME:-${GEMS_DIR}}"
# Prepend our gems dir; keep JRuby's shared path so stdlib stays reachable.
_JRUBY_SHARED="/opt/jruby/lib/ruby/gems/shared"
if [[ -n "${GEM_PATH:-}" ]]; then
  export GEM_PATH="${GEMS_DIR}:${GEM_PATH}"
else
  export GEM_PATH="${GEMS_DIR}:${_JRUBY_SHARED}"
fi

exec /opt/jruby/bin/jruby "$@"

