// Live video outside Safari: hls.js through Media Source, without a worker (CSP worker-src 'self'), loaded only when
// a stream opens; Safari keeps its own player; the link out when neither can play or hls.js gives up.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { playMode, attachHls, HLS_CONFIG } from "../src/readers/hls.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})

const video = type => ({ canPlayType: t => (t === "application/vnd.apple.mpegurl" ? type : "") })
const mse = ok => ({ isTypeSupported: () => ok })

test("Safari plays it itself; Chrome/Firefox use hls.js; neither means the link out", () => {
  assert.equal(playMode(video("maybe"), { mse: mse(true) }), "native", "native wins even where MSE exists")
  assert.equal(playMode(video(""), { mse: mse(true) }), "hlsjs")
  assert.equal(playMode(video(""), { mse: mse(false) }), "none")
  assert.equal(playMode(video(""), { mse: undefined }), "none")
  assert.equal(playMode(undefined, { mse: undefined }), "none")
})

test("hls.js never starts a worker (the vault's CSP blocks blob workers)", () => {
  assert.equal(HLS_CONFIG.enableWorker, false)
  const csp = readFileSync(new URL("../../website/nginx.conf", import.meta.url), "utf8")
  assert.match(csp, /~\^\/\(relay\|vault\)\/[^\n]*worker-src 'self'[;\"]/, "if the CSP ever allows blob: workers this can be revisited")
})

test("the full hls.js build: zap.stream sends audio as its own rendition, which the light build drops", () => {
  assert.match(readFileSync(new URL("../src/readers/hls.js", import.meta.url), "utf8"), /import\("hls\.js"\)/)
})

/** A fake hls.js: records calls, lets a test fire errors. */
function fakeHls({ supported = true } = {}) {
  const log = []
  let onError
  class Hls {
    static isSupported() { return supported }
    static Events = { ERROR: "hlsError" }
    static ErrorTypes = { MEDIA_ERROR: "mediaError", NETWORK_ERROR: "networkError" }
    constructor(cfg) { log.push(["new", cfg]); Hls.last = this }
    on(ev, fn) { if (ev === "hlsError") onError = fn }
    loadSource(u) { log.push(["load", u]) }
    attachMedia(v) { log.push(["attach", v]) }
    recoverMediaError() { log.push(["recover"]) }
    destroy() { log.push(["destroy"]) }
  }
  return { log, load: async () => ({ default: Hls }), fire: data => onError("hlsError", data) }
}
const tick = () => new Promise(r => setTimeout(r, 0))

test("attaches the stream with the no-worker config and stops cleanly", async () => {
  const f = fakeHls(), v = {}
  const stop = attachHls(v, "https://x/live.m3u8", () => assert.fail("no failure"), f.load)
  await tick()
  assert.deepEqual(f.log, [["new", HLS_CONFIG], ["load", "https://x/live.m3u8"], ["attach", v]])
  stop()
  assert.deepEqual(f.log.at(-1), ["destroy"])
})

test("a non-fatal error is ignored; one media error is recovered; a second, or a network error, falls back", async () => {
  let fails = 0
  const f = fakeHls()
  attachHls({}, "u", () => fails++, f.load)
  await tick()
  f.fire({ fatal: false, type: "networkError" })
  f.fire({ fatal: true, type: "mediaError" })
  assert.equal(fails, 0)
  assert.deepEqual(f.log.at(-1), ["recover"])
  f.fire({ fatal: true, type: "mediaError" })
  assert.equal(fails, 1)
  assert.deepEqual(f.log.at(-1), ["destroy"])

  const g = fakeHls()
  let gf = 0
  attachHls({}, "u", () => gf++, g.load)
  await tick()
  g.fire({ fatal: true, type: "networkError" })
  assert.equal(gf, 1)
})

test("falls back when hls.js is unsupported or fails to load; stopping first means nothing starts", async () => {
  let n = 0
  attachHls({}, "u", () => n++, fakeHls({ supported: false }).load)
  attachHls({}, "u", () => n++, () => Promise.reject(new Error("offline")))
  await tick()
  assert.equal(n, 2)
  const f = fakeHls()
  attachHls({}, "u", () => n++, f.load)()
  await tick()
  assert.deepEqual(f.log, [])
  assert.equal(n, 2)
})

test("the player: src only for Safari's own player, hls.js attached for the rest, the link out when it gives up", () => {
  // No DOM in these tests, so the wiring is pinned in the source; hls.js itself is exercised above.
  const src = readFileSync(new URL("../src/readers/LiveScreen.jsx", import.meta.url), "utf8")
  assert.match(src, /src=\{mode === "native" \? s\.streaming : undefined\}/)
  assert.match(src, /if \(mode !== "hlsjs" \|\| !ref\.current\) return\n\s*return attachHls\(ref\.current, s\.streaming, \(\) => setMode\("none"\)\)/)
  assert.match(src, /if \(mode === "none"\) return \([\s\S]*?class="live-out"/)
})
