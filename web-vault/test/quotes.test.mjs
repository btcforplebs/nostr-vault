// Quoted notes (nostr:nevent / note / naddr): the reference is parsed, the note comes from Haven /feed first,
// then the relays plus the reference's own hints; what the network returns is signature-checked and written
// into Haven, and a second ask for the same note hits neither again.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { noteEncode, neventEncode, naddrEncode, nprofileEncode, npubEncode } from "nostr-tools/nip19"

const sk = generateSecretKey(), pk = getPublicKey(sk)
const note = (content, at = 100, tags = []) => finalizeEvent({ kind: 1, created_at: at, tags, content }, sk)
const article = (d, title, at) => finalizeEvent({ kind: 30023, created_at: at, tags: [["d", d], ["title", title]], content: "body" }, sk)

// Haven /feed as quotes.js sees it: ids, kinds+authors+#d, and the #e lookup repostedNote() makes.
function fakeVault(events = []) {
  const stored = [...events]
  return {
    stored,
    feed: {
      async query(f) {
        return stored.filter(ev =>
          (!f.ids || f.ids.includes(ev.id)) && (!f.kinds || f.kinds.includes(ev.kind)) && (!f.authors || f.authors.includes(ev.pubkey)) &&
          (!f["#d"] || ev.tags.some(t => t[0] === "d" && f["#d"].includes(t[1]))) && (!f["#e"] || ev.tags.some(t => t[0] === "e" && f["#e"].includes(t[1]))))
      },
      async event(ev) { stored.push(ev); return { ok: true } },
    },
  }
}
let n = 0
const load = () => import(`../src/net/quotes.js?reload=${n++}`)
const never = async () => { throw new Error("network used") }

test("parseRef: note, nevent (with hints), naddr, npub, nprofile, hex; junk is null", async () => {
  const { parseRef } = await load()
  const id = note("x").id
  assert.deepEqual(parseRef(noteEncode(id)), { type: "note", id, relays: [] })
  assert.deepEqual(parseRef(neventEncode({ id, relays: ["wss://r.example", "http://not-a-relay"] })), { type: "note", id, relays: ["wss://r.example"] })
  assert.deepEqual(parseRef(naddrEncode({ kind: 30023, pubkey: pk, identifier: "p1", relays: [] })), { type: "addr", kind: 30023, pubkey: pk, d: "p1", relays: [] })
  assert.deepEqual(parseRef(npubEncode(pk)), { type: "profile", pubkey: pk, relays: [] })
  assert.deepEqual(parseRef(nprofileEncode({ pubkey: pk, relays: ["wss://r.example"] })), { type: "profile", pubkey: pk, relays: ["wss://r.example"] })
  assert.deepEqual(parseRef(pk), { type: "profile", pubkey: pk, relays: [] })
  assert.equal(parseRef("nonsense"), null)
  assert.equal(parseRef("npub1qqqqqqqq"), null)
})

test("a note in Haven is read from there and the network is not asked", async () => {
  const { fetchQuote, getQuote, quoteKey } = await load()
  const ev = note("stored")
  const q = { type: "note", id: ev.id, relays: [] }
  const got = await fetchQuote(q, { vault: fakeVault([ev]), relays: ["wss://a"], query: never })
  assert.equal(got.id, ev.id)
  assert.equal(getQuote(quoteKey(q)).id, ev.id)
})

test("a note only carried by a repost in Haven is found through the repost", async () => {
  const { fetchQuote } = await load()
  const inner = note("reposted")
  const repost = finalizeEvent({ kind: 6, created_at: 200, tags: [["e", inner.id], ["p", pk]], content: JSON.stringify(inner) }, sk)
  const got = await fetchQuote({ type: "note", id: inner.id, relays: [] }, { vault: fakeVault([repost]), relays: ["wss://a"], query: never })
  assert.equal(got.id, inner.id)
})

test("a note not in Haven comes from the relays plus the reference's hints, is verified, and is written into Haven", async () => {
  const { fetchQuote } = await load()
  const ev = note("remote")
  const vault = fakeVault()
  const asked = []
  const query = async (relays, f) => { asked.push({ relays, f }); return [ev] }
  const got = await fetchQuote({ type: "note", id: ev.id, relays: ["wss://hint"] }, { vault, relays: ["wss://a", "wss://hint"], query })
  assert.equal(got.id, ev.id)
  assert.deepEqual(asked, [{ relays: ["wss://a", "wss://hint"], f: { ids: [ev.id] } }])
  assert.equal(vault.stored.length, 1, "written into Haven")
  assert.equal(got.verified, undefined, "a plain copy, not the relay's object")
})

test("a forged note from a relay is not shown and not stored", async () => {
  const { fetchQuote } = await load()
  const ev = { ...note("real"), content: "tampered" }
  const vault = fakeVault()
  const got = await fetchQuote({ type: "note", id: ev.id, relays: [] }, { vault, relays: ["wss://a"], query: async () => [ev] })
  assert.equal(got, null)
  assert.equal(vault.stored.length, 0)
})

test("a relay answering with a different note than asked for is ignored", async () => {
  const { fetchQuote } = await load()
  const asked = note("asked"), other = note("other")
  const got = await fetchQuote({ type: "note", id: asked.id, relays: [] }, { vault: fakeVault(), relays: ["wss://a"], query: async () => [other] })
  assert.equal(got, null)
})

