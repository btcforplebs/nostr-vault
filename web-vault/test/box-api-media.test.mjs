// Box Media (W5): the API client's routes and NIP-98 headers, the browser-signed upload auths (one per 25 files),
// and the On this box rows driving a pretend box. Made-up keys; nothing is sent anywhere.
import test from "node:test"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { createServer } from "vite"
import { h, render } from "preact"
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import { fakeDom, tick, all, fire, button } from "./box-accounts-fake.mjs"

fakeDom()
const root = fileURLToPath(new URL("..", import.meta.url))
const vite = await createServer({ root, configFile: false, logLevel: "silent", appType: "custom", server: { middlewareMode: true, hmr: false, ws: false }, oxc: { jsx: { runtime: "automatic", importSource: "preact" } } })
const { mediaApi, signCopyAuths, copyAuthTemplate, batches, lastRunLine } = await vite.ssrLoadModule("/src/box/api-media.js")
const { MediaCopyRows, copyLine, untilDone } = await vite.ssrLoadModule("/src/screens/MediaCopyRows.jsx")
test.after(() => vite.close())

const sk = generateSecretKey()
const me = getPublicKey(sk)
let signs = 0
const signer = { signEvent: async t => { signs++; return finalizeEvent(t, sk) } }
const hashes = n => Array.from({ length: n }, (_, i) => i.toString(16).padStart(64, "0"))
const decode = header => JSON.parse(Buffer.from(header.replace(/^Nostr /, ""), "base64").toString())

test("one upload auth per 25 files, each naming its files, good for an hour", async () => {
  assert.deepEqual(batches(hashes(51)).map(b => b.length), [25, 25, 1])
  const t = copyAuthTemplate(hashes(2), 1000)
  assert.deepEqual(t.tags, [["t", "upload"], ["x", hashes(2)[0]], ["x", hashes(2)[1]], ["expiration", "4600"]])
  signs = 0
  const auths = await signCopyAuths({ signer, session: { pubkey: me } }, hashes(26))
  assert.equal(signs, 2)
  assert.equal(auths.length, 2)
  const ev = decode(auths[1])
  assert.ok(verifyEvent(ev))
  assert.equal(ev.kind, 24242)
  assert.equal(ev.pubkey, me)
  assert.deepEqual(ev.tags.filter(t => t[0] === "x").map(t => t[1]), [hashes(26)[25]])
  const other = generateSecretKey()
  await assert.rejects(signCopyAuths({ signer: { signEvent: async t => finalizeEvent(t, other) }, session: { pubkey: me } }, hashes(1)), /different account/)
})

test("each call goes to its route, signed for that method and body", async () => {
  const seen = []
  const fetchImpl = async (url, init) => {
    const ev = decode(init.headers.Authorization)
    seen.push({ url, method: init.method, body: init.body, u: ev.tags.find(t => t[0] === "u")[1], m: ev.tags.find(t => t[0] === "method")[1], payload: !!ev.tags.find(t => t[0] === "payload") })
    return new Response(JSON.stringify({ ok: true }), { status: 200 })
  }
  const api = mediaApi({ signer, base: "http://box.test/api/box", fetchImpl })
  await api.autoMirror(); await api.setAutoMirror(true); await api.runAutoMirror(); await api.checkCopy(); await api.copy(["Nostr x"]); await api.copyState()
  assert.deepEqual(seen.map(s => `${s.method} ${s.url.replace("http://box.test/api/box/", "")}`), [
    "GET media/auto-mirror", "PUT media/auto-mirror", "POST media/auto-mirror/run", "POST media/copy/check", "POST media/copy", "GET media/copy"])
  for (const s of seen) { assert.equal(s.u, s.url); assert.equal(s.m, s.method) }
  assert.equal(seen[1].body, JSON.stringify({ enabled: true }))
  assert.ok(seen[1].payload, "the PUT body is in the signed payload hash")
  assert.equal(seen[4].body, JSON.stringify({ auths: ["Nostr x"] }))
})

test("a 403 says only the first account can change it", async () => {
  const api = mediaApi({ signer, base: "http://box.test/api/box", fetchImpl: async () => new Response(JSON.stringify({ error: "nope" }), { status: 403 }) })
  await assert.rejects(api.setAutoMirror(true), /first account/)
})

