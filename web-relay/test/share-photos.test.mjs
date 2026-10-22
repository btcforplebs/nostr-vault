// The public post page's mesh photo script: a photo the page marked (data-x, data-vaults) is read over FIPS when its
// https server fails, from the vaults the page named and no others, in the browser only (the site keeps no copy); the
// reader starts once, as the page opens, and stops after a quiet while.
// A tiny fake document; the last test reads through the real photo-only reader over a datagram fabric.
import { test } from "node:test"
import assert from "node:assert/strict"
import { randomBytes, createHash } from "node:crypto"
import { toHex } from "@fips/core"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { meshTarget, wireMeshPhotos, MAX_PARALLEL, MAX_PHOTOS } from "../src/fips/share-photos.js"
import { startPhotoReader, throwawayIdentity } from "../src/fips/photo-reader.js"
import { meshHttpVault } from "../tools/lib/mesh-http-vault.js"
import { nodeFabric } from "./support/node-fabric.js"

const sha = b => createHash("sha256").update(b).digest("hex")
const HASH = "e4".repeat(32), V1 = "11".repeat(32), V2 = "22".repeat(32)

function img({ x = HASH, vaults = `${V1},${V2}`, failed = false, reply = false } = {}) {
  const link = { href: "https://media.example/dead.png" }
  const listeners = {}
  return {
    dataset: { ...(x && { x }), ...(vaults && { vaults }), ...(reply && { meshOn: "error" }) },
    complete: failed, naturalWidth: 0, src: "https://media.example/dead.png", link,
    closest: sel => (sel === "a" ? link : null),
    addEventListener: (type, fn) => { listeners[type] = fn },
    fail: () => listeners.error?.(),
  }
}
const doc = imgs => ({ querySelectorAll: sel => (sel === "img[data-x][data-vaults]" ? imgs.filter(i => i.dataset.x && i.dataset.vaults) : []) })
const settle = () => new Promise(r => setTimeout(r, 5))

function fakeReader(has, { size = 3, delayMs = 0 } = {}) {
  const calls = { starts: 0, stops: 0, gets: [], allowed: [], live: 0, peak: 0 }
  const start = async getPhotoVaults => {
    calls.starts++
    return {
      stop: async () => { calls.stops++ },
      getBlob: async (vault, x, { onProgress = () => {}, signal } = {}) => {
        calls.gets.push(vault); calls.allowed.push([...getPhotoVaults()])
        calls.peak = Math.max(calls.peak, ++calls.live)
        try {
          if (delayMs) await new Promise(r => setTimeout(r, delayMs))
          if (!has.includes(vault)) throw new Error("no route")
          for (let n = 0; n < size; n += 1 << 20) { onProgress(Math.min(n + (1 << 20), size)); if (signal?.aborted) throw new Error("aborted") }
          return { bytes: new Uint8Array(Math.min(size, 3)), type: "image/png" }
        } finally { calls.live-- }
      },
    }
  }
  return { calls, start, toUrl: (b, t) => `blob:${t}:${b.length}`, revoke: () => {}, onLeave: () => {} }
}

test("meshTarget: a 64-hex hash and up to three 64-hex vaults, else nothing", () => {
  assert.deepEqual(meshTarget(img()), { x: HASH, vaults: [V1, V2], fallback: false })
  assert.equal(meshTarget(img({ reply: true })).fallback, true)
  assert.equal(meshTarget(img({ vaults: "nothex" })), undefined)
  assert.equal(meshTarget(img({ x: "abc" })), undefined)
  assert.equal(meshTarget(img({ vaults: [V1, V2, "33".repeat(32), "44".repeat(32)].join(",") })).vaults.length, 3)
})

test("a photo that already failed reads now; the next vault is tried; the link opens what loaded", async () => {
  const f = fakeReader([V2]), a = img({ failed: true })
  await wireMeshPhotos(doc([a]), f)
  assert.deepEqual(f.calls.gets, [V1, V2])
  assert.equal(a.src, "blob:image/png:3")
  assert.equal(a.link.href, a.src)
  assert.equal(a.dataset.mesh, "loaded")
  assert.deepEqual(f.calls.allowed[0].sort(), [V1, V2].sort(), "the reader may ask only the vaults the page named")
})

test("the reader starts as the page opens; a photo still loading is read on its error, not before", async () => {
  const f = fakeReader([V1]), loading = img(), fine = img()
  await wireMeshPhotos(doc([loading, fine]), f)
  await settle()
  assert.equal(f.calls.starts, 1, "started before any photo failed, so the seed handshake is done in time")
  assert.equal(f.calls.gets.length, 0, "nothing read yet")
  loading.fail(); await settle()
  assert.equal(f.calls.starts, 1, "the same reader")
  assert.equal(loading.src, "blob:image/png:3")
  assert.equal(fine.src, "https://media.example/dead.png")
})

