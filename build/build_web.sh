#!/usr/bin/env bash
# Build Kristal for the web with love.js.
#
#   build_web.sh <kristal-src-dir> <out-dir>
#
# Produces a self-contained static site in <out-dir> that runs Kristal in the
# browser. The Kristal source directory is copied first, so it is never mutated.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KRISTAL_DIR="${1:?usage: build_web.sh <kristal-src-dir> <out-dir>}"
OUT_DIR="${2:?output dir}"
MEMORY="${MEMORY:-268435456}"

WORK="$(mktemp -d)"
SRC="$WORK/kristal"
LOVE="$WORK/kristal.love"

echo ">> Copying Kristal source (leaving the original untouched)"
cp -a "$KRISTAL_DIR" "$SRC"

echo ">> Applying web-compatibility patches"
python3 "$HERE/patch_kristal.py" "$SRC" "$HERE/webcompat.lua"

echo ">> Packaging .love"
( cd "$SRC" && zip -r -9 -q "$LOVE" . \
    -x '.git/*' -x '.github/*' -x '.vscode/*' -x 'docs/*' -x 'lib/*' \
       -x 'build/*' -x 'output/*' -x '*.tiled-session' -x 'docs.json' \
       -x '.gitignore' -x '.editorconfig' -x '.luarc.json' \
       -x 'build.py' -x 'icon.rc' -x 'icon.res' -x 'icon.ico' )

echo ">> Compiling with love.js (threaded build)"
rm -rf "$OUT_DIR"
npx --yes "love.js@${LOVEJS_VERSION:-11.4.1}" "$LOVE" "$OUT_DIR" -t "Kristal" -m "$MEMORY"

echo ">> Adding coi-serviceworker (cross-origin isolation for SharedArrayBuffer on GitHub Pages)"
if [ -f "$HERE/coi-serviceworker.js" ]; then
    cp "$HERE/coi-serviceworker.js" "$OUT_DIR/coi-serviceworker.js"
else
    curl -fsSL https://raw.githubusercontent.com/gzuidhof/coi-serviceworker/7b1d2a092d0d2dd2b7270b6f12f13605de26f214/coi-serviceworker.js \
        -o "$OUT_DIR/coi-serviceworker.js"
fi

echo ">> Patching index.html to register coi-serviceworker first"
python3 - "$OUT_DIR/index.html" <<'PY'
import sys
p = sys.argv[1]
html = open(p, encoding="utf-8").read()
needle = '<link rel="stylesheet" type="text/css" href="theme/love.css">'
if "coi-serviceworker.js" not in html:
    html = html.replace(needle, '<script src="coi-serviceworker.js"></script>\n\n    ' + needle, 1)
open(p, "w", encoding="utf-8").write(html)
print("   index.html patched")
PY


echo ">> Patching love.js to export the Emscripten FS (needed by the multiplayer bridge)"
python3 - "$OUT_DIR/love.js" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
if 'Module["FS"]=FS;' not in s:
    assert 'FS.staticInit();' in s
    s = s.replace('FS.staticInit();', 'FS.staticInit();Module["FS"]=FS;', 1)
    open(p, "w").write(s)
print("   FS exported on Module")
PYEOF

echo ">> Fixing the OpenAL id/object bug in love.js (love.audio.stop/pause crash)"
python3 - "$OUT_DIR/love.js" <<'PYEOF'
import sys
# Emscripten's library_openal.js passes the raw source *id* to AL.setSourceState
# in alSourcePlayv/alSourcePausev/alSourceStopv, where every other caller passes
# the source *object*. setSourceState then reads src.bufQueue.length off an
# integer and throws "Cannot read properties of undefined (reading 'length')",
# which kills the whole wasm module.
#
# LOVE routes love.audio.stop()/pause() (no arguments) through Pool::stop(), which
# calls alSourceStopv, so *any* global stop crashed the tab -- including the one
# Kristal does when it loads a mod.
p = sys.argv[1]
s = open(p).read()
old = "AL.setSourceState(GROWABLE_HEAP_I32()[pSourceIds+i*4>>2],"
new = "AL.setSourceState(AL.currentCtx.sources[GROWABLE_HEAP_I32()[pSourceIds+i*4>>2]],"
n = s.count(old)
if n == 0:
    assert new in s, "alSource*v id/object bug: no call site found to patch"
    print("   already patched")
else:
    assert n == 3, "expected 3 alSource*v call sites, found %d" % n
    open(p, "w").write(s.replace(old, new))
    print("   patched %d alSource*v call site(s)" % n)
PYEOF

echo ">> Installing multiplayer web scripts"
cp "$HERE/web/supabase.js" "$OUT_DIR/supabase.js"
cp "$HERE/web/modloader.js" "$OUT_DIR/modloader.js"
cp "$HERE/web/luafix.js" "$OUT_DIR/luafix.js"
sed -e "s|__SUPA_URL__|${SUPA_URL:-https://ofnhmnzojewxbuxntntq.supabase.co}|" \
    -e "s|__SUPA_KEY__|${SUPA_KEY:-sb_publishable_EDDPpcBiKAC6CZdfidZonw_a-WBYAau}|" \
    "$HERE/web/knet.js" > "$OUT_DIR/knet.js"

