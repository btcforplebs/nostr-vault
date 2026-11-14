// Pure helpers for the napplet host (host.js), kept apart so node tests can load them without vite's ?raw import.
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("")

// NIP-5D identity is (dTag, artifactHash): the SHA-256 of the napplet's own index.html bytes, before the shell adds
// anything to them.
export const artifactHash = async (html) => hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(html)))

// The bootstrap (CSP meta + prelude script) goes first in <head>, so it runs before any napplet script.
export const buildSrcdoc = (html, bootstrap, csp) => {
  const head = `<meta http-equiv="Content-Security-Policy" content="${csp}"><script>${bootstrap}</script>`
  const at = html.search(/<head[^>]*>/i)
  if (at < 0) return `<!doctype html><html><head>${head}</head><body>${html}</body></html>`
  const end = html.indexOf(">", at) + 1
  return html.slice(0, end) + head + html.slice(end)
}