test("a page whose photos all load over https stops the early reader after the quiet while", async () => {
  const f = fakeReader([V1])
  await wireMeshPhotos(doc([img(), img()]), { ...f, idleStopMs: 20 })
  await new Promise(r => setTimeout(r, 40))
  assert.deepEqual([f.calls.starts, f.calls.stops, f.calls.gets.length], [1, 1, 0])
})

test("the photo is read in the browser only: no request to the site for a copy", async () => {
  const f = fakeReader([]), a = img({ failed: true }), made = []
  const saved = globalThis.Image, savedFetch = globalThis.fetch
  globalThis.Image = class { constructor() { made.push(this) } }
  globalThis.fetch = async u => { made.push(u); throw new Error("no fetch") }
  try { await wireMeshPhotos(doc([a]), f) } finally { globalThis.Image = saved; globalThis.fetch = savedFetch }
  assert.deepEqual(made, [])
  assert.equal(a.dataset.mesh, "failed")
  assert.equal(a.link.href, "https://media.example/dead.png", "a photo no vault has keeps its link")
})

test("one reader for the page; a photo no vault has is marked failed and keeps its link", async () => {
  const f = fakeReader([]), a = img({ failed: true }), b = img({ failed: true, x: "f0".repeat(32) })
  await wireMeshPhotos(doc([a, b]), f)
  assert.equal(f.calls.starts, 1)
  assert.equal(a.dataset.mesh, "failed")
  assert.equal(a.link.href, "https://media.example/dead.png")
})

test("an unmarked photo is never read, and a page without one never starts the reader", async () => {
  const f = fakeReader([V1]), a = img({ failed: true, vaults: "" })
  await wireMeshPhotos(doc([a]), f)
  assert.equal(f.calls.starts, 0)
})

test("fifty failed photos: a few at a time, MAX_PHOTOS in all, the rest keep their link", async () => {
  const f = fakeReader([], { delayMs: 2 }), imgs = Array.from({ length: 50 }, (_, i) => img({ failed: true, x: (i + 16).toString(16).padStart(64, "0") }))
  await wireMeshPhotos(doc(imgs), f)
  assert.equal(f.calls.peak, MAX_PARALLEL)
  assert.equal(f.calls.gets.length, MAX_PHOTOS * 2, "two vaults each, MAX_PHOTOS photos")
  assert.equal(imgs.filter(i => i.dataset.mesh === "skipped").length, 50 - MAX_PHOTOS)
})

test("a photo over the per-photo cap is aborted; the page's byte budget stops the rest", async () => {
  const big = fakeReader([V1], { size: 5 << 20 })
  const a = img({ failed: true, vaults: V1 })
  await wireMeshPhotos(doc([a]), { ...big, limits: { photoBytes: 2 << 20 } })
  assert.equal(a.dataset.mesh, "failed")

  const f = fakeReader([V1], { size: 3 << 20 })
  const imgs = [1, 2, 3].map(i => img({ failed: true, vaults: V1, x: String(i).repeat(64) }))
  await wireMeshPhotos(doc(imgs), { ...f, limits: { pageBytes: 5 << 20, parallel: 1 } })
  assert.deepEqual(imgs.map(i => i.dataset.mesh), ["loaded", "failed", "failed"])
  assert.equal(f.calls.gets.length, 2, "the third never asks")
})

test("the reader stops after a quiet while, not per photo; leaving the page revokes the photos", async () => {
  let leave
  const revoked = [], f = fakeReader([V1])
  const a = img({ failed: true }), later = img(), last = img({ x: "f1".repeat(32) })
  await wireMeshPhotos(doc([a, later, last]), { ...f, idleStopMs: 30, revoke: u => revoked.push(u), onLeave: fn => { leave = fn } })
  later.fail(); await settle()
  assert.equal(f.calls.starts, 1, "a failure inside the quiet while reuses the reader")
  assert.equal(f.calls.stops, 0)
  await new Promise(r => setTimeout(r, 50))
  assert.equal(f.calls.stops, 1)
  last.fail(); await settle()
  assert.equal(f.calls.starts, 2, "a later failure starts a fresh reader")
  leave(); await settle()
  assert.equal(f.calls.stops, 2, "leaving stops it at once")
  assert.deepEqual(revoked, [a.src, later.src, last.src])
})

