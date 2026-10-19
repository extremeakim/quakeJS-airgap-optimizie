# QuakeJS — air-gap edition.
#
# FROM the community image that already bakes Quake 3 (baseq3) assets + a local
# manifest into the image. We patch the entrypoint so BOTH the dedicated server
# and the browser client fetch assets locally / same-origin, so nothing is
# fetched from the internet and it works behind any port mapping or proxy.
#
# Build on a box WITH internet, then `docker save` to a tarball and carry it to
# the air-gapped server (same workflow as the RA2 image).
FROM treyyoder/quakejs:latest

# Belt-and-suspenders: allow cross-origin asset fetches too, so even an unusual
# reverse-proxy / split-port setup can't get CORS-blocked on the manifest/pk3s.
RUN a2enmod headers \
 && printf 'Header set Access-Control-Allow-Origin "*"\n' > /etc/apache2/conf-available/cors.conf \
 && a2enconf cors

# Bake our tuned server config (map rotation, sv_fps, rates) into the image so
# the tarball carries good defaults. On the Linux server you can also bind-mount
# ./server.cfg over this path (see docker-compose.yml) to change the map live
# without a rebuild.
COPY server.cfg /quakejs/base/baseq3/server.cfg

# TCP_NODELAY preload — kills Nagle-induced ping spikes on the game server.
COPY nodelay-patch.js /nodelay-patch.js
# Liveness probe used by both the Docker HEALTHCHECK and the entrypoint watchdog.
COPY healthcheck.js /healthcheck.js

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Web client (Apache) and the WebSocket game server.
EXPOSE 80 27960

# Mark the container unhealthy if the game server hangs (visible in `docker ps`).
# The entrypoint watchdog is what actually restarts it; this is for visibility
# and for optional autoheal sidecars.
HEALTHCHECK --interval=30s --timeout=6s --start-period=45s --retries=3 \
  CMD node /healthcheck.js || exit 1

ENTRYPOINT ["/entrypoint.sh"]
