// index.html's haven.wasm preload, built by vite.config.js (preloadHaven). The wasm is ~6.6 MB gzipped and the app's
// own script only asks for it once it has loaded and run: 285 ms into a cold start, against 45 ms when index.html
// preloaded it with a plain link (NV_HEALTH_F_WEB). Only someone signed in needs it: a guest (src/guest, a shared
// post) must not download 6.6 MB for nothing, and the app's CSP (website/nginx.conf, script-src 'self') runs no inline
// script. So the check is this short script of its own, run before the app's script: the wasm starts once it has
// arrived, one round trip later than a link written into index.html itself would have started it.
import { createHash } from "node:crypto"
import { SESSION_KEY } from "./src/session.js"

const PUBKEY = /^[0-9a-f]{64}$/

/**
 * The check as a script: starts `wasm` (this build's hashed URL) downloading if a session this browser can use is
 * saved, decided exactly as session.js loadSession does. Test: test/nv-preload.test.mjs runs it against loadSession.
 */
export function bootScript(wasm) {
  return `;(function () {
  try {
    var s = JSON.parse(localStorage.getItem(${JSON.stringify(SESSION_KEY)}) || "null")
    if (!s || !(/${PUBKEY.source}/).test(s.pubkey)) return
    // The same URL and mode (cors, same-origin credentials) as loadHaven's fetch, so that fetch gets this response.
    var l = document.createElement("link")
    l.rel = "preload"; l.as = "fetch"; l.type = "application/wasm"
    l.crossOrigin = "anonymous"; l.href = ${JSON.stringify(wasm)}
    document.head.appendChild(l)
  } catch (e) {}
})()
`
}

/**
 * The build links index.html to the preload script (apply: build; the box build has no haven.wasm of its own).
 * The script's name is the hash of its own source, so a changed check is a new file name rather than a stale one in a
 * cache. Test: test/nv-preload.test.mjs.
 */
export function preloadHaven() {
  let base
  return {
    name: "preload-haven",
    apply: "build",
    configResolved: c => { base = c.base },
    transformIndexHtml: {
      order: "post",
      handler(html, { bundle }) {
        const file = Object.keys(bundle ?? {}).find(f => /(^|\/)haven-[\w-]+\.wasm$/.test(f))
        if (!file) throw new Error("preload-haven: no haven-*.wasm in the build")
        const source = bootScript(base + file)
        const name = `assets/nv-preload-${createHash("sha256").update(source).digest("base64url").slice(0, 8)}.js`
        this.emitFile({ type: "asset", fileName: name, source })
        // First in head, so it is fetched and run before the app's own script (both are deferred, in that order).
        return [{ tag: "script", attrs: { defer: true, src: base + name }, injectTo: "head-prepend" }]
      },
    },
  }
}
