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

window.KMODS = (function () {
  var SAVEDIR = "/home/web_user/love/kristal";
  var MODS_DIR = SAVEDIR + "/mods";
  var DB_NAME = "kristal-mods";
  var STORE = "files";

  var cache = []; // [{name, bytes}] loaded from IndexedDB before boot

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

  function idbAll() {
    return openDB().then(function (db) {
      return new Promise(function (resolve, reject) {
        var tx = db.transaction(STORE, "readonly");
        var store = tx.objectStore(STORE);
        var keysReq = store.getAllKeys();
        var valsReq = store.getAll();
        tx.oncomplete = function () {
          var out = [];
          for (var i = 0; i < keysReq.result.length; i++) {
            out.push({ name: keysReq.result[i], bytes: valsReq.result[i] });
          }
          resolve(out);
        };
        tx.onerror = function () { reject(tx.error); };
      });
    });
  }

  function idbPut(name, bytes) {
    return openDB().then(function (db) {
      return new Promise(function (resolve, reject) {
        var tx = db.transaction(STORE, "readwrite");
        tx.objectStore(STORE).put(bytes, name);
        tx.oncomplete = resolve;
        tx.onerror = function () { reject(tx.error); };
      });
    });
  }

  function idbDelete(name) {
    return openDB().then(function (db) {
      return new Promise(function (resolve, reject) {
        var tx = db.transaction(STORE, "readwrite");
        tx.objectStore(STORE).delete(name);
        tx.oncomplete = resolve;
        tx.onerror = function () { reject(tx.error); };
      });
    });
  }

  // ------------------------------------------------------------------ boot --
  // Read every stored mod into memory. Called BEFORE the engine starts so the
  // synchronous preRun step below has the bytes ready.
  function preload() {
    if (!window.indexedDB) return Promise.resolve([]);
    return idbAll().then(function (list) {
      cache = list || [];
      if (cache.length) {
        console.log("KMODS: " + cache.length + " stored mod(s) to install");
      }
      return cache;
    }).catch(function (e) {
      console.warn("KMODS: could not read stored mods:", e);
      cache = [];
      return cache;
    });
  }

  // Synchronously write the preloaded mods into the Emscripten FS. Must run in
  // Module.preRun, before Kristal scans the mods folder.
  function installToFS() {
    if (!window.Module || !Module.FS) return;
    try { Module.FS.mkdirTree(MODS_DIR); } catch (e) {}
    cache.forEach(function (m) {
      try {
        Module.FS.writeFile(MODS_DIR + "/" + m.name, m.bytes);
        console.log("KMODS: installed " + m.name);
      } catch (e) {
        console.warn("KMODS: failed to install " + m.name, e);
      }
    });
  }

  // --------------------------------------------------------------- add/del --
  function addZip(file) {
    var name = file.name;
    if (!/\.(zip|love)$/i.test(name)) {
      setStatus("Not a .zip mod: " + name, true);
      return Promise.resolve(false);
    }
    if (/\.love$/i.test(name)) name = name.replace(/\.love$/i, ".zip");
    return file.arrayBuffer().then(function (buf) {
      var bytes = new Uint8Array(buf);
      return idbPut(name, bytes).then(function () {
        try {
          Module.FS.mkdirTree(MODS_DIR);
          Module.FS.writeFile(MODS_DIR + "/" + name, bytes);
        } catch (e) {
          setStatus("Could not write " + name + ": " + e.message, true);
          return false;
        }
        cache = cache.filter(function (m) { return m.name !== name; });
        cache.push({ name: name, bytes: bytes });
        if (window.KNET && KNET.push) KNET.push("mod_added", { name: name });
        setStatus('Added "' + name + '" - open Play to see it in the mod list.');
        renderList();
        return true;
      });
    });
  }

  function removeMod(name) {
    return idbDelete(name).then(function () {
      try { Module.FS.unlink(MODS_DIR + "/" + name); } catch (e) {}
      cache = cache.filter(function (m) { return m.name !== name; });
      if (window.KNET && KNET.push) KNET.push("mod_added", { name: name, removed: true });
      setStatus('Removed "' + name + '".');
      renderList();
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
    if (!cache.length) {
      el.innerHTML = '<span class="kmods-empty">No mods added yet.</span>';
      return;
    }
    el.innerHTML = "";
    cache.forEach(function (m) {
      var row = document.createElement("span");
      row.className = "kmods-chip";
      row.textContent = m.name + " ";
      var x = document.createElement("button");
      x.textContent = "✕";
      x.title = "Remove this mod";
      x.onclick = function () { removeMod(m.name); };
      row.appendChild(x);
      el.appendChild(row);
    });
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
    // drag & drop anywhere on the page
    window.addEventListener("dragover", function (e) { e.preventDefault(); });
    window.addEventListener("drop", function (e) {
      e.preventDefault();
      var files = Array.prototype.slice.call((e.dataTransfer && e.dataTransfer.files) || []);
      if (!files.length) return;
      files.reduce(function (p, f) { return p.then(function () { return addZip(f); }); },
                   Promise.resolve());
    });
    renderList();
  }

  return {
    preload: preload,
    installToFS: installToFS,
    initUI: initUI,
    addZip: addZip,
    list: function () { return cache.map(function (m) { return m.name; }); },
  };
})();
