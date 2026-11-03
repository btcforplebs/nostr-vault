// Safari's half of "Share → Nostr Vault" (NSExtensionJavaScriptPreprocessingFile).
// Runs in the page when the person opens the share sheet and hands the
// extension what only the page knows: the selected text, the canonical URL,
// a few og: tags and the JSON-LD types (Recipe, Event). Nothing else: no full
// HTML, no cookies, no form values. Everything is capped here and capped again
// in Swift, because the page wrote all of it and may lie.
var SharePreprocess = function () {};

SharePreprocess.prototype = {
  run: function (args) {
    var cap = function (s, n) {
      if (typeof s !== "string") { return ""; }
      return s.length > n ? s.slice(0, n) : s;
    };
    var http = function (s) { return /^https?:\/\//i.test(s || "") ? s : ""; };
    var out = { url: "", canonical: "", title: "", selection: "", og: {}, ld_types: [], ld_json: "" };
    try { out.url = cap(http(String(document.location.href)), 4096); } catch (e) {}
    try { out.title = cap(document.title, 1000); } catch (e) {}
    try {
      var sel = window.getSelection ? String(window.getSelection()) : "";
      out.selection = cap(sel, 10000);
    } catch (e) {}
    try {
      var link = document.querySelector('link[rel="canonical"]');
      if (link) { out.canonical = cap(http(link.href), 4096); }
    } catch (e) {}
    try {
      var keys = ["og:title", "og:description", "og:image", "og:site_name", "og:type", "og:url"];
      for (var i = 0; i < keys.length; i++) {
        var m = document.querySelector('meta[property="' + keys[i] + '"]');
        if (m && m.content) { out.og[keys[i].slice(3)] = cap(m.content, 1000); }
      }
    } catch (e) {}
    try {
      var types = [];
      var addType = function (t) {
        if (typeof t === "string" && t.length <= 100 && types.indexOf(t) < 0 && types.length < 20) { types.push(t); }
      };
      var walk = function (node, depth) {
        if (!node || typeof node !== "object" || depth > 3) { return; }
        if (Array.isArray(node)) { for (var j = 0; j < node.length && j < 50; j++) { walk(node[j], depth + 1); } return; }
        var t = node["@type"];
        if (Array.isArray(t)) { for (var k = 0; k < t.length; k++) { addType(t[k]); } } else { addType(t); }
        if (node["@graph"]) { walk(node["@graph"], depth + 1); }
      };
      var blocks = document.querySelectorAll('script[type="application/ld+json"]');
      var kept = [];
      var total = 0;
      for (var b = 0; b < blocks.length && b < 20; b++) {
        var text = blocks[b].textContent || "";
        if (total + text.length > 200000) { break; }
        total += text.length;
        kept.push(text);
        try { walk(JSON.parse(text), 0); } catch (e) {}
      }
      out.ld_types = types;
      out.ld_json = kept.length ? "[" + kept.join(",") + "]" : "";
    } catch (e) {}
    args.completionFunction(out);
  },

  finalize: function (args) {}
};

var ExtensionPreprocessingJS = new SharePreprocess();
