// Vault › Media grid tiles (net/blossom-thumbs.js): a picture's original is fetched once, kept small under its hash,
// and a second visit draws the kept copy with no network.
import test from "node:test"
import assert from "node:assert/strict"
import { thumbStore, THUMB_PX, THUMB_MAX } from "../src/net/blossom-thumbs.js"

function fakeCaches() {
  const store = new Map()
  const cache = {
    match: async k => store.has(k) ? new Response(store.get(k)) : undefined,
    put: async (k, r) => { store.set(k, await r.blob()) },
    keys: async () => [...store.keys()].map(url => ({ url })),
    delete: async k => store.delete(k.url ?? k),
  }
  return { store, open: async () => cache }
}
const photo = (n, size = 2_000_000) => ({ sha256: `h${n}`, url: `https://blossom.example/h${n}.jpg`, kind: "photo", size })

function rig({ ok = true, shrink } = {}) {
  const caches = fakeCaches(), fetched = []
  const fetchFn = async url => { fetched.push(url); return new Response(new Blob([new Uint8Array(2_000_000)], { type: "image/jpeg" }), { status: ok ? 200 : 404 }) }
  shrink ||= async (b, px) => { assert.equal(px, THUMB_PX); return new Blob([new Uint8Array(20_000)], { type: "image/webp" }) }
  return { caches, fetched, fetchFn, shrink }
}

test("a second visit draws the kept small copy: no fetch, a fraction of the bytes", async () => {
  const r = rig()
  const first = await thumbStore({ cacheStorage: r.caches, fetchFn: r.fetchFn, shrink: r.shrink }).get(photo(1))
  assert.equal(first.size, 20_000)
  assert.equal(first.type, "image/webp")
  assert.deepEqual(r.fetched, ["https://blossom.example/h1.jpg"])
  // A reload: a new store, the same Cache Storage.
  const again = await thumbStore({ cacheStorage: r.caches, fetchFn: r.fetchFn, shrink: r.shrink }).get(photo(1))
  assert.equal(again.size, 20_000)
  assert.equal(r.fetched.length, 1, "no network on the second visit")
})

test("one fetch per hash while it loads", async () => {
  const r = rig(), s = thumbStore({ cacheStorage: r.caches, fetchFn: r.fetchFn, shrink: r.shrink })
  const [a, b] = await Promise.all([s.get(photo(1)), s.get(photo(1))])
  assert.equal(a, b)
  assert.equal(r.fetched.length, 1)
})

test("what can't be made small shows the original (null), and nothing is kept", async () => {
  for (const r of [rig({ ok: false }), rig({ shrink: async () => null })]) {
    const s = thumbStore({ cacheStorage: r.caches, fetchFn: r.fetchFn, shrink: r.shrink })
    assert.equal(await s.get(photo(1)), null)
    assert.equal(r.caches.store.size, 0)
  }
  const throws = rig()
  assert.equal(await thumbStore({ cacheStorage: throws.caches, fetchFn: async () => { throw new TypeError("CORS") }, shrink: throws.shrink }).get(photo(1)), null)
  assert.equal(await thumbStore({ cacheStorage: undefined }).get(photo(1)), null, "no Cache Storage")
})

test("GIFs, videos and other files keep the original; nothing is fetched for them", async () => {
  const r = rig(), s = thumbStore({ cacheStorage: r.caches, fetchFn: r.fetchFn, shrink: r.shrink })
  for (const kind of ["gif", "video", "other"]) assert.equal(await s.get({ ...photo(1), kind }), null)
  assert.equal(r.fetched.length, 0)
})

test("a copy no smaller than the original keeps the original's bytes", async () => {
  const r = rig({ shrink: async () => new Blob([new Uint8Array(3_000_000)], { type: "image/webp" }) })
  const kept = await thumbStore({ cacheStorage: r.caches, fetchFn: r.fetchFn, shrink: r.shrink }).get(photo(1))
  assert.equal(kept.size, 2_000_000)
})

test("the kept copies are bounded, oldest dropped first", async () => {
  assert.equal(THUMB_MAX, 1500)
  const r = rig(), s = thumbStore({ cacheStorage: r.caches, fetchFn: r.fetchFn, shrink: r.shrink, max: 3 })
  for (let i = 0; i < 5; i++) await s.get(photo(i))
  assert.deepEqual([...r.caches.store.keys()].map(k => k.slice(-2)), ["h2", "h3", "h4"])
})

test("a long first visit fetches at most 4 originals at once", async () => {
  const caches = fakeCaches()
  let open = 0, peak = 0
  const fetchFn = async () => { open++; peak = Math.max(peak, open); await new Promise(r => setTimeout(r, 5)); open--; return new Response(new Blob([new Uint8Array(10)]), { status: 200 }) }
  const s = thumbStore({ cacheStorage: caches, fetchFn, shrink: async () => new Blob([new Uint8Array(5)], { type: "image/webp" }) })
  await Promise.all(Array.from({ length: 20 }, (_, i) => s.get(photo(i))))
  assert.equal(peak, 4)
  assert.equal(caches.store.size, 20)
})
