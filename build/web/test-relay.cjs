// Minimal local WebSocket relay for testing the multiplayer stack without
// internet access. Mirrors the semantics knet.js expects: room join with
// presence roster pushes, and broadcast relay to everyone else in the room.
// NOT used in production (production uses Supabase Realtime).
const { WebSocketServer } = require("ws");

const port = Number(process.argv[2] || 9100);
const wss = new WebSocketServer({ host: "127.0.0.1", port });
const rooms = new Map(); // room -> Map(key -> {sock, meta})

function roster(room) {
  const members = rooms.get(room);
  if (!members) return [];
  return [...members.entries()].map(([key, v]) => Object.assign({ key }, v.meta));
}

function pushPresence(room) {
  const members = rooms.get(room);
  if (!members) return;
  const msg = JSON.stringify({ t: "presence", players: roster(room) });
  for (const v of members.values()) if (v.sock.readyState === 1) v.sock.send(msg);
}

wss.on("connection", (sock) => {
  let room = null, key = null;
  sock.on("message", (raw) => {
    let m;
    try { m = JSON.parse(raw.toString()); } catch { return; }
    if (m.a === "join") {
      room = m.room; key = m.key;
      if (!rooms.has(room)) rooms.set(room, new Map());
      rooms.get(room).set(key, { sock, meta: m.meta || {} });
      pushPresence(room);
    } else if (m.a === "send" && room && key) {
      const members = rooms.get(room);
      if (!members) return;
      const msg = JSON.stringify({ t: "msg", d: { from: key, e: m.e, p: m.p } });
      for (const [k, v] of members.entries())
        if (k !== key && v.sock.readyState === 1) v.sock.send(msg);
    }
  });
  sock.on("close", () => {
    if (room && key && rooms.has(room)) {
      rooms.get(room).delete(key);
      if (rooms.get(room).size === 0) rooms.delete(room);
      else pushPresence(room);
    }
  });
});

console.log("test relay on ws://127.0.0.1:" + port);
