// TCP_NODELAY patch for the QuakeJS dedicated server.
//
// Quake's netcode sends many tiny packets per second. Node.js leaves Nagle's
// algorithm ON by default, which batches small TCP packets and — combined with
// TCP delayed-ACK — produces sudden latency spikes (ping jumping from ~20ms to
// 200-700ms and players "teleporting") even on a fast LAN. WebSocket runs over
// TCP, so the game server is subject to this.
//
// The dedicated server (build/ioq3ded.js) creates its WebSocket server
// internally, so we can't pass socket options to it directly. Instead we
// preload this module (node --require) BEFORE the server starts and patch
// net.Server so every incoming connection has Nagle disabled. This covers the
// http/ws server the game server stands up on :27960.

const net = require("net");

const origEmit = net.Server.prototype.emit;
net.Server.prototype.emit = function (event, ...args) {
  if (event === "connection") {
    const socket = args[0];
    if (socket && typeof socket.setNoDelay === "function") {
      try {
        socket.setNoDelay(true);
        if (!net.Server.__nodelayLogged) {
          net.Server.__nodelayLogged = true;
          console.log("nodelay-patch: TCP_NODELAY enabled on game-server sockets");
        }
      } catch (e) {
        /* best effort */
      }
    }
  }
  return origEmit.apply(this, [event, ...args]);
};
