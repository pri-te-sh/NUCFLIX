#!/bin/bash
# Drive a Vega Fire TV from the dev PC (Developer Mode + VDA). Usage:
#   scripts/tv.sh shot [file.png]        screenshot (native res) to a local PNG
#   scripts/tv.sh key KEY_DOWN [n]       press a remote key n times (KEY_UP/DOWN/LEFT/RIGHT, KEY_ENTER,
#                                        KEY_BACK, KEY_HOMEPAGE, KEY_MENU, KEY_PLAYPAUSE, KEY_FASTFORWARD, KEY_REWIND)
#   scripts/tv.sh text "hello"           type text into the focused field
#   scripts/tv.sh launch | stop          start / stop NucFlix
#   scripts/tv.sh logs [seconds]         stream device logs, NucFlix lines only
# TV address: $NUCFLIX_TV (default 192.168.68.113:5555).
set -e
TV="${NUCFLIX_TV:-192.168.68.113:5555}"
APP=com.pritesh.nucflix.main
export PATH="$HOME/vega/bin:$PATH"
vda() { vega exec vda "$@"; }
vda connect "$TV" >/dev/null 2>&1 || true

case "$1" in
  shot)
    out="${2:-tv-$(date +%H%M%S).png}"
    remote=/tmp/nucflix-shot.png
    # The compositor only returns a frame when the screen repaints, so a static screen makes the capture
    # wait forever. Nudge focus right then left (net no change) while it waits.
    timeout 25 vega exec vda shell gwsi-tool-screenshooter2 "$remote" >/tmp/tv-shot.log 2>&1 &
    pid=$!
    sleep 3
    if kill -0 $pid 2>/dev/null; then
      vda shell inputd-cli button_press KEY_RIGHT >/dev/null 2>&1
      sleep 0.5
      vda shell inputd-cli button_press KEY_LEFT >/dev/null 2>&1
    fi
    wait $pid || { cat /tmp/tv-shot.log; exit 1; }
    vda pull "$remote" "$out" >/dev/null
    vda shell rm -f "$remote" >/dev/null 2>&1
    echo "$out"
    ;;
  key)
    for _ in $(seq "${3:-1}"); do vda shell inputd-cli button_press "$2" >/dev/null; sleep 0.3; done
    ;;
  text)
    vda shell inputd-cli send_text "$2"
    ;;
  launch)
    vega device launch-app --appName "$APP"
    ;;
  stop)
    vega device terminate-app --appName "$APP"
    ;;
  logs)
    timeout "${2:-60}" vega device start-log-stream 2>&1 | grep -a --line-buffered -E 'nucflix|\[web\]|\[player\]' || true
    ;;
  *)
    sed -n '2,10p' "$0"
    exit 1
    ;;
esac
