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

/** Runs the script against a fake page; -> the <link>s it appended to <head>. */
function run(stored, { throwOnRead = false } = {}) {
  const links = []
  const localStorage = { getItem: k => { if (throwOnRead) throw new Error("storage is blocked"); return k in stored ? stored[k] : null } }
  const document = { createElement: () => ({}), head: { appendChild: l => links.push(l) } }
  vm.runInNewContext(bootScript(WASM), { localStorage, document })
  return links
}

test("signed in: the script preloads this build's wasm the same way loadHaven fetches it", () => {
  const [link, ...rest] = run({ "nv-session": JSON.stringify({ pubkey: HEX, method: "readonly" }) })
  assert.equal(rest.length, 0, "one link")
  assert.deepEqual({ ...link }, {
    rel: "preload", as: "fetch", type: "application/wasm", crossOrigin: "anonymous", href: WASM,
  })
})

test("a guest, a broken session and unreadable storage all preload nothing", () => {
  assert.deepEqual(run({}), [], "no session")
  assert.deepEqual(run({ "nv-session": "null" }), [], "no session")
  assert.deepEqual(run({ "nv-session": "not json" }), [], "a damaged session")
  assert.deepEqual(run({ "nv-session": JSON.stringify({ pubkey: "npub1x" }) }), [], "an npub is not the stored form")
  assert.deepEqual(run({ "nv-session": JSON.stringify({ method: "readonly" }) }), [], "no pubkey")
  assert.deepEqual(run({ "nv-session": JSON.stringify({ pubkey: HEX.toUpperCase() }) }), [], "not lowercase hex")
  assert.deepEqual(run({}, { throwOnRead: true }), [], "storage blocked: no throw, no download")
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
