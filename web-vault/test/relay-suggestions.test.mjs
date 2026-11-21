// Settings › Relays › Recommended: follows' write relays ranked by how many follows use each, and the fastest
// well-known relays (iPhone RelayMatrix.followSuggestions / fastest, RelayMatrixTests). No network.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { followSuggestions, followsWithRelayLists, fastest, outboxFrom, writeRelaysOf, followOutboxes, WELL_KNOWN_RELAYS } from "../src/net/relay-suggestions.js"

const outbox = obj => new Map(Object.entries(obj))

test("follows' write relays rank by how many follows use each, ties by address", () => {
  const got = followSuggestions({
    follows: ["a", "b", "c", "d"],
    outbox: outbox({
      a: ["wss://nos.lol", "wss://relay.zeta.com", "wss://relay.alpha.com"],
      b: ["wss://nos.lol/", "wss://relay.zeta.com", "wss://relay.alpha.com"],
      c: ["wss://NOS.lol", "wss://relay.alpha.com"],
      d: ["wss://nos.lol"],
    }),
  })
  assert.deepEqual(got, [
    { url: "wss://nos.lol", follows: 4 },
    { url: "wss://relay.alpha.com", follows: 3 },
    { url: "wss://relay.zeta.com", follows: 2 },
  ])
})

test("a follow counts once per relay, and a relay needs two follows", () => {
  const got = followSuggestions({ follows: ["a", "a", "b"], outbox: outbox({ a: ["wss://x.com", "wss://x.com/", "wss://only.com"], b: ["wss://x.com"] }) })
  assert.deepEqual(got, [{ url: "wss://x.com", follows: 2 }])
})

test("yours, Never Connect and relays nobody else can reach are left out; capped at the limit", () => {
  const many = Array.from({ length: 12 }, (_, i) => `wss://r${String(i).padStart(2, "0")}.com`)
  const lists = [...many, "wss://yours.com", "wss://blocked.com", "ws://plain.com", "wss://localhost", "wss://x.onion", "wss://192.168.1.2", "wss://172.20.0.1"]
  const got = followSuggestions({ follows: ["a", "b"], outbox: outbox({ a: lists, b: lists }), taken: ["wss://YOURS.com/"], blocked: u => u === "wss://blocked.com" })
  assert.equal(got.length, 8)
  assert.deepEqual(got.map(s => s.url), many.slice(0, 8))
})

test("followsWithRelayLists counts follows with a known write list", () => {
  assert.equal(followsWithRelayLists(["a", "b", "c", "a"], outbox({ a: ["wss://x.com"], b: [] })), 1)
})

test("fastest: answered only, quickest first, yours and blocked skipped, five at most", () => {
  const ms = { "wss://relay.damus.io": 300, "wss://relay.primal.net": 90, "wss://relay.snort.social": 90, "wss://relay.nostr.bg": 40,
    "wss://nostr.oxtr.dev": 500, "wss://relay.nostr.net": 120, "wss://nostr.bitcoiner.social": 700 }
  assert.deepEqual(fastest(WELL_KNOWN_RELAYS, ms, { taken: ["wss://relay.nostr.bg"], blocked: u => u === "wss://relay.nostr.net" }),
    ["wss://relay.primal.net", "wss://relay.snort.social", "wss://relay.damus.io", "wss://nostr.oxtr.dev", "wss://nostr.bitcoiner.social"])
})

test("the newest 10002 per follow wins; read-only relays aren't write relays", () => {
  const ev = (pubkey, created_at, tags) => ({ kind: 10002, pubkey, created_at, tags })
  const got = outboxFrom([
    ev("a", 1, [["r", "wss://old.com"]]),
    ev("a", 2, [["r", "wss://new.com"], ["r", "wss://in.com", "read"], ["r", "wss://out.com", "write"]]),
    ev("z", 3, [["r", "wss://stranger.com"]]),
  ], ["a"])
  assert.deepEqual([...got], [["a", ["wss://new.com", "wss://out.com"]]])
  assert.deepEqual(writeRelaysOf(undefined), [])
})

test("followOutboxes reads Haven first and asks the network only for the rest", async () => {
  const asked = []
  const vault = { feed: { query: async f => f.authors.includes("a") ? [{ kind: 10002, pubkey: "a", created_at: 1, tags: [["r", "wss://h.com"]] }] : [] } }
  const query = async (relays, f) => { asked.push(f.authors); return [{ kind: 10002, pubkey: "b", created_at: 1, tags: [["r", "wss://n.com"]] }] }
  const got = await followOutboxes({ vault, follows: ["a", "b"], relays: ["wss://read.com"], query })
  assert.deepEqual(asked, [["b"]])
  assert.deepEqual(Object.fromEntries(got), { a: ["wss://h.com"], b: ["wss://n.com"] })
})

test("the well-known list and the section wording match the iPhone's", () => {
  const swift = readFileSync(new URL("../../HavenApp/HavenApp/Models/RelayMatrix.swift", import.meta.url), "utf8")
  for (const url of WELL_KNOWN_RELAYS) assert.ok(swift.includes(`"${url}"`), url)
  const view = readFileSync(new URL("../../HavenApp/HavenApp/Views/RelayMatrixView.swift", import.meta.url), "utf8")
  const jsx = readFileSync(new URL("../src/screens/RelaysRecommended.jsx", import.meta.url), "utf8")
  for (const words of ["Your Follows Write To", "Fastest From This Device", "follows write here", "You already read from the relays your follows use most.",
    "Well-known public relays, timed from here just now.", "Nothing faster to suggest.", "Measuring…"]) {
    assert.ok(view.includes(words) && jsx.includes(words), words)
  }
})
