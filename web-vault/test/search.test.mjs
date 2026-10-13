// Search: what the box holds decides whether to search (NIP-50) or open one profile directly.
import test from "node:test"
import assert from "node:assert/strict"
import { npubEncode, nprofileEncode } from "nostr-tools/nip19"
import { parseQuery, dedupePeople, sortNotes } from "../src/net/search.js"

const PK = "b7ed68b062de6b4a12e51fd5285c1e1e0ed0e5128cda93ab11b4150b55ed32fc" // Gigi
const NPUB = npubEncode(PK)

test("an empty or blank box is no query", () => {
  assert.deepEqual(parseQuery(""), { type: "empty" })
  assert.deepEqual(parseQuery("   \n"), { type: "empty" })
  assert.deepEqual(parseQuery(undefined), { type: "empty" })
})

test("words are searched, trimmed", () => {
  assert.deepEqual(parseQuery("  bitcoin is time "), { type: "search", text: "bitcoin is time" })
})

test("an npub opens that profile, with or without nostr: and in any case", () => {
  const want = { type: "profile", pubkey: PK, relays: [] }
  assert.deepEqual(parseQuery(NPUB), want)
  assert.deepEqual(parseQuery(` nostr:${NPUB} `), want)
  assert.deepEqual(parseQuery(NPUB.toUpperCase()), want)
})

test("an nprofile opens that profile and keeps its relay hints", () => {
  const nprofile = nprofileEncode({ pubkey: PK, relays: ["wss://relay.example.com"] })
  assert.deepEqual(parseQuery(nprofile), { type: "profile", pubkey: PK, relays: ["wss://relay.example.com"] })
})

test("a 64-char hex pubkey opens that profile, lowercased", () => {
  assert.deepEqual(parseQuery(PK.toUpperCase()), { type: "profile", pubkey: PK, relays: [] })
})

test("a broken npub or short hex is searched as text, not opened", () => {
  const broken = NPUB.slice(0, -1) + (NPUB.endsWith("q") ? "p" : "q") // bad checksum
  assert.deepEqual(parseQuery(broken), { type: "search", text: broken })
  assert.deepEqual(parseQuery("npub"), { type: "search", text: "npub" })
  assert.deepEqual(parseQuery(PK.slice(0, 63)), { type: "search", text: PK.slice(0, 63) })
})

test("people: one per pubkey, newest kind 0 wins, relay rank kept, other kinds dropped", () => {
  const evs = [
    { kind: 0, pubkey: "a", created_at: 1, content: "old a" },
    { kind: 0, pubkey: "b", created_at: 5, content: "b" },
    { kind: 1, pubkey: "c", created_at: 9, content: "not a profile" },
    { kind: 0, pubkey: "a", created_at: 3, content: "new a" },
  ]
  assert.deepEqual(dedupePeople(evs).map(e => e.content), ["new a", "b"])
})

test("notes: one per id, newest first, kind 1 only", () => {
  const evs = [
    { kind: 1, id: "x", created_at: 1 },
    { kind: 1, id: "y", created_at: 3 },
    { kind: 1, id: "x", created_at: 1 },
    { kind: 0, id: "z", created_at: 9 },
  ]
  assert.deepEqual(sortNotes(evs).map(e => e.id), ["y", "x"])
})
