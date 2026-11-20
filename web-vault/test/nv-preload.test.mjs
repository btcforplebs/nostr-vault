// index.html's haven.wasm preload (nv-preload.js): a script of its own, because the site's CSP (website/nginx.conf,
// script-src 'self') runs no inline script. It starts the wasm only for someone signed in — a guest opening a shared
// post must not download 6.6 MB — and its decision must be exactly session.js's, or the app fetches the wasm again.
import test from "node:test"
import assert from "node:assert/strict"
import vm from "node:vm"
import { bootScript, preloadHaven } from "../nv-preload.js"
import { loadSession } from "../src/session.js"

const HEX = "a".repeat(64), WASM = "/vault/assets/haven-Bn4oz0MM.wasm"
const storage = stored => ({ getItem: k => (k in stored ? stored[k] : null) })

/** Runs the script against a fake page; -> the downloads it started ({ url, opts }) and what it left for loadHaven. */
function run(stored, { throwOnRead = false } = {}) {
  const fetched = []
  const localStorage = { getItem: k => { if (throwOnRead) throw new Error("storage is blocked"); return k in stored ? stored[k] : null } }
  const window = {}
  const fetch = (url, opts) => { fetched.push({ url, opts }); return Promise.resolve({ ok: true }) }
  vm.runInNewContext(bootScript(WASM), { localStorage, window, fetch, URL, document: { baseURI: "https://nostrvault.app/vault/" } })
  fetched.left = window.__nvHavenWasm
  return fetched
}

test("signed in: the script starts this build's wasm and leaves the response for loadHaven, no preload link", () => {
  const got = run({ "nv-session": JSON.stringify({ pubkey: HEX, method: "readonly" }) })
  assert.equal(got.length, 1, "one download")
  assert.deepEqual(JSON.parse(JSON.stringify(got[0])), { url: `https://nostrvault.app${WASM}`, opts: { credentials: "same-origin" } })
  assert.equal(got.left.href, `https://nostrvault.app${WASM}`, "the absolute URL loadHaven compares")
  assert.ok(typeof got.left.res.then === "function")
})

test("a failed early download leaves null, not a rejection nobody catches", async () => {
  const window = {}
  vm.runInNewContext(bootScript(WASM), {
    localStorage: { getItem: () => JSON.stringify({ pubkey: HEX }) }, window, URL,
    fetch: () => Promise.reject(new TypeError("offline")), document: { baseURI: "https://nostrvault.app/vault/" },
  })
  assert.equal(await window.__nvHavenWasm.res, null)
})

test("a guest, a broken session and unreadable storage all preload nothing", () => {
  assert.equal(run({}).length, 0, "no session")
  assert.equal(run({ "nv-session": "null" }).length, 0, "no session")
  assert.equal(run({ "nv-session": "not json" }).length, 0, "a damaged session")
  assert.equal(run({ "nv-session": JSON.stringify({ pubkey: "npub1x" }) }).length, 0, "an npub is not the stored form")
  assert.equal(run({ "nv-session": JSON.stringify({ method: "readonly" }) }).length, 0, "no pubkey")
  assert.equal(run({ "nv-session": JSON.stringify({ pubkey: HEX.toUpperCase() }) }).length, 0, "not lowercase hex")
  assert.equal(run({}, { throwOnRead: true }).length, 0, "storage blocked: no throw, no download")
})

test("the script's decision is exactly session.js loadSession's, so a signed-in reader always gets the preload", () => {
  const cases = [
    {}, { "nv-session": "null" }, { "nv-session": "{" }, { "nv-session": JSON.stringify({}) },
    { "nv-session": JSON.stringify({ pubkey: HEX }) }, { "nv-session": JSON.stringify({ pubkey: "b".repeat(64), method: "local", ncryptsec: "ncryptsec1x" }) },
    { "nv-session": JSON.stringify({ pubkey: HEX.toUpperCase() }) }, { "nv-session": JSON.stringify({ pubkey: HEX.slice(1) }) },
    { "nv-session": JSON.stringify({ pubkey: HEX, method: "readonly" }), "nv-accounts": "[]" },
  ]
  for (const stored of cases) assert.equal(run(stored).length === 1, !!loadSession(storage(stored)), JSON.stringify(stored))
})

test("the build links index.html to the script before the app's own, named by the hash of its source", () => {
  const emitted = []
  const plugin = preloadHaven()
  plugin.configResolved({ base: "/vault/" })
  const tags = plugin.transformIndexHtml.handler.call({ emitFile: f => emitted.push(f) }, "<html></html>", {
    bundle: { "assets/haven-Bn4oz0MM.wasm": { type: "asset" }, "assets/index-Ab12Cd34.js": { type: "chunk" } },
  })
  assert.equal(emitted.length, 1, "one asset: the script")
  assert.match(emitted[0].fileName, /^assets\/nv-preload-[\w-]{8}\.js$/)
  assert.equal(emitted[0].source, bootScript("/vault/assets/haven-Bn4oz0MM.wasm"))
  assert.deepEqual(tags, [{ tag: "script", attrs: { defer: true, src: `/vault/${emitted[0].fileName}` }, injectTo: "head-prepend" }])
  // A different wasm URL is a different script, so a cached one can never preload an older build's file.
  const other = preloadHaven()
  other.configResolved({ base: "/vault/" })
  const again = []
  other.transformIndexHtml.handler.call({ emitFile: f => again.push(f) }, "", { bundle: { "assets/haven-Zz99Yy88.wasm": {} } })
  assert.notEqual(again[0].fileName, emitted[0].fileName)
  assert.notEqual(again[0].source, emitted[0].source)
})

test("a build with no haven.wasm fails rather than shipping an index.html with no preload", () => {
  const plugin = preloadHaven()
  plugin.configResolved({ base: "/vault/" })
  assert.throws(() => plugin.transformIndexHtml.handler.call({ emitFile() {} }, "", { bundle: {} }), /no haven-\*\.wasm/)
})

test("main.jsx's own early start joins the boot script's, and starts one the same way when there is none (dev)", async () => {
  const { preloadHaven: early } = await import("../src/haven/vault.js")
  const asked = []
  const g = { fetch: (url, opts) => { asked.push([url, opts]); return Promise.resolve({ ok: true }) } }
  early(g)
  assert.equal(asked.length, 1)
  assert.match(g.__nvHavenWasm.href, /haven\.wasm$/)
  assert.deepEqual(asked[0][1], { credentials: "same-origin" })
  early(g)
  assert.equal(asked.length, 1, "already started: no second download")
})
