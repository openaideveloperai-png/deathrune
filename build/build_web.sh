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
# coi-serviceworker (gzuidhof, MIT), pinned to a specific commit for reproducibility.
# A local copy at build/coi-serviceworker.js, if present, takes precedence.
COI_SHA="7b1d2a092d0d2dd2b7270b6f12f13605de26f214"
if [ -f "$HERE/coi-serviceworker.js" ]; then
    cp "$HERE/coi-serviceworker.js" "$OUT_DIR/coi-serviceworker.js"
else
    curl -fsSL "https://raw.githubusercontent.com/gzuidhof/coi-serviceworker/${COI_SHA}/coi-serviceworker.js" \
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

# GitHub Pages serves everything except files starting with "_" and won't serve
# a directory that has a Jekyll build; disable Jekyll to be safe.
touch "$OUT_DIR/.nojekyll"

rm -rf "$WORK"
echo ">> Done: $OUT_DIR"
