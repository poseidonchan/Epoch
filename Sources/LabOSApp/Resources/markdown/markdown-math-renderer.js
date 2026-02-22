(function () {
  function safeGetText(id) {
    var el = document.getElementById(id);
    if (!el) return "";
    return el.textContent || el.innerText || "";
  }

  function computeContentHeight() {
    var el = document.getElementById("content");
    if (!el) {
      return Math.max(
        document.body ? document.body.scrollHeight : 0,
        document.documentElement ? document.documentElement.scrollHeight : 0
      );
    }
    var rect = el.getBoundingClientRect();
    var height = Math.max(el.scrollHeight || 0, rect ? rect.height : 0);
    return Math.ceil(height + 4);
  }

  var heightPostScheduled = false;
  function postHeight() {
    if (heightPostScheduled) return;
    heightPostScheduled = true;
    requestAnimationFrame(function () {
      heightPostScheduled = false;
      try {
        if (
          window.webkit &&
          window.webkit.messageHandlers &&
          window.webkit.messageHandlers.height
        ) {
          window.webkit.messageHandlers.height.postMessage(computeContentHeight());
        }
      } catch (e) {}
    });
  }

  function isInCodeContext(node) {
    var cur = node;
    while (cur) {
      if (cur.nodeType === 1) {
        var tag = (cur.tagName || "").toLowerCase();
        if (tag === "code" || tag === "pre") return true;
      }
      cur = cur.parentNode;
    }
    return false;
  }

  function extractMath(source) {
    var segments = [];
    var out = "";

    var inFence = null;
    var inInlineCode = false;
    var prevWasBackslash = false;

    function toggleFence(marker) {
      if (inFence === marker) inFence = null;
      else if (!inFence) inFence = marker;
    }

    var i = 0;
    while (i < source.length) {
      // Fence handling at start of line.
      if (i === 0 || source[i - 1] === "\n") {
        var lineEnd = source.indexOf("\n", i);
        if (lineEnd === -1) lineEnd = source.length;
        var line = source.slice(i, lineEnd);
        var trimmed = line.replace(/^[ \t]+/, "");
        if (trimmed.startsWith("```")) {
          out += line;
          if (lineEnd < source.length) out += "\n";
          toggleFence("```");
          i = lineEnd + 1;
          prevWasBackslash = false;
          inInlineCode = false;
          continue;
        }
        if (trimmed.startsWith("~~~")) {
          out += line;
          if (lineEnd < source.length) out += "\n";
          toggleFence("~~~");
          i = lineEnd + 1;
          prevWasBackslash = false;
          inInlineCode = false;
          continue;
        }
      }

      if (inFence) {
        var chFence = source[i];
        out += chFence;
        prevWasBackslash = chFence === "\\";
        inInlineCode = false;
        i += 1;
        continue;
      }

      var ch = source[i];
      if (ch === "`" && !prevWasBackslash) {
        inInlineCode = !inInlineCode;
        out += ch;
        prevWasBackslash = false;
        i += 1;
        continue;
      }
      if (inInlineCode) {
        out += ch;
        prevWasBackslash = ch === "\\";
        i += 1;
        continue;
      }

      // Display: $$...$$
      if (source.startsWith("$$", i)) {
        var close = source.indexOf("$$", i + 2);
        if (close !== -1) {
          var tex = source.slice(i + 2, close);
          var token = "@@MATH" + segments.length + "@@";
          segments.push({ token: token, tex: tex, display: true, raw: source.slice(i, close + 2) });
          out += token;
          i = close + 2;
          prevWasBackslash = false;
          continue;
        }
      }

      // Display: \\[ ... \\]
      if (source.startsWith("\\\\[", i)) {
        var close2 = source.indexOf("\\\\]", i + 3);
        if (close2 !== -1) {
          var tex2 = source.slice(i + 3, close2);
          var token2 = "@@MATH" + segments.length + "@@";
          segments.push({ token: token2, tex: tex2, display: true, raw: source.slice(i, close2 + 3) });
          out += token2;
          i = close2 + 3;
          prevWasBackslash = false;
          continue;
        }
      }

      // Inline: \\( ... \\)
      if (source.startsWith("\\\\(", i)) {
        var close3 = source.indexOf("\\\\)", i + 3);
        if (close3 !== -1) {
          var tex3 = source.slice(i + 3, close3);
          var token3 = "@@MATH" + segments.length + "@@";
          segments.push({ token: token3, tex: tex3, display: false, raw: source.slice(i, close3 + 3) });
          out += token3;
          i = close3 + 3;
          prevWasBackslash = false;
          continue;
        }
      }

      // Inline: $...$ (simple heuristics)
      if (ch === "$" && !prevWasBackslash) {
        if (i + 1 < source.length && source[i + 1] !== "$") {
          var nextCh = source[i + 1];
          if (nextCh !== " " && nextCh !== "\t" && nextCh !== "\n") {
            var j = i + 1;
            var found = -1;
            while (j < source.length) {
              var cj = source[j];
              if (cj === "\n") break;
              if (cj === "$" && source[j - 1] !== "\\") {
                if (source[j - 1] !== " " && source[j - 1] !== "\t") {
                  found = j;
                }
                break;
              }
              j += 1;
            }
            if (found !== -1) {
              var tex4 = source.slice(i + 1, found);
              var token4 = "@@MATH" + segments.length + "@@";
              segments.push({ token: token4, tex: tex4, display: false, raw: source.slice(i, found + 1) });
              out += token4;
              i = found + 1;
              prevWasBackslash = false;
              continue;
            }
          }
        }
      }

      out += ch;
      prevWasBackslash = ch === "\\";
      i += 1;
    }

    return { text: out, segments: segments };
  }

  function renderExtractedMath(root, segments) {
    if (!segments || !segments.length) return;

    // Always remove tokens (even if KaTeX isn't available) so users don't see @@MATH@@.
    var canRender = !!window.katex;
    var re = /@@MATH(\d+)@@/g;

    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    var nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);

    for (var n = 0; n < nodes.length; n++) {
      var node = nodes[n];
      if (!node || !node.nodeValue) continue;
      var text = node.nodeValue;
      if (text.indexOf("@@MATH") === -1) continue;

      var inCode = isInCodeContext(node);

      var frag = document.createDocumentFragment();
      var lastIndex = 0;
      var match;
      re.lastIndex = 0;
      while ((match = re.exec(text)) !== null) {
        var before = text.slice(lastIndex, match.index);
        if (before) frag.appendChild(document.createTextNode(before));

        var idx = parseInt(match[1], 10);
        var seg = segments[idx];
        if (!seg) {
          frag.appendChild(document.createTextNode(match[0]));
        } else if (inCode || !canRender) {
          frag.appendChild(document.createTextNode(seg.raw));
        } else {
          var span = document.createElement("span");
          span.className = seg.display ? "math-display" : "math-inline";
          try {
            window.katex.render(seg.tex, span, {
              displayMode: !!seg.display,
              throwOnError: false,
              strict: "warn",
              macros: {
                // Common "missing package" macros from LLM outputs.
                "\\mathbbf": "\\mathbf",
                "\\mathbbm": "\\mathbb",
                "\\bm": "\\boldsymbol",
              },
            });
          } catch (e) {
            span.textContent = seg.raw;
          }
          frag.appendChild(span);
        }

        lastIndex = match.index + match[0].length;
      }

      var after = text.slice(lastIndex);
      if (after) frag.appendChild(document.createTextNode(after));

      if (node.parentNode) {
        node.parentNode.replaceChild(frag, node);
      }
    }
  }

  function normalizeDisplayMathContainers(root) {
    if (!root) return;
    var displays = root.querySelectorAll(".katex-display");
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i];
      if (!display || !display.parentNode) continue;
      if (display.parentNode.classList && display.parentNode.classList.contains("math-display")) continue;
      var wrapper = document.createElement("span");
      wrapper.className = "math-display";
      display.parentNode.insertBefore(wrapper, display);
      wrapper.appendChild(display);
    }
  }

  function render() {
    var source = safeGetText("md-source");
    var content = document.getElementById("content");
    if (!content) return;

    if (!window.markdownit) {
      content.textContent = source;
      postHeight();
      return;
    }

    var extracted = extractMath(source);

    var md = window.markdownit({
      html: false,
      linkify: true,
      typographer: false,
    });

    // Enable common GFM-ish extensions.
    try {
      md.enable(["table", "strikethrough"]);
    } catch (e) {}

    var rendered = "";
    try {
      rendered = md.render(extracted.text);
    } catch (e) {
      rendered = "<pre class=\"md-error\"></pre>";
      content.textContent = source;
      postHeight();
      return;
    }

    var container = document.createElement("div");
    container.innerHTML = rendered;

    // Block external resources.
    var links = container.querySelectorAll("a[href]");
    for (var i = 0; i < links.length; i++) {
      var href = (links[i].getAttribute("href") || "").trim();
      if (href.startsWith("http:") || href.startsWith("https:")) {
        links[i].setAttribute("href", "#");
      }
    }
    var images = container.querySelectorAll("img[src]");
    for (var j = 0; j < images.length; j++) {
      var src = (images[j].getAttribute("src") || "").trim();
      if (src.startsWith("http:") || src.startsWith("https:")) {
        images[j].removeAttribute("src");
      }
    }

    content.innerHTML = container.innerHTML;

    // Highlight code blocks (optional).
    if (window.hljs) {
      var blocks = content.querySelectorAll("pre code");
      for (var i = 0; i < blocks.length; i++) {
        try {
          window.hljs.highlightElement(blocks[i]);
        } catch (e) {}
      }
    }

    // Render extracted LaTeX math segments (prevents Markdown parsing from breaking underscores, etc).
    renderExtractedMath(content, extracted.segments);
    normalizeDisplayMathContainers(content);

    // As a fallback, render any remaining delimiter-based math.
    if (window.renderMathInElement) {
      try {
        window.renderMathInElement(content, {
          delimiters: [
            { left: "$$", right: "$$", display: true },
            { left: "$", right: "$", display: false },
            { left: "\\[", right: "\\]", display: true },
            { left: "\\(", right: "\\)", display: false },
          ],
          macros: {
            "\\mathbbf": "\\mathbf",
            "\\mathbbm": "\\mathbb",
            "\\bm": "\\boldsymbol",
          },
          throwOnError: false,
          strict: "warn",
        });
      } catch (e) {}
    }

    normalizeDisplayMathContainers(content);

    postHeight();
    setTimeout(postHeight, 50);
    setTimeout(postHeight, 200);
    try {
      var observer = new MutationObserver(function () {
        postHeight();
      });
      observer.observe(content, { childList: true, subtree: true, characterData: true });
    } catch (e) {}
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", render);
  } else {
    render();
  }
})();
