// Compose upgrade (2026-11-01): photos go in at the cursor, uploads report progress and stop when removed, Post waits
// only on unfinished uploads, and the live preview is the note buildPost makes. Throwaway keys, a fake XMLHttpRequest
// and a stubbed fetch: nothing is uploaded or published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { uploadPhoto } from "../src/net/upload.js"
import { xhrPut } from "../src/net/upload-progress.js"
import { EMPTY_DRAFT, addPhotos, insertAtCaret, isPlaced, photoToken, placeBody, removePhoto, updatePhoto, withoutStaleTokens } from "../src/screens/compose/draft-model.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { buildPost } = await import("../src/screens/ComposeScreen.jsx")
const { previewEvent } = await import("../src/screens/compose/ComposePreview.jsx")

const me = generateSecretKey()
const draftWith = text => ({ ...EMPTY_DRAFT, text })

test("insert at the caret: on a line of its own, a selection replaced, the caret after it", () => {
  assert.deepEqual(insertAtCaret("hello world", 5, "[photo 1]"), { text: "hello\n[photo 1]\nworld", caret: 16 })
  assert.deepEqual(insertAtCaret("line one\n", 9, "X"), { text: "line one\nX\n", caret: 11 })
  assert.deepEqual(insertAtCaret("abc", 3, "X"), { text: "abc\nX\n", caret: 6 })
  assert.deepEqual(insertAtCaret("a SELECTED b", 2, "X", 10), { text: "a\nX\nb", caret: 4 })
  assert.equal(insertAtCaret("abc", undefined, "X").text, "abc\nX\n", "no caret known: at the end")
})

test("a photo picked while there's text goes in at the cursor; into an empty box it isn't placed", () => {
  const d = addPhotos(draftWith("before after"), [{ id: 7 }, { id: 8 }], 6)
  assert.equal(d.text, "before\n[photo 7]\n[photo 8]\nafter")
  assert.equal(d.photos.length, 2)
  const e = addPhotos(EMPTY_DRAFT, [{ id: 9 }], 0)
  assert.equal(e.text, "", "an empty box gets no placeholder")
  assert.equal(isPlaced(e.text, { id: 9 }), false)
})

test("an upload finishing swaps its placeholder for its link, in the same step", () => {
  let d = addPhotos(draftWith("look:"), [{ id: 1, status: "uploading" }], 5)
  d = updatePhoto(d, 1, { progress: 0.5 })
  assert.equal(d.photos[0].progress, 0.5)
  assert.match(d.text, /\[photo 1\]/)
  d = updatePhoto(d, 1, { status: "done", url: "https://m.example/a.jpg" })
  assert.equal(d.text, "look:\nhttps://m.example/a.jpg\n")
  assert.equal(d.photos[0].status, "done")
})

test("removing a photo takes its placeholder or its placed link out of the text", () => {
  let d = addPhotos(draftWith("a b"), [{ id: 1 }, { id: 2 }], 1)
  assert.equal(d.text, "a\n[photo 1]\n[photo 2]\nb")
  d = updatePhoto(d, 2, { status: "done", url: "https://m/2.png" })
  d = removePhoto(d, 1)
  assert.equal(d.text, "a\nhttps://m/2.png\nb")
  d = removePhoto(d, 2)
  assert.equal(d.text, "a\nb")
  assert.deepEqual(d.photos, [])
})

test("the post body: placed links stay where they are, unplaced ones go at the end, stray placeholders go", () => {
  const photos = [{ id: 1, url: "https://m/1.png" }, { id: 2, url: "https://m/2.png" }, { id: 3, url: "https://m/3.png" }]
  const text = "one\nhttps://m/1.png\ntwo\n[photo 2]\nthree [photo 99]"
  assert.equal(placeBody(text, photos), "one\nhttps://m/1.png\ntwo\nhttps://m/2.png\nthree\nhttps://m/3.png")
  assert.equal(placeBody("", photos.slice(0, 1)), "https://m/1.png", "a photo alone, as before")
  assert.equal(withoutStaleTokens("a\n[photo 4]\nb"), "a\n\nb")
})

test("buildPost: a placed photo isn't posted twice, and still gets its imeta", () => {
  const photos = [{ id: 1, url: "https://m/1.png", mime: "image/png", sha256: "1" }, { id: 2, url: "https://m/2.png" }]
  const { content, tags } = buildPost({ text: "first\nhttps://m/1.png\nsecond", mentions: {}, photos, target: null, parent: null })
  assert.equal(content, "first\nhttps://m/1.png\nsecond\nhttps://m/2.png")
  assert.equal(content.split("https://m/1.png").length, 2)
  assert.equal(tags.filter(t => t[0] === "imeta").length, 2)
})

