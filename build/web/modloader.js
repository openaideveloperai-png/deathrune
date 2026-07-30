// Web mod support for Kristal.
//
// Three archive layouts are accepted, because that's what people actually have:
//
//   1. A plain mod zip (mod.json at the top). Stored as-is -- Kristal's own
//      loader mounts .zip mods when it scans the mods folder.
//   2. A zip of the mod's parent folder (mod.json one level down).
//   3. A **full engine/game download** (the whole Kristal tree with the mod
//      inside its mods/ folder) -- e.g. a GameJolt or itch release.
//
// For 2 and 3 the mod is unpacked out of the archive and installed as a real
// folder under the save directory's mods/, which Kristal reads exactly like a
// desktop install. Unpacking uses the browser's built-in DecompressionStream,
// so there's no zip library to ship.
//
// Everything installed is mirrored into IndexedDB and rewritten into the
// Emscripten filesystem during Module.preRun, i.e. before the engine scans for
// mods, so mods survive reloads.

window.KMODS = (function () {
  var SAVEDIR = "/home/web_user/love/kristal";
  var MODS_DIR = SAVEDIR + "/mods";
  var DB_NAME = "kristal-mods";
  var STORE = "files";

  var MAX_READ_BYTES = 512 * 1024 * 1024;   // largest archive we'll open
  var MAX_INSTALL_BYTES = 192 * 1024 * 1024; // largest single mod we'll keep
  var MAX_TOTAL_BYTES = 384 * 1024 * 1024;   // all mods together
  var BOOT_FLAG = "kristal-mods-installing";

  // Folders inside a full engine build that aren't the user's mod.
  var SKIP_MODS = { example: 1, mod_template: 1 };

  var crashedLastBoot = false; // flag state as it was BEFORE this boot set it
  var entries = [];  // [{name, size, kind}] -- metadata for the UI
  var pending = [];  // [{name, value}] held only between preload() and preRun

  function mb(n) { return (n / 1048576).toFixed(1) + " MB"; }

  // ------------------------------------------------------------- IndexedDB --
  function openDB() {
    return new Promise(function (resolve, reject) {
      var req = indexedDB.open(DB_NAME, 1);
      req.onupgradeneeded = function () {
        if (!req.result.objectStoreNames.contains(STORE)) req.result.createObjectStore(STORE);
      };
      req.onsuccess = function () { resolve(req.result); };
      req.onerror = function () { reject(req.error); };
    });
  }

  function tx(mode, fn) {
    return openDB().then(function (db) {
      return new Promise(function (resolve, reject) {
        var t = db.transaction(STORE, mode);
        fn(t.objectStore(STORE));
        t.oncomplete = resolve;
        t.onerror = function () { reject(t.error); };
      });
    });
  }

  function idbAll() {
    return openDB().then(function (db) {
      return new Promise(function (resolve, reject) {
        var t = db.transaction(STORE, "readonly");
        var store = t.objectStore(STORE);
        var k = store.getAllKeys(), v = store.getAll();
        t.oncomplete = function () {
          var out = [];
          for (var i = 0; i < k.result.length; i++) out.push({ name: k.result[i], value: v.result[i] });
          resolve(out);
        };
        t.onerror = function () { reject(t.error); };
      });
    });
  }

  // ------------------------------------------------------------ zip reading --
  function readCentralDirectory(bytes) {
    var dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    var eocd = -1;
    var floor = Math.max(0, bytes.length - 66000);
    for (var i = bytes.length - 22; i >= floor; i--) {
      if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) return null;
    var count = dv.getUint16(eocd + 10, true);
    var cdOff = dv.getUint32(eocd + 16, true);
    if (cdOff === 0xffffffff || count === 0xffff) return null; // zip64 unsupported
    var list = [];
    var p = cdOff;
    for (var n = 0; n < count && p + 46 <= bytes.length; n++) {
      if (dv.getUint32(p, true) !== 0x02014b50) break;
      var method = dv.getUint16(p + 10, true);
      var cSize = dv.getUint32(p + 20, true);
      var uSize = dv.getUint32(p + 24, true);
      var nameLen = dv.getUint16(p + 28, true);
      var extraLen = dv.getUint16(p + 30, true);
      var cmtLen = dv.getUint16(p + 32, true);
      var lho = dv.getUint32(p + 42, true);
      var name = "";
      for (var c = 0; c < nameLen; c++) name += String.fromCharCode(bytes[p + 46 + c]);
      list.push({ name: name, method: method, cSize: cSize, uSize: uSize, lho: lho });
      p += 46 + nameLen + extraLen + cmtLen;
    }
    return list;
  }

  function inflateEntry(bytes, e) {
    var dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    if (dv.getUint32(e.lho, true) !== 0x04034b50) {
      return Promise.reject(new Error("bad local header for " + e.name));
    }
    var nameLen = dv.getUint16(e.lho + 26, true);
    var extraLen = dv.getUint16(e.lho + 28, true);
    var start = e.lho + 30 + nameLen + extraLen;
    var data = bytes.subarray(start, start + e.cSize);
    if (e.method === 0) return Promise.resolve(data);
    if (e.method !== 8) return Promise.reject(new Error("unsupported compression in " + e.name));
    if (typeof DecompressionStream === "undefined") {
      return Promise.reject(new Error("this browser can't unpack zips (no DecompressionStream)"));
    }
    var stream = new Blob([data]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
    return new Response(stream).arrayBuffer().then(function (buf) { return new Uint8Array(buf); });
  }

  // Which mod folder(s) can we get out of this archive?
  function planFor(list) {
    if (list === null) return { kind: "zip" }; // couldn't inspect; let the engine try
    var names = list.map(function (e) { return e.name; });
    if (names.indexOf("mod.json") !== -1) return { kind: "zip" };

    // full engine/game build: mods/<name>/mod.json
    var inMods = [];
    names.forEach(function (n) {
      var m = /^mods\/([^/]+)\/mod\.json$/.exec(n);
      if (m) inMods.push(m[1]);
    });
    if (inMods.length) {
      var real = inMods.filter(function (n) { return !SKIP_MODS[n]; });
      var picked = real.length ? real : inMods;
      return { kind: "extract", folders: picked.map(function (n) { return { prefix: "mods/" + n + "/", name: n }; }) };
    }

    // zip of the mod's parent folder: <name>/mod.json
    var nested = [];
    names.forEach(function (n) {
      var m = /^([^/]+)\/mod\.json$/.exec(n);
      if (m && !SKIP_MODS[m[1]]) nested.push(m[1]);
    });
    if (nested.length) {
      return { kind: "extract", folders: nested.map(function (n) { return { prefix: n + "/", name: n }; }) };
    }

    if (names.indexOf("main.lua") !== -1 && names.indexOf("conf.lua") !== -1) {
      return { kind: "error", why: "This looks like the Kristal engine with no mods inside it." };
    }
    return { kind: "error", why: "No mod.json found anywhere in this zip, so there's no mod to install." };
  }

  // ------------------------------------------------------------------ boot --
  function safeMode() {
    try { return localStorage.getItem(BOOT_FLAG) === "1"; } catch (e) { return false; }
  }
  function setBootFlag(v) {
    try { v ? localStorage.setItem(BOOT_FLAG, "1") : localStorage.removeItem(BOOT_FLAG); } catch (e) {}
  }

  function sizeOf(value) {
    if (value instanceof Uint8Array) return value.length;
    var t = 0;
    (value.files || []).forEach(function (f) { t += f.bytes.length; });
    return t;
  }

  function preload() {
    if (!window.indexedDB) return Promise.resolve([]);
    return idbAll().then(function (list) {
      entries = (list || []).map(function (m) {
        return {
          name: m.name, size: sizeOf(m.value),
          kind: m.value instanceof Uint8Array ? "zip" : "folder",
        };
      });
      crashedLastBoot = safeMode();
      if (crashedLastBoot) {
        pending = [];
        console.warn("KMODS: safe mode - skipping mod install after a failed load");
        return [];
      }
      pending = list || [];
      if (pending.length) {
        setBootFlag(true);
        console.log("KMODS: installing " + pending.length + " stored mod(s)");
      }
      return pending;
    }).catch(function (e) {
      console.warn("KMODS: could not read stored mods:", e);
      entries = []; pending = [];
      return [];
    });
  }

  function writeValueToFS(name, value) {
    if (value instanceof Uint8Array) {
      Module.FS.writeFile(MODS_DIR + "/" + name, value);
      return;
    }
    (value.files || []).forEach(function (f) {
      var full = MODS_DIR + "/" + name + "/" + f.path;
      var dir = full.slice(0, full.lastIndexOf("/"));
      try { Module.FS.mkdirTree(dir); } catch (e) {}
      Module.FS.writeFile(full, f.bytes);
    });
  }

  function installToFS() {
    if (!window.Module || !Module.FS) return;
    try { Module.FS.mkdirTree(MODS_DIR); } catch (e) {}
    pending.forEach(function (m) {
      try { writeValueToFS(m.name, m.value); }
      catch (e) { console.warn("KMODS: failed to install " + m.name, e); }
    });
    pending = [];
  }

  function bootSucceeded() { setBootFlag(false); }

  // --------------------------------------------------------------- add/del --
  function totalStored() {
    return entries.reduce(function (a, m) { return a + (m.size || 0); }, 0);
  }

  function store(name, value, kind) {
    var size = sizeOf(value);
    if (size > MAX_INSTALL_BYTES) {
      setStatus('"' + name + '" unpacks to ' + mb(size) + " - too big for a browser (limit " +
                mb(MAX_INSTALL_BYTES) + ").", true);
      return Promise.resolve(false);
    }
    if (totalStored() + size > MAX_TOTAL_BYTES) {
      setStatus("Not enough room: mods already total " + mb(totalStored()) + " (limit " +
                mb(MAX_TOTAL_BYTES) + "). Remove one first.", true);
      return Promise.resolve(false);
    }
    return tx("readwrite", function (s) { s.put(value, name); }).then(function () {
      try {
        Module.FS.mkdirTree(MODS_DIR);
        writeValueToFS(name, value);
      } catch (e) {
        setStatus("Could not install " + name + ": " + e.message, true);
        return false;
      }
      entries = entries.filter(function (m) { return m.name !== name; });
      entries.push({ name: name, size: size, kind: kind });
      if (window.KNET && KNET.push) KNET.push("mod_added", { name: name });
      renderList();
      return true;
    });
  }

  function extractFolder(bytes, list, folder) {
    var wanted = list.filter(function (e) {
      return e.name.indexOf(folder.prefix) === 0 && !/\/$/.test(e.name);
    });
    var files = [];
    return wanted.reduce(function (p, e) {
      return p.then(function () {
        return inflateEntry(bytes, e).then(function (data) {
          files.push({ path: e.name.slice(folder.prefix.length), bytes: data });
        }).catch(function (err) {
          console.warn("KMODS: skipping " + e.name + ": " + err.message);
        });
      });
    }, Promise.resolve()).then(function () {
      return { files: files, __folder: true };
    });
  }

  function addZip(file) {
    var fname = file.name;
    if (!/\.(zip|love)$/i.test(fname)) {
      setStatus("Not a .zip: " + fname, true);
      return Promise.resolve(false);
    }
    if (file.size > MAX_READ_BYTES) {
      setStatus('"' + fname + '" is ' + mb(file.size) + " - too big to open in a browser.", true);
      return Promise.resolve(false);
    }
    setStatus("Reading " + fname + " (" + mb(file.size) + ")...");

    return file.arrayBuffer().then(function (buf) {
      var bytes = new Uint8Array(buf);
      var list = readCentralDirectory(bytes);
      var plan = planFor(list);

      if (plan.kind === "error") { setStatus(plan.why, true); return false; }

      if (plan.kind === "zip") {
        var zipName = fname.replace(/\.love$/i, ".zip");
        return store(zipName, bytes, "zip").then(function (ok) {
          if (ok) setStatus('Added "' + zipName + '" - open Play to find it.');
          return ok;
        });
      }

      // extract one or more mod folders out of the archive
      setStatus("Unpacking " + plan.folders.length + " mod(s) from " + fname + "...");
      var added = [];
      return plan.folders.reduce(function (p, folder) {
        return p.then(function () {
          return extractFolder(bytes, list, folder).then(function (value) {
            if (!value.files.length) return;
            return store(folder.name, value, "folder").then(function (ok) {
              if (ok) added.push(folder.name);
            });
          });
        });
      }, Promise.resolve()).then(function () {
        if (!added.length) { setStatus("Couldn't unpack a mod from " + fname + ".", true); return false; }
        setStatus('Added ' + added.map(function (n) { return '"' + n + '"'; }).join(", ") +
                  " from " + fname + " - open Play to find " +
                  (added.length > 1 ? "them." : "it."));
        return true;
      });
    }).catch(function (e) {
      setStatus("Failed to read that file: " + e.message, true);
      return false;
    });
  }

  function removeMod(name) {
    return tx("readwrite", function (s) { s.delete(name); }).then(function () {
      var m = entries.filter(function (x) { return x.name === name; })[0];
      try {
        if (m && m.kind === "folder") {
          // recursive delete
          var walk = function (dir) {
            (Module.FS.readdir(dir) || []).forEach(function (f) {
              if (f === "." || f === "..") return;
              var full = dir + "/" + f;
              var st = Module.FS.stat(full);
              if (Module.FS.isDir(st.mode)) { walk(full); try { Module.FS.rmdir(full); } catch (e) {} }
              else { try { Module.FS.unlink(full); } catch (e) {} }
            });
          };
          walk(MODS_DIR + "/" + name);
          try { Module.FS.rmdir(MODS_DIR + "/" + name); } catch (e) {}
        } else {
          Module.FS.unlink(MODS_DIR + "/" + name);
        }
      } catch (e) {}
      entries = entries.filter(function (x) { return x.name !== name; });
      if (window.KNET && KNET.push) KNET.push("mod_added", { name: name, removed: true });
      setStatus('Removed "' + name + '".');
      renderList();
    });
  }

  function removeAll() {
    return entries.map(function (m) { return m.name; })
      .reduce(function (p, n) { return p.then(function () { return removeMod(n); }); }, Promise.resolve())
      .then(function () { setBootFlag(false); setStatus("All mods removed."); });
  }

  // -------------------------------------------------------------------- UI --
  function setStatus(text, isError) {
    var el = document.getElementById("kmods-status");
    if (!el) return;
    el.textContent = text;
    el.style.color = isError ? "#c0392b" : "#1c4e68";
  }

  function renderList() {
    var el = document.getElementById("kmods-list");
    if (!el) return;
    el.innerHTML = "";
    if (!entries.length) {
      el.innerHTML = '<span class="kmods-empty">No mods added yet.</span>';
      return;
    }
    entries.forEach(function (m) {
      var row = document.createElement("span");
      row.className = "kmods-chip";
      row.textContent = m.name + " (" + mb(m.size) + ") ";
      var x = document.createElement("button");
      x.textContent = "✕";
      x.title = "Remove this mod";
      x.onclick = function () { removeMod(m.name); };
      row.appendChild(x);
      el.appendChild(row);
    });
    var all = document.createElement("button");
    all.className = "kmods-clear";
    all.textContent = "Remove all";
    all.onclick = removeAll;
    el.appendChild(all);
  }

  function initUI() {
    var input = document.getElementById("kmods-file");
    var handle = function (files) {
      Array.prototype.slice.call(files || []).reduce(function (p, f) {
        return p.then(function () { return addZip(f); });
      }, Promise.resolve());
    };
    if (input) {
      input.addEventListener("change", function () { handle(input.files); input.value = ""; });
    }
    window.addEventListener("dragover", function (e) { e.preventDefault(); });
    window.addEventListener("drop", function (e) {
      e.preventDefault();
      if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length) handle(e.dataTransfer.files);
    });
    renderList();
    if (crashedLastBoot) {
      setStatus("Your mods were skipped because the last load crashed. Remove the " +
                "biggest one below, then reload.", true);
      setBootFlag(false);
    } else if (entries.length) {
      setStatus(entries.length + " mod(s) installed - open Play to choose one.");
    }
  }

  return {
    preload: preload,
    installToFS: installToFS,
    bootSucceeded: bootSucceeded,
    initUI: initUI,
    addZip: addZip,
    list: function () { return entries.map(function (m) { return m.name; }); },
  };
})();
