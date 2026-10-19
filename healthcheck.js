// Liveness probe for the QuakeJS dedicated server.
//
// Opens a WebSocket to the game server on :27960. If the server's Node event
// loop is healthy it completes the upgrade almost instantly (exit 0). If the
// server has hung or died (the "silently fails on idle" case), the upgrade
// never completes and this exits non-zero — used by both the Docker HEALTHCHECK
// (for `docker ps` visibility) and the entrypoint watchdog (which restarts it).

const WebSocket = require("/quakejs/node_modules/ws");

let settled = false;
function done(code) {
  if (settled) return;
  settled = true;
  try { ws.terminate(); } catch (e) {}
  process.exit(code);
}

const ws = new WebSocket("ws://127.0.0.1:27960");
ws.on("open", () => done(0));
ws.on("error", () => done(1));
setTimeout(() => done(1), 4000);
