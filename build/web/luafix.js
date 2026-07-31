// Rewrite Lua 5.2 `goto` loops into Lua 5.1.
//
// love.js runs vanilla Lua 5.1, which has no `goto` / `::labels::`. Desktop
// LOVE runs LuaJIT, which accepts them, so plenty of mods use the standard
// "continue" idiom:
//
//     for i, v in ipairs(t) do
//         if skip(v) then goto continue end
//         ...
//         ::continue::
//     end
//
// and fail to even parse in the browser. The equivalent 5.1 idiom is
// `repeat ... until true` with `break` in place of the jump, which is what this
// module rewrites uploaded mods to before they hit the engine:
//
//     for i, v in ipairs(t) do repeat
//         if skip(v) then break end
//         ...
//     until true end
//
// The rewrite is only applied where it is provably equivalent. Anything this
// can't prove (backwards jumps, a real `break` that would get captured by the
// inserted `repeat`, labels nested inside an `if`) is left alone and reported,
// so a mod never silently changes behaviour.

window.KLUAFIX = (function () {
  // ------------------------------------------------------------- scanning --
  // Just enough of a Lua lexer to find keywords, labels and gotos that are not
  // inside a string or a comment.

  function longBracketEnd(src, i) {
    // src[i] must be "["; returns the index past a [[ ]] / [==[ ]==] block, or
    // -1 if this isn't a long bracket at all.
    var j = i + 1, level = 0;
    while (src[j] === "=") { level++; j++; }
    if (src[j] !== "[") return -1;
    var close = "]" + new Array(level + 1).join("=") + "]";
    var k = src.indexOf(close, j + 1);
    return k < 0 ? src.length : k + close.length;
  }

  function quotedEnd(src, i) {
    var q = src[i];
    for (i++; i < src.length; i++) {
      var c = src[i];
      if (c === "\\") { i++; continue; }
      if (c === q || c === "\n") return i + 1;
    }
    return i;
  }

  var LABEL_RE = /^::[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*::/;

  function scan(src) {
    var toks = [], i = 0, n = src.length;
    while (i < n) {
      var c = src[i];
      if (c === "-" && src[i + 1] === "-") {
        i += 2;
        var lc = src[i] === "[" ? longBracketEnd(src, i) : -1;
        if (lc >= 0) { i = lc; continue; }
        while (i < n && src[i] !== "\n") i++;
        continue;
      }
      if (c === "[") {
        var lb = longBracketEnd(src, i);
        if (lb >= 0) { i = lb; continue; }
      }
      if (c === '"' || c === "'") { i = quotedEnd(src, i); continue; }
      if (c === ":" && src[i + 1] === ":") {
        var m = LABEL_RE.exec(src.slice(i, i + 80));
        if (m) {
          toks.push({ kind: "label", value: m[1], start: i, end: i + m[0].length });
          i += m[0].length;
          continue;
        }
        i += 2;
        continue;
      }
      if (/[A-Za-z_]/.test(c)) {
        var j = i;
        while (j < n && /[A-Za-z0-9_]/.test(src[j])) j++;
        toks.push({ kind: "name", value: src.slice(i, j), start: i, end: j });
        i = j;
        continue;
      }
      i++;
    }
    return toks;
  }

  // ------------------------------------------------------------- structure --
  // Walk the token stream keeping a stack of open blocks, so every label, goto
  // and break knows which blocks it sits inside.

  function analyse(src) {
    var toks = scan(src);
    var stack = [], labels = [], gotos = [], breaks = [];

    for (var t = 0; t < toks.length; t++) {
      var tk = toks[t];
      if (tk.kind === "label") {
        labels.push({ tok: tk, name: tk.value, stack: stack.slice() });
        continue;
      }
      switch (tk.value) {
        case "function":
          stack.push({ type: "function", start: tk.start });
          break;
        case "if":
          stack.push({ type: "if", start: tk.start });
          break;
        case "for":
        case "while":
          stack.push({ type: "loop", start: tk.start, bodyStart: -1 });
          break;
        case "do":
          var top = stack[stack.length - 1];
          if (top && top.type === "loop" && top.bodyStart < 0) top.bodyStart = tk.end;
          else stack.push({ type: "do", start: tk.start, bodyStart: tk.end });
          break;
        case "repeat":
          stack.push({ type: "repeat", start: tk.start, bodyStart: tk.end });
          break;
        case "until":
        case "end":
          var done = stack.pop();
          if (done) done.end = tk.start;
          break;
        case "goto":
          var nx = toks[t + 1];
          if (nx && nx.kind === "name") {
            gotos.push({ name: nx.value, start: tk.start, end: nx.end, stack: stack.slice() });
            t++;
          }
          break;
        case "break":
          breaks.push({ start: tk.start, stack: stack.slice() });
          break;
      }
    }
    return { labels: labels, gotos: gotos, breaks: breaks, open: stack.length };
  }

  function innermostLoop(frames) {
    for (var i = frames.length - 1; i >= 0; i--) {
      if (frames[i].type === "loop" || frames[i].type === "repeat") return frames[i];
    }
    return null;
  }

  // ------------------------------------------------------------- rewriting --
  function fix(src) {
    var skipped = [];
    if (src.indexOf("::") === -1) return { text: src, changed: false, skipped: skipped };

    var info;
    try { info = analyse(src); } catch (e) { return { text: src, changed: false, skipped: ["parse failed"] }; }
    if (!info.labels.length) return { text: src, changed: false, skipped: skipped };
    if (info.open !== 0) {
      // Unbalanced blocks mean the scan lost track somewhere; don't touch it.
      return { text: src, changed: false, skipped: ["could not follow the block structure"] };
    }

    var edits = [], wrapped = [];

    info.labels.forEach(function (label) {
      var block = label.stack[label.stack.length - 1];
      var why = null;

      if (!block) why = "label is not inside a loop";
      else if (block.type !== "loop" && block.type !== "do" && block.type !== "repeat") {
        why = "label sits directly inside an " + block.type + " block";
      } else if (block.bodyStart < 0 || block.end === undefined) {
        why = "could not find the enclosing block's body";
      } else if (wrapped.indexOf(block) !== -1) {
        why = "the same block already has another label";
      }

      // Jumps to this label are the ones between the block's start and the
      // label itself; same-named labels elsewhere in the file own the rest.
      // Each has to reach the label with a plain `break`, so no nested loop may
      // sit in between (that `break` would target the wrong loop).
      var mine = [];
      if (!why) {
        var outer = block.type === "do" ? innermostLoop(label.stack) : block;
        var all = info.gotos.filter(function (g) {
          return g.name === label.name && g.start > block.bodyStart && g.start < label.tok.start;
        });
        for (var i = 0; i < all.length; i++) {
          if (innermostLoop(all[i].stack) !== outer) {
            why = "a jump to ::" + label.name + ":: crosses a nested loop";
            break;
          }
          mine.push(all[i]);
        }
      }

      // A real `break` between the block's start and the label would be
      // swallowed by the `repeat` we're about to insert.
      if (!why) {
        for (var b = 0; b < info.breaks.length; b++) {
          var br = info.breaks[b];
          if (br.start < block.bodyStart || br.start > label.tok.start) continue;
          var target = innermostLoop(br.stack);
          if (!target || target.start <= block.start) {
            why = "a `break` inside the loop would change meaning";
            break;
          }
        }
      }

      if (why) { skipped.push("::" + label.name + ":: - " + why); return; }

      wrapped.push(block);
      edits.push({ at: block.bodyStart, len: 0, text: " repeat" });
      mine.forEach(function (g) { edits.push({ at: g.start, len: g.end - g.start, text: "break" }); });
      edits.push({ at: label.tok.start, len: label.tok.end - label.tok.start, text: "until true" });
    });

    var taken = {};
    edits.forEach(function (e) { if (e.text === "break") taken[e.at] = 1; });
    info.gotos.forEach(function (g) {
      if (!taken[g.start]) skipped.push("goto " + g.name + " - no label this rewrite could reach");
    });

    if (!edits.length) return { text: src, changed: false, skipped: skipped };

    edits.sort(function (a, b) { return b.at - a.at; });
    var out = src;
    edits.forEach(function (e) { out = out.slice(0, e.at) + e.text + out.slice(e.at + e.len); });
    return { text: out, changed: true, skipped: skipped, count: wrapped.length };
  }

  // Cheap pre-check: is it even worth decoding/rewriting this file?
  function mayNeedFix(text) {
    return /::[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*::/.test(text);
  }

  return { fix: fix, mayNeedFix: mayNeedFix };
})();
