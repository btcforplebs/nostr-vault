// The WoT napplet carries the app's own globe maths (plan P6): net/wot-pure.js and net/wot-globe.js, put into its
// index.html where it says /*@wot-maths*/, with their import lines and `export` words taken out. One copy of the maths,
// so the napplet places and draws people exactly as the app does. Pure: first-party.js passes the files' text (vite
// ?raw), node tests read them from disk.
export const MARKER = "/*@wot-maths*/"

/** An ES module's source as plain script: no imports, no `export` keywords. Throws on what it can't turn. */
export function asScript(src) {
  if (/^export\s*(\{|default|\*)/m.test(src)) throw new Error("wot-inject: re-exports and default exports can't be inlined")
  return src.replace(/^import\s[^\n]*\n/gm, "").replace(/^export (?=(const|let|function|async function|class) )/gm, "")
}

/** The napplet's html with the maths in place of the marker (exactly one marker). */
export function injectWot(html, sources) {
  if (html.split(MARKER).length !== 2) throw new Error("wot-inject: the napplet needs exactly one maths marker")
  const code = sources.map(asScript).join("\n")
  return html.replace(MARKER, () => code)
}
