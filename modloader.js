// Web mod support for Kristal.
//
// Kristal's mod loader already understands .zip mods: when it scans the mods
// folder it mounts any .zip it finds (see src/engine/loadthread.lua). So the
// browser build only has to place the uploaded zip into the save directory's
// mods/ folder -- no unzipping, no engine changes to how mods are read.
//
// Mods are kept in IndexedDB so they survive reloads, and are written back into
// the Emscripten filesystem during Module.preRun, i.e. before the engine boots
// and scans for mods.
//
// Uploads are validated before being stored, because the two most common
// mistakes both used to end badly:
//   * a full game/engine download (hundreds of MB, no mod.json at the root)
//     would be stored and then crash the tab on every single load, since the
//     stored copy is re-read at boot -- an inescapable crash loop.
//   * a zip of the mod's *parent* folder puts mod.json one level too deep, so
//     Kristal silently ignores it.
// Both are now rejected up front with an explanation, plus a hard size cap and
// a safe-mode flag that skips mod installation if the previous boot died.

window.KMODS = (function () {
  var SAVEDIR = "/home/web_user/love/kristal";
  var MODS_DIR = SAVEDIR + "/mods";
  var DB_NAME = "kristal-mods";
  var STORE = "files";

  var MAX_BYTES = 128 * 1024 * 1024;      // per mod
  var MAX_TOTAL_BYTES = 256 * 1024 * 1024; // all mods together
  var WARN_BYTES = 48 * 1024 * 1024;

  var BOOT_FLAG = "kristal-mods-installing";

  var entries = [];  // [{name, size}] -- metadata only, never the bytes
  var pending = [];  // [{name, bytes}] held only between preload() and preRun

  function mb(n) { return (n / 1048576).toFixed(1) + " MB"; }

  // ------------------------------------------------------------- IndexedDB --
  function openDB() {
    return new Promise(function (resolve, reject) {
      var req = indexedDB.open(DB_NAME, 1);
      req.onupgradeneeded = function () {
        if (!req.result.objectStoreNames.contains(STORE)) {
          req.result.createObjectStore(STORE);
        }
      };
      req.onsuccess = function () { resolve(req.result); };
      req.onerror = function () { reject(req.error); };
    });
  }

  function tx(mode, fn) {
    return openDB().then(function (db) {
      return new Promise(function (resolve, reject) {
        var t = db.transaction(STORE, mode);
        var out = fn(t.objectStore(STORE));
        t.oncomplete = function () { resolve(out && out.result !== undefined ? out.result : out); };
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
          for (var i = 0; i < k.result.length; i++) out.push({ name: k.result[i], bytes: v.result[i] });
          resolve(out);
        };
        t.onerror = function () { reject(t.error); };
      });
    });
  }

  // ------------------------------------------------------ zip introspection --
  // Minimal central-directory reader: enough to list the archive's entries so
  // we can tell a real mod from a full game download.
  function zipEntries(bytes) {
    var dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    var eocd = -1;
    var start = Math.max(0, bytes.length - 66000);
    for (var i = bytes.length - 22; i >= start; i--) {
      if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) return null; // not a zip at all
    var count = dv.getUint16(eocd + 10, true);
    var cdOff = dv.getUint32(eocd + 16, true);
    if (cdOff === 0xffffffff || count === 0xffff) return null; // zip64: skip checks
    var names = [];
    var p = cdOff;
    for (var n = 0; n < count && p + 46 <= bytes.length; n++) {
      if (dv.getUint32(p, true) !== 0x02014b50) break;
      var nameLen = dv.getUint16(p + 28, true);
      var extraLen = dv.getUint16(p + 30, true);
      var cmtLen = dv.getUint16(p + 32, true);
      var name = "";
      for (var c = 0; c < nameLen; c++) name += String.fromCharCode(bytes[p + 46 + c]);
      names.push(name);
      p += 46 + nameLen + extraLen + cmtLen;
    }
    return names;
  }

  // Returns null if this archive is a usable Kristal mod, else a message.
  function whyNotAMod(names) {
    if (names === null) return null; // couldn't inspect: let the engine decide
    var has = function (re) { return names.some(function (n) { return re.test(n); }); };
    if (has(/^mod\.json$/)) return null; // 👍 a proper mod

    var nested = names.filter(function (n) { return /^[^/]+\/mod\.json$/.test(n); });
    if (nested.length === 1) {
      var folder = nested[0].split("/")[0];
      return 'This zip has the mod inside a "' + folder + '" folder. Open ' +
             'that folder and zip its *contents* (so mod.json is at the top of the zip).';
    }
    var inMods = names.filter(function (n) { return /^mods\/[^/]+\/mod\.json$/.test(n); });
    if (inMods.length) {
      var list = inMods.map(function (n) { return n.split("/")[1]; }).join(", ");
      return "This is a full game download, not a mod. The mod itself is in its " +
             "mods folder (" + list + ") - unzip this, then zip that mod's own " +
             "folder contents instead.";
    }
    if (has(/^main\.lua$/) && has(/^conf\.lua$/)) {
      return "This is a whole Kristal/LOVE game, not a mod (no mod.json). " +
             "Only individual mod folders can be added here.";
    }
    return "No mod.json found at the top of this zip, so Kristal can't read it " +
           "as a mod.";
  }

  // ------------------------------------------------------------------ boot --
  function safeMode() {
    try { return localStorage.getItem(BOOT_FLAG) === "1"; } catch (e) { return false; }
  }
  function setBootFlag(v) {
    try { v ? localStorage.setItem(BOOT_FLAG, "1") : localStorage.removeItem(BOOT_FLAG); } catch (e) {}
  }

  // Read stored mods into memory. Called before the engine starts so the
  // synchronous preRun step has the bytes ready.
  function preload() {
    if (!window.indexedDB) return Promise.resolve([]);
    return idbAll().then(function (list) {
      entries = (list || []).map(function (m) {
        return { name: m.name, size: m.bytes && m.bytes.length || 0 };
      });
      if (safeMode()) {
        // The previous boot set this flag and never cleared it, i.e. the tab
        // died while these mods were installed. Don't try again.
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

  // Synchronously write the preloaded mods into the FS (Module.preRun), then
  // release the byte copies so they aren't held for the whole session.
  function installToFS() {
    if (!window.Module || !Module.FS) return;
    try { Module.FS.mkdirTree(MODS_DIR); } catch (e) {}
    pending.forEach(function (m) {
      try {
        Module.FS.writeFile(MODS_DIR + "/" + m.name, m.bytes);
      } catch (e) {
        console.warn("KMODS: failed to install " + m.name, e);
      }
    });
    pending = [];
  }

  // Called once the engine is actually running: the boot survived, so the mods
  // we installed are safe to install again next time.
  function bootSucceeded() { setBootFlag(false); }

  // --------------------------------------------------------------- add/del --
  function totalStored() {
    return entries.reduce(function (a, m) { return a + (m.size || 0); }, 0);
  }

  function addZip(file) {
    var name = file.name;
    if (!/\.(zip|love)$/i.test(name)) {
      setStatus("Not a .zip mod: " + name, true);
      return Promise.resolve(false);
    }
    if (/\.love$/i.test(name)) name = name.replace(/\.love$/i, ".zip");

    if (file.size > MAX_BYTES) {
      setStatus('"' + file.name + '" is ' + mb(file.size) + " - too big to load in a " +
                "browser (limit " + mb(MAX_BYTES) + "). Full game downloads won't work; " +
                "add just the mod folder.", true);
      return Promise.resolve(false);
    }
    if (totalStored() + file.size > MAX_TOTAL_BYTES) {
      setStatus("Not enough room: mods total " + mb(totalStored()) + " and the limit is " +
                mb(MAX_TOTAL_BYTES) + ". Remove one first.", true);
      return Promise.resolve(false);
    }
    if (file.size > WARN_BYTES) setStatus("Reading " + mb(file.size) + ", one moment...");

    return file.arrayBuffer().then(function (buf) {
      var bytes = new Uint8Array(buf);

      var problem = whyNotAMod(zipEntries(bytes));
      if (problem) {
        setStatus(problem, true);
        return false;
      }

      return tx("readwrite", function (store) { store.put(bytes, name); }).then(function () {
        try {
          Module.FS.mkdirTree(MODS_DIR);
          Module.FS.writeFile(MODS_DIR + "/" + name, bytes);
        } catch (e) {
          setStatus("Could not install " + name + ": " + e.message, true);
          return false;
        }
        entries = entries.filter(function (m) { return m.name !== name; });
        entries.push({ name: name, size: bytes.length });
        if (window.KNET && KNET.push) KNET.push("mod_added", { name: name });
        setStatus('Added "' + name + '" (' + mb(bytes.length) + ') - open Play to find it.');
        renderList();
        return true;
      });
    }).catch(function (e) {
      setStatus("Failed to read that file: " + e.message, true);
      return false;
    });
  }

  function removeMod(name) {
    return tx("readwrite", function (store) { store.delete(name); }).then(function () {
      try { Module.FS.unlink(MODS_DIR + "/" + name); } catch (e) {}
      entries = entries.filter(function (m) { return m.name !== name; });
      if (window.KNET && KNET.push) KNET.push("mod_added", { name: name, removed: true });
      setStatus('Removed "' + name + '".');
      renderList();
    });
  }

  function removeAll() {
    var names = entries.map(function (m) { return m.name; });
    return names.reduce(function (p, n) {
      return p.then(function () { return removeMod(n); });
    }, Promise.resolve()).then(function () {
      setBootFlag(false);
      setStatus("All mods removed.");
    });
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
    if (input) {
      input.addEventListener("change", function () {
        var files = Array.prototype.slice.call(input.files || []);
        files.reduce(function (p, f) { return p.then(function () { return addZip(f); }); },
                     Promise.resolve());
        input.value = "";
      });
    }
    window.addEventListener("dragover", function (e) { e.preventDefault(); });
    window.addEventListener("drop", function (e) {
      e.preventDefault();
      var files = Array.prototype.slice.call((e.dataTransfer && e.dataTransfer.files) || []);
      if (!files.length) return;
      files.reduce(function (p, f) { return p.then(function () { return addZip(f); }); },
                   Promise.resolve());
    });
    renderList();
    if (safeMode()) {
      setStatus("Your mods were skipped because the last load crashed - the mod " +
                "was probably too big. Remove it below, then reload.", true);
      setBootFlag(false); // one-shot: next reload tries again
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
