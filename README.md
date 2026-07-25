# Kristal on the Web

This repository packages the [**Kristal**](https://github.com/KristalTeam/Kristal)
DELTARUNE fangame engine to run **in a web browser**, and hosts it on GitHub
Pages.

Kristal is built with [LÖVE](https://love2d.org/) (a desktop Lua game
framework). To run it on the web it is compiled to WebAssembly with
[**love.js**](https://github.com/Davidobot/love.js) (an Emscripten port of
LÖVE), plus a small compatibility layer that bridges the differences between
desktop LÖVE (LuaJIT) and the browser runtime (vanilla Lua 5.1).

## 🎮 Live demo

Once the **Deploy** workflow has run, the engine is live at:

> **https://openaideveloperai-png.github.io/deathrune/**

The first load downloads ~19 MB and then spends up to a minute on a black
`kristal LOADING....` screen while it decodes every engine asset in the
browser — this is normal (see [Limitations](#limitations)). When it finishes
you get the full main menu, playable with the keyboard.

Controls: **arrow keys** to move, **Z / Enter** to confirm, **X / Shift** to
cancel, **C / Ctrl** for the menu.

## 🌐 Multiplayer

The web build now has **online co-op**: pick **Play Online** on the main menu,
choose a username and SOUL color, then **host** a room (you get a 4-letter
code) or **join** with a friend's code. Rooms run over **Supabase Realtime**
(hosted WebSockets) -- nobody needs to host or install anything.

- Player 1 (the host) is always **Kris**; joiners become **Susie, Ralsei,
  Noelle**, then that trio repeats. Only the host can be Kris.
- Every player walks around as **their own character** -- nobody trails behind
  Kris. Other players appear live with their username above their head in
  their chosen soul color.
- In the dark-world **C menu** there's a new **PARTY** button showing the room
  code (share it to invite people) and everyone connected.
- Multiplayer **battles** (turn order per player, one soul per player in the
  bullet phase, host-authoritative attacks) are the next stage and not yet
  synced -- battles currently run locally per player.

## What's in here

```
build/                  Tooling that compiles Kristal's source into the web app
  build_web.sh            One command: package .love + compile with love.js + add coi
  patch_kristal.py        Applies the minimal web-compatibility source patches
  webcompat.lua           Runtime shim (ffi / bit / package.searchpath / a love.js bug workaround)
  coi-serviceworker.js    Enables SharedArrayBuffer on GitHub Pages (see below)
.github/workflows/deploy.yml   Builds Kristal (pinned commit) and deploys to Pages
```

The finished site lives in `public/`, which is **generated** — by CI on every
push, or locally with `build/build_web.sh`. It is not committed (see
`.gitignore`); the engine's assets are large and the source of truth is
Kristal's repository plus the small patches in `build/`.

## How it works

### 1. Compiling to WebAssembly (love.js)

Kristal targets **LÖVE 11.5**. love.js is the Emscripten port of LÖVE 11.x, so
`build_web.sh` zips the engine into a `.love` and runs love.js on it. The
result is a static site: `index.html`, `love.wasm`, `love.js`,
`love.worker.js`, and `game.data` (the packaged engine).

### 2. Threads need cross-origin isolation (coi-serviceworker)

Kristal loads its assets on a background **thread** (`love.thread`). In love.js
that becomes a pthread / Web Worker, which requires `SharedArrayBuffer`, which
in turn requires the page to be *cross-origin isolated* via the
`Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy` HTTP headers.

**GitHub Pages cannot set custom response headers.** The standard workaround —
[`coi-serviceworker`](https://github.com/gzuidhof/coi-serviceworker) — is a
service worker that reloads the page with those headers applied client-side. It
is loaded as the very first script in `index.html`.

### 3. Bridging LuaJIT → Lua 5.1 (the web-compat layer)

Desktop LÖVE runs on **LuaJIT**; love.js runs on **vanilla Lua 5.1**. Kristal
uses a handful of LuaJIT/Lua-5.2 features that vanilla 5.1 doesn't have. The
compat layer supplies web-safe equivalents. **None of these change desktop
behaviour** — the patches are applied only to the copy that gets compiled for
the web, and `webcompat.lua` detects LuaJIT and disables itself there.

| Gap on the web | Where Kristal uses it | Fix |
|---|---|---|
| `ffi` module missing | `discordrpc.lua`, `https.lua` (native Discord/HTTPS libs, impossible in a browser anyway) | `webcompat.lua` preloads a stub `ffi` whose `load()` returns nil, so both modules cleanly report the feature unavailable |
| `bit` library missing | `tiledutils.lua` (`bit.band` for Tiled tile-flip flags) | `webcompat.lua` provides a pure-Lua `bit` implementation |
| `package.searchpath` missing (Lua 5.2+) | `hotswapper.lua` | `webcompat.lua` provides the standard implementation |
| `goto` / `::labels::` (Lua 5.2+) rejected by the 5.1 parser | 6 `goto continue` loops | rewritten to the equivalent `repeat … until true` idiom |
| `love.filesystem.getRealDirectory()` **hangs forever** on a missing path (a love.js bug) | `discordrpc.lua`, `https.lua` look up `lib/` which never exists on the web | `webcompat.lua` guards it: missing paths (checked with the safe `getInfo`) return nil instead of hanging |
| `Channel:demand()` **never wakes** across love.js pthreads (`pop()` works) | the asset **load thread** blocks on `demand()`, so loading never starts | the worker loops are rewritten to poll with `pop()` + a short `sleep()` |

The last two were the difference between a permanently-frozen loading screen and
a working game.

## Reproducing the build

Requirements: `node`/`npx`, `python3`, `zip`, `bash`.

```bash
git clone https://github.com/KristalTeam/Kristal.git
./build/build_web.sh Kristal public
```

This copies Kristal (leaving your clone untouched), applies the web-compat
patches, compiles with love.js, adds `coi-serviceworker.js`, and writes the
finished site to `public/`. Serve it with **any** static server that either
sets the COOP/COEP headers *or* is on `localhost` (where the service worker can
register):

```bash
cd public && python3 -m http.server 8000   # then open http://localhost:8000
```

## Limitations

- **Slow first load.** The engine decodes all of its assets in interpreted Lua
  (love.js has no JIT), which takes roughly 40–60 s on first load. Subsequent
  loads are faster thanks to browser caching.
- **No local mods.** The browser build ships only the engine (and its bundled
  example), and there is no folder to drop mods into. "Open folder" does
  nothing on the web.
- **No Discord Rich Presence / online update checks.** These rely on native
  libraries that don't exist in a browser; they're cleanly disabled.
- Audio starts only after your first click/keypress (browser autoplay policy).

## Credits

- **Kristal** — © [Kristal Team](https://github.com/KristalTeam/Kristal), under its own license.
- **love.js** — [Davidobot/love.js](https://github.com/Davidobot/love.js).
- **coi-serviceworker** — [gzuidhof/coi-serviceworker](https://github.com/gzuidhof/coi-serviceworker) (MIT).

This repo only adds the web packaging and hosting; all engine credit belongs to
the Kristal Team.
