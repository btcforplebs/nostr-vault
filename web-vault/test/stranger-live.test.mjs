// What Global, Hashtag and Discover keep open for their New posts pill (net/feeds.js liveFilters / liveKeeps), as the
// iPhone keeps their feed REQ open. Made-up pubkeys: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { liveFilters, liveKeeps } from "../src/net/feeds.js"

const pk = n => n.toString(16).padStart(64, "0")
const T = pk(1), S = pk(2)
const note = (pubkey, o = {}) => ({ id: "x", pubkey, kind: 1, created_at: 5, tags: [], content: "hi", ...o })

test("Global asks as its pages do: trusted authors, then open; with no web it asks nothing", () => {
  const fs = liveFilters({ mode: "global", tag: "" }, { trust: new Set([T]) })
  assert.equal(fs.length, 2)
  assert.deepEqual(fs[0].authors, [T])
  assert.equal(fs[1].authors, undefined)
  assert.ok(fs.every(f => f.kinds.includes(1) && !("limit" in f) && !("since" in f)))
  assert.deepEqual(liveFilters({ mode: "global", tag: "" }, { trust: null }), [])
  assert.equal(liveFilters({ mode: "media", tag: "", scope: "global" }, { trust: new Set([T]) }).length, 2)
})

test("Global keeps only what its pages keep", () => {
  const trust = new Set([T])
  assert.equal(liveKeeps({ mode: "global" }, note(T), { trust }), true)
  assert.equal(liveKeeps({ mode: "global" }, note(S), { trust }), false)
  assert.equal(liveKeeps({ mode: "global" }, note(T, { kind: 7 }), { trust }), false)
  assert.equal(liveKeeps({ mode: "global" }, note(T), { trust: null }), false)
})

test("Hashtag asks for its tag and keeps tagged notes only", () => {
  assert.deepEqual(liveFilters({ mode: "hashtag", tag: "nostr" }), [{ kinds: [1], "#t": ["nostr"] }])
  assert.deepEqual(liveFilters({ mode: "hashtag", tag: "" }), [])
  assert.equal(liveKeeps({ mode: "hashtag", tag: "nostr" }, note(S, { tags: [["t", "Nostr"]] })), true)
  assert.equal(liveKeeps({ mode: "hashtag", tag: "nostr" }, note(S, { tags: [["t", "bitcoin"]] })), false)
})

test("Discover asks for its network in REQs of 250 and keeps only theirs", () => {
  const network = Array.from({ length: 260 }, (_, i) => pk(100 + i))
  assert.deepEqual(liveFilters({ mode: "discovery" }, { network }).map(f => f.authors.length), [250, 10])
  assert.deepEqual(liveFilters({ mode: "discovery" }, { network: [] }), [])
  assert.equal(liveKeeps({ mode: "discovery" }, note(network[3]), { network }), true)
  assert.equal(liveKeeps({ mode: "discovery" }, note(S), { network }), false)
})

test("Popular, Following and the readers keep nothing open here", () => {
  for (const mode of ["popular", "following", "articles"]) assert.deepEqual(liveFilters({ mode, tag: "" }, { trust: new Set([T]), network: [T] }), [])
})