test("words for the last run and the copy line", () => {
  const now = 10_000_000
  assert.equal(lastRunLine({ state: null }), "")
  assert.equal(lastRunLine({ state: { running: true } }), "Copying in now…")
  assert.equal(lastRunLine({ state: { last_finish: now / 1000 - 600, last: { saved: 3, skipped: 1, cap_reached: true, unreachable: ["a.example"] } } }, now),
    "Last run 10 min ago: 3 new files, 1 skipped, more next run, couldn't read a.example.")
  assert.match(copyLine(null, "", 0), /Send your files/)
  assert.equal(copyLine({ checked_at: 1, checked: 10 }, "", 2), "2 files of 10 files on this box are missing from a server.")
  assert.equal(copyLine({ checked_at: 1, checked: 10 }, "", 0), "All 10 files on this box are on every server.")
  assert.equal(copyLine({ checked_at: 1, action: "copy", copied: 1, failed: 1 }, "", 1), "1 file copied, 1 failed. 1 file still to send.")
})

test("waits for the job it asked for, not an older one", async () => {
  const answers = [{ queued: true, state: { id: "old", running: false } }, { state: { id: "new", running: true } }, { state: { id: "new", running: false, copied: 2 } }]
  const st = await untilDone({ copyState: async () => answers.shift() }, "new", { pollMs: 1 })
  assert.equal(st.copied, 2)
})

/** A pretend box: what the engine would answer, from memory. */
function fakeMediaBox() {
  const box = { enabled: false, job: null, calls: [], auths: null }
  const files = hashes(30).map(sha256 => ({ sha256, absent: ["https://a.example"], status: "waiting" }))
  box.api = {
    autoMirror: async () => ({ enabled: box.enabled, state: null }),
    setAutoMirror: async v => { box.calls.push(`set ${v}`); box.enabled = v; return { enabled: v, state: null } },
    runAutoMirror: async () => { box.calls.push("run"); return { enabled: true, runNowAt: 1, state: { running: true } } },
    checkCopy: async () => { box.job = { id: "c", action: "check", running: false, checked: 40, checked_at: 1, files }; return { id: "c" } },
    copy: async auths => {
      box.auths = auths
      box.job = { id: "p", action: "copy", running: false, checked: 40, checked_at: 1, copied: 29, failed: 1,
        files: files.map((f, i) => i === 0 ? { ...f, status: "failed", reasons: { "https://a.example": "HTTP 413" } } : { ...f, status: "copied" }) }
      return { id: "p" }
    },
    copyState: async () => ({ state: box.job }),
  }
  return box
}

test("On this box: switch, run now, check, then copy with one signature per 25 files", async () => {
  const box = fakeMediaBox()
  const el = document.createElement("div")
  render(h(MediaCopyRows, { ctx: { signer, session: { pubkey: me } }, api: box.api, pollMs: 1 }), el)
  await tick(5)
  const sw = all(el).find(n => n.localName === "input")
  assert.ok(!sw.checked && sw.attributes.checked !== "true", "off at first")
  await fire(sw, "change"); await tick(5)
  assert.deepEqual(box.calls, ["set true"])
  await fire(button(el, "Run now"), "click", { preventDefault() {} }); await tick(5)
  assert.deepEqual(box.calls, ["set true", "run"])

  await fire(button(el, "Check"), "click"); await tick(10)
  assert.match(el.textContent, /30 files of 40 files on this box are missing from a server/)
  signs = 0
  await fire(button(el, "Copy 30 files"), "click"); await tick(20)
  assert.equal(signs, 2, "30 files: two signatures")
  assert.equal(box.auths.length, 2)
  assert.match(el.textContent, /29 files copied, 1 failed/)
  assert.match(el.textContent, /a\.example HTTP 413/)
  assert.ok(button(el, "Retry"))
  render(null, el)
})

test("a read-only sign-in shows nothing", async () => {
  const el = document.createElement("div")
  render(h(MediaCopyRows, { ctx: { signer: { readOnly: true } }, api: fakeMediaBox().api }), el)
  await tick(1)
  assert.equal(el.textContent, "")
})