echo ">> Wiring multiplayer into index.html"
python3 - "$OUT_DIR/index.html" <<'PYEOF'
import sys
p = sys.argv[1]
h = open(p).read()
needle = '<link rel="stylesheet" type="text/css" href="theme/love.css">'
scripts = ('<script src="supabase.js"></script>\n    <script src="knet.js"></script>\n'
           '    <script src="luafix.js"></script>\n    <script src="modloader.js"></script>\n    ')
if 'knet.js' not in h:
    h = h.replace(needle, scripts + needle, 1)
hook = """
      Module.print = function(text) {
        if (window.KNET && KNET.fromLua(text)) return;
        console.log(text);
      };
"""
anchor = "Module.setStatus('Downloading...');"
if 'KNET.fromLua' not in h:
    h = h.replace(anchor, anchor + hook, 1)
# install stored mods before the engine scans the mods folder
h = h.replace("var Module = {", "var Module = {\n        preRun: [function () { if (window.KMODS) KMODS.installToFS(); }],", 1)

# mod manager UI under the canvas
mod_ui = """
    <div id="kmods">
      <div class="kmods-row">
        <strong>Mods</strong>
        <label class="kmods-btn">+ Add mod (.zip)
          <input id="kmods-file" type="file" accept=".zip,.love" multiple hidden>
        </label>
        <span id="kmods-status">Drop a Kristal mod .zip anywhere on this page.</span>
      </div>
      <div id="kmods-list"><span class="kmods-empty">No mods added yet.</span></div>
    </div>
"""
h = h.replace("    <footer>", mod_ui + "    <footer>", 1)

mod_css = """
    <style>
      #kmods { font-family: arial; font-size: 13px; color: rgb(28,78,104);
               max-width: 640px; margin: 6px auto 40px; text-align: left; }
      .kmods-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
      .kmods-btn { background: rgb(233,73,154); color: #fff; padding: 3px 10px;
                   border-radius: 4px; cursor: pointer; white-space: nowrap; }
      .kmods-btn:hover { background: rgb(252,207,230); color: rgb(110,30,71); }
      #kmods-list { margin-top: 6px; }
      .kmods-chip { display: inline-block; background: rgba(255,255,255,.6);
                    border: 1px solid rgb(142,195,227); border-radius: 4px;
                    padding: 2px 6px; margin: 2px 4px 2px 0; }
      .kmods-chip button { border: 0; background: none; cursor: pointer;
                           color: rgb(233,73,154); font-weight: bold; }
      .kmods-empty { opacity: .6; }
      .kmods-clear { border: 0; background: none; cursor: pointer; font-size: 12px;
                     color: rgb(28,78,104); text-decoration: underline; }
    </style>
"""
h = h.replace("  </head>", mod_css + "  </head>", 1)

old_load = "var applicationLoad = function(e) {\n        Love(Module);\n      }"
new_load = """var applicationLoad = function(e) {
        if (!window.crossOriginIsolated && 'serviceWorker' in navigator) {
          // First-ever visit: coi-serviceworker is registering and is about to
          // reload the page with cross-origin isolation enabled. Starting the
          // engine now would throw "SharedArrayBuffer is not defined".
          drawLoadingText('Preparing... the page will reload.');
          return;
        }
        // Load stored mods out of IndexedDB before booting, so preRun can put
        // them on disk ahead of Kristal's mod scan.
        var ready = window.KMODS ? KMODS.preload() : Promise.resolve();
        ready.then(function () {
          if (window.KMODS) KMODS.initUI();
          Love(Module);
        });
      }"""
if 'crossOriginIsolated' not in h:
    h = h.replace(old_load, new_load, 1)
open(p, "w").write(h)
print("   index.html wired")
PYEOF

BUILD_ID="$(date -u +%Y%m%d-%H%M%S)"
echo ">> Stamping build $BUILD_ID (cache-busting all resources)"
sed -i "s|REMOTE_PACKAGE_BASE = 'game.data'|REMOTE_PACKAGE_BASE = 'game.data?v=$BUILD_ID'|" "$OUT_DIR/game.js"
python3 - "$OUT_DIR/index.html" "$BUILD_ID" <<'PYEOF'
import sys
p, v = sys.argv[1], sys.argv[2]
h = open(p).read()
for name in ["coi-serviceworker.js", "supabase.js", "knet.js", "luafix.js", "modloader.js", "theme/love.css"]:
    h = h.replace('src="%s"' % name, 'src="%s?v=%s"' % (name, v))
    h = h.replace('href="%s"' % name, 'href="%s?v=%s"' % (name, v))
h = h.replace('src="game.js"', 'src="game.js?v=%s"' % v)
h = h.replace('src="love.js"', 'src="love.js?v=%s"' % v)
h = h.replace('<script src="supabase.js',
    '<script>window.KRISTAL_BUILD="%s";console.log("Kristal web build "+window.KRISTAL_BUILD);</script>\n    <script src="supabase.js' % v)
h = h.replace('Hint: Reload the page if screen is blank',
    'Hint: Reload the page if screen is blank &middot; build %s' % v)
open(p, "w").write(h)
print("   build id stamped into index.html")
PYEOF

# GitHub Pages serves everything except files starting with "_" and won't serve
# a directory that has a Jekyll build; disable Jekyll to be safe.
touch "$OUT_DIR/.nojekyll"

rm -rf "$WORK"
echo ">> Done: $OUT_DIR"
