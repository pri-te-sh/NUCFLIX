#!/bin/bash
# Build (debug by default) and install NucFlix on a Fire TV, keeping the app's data.
# `vega run-app` uninstalls first, which wipes the pairing; `vpm install --force` updates in place.
# Usage: scripts/deploy.sh [tv-ip:port] [Debug|Release]
set -e
TV="${1:-${NUCFLIX_TV:-192.168.68.113:5555}}"
TYPE="${2:-Debug}"
ARCH=armv7 # Fire TV Stick 4K Select (Vega OS) is armv7l

[ -s ~/.nvm/nvm.sh ] && . ~/.nvm/nvm.sh
export PATH="$HOME/vega/bin:$PATH"
cd "$(dirname "$0")/.."

npm run "build:$(echo "$TYPE" | tr '[:upper:]' '[:lower:]')"
PKG="build/${ARCH}-$(echo "$TYPE" | tr '[:upper:]' '[:lower:]')/nucflixvega_${ARCH}.vpkg"

vega exec vda connect "$TV" >/dev/null
vega device copy-to --source "$PKG" --destination /tmp/nucflix.vpkg
vega device terminate-app --appName com.pritesh.nucflix.main >/dev/null 2>&1 || true
vega device run-cmd --command 'vpm install /tmp/nucflix.vpkg --force'
vega device run-cmd --command 'rm -f /tmp/nucflix.vpkg' >/dev/null 2>&1 || true
vega device launch-app --appName com.pritesh.nucflix.main
