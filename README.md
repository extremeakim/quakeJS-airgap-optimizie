# QuakeJS — air-gapped LAN server

A Docker image that runs [QuakeJS](https://github.com/inolen/quakejs) (Quake 3
Arena in the browser) as a self-contained LAN server on a machine with **no
internet access**. Build it once on a connected machine, carry the image across
as a tarball, load it on the isolated server, and every player joins from a
browser. Nothing is fetched from the internet at runtime.

## Credits

- **Quake 3 Arena** — id Software.
- **ioquake3** — the open-source engine QuakeJS is built on.
- **QuakeJS** — [inolen/quakejs](https://github.com/inolen/quakejs), the
  Emscripten port of ioquake3 to the browser.
- **treyyoder/quakejs** — [github.com/treyyoder/quakejs](https://github.com/treyyoder/quakejs),
  the Docker image this one is based on. It bundles the game assets, the Apache
  web client, and the Node dedicated server into one container.

This repository only adds a thin layer on top of that image. All credit for the
game, the port, and the packaging belongs to the projects above.

## What this image changes

The stock image assumes internet access and a fixed hostname. This image patches
four things so it runs offline, from any address, and stays up unattended:

| Change | Where | Why |
|--------|-------|-----|
| Dedicated server reads assets from the local Apache (`fs_cdn 127.0.0.1:80`) | `entrypoint.sh` | Stock server fetches its manifest from `content.quakejs.com` and crashes offline |
| Browser client loads assets and connects to the game server using the page's own origin | `entrypoint.sh` | Stock client hardcodes `quakejs:80` / `quakejs:27960`, which breaks with CORS behind any other IP, port, or proxy |
| `TCP_NODELAY` forced on every game-server socket | `nodelay-patch.js` | Node leaves Nagle's algorithm on; with Quake's small packets this causes ping spikes and rubber-banding even on a LAN |
| Watchdog + Docker `HEALTHCHECK` | `entrypoint.sh`, `healthcheck.js` | Docker only restarts on process exit; the Emscripten server can hang while still running. The watchdog turns a hang into an exit so the restart policy fires |

Plus a tuned `server.cfg` (map rotation, tick rate, rates) baked in and
bind-mountable, so maps and rules change without a rebuild.

## Repository contents

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds on `treyyoder/quakejs`, adds the patches below |
| `entrypoint.sh` | Patches the client page, starts Apache and the dedicated server, runs the watchdog |
| `nodelay-patch.js` | Preloaded via `node --require`; sets `TCP_NODELAY` on incoming connections |
| `healthcheck.js` | Opens a WebSocket to `:27960`; exit 0 if the server answers |
| `server.cfg` | Server name, rules, map rotation, rcon password |
| `docker-compose.yml` | Runs the container with ports, restart policy, and the `server.cfg` bind mount |

## Build (on a machine with internet)

Requires Docker.

```bash
git clone https://github.com/extremeakim/quakeJS-airgap-optimizie.git
cd quakeJS-airgap-optimizie
docker build -t quakejs-airgap:latest .
docker save quakejs-airgap:latest | gzip > quakejs-airgap.tar.gz
```

Copy `quakejs-airgap.tar.gz`, `docker-compose.yml`, and `server.cfg` to the
air-gapped server. Keep `server.cfg` next to `docker-compose.yml`: the compose
file bind-mounts it, and a bind mount of a missing file creates an empty one and
the server loses its config.

## Deploy (on the air-gapped server)

Requires Docker and Docker Compose v2.

```bash
docker load < quakejs-airgap.tar.gz
docker compose up -d
```

Check it is running:

```bash
docker ps            # STATUS should show "healthy" after ~45s
docker logs quakejs  # look for "nodelay-patch: TCP_NODELAY enabled" once a player connects
```

## Play

Every player opens `http://<server-ip>:8080` in a browser. The client connects
automatically to the dedicated server in the same container.

Two ports must be reachable from the player PCs:

| Port | Purpose |
|------|---------|
| 8080 | Web client (HTTP) |
| 27960 | Game server (WebSocket) |

Browser clients can only play against other browser clients, not native Quake 3.

## Configuration

Edit `server.cfg` on the server, then `docker compose restart quakejs`. The file
is commented; the main knobs are at the top.

- **Rcon password** — change `rconpassword` before use. The shipped value is a
  placeholder.
- **Maps** — only the maps baked into the base image can be loaded:
  `q3dm1 q3dm7 q3dm9 q3dm17 q3tourney2 q3tourney6_ctf`. Other names fail to load.
- **Game type** — `g_gametype` 0 = FFA, 1 = tournament, 3 = team DM, 4 = CTF
  (CTF needs `q3tourney6_ctf`).
- **Tick rate** — `sv_fps 20` is stock and gives the single-threaded server the
  most headroom. Try 30 only if pings stay flat.

To change the map live without a restart, open the in-game console (`~`):

```
\rconpassword <your rcon password>
\rcon map q3dm17
```

## Operation notes

- **Restart policy** is `unless-stopped`: the container comes back after a
  crash, a hang (via the watchdog), or a host reboot, but not after a manual
  `docker compose stop`.
- **No persistent server state.** Quake 3 has no save system; scores reset on
  restart by design. Player names, binds, and video settings live in each
  player's browser storage, not on the server. The only durable server-side
  state is `server.cfg`.
- **CPU.** The dedicated server is single-threaded. `docker-compose.yml` grants
  it 2 CPUs; uncomment `cpuset` to pin it to specific cores if other containers
  share the host and pings spike under load.
- **Ping spikes after all this** almost always mean Wi-Fi or a lossy link. TCP
  turns small packet loss into stalls; use wired connections.

### Client-side tuning

In the in-game console (persists per browser):

```
\rate 25000
\snaps 40
\cl_maxpackets 60
\cl_timenudge 0
```

Lowering resolution or the render method in the in-game video menu fixes low
FPS on weaker client PCs.
