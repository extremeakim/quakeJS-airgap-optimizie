# QuakeJS — browser LAN, air-gap edition

Quake 3 Arena in the browser, full multiplayer, no internet. Same idea as the RA2
setup next door: build the image on a box **with** internet, `docker save` it to a
tarball, carry it to the air-gapped server, `docker load`, `docker compose up`.

Unlike RA2 (one container per player), QuakeJS runs one real dedicated server
inside the image, so **everyone shares one container** and just points a browser at
it.

## Why a custom image (vs. the stock `treyyoder/quakejs`)

The stock image bakes the game assets in, but breaks on an air-gapped box in two
ways — both patched in `entrypoint.sh`:

1. **Dedicated server** launches with no `fs_cdn`, so it tries to download the
   asset manifest from `content.quakejs.com` and the container dies. Fix: point
   the server's `fs_cdn` at the local Apache (`127.0.0.1:80`), which already
   serves every `.pk3` and the manifest.
2. **Browser client** fetched its assets from a hardcoded host:port. If the page
   is opened from any other origin (a different published port, an IP, a reverse
   proxy) the asset XHR becomes cross-origin and the browser blocks it (no
   `Access-Control-Allow-Origin`) — the game hangs on the first logo. Fix: the
   client now fetches assets from `window.location.host` (the exact origin the
   page loaded from → always same-origin), and Apache also sends a permissive
   CORS header as insurance. Works behind any port mapping or proxy.

The game server is a WebSocket on **:27960** — that port must be reachable from
the player PCs too (not just the web port).

## Build (on a box with internet)

```powershell
docker build -t quakejs-airgap:latest .
docker save quakejs-airgap:latest | gzip > quakejs-airgap.tar.gz   # carry this across
```

## Run (on the air-gapped server)

```bash
docker load < quakejs-airgap.tar.gz
docker compose up -d
```

## Play

Every player opens `http://<server-ip>:8080`. The web client auto-connects to the
dedicated server baked into the same container (map rotation is in the image's
`server.cfg`; starts on `q3dm1` with bots). Ports: **8080** = web client, **27960**
= WebSocket game server — both must be reachable from the player PCs.

> Note: browser (WebSocket) clients can only play against other browser clients,
> not native Quake 3.

## Persistence — what survives a restart (and what can't)

**Quake 3 Arena has no save-game / progression system, and QuakeJS ships no
database** (there are no db libraries in the image). It's a session-based arena
shooter, so there's genuinely no "player progress" to store. Concretely:

| State | Where it lives | Survives container restart? |
|-------|----------------|------------------------------|
| Current match scores / frags / map timer | Server RAM | **No** — resets on any server restart, by design. Not fixable; there's nothing to persist it to. |
| Server rules & map (hostname, gametype, rotation, rcon changes) | `server.cfg` | **Yes**, if you put them in `server.cfg` (mounted). Changes made *live* via rcon are RAM-only — write them into `server.cfg` to keep them. |
| Player name, cvars, key binds, video settings | **Each player's browser** (IndexedDB), not the server | **Yes** — unaffected by container restarts. If a player loses these, it's their browser clearing site data, not the server. |

So the honest answer to "is there a local DB for active state": no, and there's
nothing to point one at — the only durable server-side state is `server.cfg`,
which you already control. (The emscripten server uses a virtual filesystem, so
`fs_homepath` can't be redirected to a volume; don't try — it fails FS_Startup.)

## Staying up: auto-restart on crash *or* hang

`restart: unless-stopped` alone isn't enough: Docker only restarts a container
when its main process **exits**, but the emscripten server can occasionally *hang*
(process alive, game dead) — which is why it could "silently fail and never come
back." This image adds:

- an internal **watchdog** (in `entrypoint.sh`) that probes the game server every
  30s and, if it has died or stopped responding for ~60s, exits so the `restart`
  policy recreates the container;
- a Docker **HEALTHCHECK** so `docker ps` shows `healthy` / `unhealthy`.

Verified: killing the server process is detected within 30s and the container
restarts itself back to `healthy`.

## Changing the map / rules

The server reads `server.cfg` (baked into the image with good defaults, and also
bind-mounted from `./server.cfg` via `docker-compose.yml` so you can edit it on the
server). **Carry `server.cfg` alongside `docker-compose.yml`** — the bind mount
needs it.

- **Persistent:** edit `server.cfg` (map rotation / fixed map / rules are all at
  the top, with the full map list), then `docker compose restart quakejs`.
- **Live, no restart:** open the in-game console (the `~` key) and use rcon:
  ```
  \rconpassword <your rcon password from server.cfg>
  \rcon map q3dm17
  ```

> If you carry `docker-compose.yml` but forget `server.cfg`, a Linux bind mount
> will create an empty file and the server loses its config — so keep them
> together. (You can also delete the `volumes:` block to just use the baked-in
> defaults.)

## Performance

### Ping spikes / rubber-banding / "teleporting" (20ms → 700ms)

This is a **network-transport** problem, not FPS. QuakeJS talks to the server over
WebSocket (TCP), and Quake sends many tiny packets per second. Node leaves TCP
Nagle's algorithm on by default, which batches those packets and — with TCP
delayed-ACK — causes sudden latency spikes even on a quiet LAN. That's the classic
"ping normally 20, jumps to 700, everyone teleports."

**Fixed in this image:** `nodelay-patch.js` (preloaded via `node --require` in
`entrypoint.sh`) forces `TCP_NODELAY` on every game-server socket, disabling
Nagle. You'll see `nodelay-patch: TCP_NODELAY enabled on game-server sockets` in
`docker logs quakejs` the first time a player connects.

If pings still spike after that, the remaining causes are, in order:

- **WiFi / lossy links.** TCP turns a little packet loss into big stalls
  (head-of-line blocking). Put players (and the server) on **wired** connections.
- **Server frame hitches.** The dedicated server is a single-threaded emscripten
  process; under load it can stall for a fraction of a second, spiking everyone's
  ping at once. Give the container a dedicated, fast core on the host — e.g. in
  `docker-compose.yml`:
  ```yaml
      cpus: "2.0"           # let it have real CPU
      cpuset: "2,3"         # pin to specific cores, away from other containers
  ```
  and keep player counts and map sizes modest (q3dm7, q3tourney2 are lighter than
  q3dm17). `server.cfg` ships `sv_fps 20` (stock, max headroom); only try 30 if
  pings stay flat.

### Client-side smoothness

- **Resolution / render method:** lowering these in the in-game menu fixes low FPS
  (as you found).
- **Client netcode cvars** (console `~`, persist per browser):
  ```
  \rate 25000
  \snaps 40
  \cl_maxpackets 60
  \cl_timenudge 0
  ```
