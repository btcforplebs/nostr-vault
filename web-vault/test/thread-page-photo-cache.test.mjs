// The share page server's copy of mesh photos (thread-page/photo-cache.js): a page build arms the post's photo, a
// warm reader fetches it from the post's vaults only, and it serves only while a build keeps confirming it. A deleted
// post, a dropped photo or a 10063 that stops naming the vault drops it at once. A fake reader and clock.
import test from "node:test"
import assert from "node:assert/strict"
import { createPhotoCache } from "../thread-page/photo-cache.js"

const X = "e4".repeat(32), Y = "f1".repeat(32), V1 = "11".repeat(32), V2 = "22".repeat(32)
const settle = () => new Promise(r => setTimeout(r, 5))

function fakeReader(has, { size = 3, delayMs = 0 } = {}) {
  const calls = { starts: 0, stops: 0, gets: [], allowed: [] }
  const startReader = async getPhotoVaults => {
    calls.starts++
    return {
      stop: async () => { calls.stops++ },
      getBlob: async (vault, x) => {
        calls.gets.push([vault, x]); calls.allowed.push([...getPhotoVaults()])
        if (delayMs) await new Promise(r => setTimeout(r, delayMs))
        if (!has.includes(vault)) throw new Error("no route")
        return { bytes: new Uint8Array(size).fill(7), type: "image/png" }
      },
    }
  }
  return { calls, startReader }
}
function setup(has, opts = {}) {
  let now = 1_000_000
  const f = fakeReader(has, opts)
  const cache = createPhotoCache({ startReader: f.startReader, clock: () => now, limits: opts.limits })
  return { f, cache, tick: ms => { now += ms } }
}

test("a build arms the photo; the warm reader reads it from the post's vaults only, next vault on failure", async () => {
  const { f, cache } = setup([V2])
  assert.equal(cache.get(X), undefined)
  cache.sync("note1", [X], [V1, V2])
  const got = await cache.lookup(X)
  assert.deepEqual([...got.bytes], [7, 7, 7])
  assert.equal(got.type, "image/png")
  assert.deepEqual(f.calls.gets, [[V1, X], [V2, X]])
  assert.deepEqual(f.calls.allowed, [[V1], [V2]], "the reader may ask only the vault being read")
  cache.sync("note1", [X], [V1, V2])
  await settle()
  assert.equal(f.calls.gets.length, 2, "kept: not read again")
  assert.equal(f.calls.starts, 1, "one warm reader")
})

test("nothing is read without a build: an unknown or malformed hash is just a miss", async () => {
  const { f, cache } = setup([V1])
  assert.equal(await cache.lookup(X, 10), undefined)
  assert.equal(await cache.lookup("nothex", 10), undefined)
  cache.sync("note1", ["nothex"], [V1])
  cache.sync("note1", [X], ["nothex"])
  await settle()
  assert.equal(f.calls.gets.length, 0)
})

test("a lookup waits for a read in flight; a photo no vault has stays a miss", async () => {
  const { cache } = setup([V1], { delayMs: 20 })
  cache.sync("note1", [X], [V1])
  assert.ok(await cache.lookup(X, 1000), "waited for the read")
  const none = setup([])
  none.cache.sync("note1", [X], [V1])
  assert.equal(await none.cache.lookup(X, 1000), undefined)
})

test("served only while a build keeps confirming it, and never past its max age", async () => {
  const { cache, tick } = setup([V1], { limits: { checkTtl: 100, maxAge: 1000 } })
  cache.sync("note1", [X], [V1])
  await cache.lookup(X)
  tick(150)
  assert.equal(cache.get(X), undefined, "unconfirmed for too long")
  cache.sync("note1", [X], [V1])
  assert.ok(cache.get(X), "a fresh build confirms it again, no new read")
  tick(900); cache.sync("note1", [X], [V1]); tick(150)
  assert.equal(cache.get(X), undefined, "past max age")
  assert.equal(cache.stats().photos, 0)
})

test("a deleted or missing post drops its photo at once", async () => {
  const { cache } = setup([V1])
  cache.sync("note1", [X], [V1])
  await cache.lookup(X)
  cache.drop("note1")
  assert.equal(cache.get(X), undefined)
  cache.sync("note2", [Y], [V1])
  await cache.lookup(Y)
  cache.sync("note2", [Y], []) // a deleted post builds with no vaults (fetch.js readDeleted)
  assert.equal(cache.get(Y), undefined)
})

test("a 10063 that stops naming the vault drops the photo; one that names a new vault reads it from there", async () => {
  const { f, cache } = setup([V1, V2])
  cache.sync("note1", [X], [V1])
  await cache.lookup(X)
  cache.sync("note1", [X], [V2])
  assert.equal(cache.get(X), undefined, "the vault it came from is no longer named")
  assert.ok(await cache.lookup(X), "read again from the vault now named")
  assert.deepEqual(f.calls.gets.at(-1), [V2, X])
})

test("a photo the post no longer has is dropped; another post with the same photo keeps it", async () => {
  const { cache } = setup([V1])
  cache.sync("note1", [X], [V1])
  cache.sync("note2", [X], [V1])
  await cache.lookup(X)
  cache.sync("note1", [Y], [V1])
  assert.ok(cache.get(X), "note2 still vouches for it")
  cache.drop("note2")
  assert.equal(cache.get(X), undefined)
})

test("a post dropped while its photo reads keeps nothing", async () => {
  const { cache } = setup([V1], { delayMs: 20 })
  cache.sync("note1", [X], [V1])
  cache.drop("note1")
  await new Promise(r => setTimeout(r, 40))
  assert.equal(cache.stats().photos, 0)
})

test("size caps: a photo over the per-photo cap isn't kept; the total cap evicts the oldest", async () => {
  const big = setup([V1], { size: 10, limits: { photoBytes: 5 } })
  big.cache.sync("note1", [X], [V1])
  assert.equal(await big.cache.lookup(X), undefined)

  const { cache } = setup([V1], { size: 4, limits: { totalBytes: 10 } })
  const xs = ["a1", "b2", "c3"].map(s => s.repeat(32))
  for (const [i, x] of xs.entries()) { cache.sync(`n${i}`, [x], [V1]); await cache.lookup(x) }
  assert.equal(cache.get(xs[0]), undefined, "the oldest went")
  assert.ok(cache.get(xs[1]) && cache.get(xs[2]))
  assert.equal(cache.stats().bytes, 8)
})

test("reads queue a couple at a time and the queue is capped", async () => {
  const { f, cache } = setup([V1], { delayMs: 10, limits: { reads: 2, queued: 3 } })
  const xs = Array.from({ length: 6 }, (_, i) => String(i + 1).repeat(64))
  xs.forEach((x, i) => cache.sync(`n${i}`, [x], [V1]))
  assert.equal(cache.stats().running, 2)
  await new Promise(r => setTimeout(r, 60))
  assert.equal(f.calls.gets.length, 5, "two running and three queued; the sixth was not taken")
})