test("the preview is the event buildPost makes, by you, unsigned", () => {
  const built = buildPost({ text: "gm #nostr https://example.com", mentions: {}, photos: [], target: null, parent: null })
  const ev = previewEvent(built, "ab".repeat(32), 1000)
  assert.equal(ev.kind, 1); assert.equal(ev.pubkey, "ab".repeat(32)); assert.equal(ev.created_at, 1000); assert.equal(ev.sig, "")
  assert.equal(ev.content, built.content); assert.deepEqual(ev.tags, built.tags)
  assert.match(ev.id, /^[0-9a-f]{64}$/, "a real event id, so the renderer can encode it")
  assert.ok(ev.tags.some(t => t[0] === "t" && t[1] === "nostr"))
})

// A fake XMLHttpRequest: records what was sent, reports progress, answers, or is aborted.
function fakeXHR(script) {
  const made = []
  class X {
    constructor() { this.upload = {}; this.headers = {}; made.push(this) }
    open(m, u) { this.method = m; this.url = u }
    setRequestHeader(k, v) { this.headers[k] = v }
    getResponseHeader() { return null }
    abort() { this.aborted = true; queueMicrotask(() => this.onabort?.()) }
    send(body) { this.body = body; script(this) }
  }
  return { X, made }
}

test("xhrPut: progress as a fraction, a fetch-like answer, abort as an AbortError", async () => {
  const seen = []
  const { X } = fakeXHR(x => {
    x.upload.onprogress?.({ lengthComputable: true, loaded: 1, total: 4 })
    x.upload.onprogress?.({ lengthComputable: true, loaded: 4, total: 4 })
    x.status = 200; x.responseText = '{"ok":1}'; x.onload()
  })
  const res = await xhrPut("https://m/upload", { headers: { A: "1" }, body: new Uint8Array(4), onProgress: f => seen.push(f) }, X)
  assert.deepEqual(seen, [0.25, 1])
  assert.equal(res.ok, true)
  assert.deepEqual(await res.json(), { ok: 1 })
  const stop = new AbortController()
  const { X: Hang } = fakeXHR(() => {})
  const p = xhrPut("https://m/upload", { body: new Uint8Array(1), signal: stop.signal }, Hang)
  stop.abort()
  await assert.rejects(p, { name: "AbortError" })
  await assert.rejects(xhrPut("https://m/upload", { signal: stop.signal }, Hang), { name: "AbortError" }, "already stopped: nothing sent")
})

test("uploadPhoto: a photo removed before its turn never asks the signer, nor uploads", async () => {
  let signs = 0, puts = 0
  const ctx = { session: { pubkey: getPublicKey(me) }, signer: { signEvent: async t => { signs++; return finalizeEvent(t, me) } } }
  const stop = new AbortController(); stop.abort()
  const file = { type: "image/png", arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer }
  await assert.rejects(uploadPhoto(file, { ctx, servers: ["https://m"], signal: stop.signal, fetch: async () => { puts++ } }), { name: "AbortError" })
  assert.equal(signs, 0); assert.equal(puts, 0)
})

test("uploadPhoto: stopped mid-upload, it doesn't try the next server", async () => {
  const ctx = { session: { pubkey: getPublicKey(me) }, signer: { signEvent: async t => finalizeEvent(t, me) } }
  const stop = new AbortController(), urls = []
  const fetch = async url => { urls.push(url); stop.abort(); throw Object.assign(new Error("stopped"), { name: "AbortError" }) }
  const file = { type: "image/png", arrayBuffer: async () => new Uint8Array([1]).buffer }
  await assert.rejects(uploadPhoto(file, { ctx, servers: ["https://a", "https://b"], signal: stop.signal, fetch }), { name: "AbortError" })
  assert.deepEqual(urls, ["https://a/upload"])
})

test("uploadPhoto: with onProgress and no fetch given, it goes through XMLHttpRequest and reports progress", async () => {
  const sha = await crypto.subtle.digest("SHA-256", new Uint8Array([5, 6]))
  const hex = [...new Uint8Array(sha)].map(b => b.toString(16).padStart(2, "0")).join("")
  const { X, made } = fakeXHR(x => { x.upload.onprogress?.({ lengthComputable: true, loaded: 2, total: 2 }); x.status = 200; x.responseText = JSON.stringify({ url: `https://m/${hex}.png`, sha256: hex }); x.onload() })
  const saved = globalThis.XMLHttpRequest; globalThis.XMLHttpRequest = X
  try {
    const ctx = { session: { pubkey: getPublicKey(me) }, signer: { signEvent: async t => finalizeEvent(t, me) } }
    const seen = []
    const up = await uploadPhoto({ type: "image/png", arrayBuffer: async () => new Uint8Array([5, 6]).buffer }, { ctx, servers: ["https://m"], onProgress: f => seen.push(f) })
    assert.equal(up.url, `https://m/${hex}.png`)
    assert.deepEqual(seen, [0, 1])
    assert.equal(made[0].method, "PUT"); assert.match(made[0].headers.Authorization, /^Nostr /)
  } finally { globalThis.XMLHttpRequest = saved }
})
