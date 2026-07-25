// KNet: JavaScript side of the Kristal web multiplayer bridge.
//
// Lua -> JS: the game prints "[KNET]<json>" lines; index.html routes
//            Module.print through KNET.fromLua.
// JS -> Lua: messages are queued and flushed into <savedir>/knet_in.json in
//            the Emscripten filesystem, which the Lua side polls every frame.
//
// Transport: Supabase Realtime channels (broadcast + presence). For local
// testing without internet access, add ?knetws=ws://127.0.0.1:PORT to use a
// plain WebSocket relay speaking a tiny JSON protocol instead.

window.KNET = (function () {
  var SUPA_URL = "__SUPA_URL__";
  var SUPA_KEY = "__SUPA_KEY__";

  var savedir = null;
  var seq = 0;
  var queue = [];
  var myKey = null;
  var trackMeta = null;
  var hostFlag = 0;
  var trackTs = 0;

  // Supabase state
  var client = null;
  var channel = null;
  var chJoined = false;

  // Local-relay state (testing only)
  var ws = null;
  var wsUrl = new URLSearchParams(location.search).get("knetws");

  function toLua(t, d) {
    queue.push({ s: ++seq, t: t, d: d || {} });
    if (queue.length > 500) queue.splice(0, queue.length - 500);
  }

  function flush() {
    if (!savedir || !window.Module || !Module.FS) return;
    try {
      Module.FS.writeFile(savedir + "/knet_in.json", JSON.stringify({ msgs: queue }));
    } catch (e) {}
  }
  setInterval(flush, 33);

  function genKey() {
    return "p" + Math.random().toString(36).slice(2, 10);
  }

  // ---------------- Supabase transport ----------------

  function supaConnect(room, hosting, meta) {
    myKey = genKey();
    hostFlag = hosting ? 1 : 0;
    trackTs = Date.now();
    trackMeta = meta || {};
    try {
      client = client || supabase.createClient(SUPA_URL, SUPA_KEY);
    } catch (e) {
      toLua("status", { state: "error", why: "supabase client: " + e.message });
      return;
    }
    channel = client.channel("kristal:" + room, {
      config: { broadcast: { self: false }, presence: { key: myKey } },
    });
    channel.on("presence", { event: "sync" }, function () {
      var st = channel.presenceState();
      var players = [];
      for (var k in st) {
        if (st[k] && st[k][0]) {
          var m = st[k][0];
          players.push({ key: k, name: m.name, color: m.color, ts: m.ts, h: m.h });
        }
      }
      toLua("presence", { players: players });
    });
    channel.on("broadcast", { event: "m" }, function (p) {
      if (p && p.payload) toLua("msg", p.payload);
    });
    channel.subscribe(function (status, err) {
      if (status === "SUBSCRIBED") {
        chJoined = true;
        channel.track(Object.assign({ ts: trackTs, h: hostFlag }, trackMeta));
        toLua("status", { state: "joined", room: room, key: myKey });
      } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
        toLua("status", { state: "error", why: String(status) + (err ? ": " + err.message : "") });
      } else if (status === "CLOSED") {
        chJoined = false;
        toLua("status", { state: "closed" });
      }
    });
  }

  function supaSend(e, d) {
    if (channel && chJoined) {
      channel.send({ type: "broadcast", event: "m", payload: { from: myKey, e: e, p: d } });
    }
  }

  function supaLeave() {
    if (channel && client) {
      try { client.removeChannel(channel); } catch (e) {}
    }
    channel = null;
    chJoined = false;
  }

  // ---------------- Local relay transport (testing) ----------------

  function wsConnect(room, hosting, meta) {
    myKey = genKey();
    ws = new WebSocket(wsUrl);
    ws.onopen = function () {
      ws.send(JSON.stringify({
        a: "join", room: room, key: myKey,
        meta: Object.assign({ ts: Date.now(), h: hosting ? 1 : 0 }, meta || {}),
      }));
      toLua("status", { state: "joined", room: room, key: myKey });
    };
    ws.onmessage = function (ev) {
      try {
        var m = JSON.parse(ev.data);
        if (m.t === "presence") toLua("presence", { players: m.players });
        else if (m.t === "msg") toLua("msg", m.d);
      } catch (e) {}
    };
    ws.onerror = function () { toLua("status", { state: "error", why: "ws error" }); };
    ws.onclose = function () { toLua("status", { state: "closed" }); };
  }

  function wsSend(e, d) {
    if (ws && ws.readyState === 1) {
      ws.send(JSON.stringify({ a: "send", e: e, p: d }));
    }
  }

  function wsLeave() {
    if (ws) { try { ws.close(); } catch (e) {} ws = null; }
  }

  // ---------------- Command dispatch from Lua ----------------

  function fromLua(line) {
    if (typeof line !== "string" || line.indexOf("[KNET]") !== 0) return false;
    var m;
    try { m = JSON.parse(line.slice(6)); } catch (e) { return true; }
    try {
      if (m.c === "ready") {
        savedir = m.savedir;
        try { Module.FS.mkdirTree(savedir); } catch (e) {}
        toLua("hello", {});
      } else if (m.c === "ack") {
        queue = queue.filter(function (x) { return x.s > m.s; });
      } else if (m.c === "host") {
        (wsUrl ? wsConnect : supaConnect)(m.room, true, m.meta);
      } else if (m.c === "join") {
        (wsUrl ? wsConnect : supaConnect)(m.room, false, m.meta);
      } else if (m.c === "send") {
        (wsUrl ? wsSend : supaSend)(m.e, m.d);
      } else if (m.c === "leave") {
        (wsUrl ? wsLeave : supaLeave)();
      }
    } catch (e) {
      console.error("KNET error handling", m, e);
    }
    return true;
  }

  return { fromLua: fromLua };
})();