test("a relay answering with the asked note plus a newer unrelated one still gives the asked note", async () => {
  const { fetchQuote } = await load()
  const asked = note("asked", 100), extra = note("extra", 200)
  const vault = fakeVault()
  const got = await fetchQuote({ type: "note", id: asked.id, relays: [] }, { vault, relays: ["wss://a"], query: async () => [extra, asked] })
  assert.equal(got.id, asked.id)
  assert.deepEqual(vault.stored.map(e => e.id), [asked.id])
})

test("an naddr quote never shows another key's article with the same d tag, even a newer signed one", async () => {
  const { fetchQuote } = await load()
  const other = generateSecretKey()
  const mine = article("p1", "Mine", 100)
  const forged = finalizeEvent({ kind: 30023, created_at: 200, tags: [["d", "p1"], ["title", "Theirs"]], content: "body" }, other)
  const q = { type: "addr", kind: 30023, pubkey: pk, d: "p1", relays: [] }
  const vault = fakeVault()
  const got = await fetchQuote(q, { vault, relays: ["wss://a"], query: async () => [forged, mine] })
  assert.equal(got.id, mine.id)
  assert.deepEqual(vault.stored.map(e => e.id), [mine.id], "only the matching article is written into Haven")

  const onlyForged = await fetchQuote({ ...q, d: "p2" }, { vault: fakeVault(), relays: ["wss://a"], query: async () => [finalizeEvent({ kind: 30023, created_at: 300, tags: [["d", "p2"]], content: "" }, other)] })
  assert.equal(onlyForged, null)
})

test("an naddr answer with the right key but another kind or d tag is ignored", async () => {
  const { fetchQuote, matches } = await load()
  const q = { type: "addr", kind: 30023, pubkey: pk, d: "p1", relays: [] }
  const wrongD = article("p9", "Wrong d", 100)
  const wrongKind = finalizeEvent({ kind: 30024, created_at: 100, tags: [["d", "p1"]], content: "" }, sk)
  assert.equal(matches(q, wrongD), false)
  assert.equal(matches(q, wrongKind), false)
  assert.equal(matches(q, article("p1", "Right", 100)), true)
  assert.equal(await fetchQuote(q, { vault: fakeVault(), relays: ["wss://a"], query: async () => [wrongD, wrongKind] }), null)
})

test("a note nowhere is null, remembered, and asked for only once", async () => {
  const { fetchQuote, getQuote, hasQuote, quoteKey } = await load()
  const q = { type: "note", id: note("gone").id, relays: [] }
  let calls = 0
  const query = async () => { calls++; return [] }
  const vault = fakeVault()
  assert.equal(await fetchQuote(q, { vault, relays: ["wss://a"], query }), null)
  assert.equal(await fetchQuote(q, { vault, relays: ["wss://a"], query }), null)
  assert.equal(calls, 1)
  assert.equal(hasQuote(quoteKey(q)), true)
  assert.equal(getQuote(quoteKey(q)), null)
})

test("two asks for the same note while the first is in flight share one fetch", async () => {
  const { fetchQuote } = await load()
  const ev = note("shared")
  let calls = 0
  const query = () => new Promise(r => { calls++; setTimeout(() => r([ev]), 10) })
  const q = { type: "note", id: ev.id, relays: [] }
  const opts = { vault: fakeVault(), relays: ["wss://a"], query }
  const [a, b] = await Promise.all([fetchQuote(q, opts), fetchQuote(q, opts)])
  assert.equal(a.id, ev.id); assert.equal(b.id, ev.id)
  assert.equal(calls, 1)
})

test("with no relays and nothing in Haven the answer is null without a network call", async () => {
  const { fetchQuote } = await load()
  assert.equal(await fetchQuote({ type: "note", id: note("x").id, relays: [] }, { vault: fakeVault(), relays: [], query: never }), null)
})

test("an naddr is looked up by kind, author and d, and the newest version wins", async () => {
  const { fetchQuote, quoteKey } = await load()
  const old = article("p1", "Old title", 100), fresh = article("p1", "New title", 200)
  const q = { type: "addr", kind: 30023, pubkey: pk, d: "p1", relays: [] }
  assert.equal(quoteKey(q), `30023:${pk}:p1`)
  const asked = []
  const got = await fetchQuote(q, { vault: fakeVault(), relays: ["wss://a"], query: async (r, f) => { asked.push(f); return [old, fresh] } })
  assert.equal(got.id, fresh.id)
  assert.deepEqual(asked, [{ kinds: [30023], authors: [pk], "#d": ["p1"] }])
  const local = await fetchQuote({ ...q, d: "p2" }, { vault: fakeVault([article("p2", "Local", 1)]), relays: ["wss://a"], query: never })
  assert.equal(local.tags.find(t => t[0] === "title")[1], "Local")
})

test("listeners hear a quote land and the vault being registered", async () => {
  const { fetchQuote, onQuotes, setQuoteSource, quoteSource } = await load()
  let heard = 0
  const off = onQuotes(() => heard++)
  const src = { vault: fakeVault(), relays: [] }
  setQuoteSource(src)
  assert.equal(quoteSource(), src)
  assert.equal(heard, 1)
  await fetchQuote({ type: "note", id: note("y").id, relays: [] }, { vault: fakeVault(), relays: [], query: never })
  assert.equal(heard, 2)
  off()
  await fetchQuote({ type: "note", id: note("z").id, relays: [] }, { vault: fakeVault(), relays: [], query: never })
  assert.equal(heard, 2)
})

test("a tap on a quoted card goes to that note's thread", async () => {
  const { quoteHash } = await load()
  const ev = note("t")
  assert.equal(quoteHash(ev), `#/thread/${ev.id}`)
})
