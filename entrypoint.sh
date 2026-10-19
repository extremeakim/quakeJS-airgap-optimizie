#!/bin/sh
# Air-gap patched entrypoint for QuakeJS.
#
# Fixes over the stock image (all so it works with zero internet + stays up):
#
# 1) Dedicated SERVER fetched its asset manifest from content.quakejs.com and
#    crashed on an air-gapped box. We point fs_cdn at local Apache (127.0.0.1:80).
# 2) Browser CLIENT fetched assets from a hardcoded host, which broke (CORS) when
#    the page was opened from any other origin. We rewrite it to use
#    window.location.host (always same-origin).
# 3) Nagle-induced ping spikes: node is launched with --require /nodelay-patch.js
#    to force TCP_NODELAY on the game-server sockets.
# 4) "Silently fails on idle and never restarts": Docker's restart policy only
#    fires when the main process EXITS, not when the server HANGS. So we run the
#    server in the background and a watchdog probes it; if it dies or stops
#    responding, the watchdog exits -> the container exits -> `restart:
#    unless-stopped` recreates it.

cd /var/www/html
# Client: assets from the page's own origin; game server on :27960.
sed -i "s#'quakejs:80'#window.location.host#g" index.html
sed -i "s#'quakejs:27960'#window.location.hostname + ':27960'#g" index.html

/etc/init.d/apache2 start

cd /quakejs
# NOTE: the emscripten server uses a virtual filesystem with only certain paths
# mounted, so fs_homepath cannot be redirected to an arbitrary volume dir
# (doing so fails FS_Startup). Runtime writes go to the image's baked game dir.
node --require /nodelay-patch.js build/ioq3ded.js \
  +set fs_cdn 127.0.0.1:80 \
  +set fs_game baseq3 \
  +set dedicated 1 \
  +exec server.cfg &
GAME_PID=$!

# Clean shutdown: on stop, forward the signal to the server.
trap 'kill -TERM "$GAME_PID" 2>/dev/null; exit 0' TERM INT

# Watchdog.
fails=0
while true; do
  sleep 30
  if ! kill -0 "$GAME_PID" 2>/dev/null; then
    echo "watchdog: dedicated server process exited — letting Docker restart the container"
    exit 1
  fi
  if node /healthcheck.js; then
    fails=0
  else
    fails=$((fails + 1))
    echo "watchdog: health probe failed ($fails/2)"
    if [ "$fails" -ge 2 ]; then
      echo "watchdog: server unresponsive ~60s — exiting so Docker restarts the container"
      kill -9 "$GAME_PID" 2>/dev/null
      exit 1
    fi
  fi
done
