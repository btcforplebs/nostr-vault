// Media's Following / Global choice (net/feeds.js), as the iPhone's FeedService.mediaFeedMode: Following reads Haven
// /feed, Global reads Global's trust-screened notes into memory. Made-up pubkeys and a mocked query: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { loadMediaScope, saveMediaScope, withScope, readsHaven, globalLike, feedKey, feedFilter, fetchStrangerFeed } from "../src/net/feeds.js"

const memStorage = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }
const A = "a".repeat(64), S = "5".repeat(64)

test("Media opens on Following until Global is picked, and remembers it", () => {
  const s = memStorage()
  assert.equal(loadMediaScope(s), "following")
  assert.deepEqual(withScope({ mode: "media", tag: "" }, s), { mode: "media", tag: "", scope: "following" })
  saveMediaScope("global", s)
  assert.deepEqual(withScope({ mode: "media", tag: "" }, s), { mode: "media", tag: "", scope: "global" })
  assert.equal(withScope({ mode: "media", tag: "", scope: "following" }, s).scope, "following")
  assert.deepEqual(withScope({ mode: "global", tag: "" }, s), { mode: "global", tag: "" })
  s.setItem("nv-media-scope", "junk")
  assert.equal(loadMediaScope(s), "following")
})

test("Media on Following reads Haven; Media on Global is a trust-screened stranger feed with its own notes", () => {
  const mf = { mode: "media", tag: "", scope: "following" }, mg = { mode: "media", tag: "", scope: "global" }
  assert.equal(readsHaven(mf), true)
  assert.equal(readsHaven(mg), false)
  assert.equal(readsHaven({ mode: "following" }), true)
  assert.equal(globalLike(mg), true)
  assert.equal(globalLike(mf), false)
  assert.equal(feedKey(mg), "media:global")
  assert.notEqual(feedKey(mg), feedKey({ mode: "global", tag: "" }))
  assert.deepEqual(feedFilter(mg, { limit: 300 }).limit, 300)
  assert.equal(feedFilter(mf), null)
})

test("Media on Global asks as Global does and keeps only what Global shows; no web shows nothing", async () => {
  const mg = { mode: "media", tag: "", scope: "global" }
  const asked = []
  const query = async (r, f) => { asked.push(f); return [{ id: "1", kind: 1, pubkey: A, created_at: 5, tags: [], content: "https://x/a.jpg" }, { id: "2", kind: 1, pubkey: S, created_at: 6, tags: [], content: "https://x/b.jpg" }] }
  const notes = await fetchStrangerFeed(mg, ["wss://r"], { limit: 300, trust: new Set([A]), query })
  assert.equal(asked.length, 2) // trusted authors, then open
  assert.deepEqual(asked[0].authors, [A])
  assert.deepEqual(notes.map(n => n.id), ["1"])
  assert.deepEqual(await fetchStrangerFeed(mg, ["wss://r"], { trust: null, query: () => assert.fail("asked") }), [])
})
