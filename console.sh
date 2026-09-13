#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEMS_DIR="${SCRIPT_DIR}/.gems"
JAVA_OPTS="--enable-native-access=ALL-UNNAMED --enable-native-access=org.jruby.dist"
JRUBY_BIN="/usr/bin/jruby"
JIRB_BIN="/usr/bin/jirb"
JRUBY_OPTS="-J-Xms256m -J-Xmx2g"
FILE_TO_LOAD="$1"
#
# export GEM_HOME="${GEMS_DIR}"
# export GEM_PATH="/usr/lib/ruby/gems/3.2.0/:${GEMS_DIR}"
export GEM_HOME="${GEMS_DIR}"
export GEM_PATH="${GEMS_DIR}"
#
if [ -e "${JIRB_BIN}" ]; then
  if [ -e "${SCRIPT_DIR}/${FILE_TO_LOAD}" ]; then
    # exec env GEM_HOME="${GEM_HOME}" GEM_PATH="${GEM_PATH}" JAVA_OPTS="${JAVA_OPTS}" JRUBY_OPTS="${JRUBY_OPTS}" /usr/bin/sudo -u liquidsoap "${JIRB_BIN}" -r "${SCRIPT_DIR}/${FILE_TO_LOAD}"
    # sudo -u liquidsoap "${JIRB_BIN}" -r "${SCRIPT_DIR}/${FILE_TO_LOAD}"
    sudo -u liquidsoap GEM_HOME="${GEMS_DIR}" GEM_PATH="${GEMS_DIR}" JAVA_OPTS="${JAVA_OPTS}" JRUBY_OPTS="${JRUBY_OPTS}" "${JIRB_BIN}" -r "${SCRIPT_DIR}/${FILE_TO_LOAD}"
  else
    # exec env GEM_HOME="${GEM_HOME}" GEM_PATH="${GEM_PATH}" JAVA_OPTS="${JAVA_OPTS}" JRUBY_OPTS="${JRUBY_OPTS}" /usr/bin/sudo -u liquidsoap "${JIRB_BIN}"
    # sudo -u liquidsoap "${JIRB_BIN}"
    sudo -u liquidsoap GEM_HOME="${GEMS_DIR}" GEM_PATH="${GEMS_DIR}" JAVA_OPTS="${JAVA_OPTS}" JRUBY_OPTS="${JRUBY_OPTS}" "${JIRB_BIN}"
  fi
  exit 0
else
  echo "Error: could not locate ${JIRB_BIN}"
  exit 1
fi
#