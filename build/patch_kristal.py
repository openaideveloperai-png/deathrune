#!/usr/bin/env python3
"""Apply the minimal web-compatibility patches to a Kristal source tree.

Two changes, both required for love.js (vanilla Lua 5.1) and both no-ops or
behaviour-preserving on desktop LÖVE (LuaJIT):

  1. Require web/webcompat.lua as the first statement of main.lua. That module
     self-detects LuaJIT and does nothing on desktop.

  2. Rewrite `goto continue` / `::continue::` (Lua 5.2 syntax LuaJIT accepts but
     vanilla Lua 5.1 rejects) into the `repeat ... until true` idiom, which both
     runtimes parse and which has identical semantics.

The script is idempotent: running it twice is a no-op.
"""
import os
import re
import sys
import shutil

def patch_main(kristal_dir):
    main = os.path.join(kristal_dir, "main.lua")
    text = open(main, encoding="utf-8").read()
    if 'require("webcompat")' in text:
        return "main.lua already patched"
    text = 'require("webcompat") -- web (love.js) compatibility layer; no-op on desktop\n' + text
    open(main, "w", encoding="utf-8").write(text)
    return "main.lua: prepended webcompat require"

def install_webcompat(kristal_dir, webcompat_src):
    dst = os.path.join(kristal_dir, "webcompat.lua")
    shutil.copyfile(webcompat_src, dst)
    return "installed webcompat.lua at engine root"

DO_RE = re.compile(r"\bdo$")
LOOP_RE = re.compile(r"^(for|while)\b")

def indent_of(line):
    return len(line) - len(line.lstrip())

def patch_gotos(path):
    src = open(path, encoding="utf-8").read()
    if "goto continue" not in src and "::continue::" not in src:
        return None
    lines = src.split("\n")

    # For each `::continue::` label, find the innermost enclosing loop header
    # (nearest preceding `for`/`while ... do` at a shallower indent).
    header_idxs = set()
    for i, l in enumerate(lines):
        if l.strip() != "::continue::":
            continue
        lab_indent = indent_of(l)
        for j in range(i - 1, -1, -1):
            s = lines[j].rstrip()
            st = s.strip()
            if indent_of(lines[j]) < lab_indent and LOOP_RE.match(st) and DO_RE.search(st):
                header_idxs.add(j)
                break
        else:
            raise RuntimeError(f"{path}: no enclosing loop found for ::continue:: at line {i+1}")

    for j in header_idxs:
        lines[j] = lines[j].rstrip() + " repeat"

    changed_goto = 0
    for i, l in enumerate(lines):
        st = l.strip()
        if st == "goto continue" or st.endswith("then goto continue end"):
            lines[i] = l.replace("goto continue", "break")
            changed_goto += 1
        if st == "::continue::":
            lines[i] = l.replace("::continue::", "until true")

    out = "\n".join(lines)
    assert "goto continue" not in out, path + " still has goto continue"
    assert "::continue::" not in out, path + " still has ::continue::"
    open(path, "w", encoding="utf-8").write(out)
    return f"{os.path.relpath(path, os.path.dirname(os.path.dirname(path)))}: {changed_goto} goto/label pair(s) rewritten"

def patch_threads(kristal_dir):
    # love.js pthreads: Channel:demand() blocks forever even after a message is
    # pushed from another thread (Channel:pop() works fine). Kristal's worker
    # threads block on demand(), so the loader never receives its request and
    # startup hangs on the loading screen. Rewrite the demand() loops to poll
    # with pop() + a short sleep. This only touches the web build copy.
    results = []
    targets = {
        os.path.join(kristal_dir, "src/engine/loadthread.lua"): (
            '    local msg = in_channel:demand()\n    if msg == "verbose" then',
            '    local msg = in_channel:pop()\n'
            '    if msg == nil then\n'
            '        love.timer.sleep(0.005)\n'
            '    elseif msg == "verbose" then',
        ),
        os.path.join(kristal_dir, "src/engine/httpsthread.lua"): (
            '    local msg = in_channel:demand()\n    if msg == "stop" then',
            '    local msg = in_channel:pop()\n'
            '    if msg == nil then\n'
            '        love.timer.sleep(0.005)\n'
            '    elseif msg == "stop" then',
        ),
    }
    for path, (old, new) in targets.items():
        text = open(path, encoding="utf-8").read()
        if "in_channel:demand()" not in text:
            results.append(f"{os.path.basename(path)} already patched")
            continue
        if "require(\"love.timer\")" not in text:
            text = text.replace(
                'in_channel = love.thread.getChannel',
                'require("love.timer") -- needed for the polling loop below\n'
                'in_channel = love.thread.getChannel', 1)
        assert old in text, path + ": demand() loop not found"
        text = text.replace(old, new, 1)
        open(path, "w", encoding="utf-8").write(text)
        results.append(f"{os.path.basename(path)}: demand() -> polling pop()")
    return results

def main():
    kristal_dir = sys.argv[1]
    webcompat_src = sys.argv[2]
    print(install_webcompat(kristal_dir, webcompat_src))
    print(patch_main(kristal_dir))
    for r in patch_threads(kristal_dir):
        print("  " + r)
    for root, _, files in os.walk(os.path.join(kristal_dir, "src")):
        for f in files:
            if f.endswith(".lua"):
                r = patch_gotos(os.path.join(root, f))
                if r:
                    print("  " + r)

if __name__ == "__main__":
    main()
