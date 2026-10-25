// The Feed's picker: what each feed asks the relays for, what is remembered, and that strangers' notes stay in memory.
import test from "node:test"
import assert from "node:assert/strict"
import { FEEDS, feedList, loadChoice, saveChoice, normalizeTag, feedFilter, fetchStrangerFeed, mergePage, statusGate, noteAuthors, heldNotes, holdNotes, feedKey, fromHaven } from "../src/net/feeds.js"
import { getProfile, fetchProfiles } from "../src/net/profiles.js"
import { visibleNotes } from "../src/net/blocks.js"

const memStorage = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }
const A = "a".repeat(64), B = "b".repeat(64)

test("the picker offers Following, Global, Hashtag, Popular and Media, in the iPhone's order", () => {
  assert.deepEqual(FEEDS.map(f => f.label), ["Following", "Global", "Hashtag", "Popular", "Media"])
})

test("readers take their iPhone FeedMode place in the picker, and a saved reader is remembered", () => {
  const readers = [{ id: "music", label: "Music" }, { id: "articles", label: "Articles" }, { id: "live", label: "Live" }]
  assert.deepEqual(feedList(readers).map(f => f.id), ["following", "global", "hashtag", "popular", "media", "articles", "live", "music"])
  assert.deepEqual(feedList().map(f => f.id), FEEDS.map(f => f.id))
  const s = memStorage()
  saveChoice({ mode: "articles", tag: "" }, s)
  assert.equal(loadChoice(s, feedList(readers)).mode, "articles")
  assert.equal(loadChoice(s).mode, "following")
})

test("only Following and Media are read from Haven /feed", () => {
  assert.deepEqual(FEEDS.filter(f => fromHaven(f.id)).map(f => f.id), ["following", "media"])
})

test("the last choice is remembered; nothing or junk saved means Following", () => {
  const s = memStorage()
  assert.deepEqual(loadChoice(s), { mode: "following", tag: "" })
  saveChoice({ mode: "hashtag", tag: "#Bitcoin" }, s)
  assert.deepEqual(loadChoice(s), { mode: "hashtag", tag: "bitcoin" })
  s.setItem("nv-feed", JSON.stringify({ mode: "reels" }))
  assert.equal(loadChoice(s).mode, "following")
  s.setItem("nv-feed", "{not json")
  assert.deepEqual(loadChoice(s), { mode: "following", tag: "" })
})

test("a hashtag is one lowercased word without its #", () => {
  assert.equal(normalizeTag("  ##Nostr "), "nostr")
  assert.equal(normalizeTag("two words"), "")
  assert.equal(normalizeTag("#"), "")
  assert.equal(normalizeTag(undefined), "")
})

test("each feed's relay filter", () => {
  assert.deepEqual(feedFilter({ mode: "global" }), { kinds: [1, 6, 30023, 1068, 9802, 1111, 16, 20], limit: 100 }) // the iPhone's timelineKinds
  assert.deepEqual(feedFilter({ mode: "hashtag", tag: "art" }, { until: 50, limit: 20 }), { kinds: [1], "#t": ["art"], limit: 20, until: 50 })
  assert.equal(feedFilter({ mode: "hashtag", tag: "" }), null)
  assert.equal(feedFilter({ mode: "following" }), null, "Following reads Haven, not this")
})

test("a stranger feed comes from the network, newest first, once each, and nothing is stored", async () => {
  const asked = []
  const evs = [
    { id: "1", kind: 1, pubkey: A, created_at: 10 },
    { id: "2", kind: 1, pubkey: B, created_at: 30 },
    { id: "1", kind: 1, pubkey: A, created_at: 10 },
    { id: "3", kind: 7, pubkey: B, created_at: 40 }, // a relay that ignores kinds
  ]
  const got = await fetchStrangerFeed({ mode: "hashtag", tag: "art" }, ["wss://r", "wss://r"], { query: async (r, f) => { asked.push([r, f]); return evs } })
  assert.deepEqual(got.map(e => e.id), ["2", "1"])
  assert.deepEqual(asked, [[["wss://r"], { kinds: [1], "#t": ["art"], limit: 100 }]])
  assert.deepEqual(await fetchStrangerFeed({ mode: "hashtag", tag: "" }, ["wss://r"], { query: async () => assert.fail("no query") }), [])
})

test("older pages add only notes not already shown", () => {
  assert.deepEqual(mergePage([{ id: "1" }, { id: "2" }], [{ id: "2" }, { id: "3" }]).map(e => e.id), ["1", "2", "3"])
})

test("loaded stranger feeds are held per feed, in memory", () => {
  assert.equal(heldNotes({ mode: "hashtag", tag: "zzz" }), null)
  holdNotes({ mode: "hashtag", tag: "zzz" }, [{ id: "x" }])
  assert.deepEqual(heldNotes({ mode: "hashtag", tag: "zzz" }), [{ id: "x" }])
  assert.equal(heldNotes({ mode: "hashtag", tag: "yyy" }), null)
  assert.notEqual(feedKey({ mode: "hashtag", tag: "a" }), feedKey({ mode: "hashtag", tag: "b" }))
})

test("strangers' profiles go to memory, not Haven, once each, in one batch", async () => {
  const pk = "c".repeat(64), pk2 = "d".repeat(64)
  const writes = [], asked = []
  const vault = { feed: { query: async () => [], event: async ev => writes.push(ev) } }
  const kind0 = (p, name) => ({ kind: 0, pubkey: p, created_at: 1, content: JSON.stringify({ name }) })
  const query = async (r, f) => { asked.push([r.join(), f.authors]); await new Promise(r => setTimeout(r, 5)); return [kind0(pk, "Stranger"), kind0(pk2, "Other")] }
  // Two loads at once (a page re-render): the second finds the first in flight and doesn't ask again.
  await Promise.all([fetchProfiles(vault, [pk, pk2, pk], ["wss://r"], { save: false, query }), fetchProfiles(vault, [pk], ["wss://r"], { save: false, query })])
  assert.equal(getProfile(pk).name, "Stranger")
  assert.equal(getProfile(pk2).name, "Other")
  // Each relay is asked on its own (its answer is drawn as it lands), once, for both.
  assert.ok(asked.length > 0)
  for (const [, authors] of asked) assert.deepEqual(authors, [pk, pk2])
  assert.equal(new Set(asked.map(([url]) => url)).size, asked.length, "no relay asked twice")
  assert.deepEqual(writes, [], "nothing written to Haven /feed")
  await fetchProfiles(vault, [pk], ["wss://r"], { save: false, query: async () => assert.fail("already known") })
})

test("authors include the person inside a repost", () => {
  assert.deepEqual(noteAuthors([{ kind: 1, pubkey: A }, { kind: 6, pubkey: A, content: JSON.stringify({ pubkey: B }) }, { kind: 6, pubkey: B, content: "x" }]), [A, A, B, B])
})

test("blocks apply to stranger feeds too", () => {
  const notes = [{ id: "1", kind: 1, pubkey: A }, { id: "2", kind: 1, pubkey: B }]
  assert.deepEqual(visibleNotes(notes, new Set([B])).map(e => e.id), ["1"])
})

test("a status line set by older work goes quiet once the feed is switched", () => {
  const seq = { current: 0 }, said = []
  const following = statusGate(seq, s => said.push(s))
  following("Syncing 3/10 follows")
  seq.current++ // picked Global
  const global = statusGate(seq, s => said.push(s))
  following("Up to date")
  global("Loading…")
  assert.deepEqual(said, ["Syncing 3/10 follows", "Loading…"])
})
