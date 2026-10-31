// Discover (net/discover.js): the extended network as the iPhone ranks it (ContactManager.rankExtendedNetwork), and its
// notes read from the relays into memory. Made-up pubkeys and a mocked query only: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { extendedNetwork, discoverNetwork, fetchDiscover, DISCOVER_MAX } from "../src/net/discover.js"
import { fromHaven } from "../src/net/feeds.js"

const pk = n => n.toString(16).padStart(64, "0")
const ME = pk(1), F1 = pk(2), F2 = pk(3), F3 = pk(4), X = pk(10), Y = pk(11), Z = pk(12)
const list = (...ps) => ({ kind: 3, tags: ps.map(p => ["p", p]) })

test("the network is who the follows follow, most-followed first, without me, my follows, junk or repeats", () => {
  const lists = new Map([[F1, list(X, Y, ME, F2, "nothex", Y)], [F2, list(Y, Z)], [F3, list(Y, X)]])
  assert.deepEqual(extendedNetwork(ME, [F1, F2, F3], lists), [Y, X, Z])
})

test("blocked people are left out, and nobody is reached through a blocked follow", () => {
  const lists = new Map([[F1, list(X, Y)], [F2, list(Z)]])
  assert.deepEqual(extendedNetwork(ME, [F1, F2], lists, { blocked: new Set([F2, Y]) }), [X])
})

test("the network stops at the iPhone's 500, ties by pubkey", () => {
  const many = Array.from({ length: 600 }, (_, i) => pk(1000 + i))
  const net = extendedNetwork(ME, [F1], new Map([[F1, list(...[...many].reverse())]]))
  assert.equal(DISCOVER_MAX, 500)
  assert.equal(net.length, 500)
  assert.deepEqual(net.slice(0, 2), [many[0], many[1]])
})

test("no follows means no network, and no list is asked for", async () => {
  let asked = 0
  assert.deepEqual(await discoverNetwork(ME, [], { lists: async () => { asked++; return new Map() } }), [])
  assert.equal(asked, 0)
  assert.deepEqual(await discoverNetwork(ME, [F1], { lists: async () => new Map([[F1, list(X)]]) }), [X])
})

test("a page asks for the network's notes in chunks, keeps only theirs, newest first, once each", async () => {
  const network = Array.from({ length: 300 }, (_, i) => pk(5000 + i))
  const filters = []
  const query = async (relays, f) => {
    filters.push(f)
    return [
      { id: "a", kind: 1, pubkey: f.authors[0], created_at: 10 },
      { id: "b", kind: 1, pubkey: network[0], created_at: 30 },
      { id: "c", kind: 1, pubkey: X, created_at: 50 }, // not in the network
      { id: "d", kind: 7, pubkey: network[1], created_at: 40 }, // not a feed kind
    ]
  }
  const notes = await fetchDiscover(network, ["wss://r"], { limit: 100, until: 99, query })
  assert.deepEqual(filters.map(f => f.authors.length), [250, 50])
  assert.ok(filters.every(f => f.until === 99 && f.limit === 100 && f.kinds.includes(1)))
  assert.deepEqual(notes.map(n => n.id), ["b", "a"])
  assert.deepEqual(await fetchDiscover([], ["wss://r"], { query: () => assert.fail("asked") }), [])
})

test("Discover's notes are strangers': not read from Haven /feed", () => {
  assert.equal(fromHaven("discovery"), false)
})
