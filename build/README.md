# Build tooling

These scripts turn a clean [Kristal](https://github.com/KristalTeam/Kristal)
checkout into the static web app in [`../public`](../public). See the
[top-level README](../README.md) for the *why* behind each web-compatibility fix.

## Usage

```bash
git clone https://github.com/KristalTeam/Kristal.git
./build_web.sh Kristal ../public
```

`build_web.sh <kristal-src-dir> <out-dir>` does:

1. **Copy** the Kristal source to a temp dir (your checkout is never modified).
2. **Patch** it for the web with `patch_kristal.py`.
3. **Package** it into a `.love` (zip), excluding desktop-only files
   (`.git`, native `lib/`, Windows icon/build files, docs …).
4. **Compile** with `npx love.js@latest` (threaded build; `-m` sets initial
   memory, default 256 MiB, and memory grows as needed).
5. **Add** `coi-serviceworker.js` and register it as the first script in the
   generated `index.html`.
6. Drop a `.nojekyll` marker so GitHub Pages serves the files verbatim.

Environment overrides: `MEMORY=<bytes> ./build_web.sh …`.

## Files

- **`build_web.sh`** — the orchestrator described above.
- **`patch_kristal.py <kristal-dir> <webcompat.lua>`** — applies the source
  patches. Idempotent. It:
  - installs `webcompat.lua` at the engine root and adds `require("webcompat")`
    as the first line of `main.lua`;
  - rewrites every `goto continue` / `::continue::` loop into `repeat … until
    true` (vanilla Lua 5.1 has no `goto`);
  - rewrites the `Channel:demand()` worker loops in `loadthread.lua` and
    `httpsthread.lua` into `pop()` polling (`demand()` never wakes across
    love.js pthreads).
- **`webcompat.lua`** — runtime shim, required first from `main.lua`. It
  self-disables on desktop LÖVE (detected via a real `ffi`), so it only ever
  runs in the browser. Provides a stub `ffi`, a pure-Lua `bit`,
  `package.searchpath`, and a guard around the `love.filesystem.getRealDirectory`
  hang.
- **coi-serviceworker** — [gzuidhof/coi-serviceworker](https://github.com/gzuidhof/coi-serviceworker)
  (MIT). Fetched at build time, pinned to a specific commit (see `build_web.sh`),
  unless a local `build/coi-serviceworker.js` is present, which takes precedence.
  Enables `SharedArrayBuffer` (and therefore threads) on hosts that can't send
  COOP/COEP headers, like GitHub Pages.

## Testing the build locally

Threads need cross-origin isolation. On `localhost` the service worker can
register over plain HTTP, so a normal static server works:

```bash
cd ../public && python3 -m http.server 8000   # http://localhost:8000
```

Or serve with the headers set directly (no service-worker round-trip):

```bash
cd ../public && npx http-server -p 8000 \
  --header Cross-Origin-Opener-Policy=same-origin \
  --header Cross-Origin-Embedder-Policy=require-corp
```