test("end to end: the real photo-only reader fetches the blob, hash-checked, from the named vault", async () => {
  const net = nodeFabric()
  const bytes = new Uint8Array(randomBytes(30_000)), h = sha(bytes)
  const vaultKey = "02" + getPublicKey(generateSecretKey())
  const vault = meshHttpVault(net.node(vaultKey), vaultKey, new Map([[h, { bytes, type: "image/jpeg" }]]))
  const timer = setInterval(async () => { await net.deliver(); await vault.tick() }, 2)
  let reader
  try {
    const identity = await throwawayIdentity()
    const start = async getPhotoVaults => (reader = await startPhotoReader({ getPhotoVaults, identity,
      makeNode: id => ({ ...net.node("02" + toHex(id.xOnlyPubkey)), start: async () => {}, stop: async () => {} }) }))
    let got
    const a = img({ failed: true, x: h, vaults: vaultKey.slice(2) })
    await wireMeshPhotos(doc([a]), { start, toUrl: (b, t) => { got = { b, t }; return "blob:ok" }, timeoutMs: 20_000 })
    assert.equal(a.src, "blob:ok")
    assert.equal(sha(got.b), h)
    assert.equal(got.t, "image/jpeg")
    assert.equal(vault.stats.served, 1)
  } finally { clearInterval(timer); await reader?.stop(); await vault.stop() }
})

// A fake DOM just big enough for the placeholder card: elements with children, text, attributes and `hidden`.
function el(tag) {
  const e = { tagName: tag, children: [], dataset: {}, attrs: {}, hidden: false, textContent: "", parentNode: null,
    setAttribute: (k, v) => { e.attrs[k] = v },
    append: (...cs) => cs.forEach(c => { c.parentNode = e; e.children.push(c) }),
    insertBefore: (c, ref) => { c.parentNode = e; e.children.splice(e.children.indexOf(ref), 0, c) },
    remove: () => { const p = e.parentNode; if (p) p.children.splice(p.children.indexOf(e), 1); e.parentNode = null },
  }
  return e
}
function domImg(opts) {
  const i = img(opts), box = el("div"), a = el("a")
  box.append(a); a.append(i)
  i.closest = sel => (sel === "a" ? a : null)
  i.ownerDocument = { createElement: el }
  return { i, a, box }
}
const card = box => box.children.find(c => c.className === "mesh-ph")
const cardText = c => c.children.map(x => x.textContent).join("")

test("while a photo reads over the mesh its dead link is hidden behind a loading card; the photo replaces it", async () => {
  const f = fakeReader([V1], { delayMs: 20 }), { i, a, box } = domImg({ failed: true })
  const done = wireMeshPhotos(doc([i]), f)
  await settle()
  assert.equal(a.hidden, true, "the broken-image link is hidden while the mesh reads")
  assert.equal(cardText(card(box)), "Loading image over FIPS…")
  assert.equal(card(box).attrs.role, "status")
  assert.ok(box.children.indexOf(card(box)) < box.children.indexOf(a), "the card sits where the photo will be")
  await done
  assert.equal(card(box), undefined, "the card goes once the photo loads")
  assert.equal(a.hidden, false)
  assert.equal(i.src, "blob:image/png:3")
})

test("a photo no vault has: the card says the vault couldn't be reached, no spinner, dead link stays hidden", async () => {
  const f = fakeReader([]), { a, box, i } = domImg({ failed: true })
  await wireMeshPhotos(doc([i]), f)
  assert.equal(card(box).dataset.state, "failed")
  assert.equal(cardText(card(box)), "Couldn't reach the owner's vault")
  assert.equal(card(box).children.some(c => c.className === "spin"), false)
  assert.equal(a.hidden, true)
})

test("a photo that loads over https never gets a card", async () => {
  const f = fakeReader([V1]), { box, i } = domImg()
  await wireMeshPhotos(doc([i]), f)
  assert.equal(card(box), undefined)
})

test("a reply's photo is a fallback only: no reader at page open, its vaults once it fails", async () => {
  const f = fakeReader([V1]), reply = img({ reply: true })
  await wireMeshPhotos(doc([reply, img({ reply: true })]), f)
  await settle()
  assert.equal(f.calls.starts, 0, "replies whose https photos load open no fips connection")
  reply.fail(); await settle()
  assert.equal(f.calls.starts, 1)
  assert.equal(reply.src, "blob:image/png:3")
})

test("a reply that already failed when the script ran is read at once", async () => {
  const f = fakeReader([V1]), reply = img({ reply: true, failed: true })
  await wireMeshPhotos(doc([reply]), f)
  assert.deepEqual([f.calls.starts, reply.dataset.mesh], [1, "loaded"])
})
