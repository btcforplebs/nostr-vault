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

// --- iPhone parity: notes, hashtags, filter, ranking, Recent (Views/Search) ---
import { noteEncode, neventEncode } from "nostr-tools/nip19"
import { hashtagOf, shapeResults, hashtagsIn, linksIn, loadRecent, saveRecent, clearRecent, trendingTags, activePosters, filterCaption, NO_FILTER } from "../src/net/search.js"

const ID = "a".repeat(64)
const ME = "1".repeat(64), FRIEND = "2".repeat(64), STRANGER = "3".repeat(64)

test("a note1 or nevent opens that note, keeping nevent relay hints", () => {
  assert.deepEqual(parseQuery(noteEncode(ID)), { type: "note", id: ID, relays: [] })
  assert.deepEqual(parseQuery(`nostr:${neventEncode({ id: ID, relays: ["wss://r.example"] })}`), { type: "note", id: ID, relays: ["wss://r.example"] })
})

test("#tag on its own names a hashtag feed; words or a lone # do not", () => {
  assert.equal(hashtagOf(" #Bitcoin "), "bitcoin")
  assert.equal(hashtagOf("#b"), null)
  assert.equal(hashtagOf("#bitcoin news"), null)
  assert.equal(hashtagOf("bitcoin"), null)
  assert.equal(hashtagOf("#a#b"), null)
})

const note = (id, pubkey, created_at, content = "") => ({ id, pubkey, created_at, kind: 1, content, tags: [] })

test("results rank you, then people you follow, then everyone, keeping order inside each", () => {
  const notes = [note("n1", STRANGER, 50), note("n2", FRIEND, 40), note("n3", ME, 30), note("n4", FRIEND, 20)]
  const r = shapeResults({ people: [STRANGER, FRIEND, ME], notes }, "x", { me: ME, follows: [FRIEND] })
  assert.deepEqual(r.people, [ME, FRIEND, STRANGER])
  assert.deepEqual(r.notes.map(n => n.id), ["n3", "n2", "n4", "n1"])
})

test("Who and When narrow people and notes; hashtags and links follow the filter", () => {
  const now = 1_000_000
  const notes = [note("old", FRIEND, now - 8 * 86400, "#nostr https://a.example/x"), note("new", FRIEND, now - 3600, "#nostrich"), note("s", STRANGER, now, "#nostrudel")]
  const r = shapeResults({ people: [FRIEND, STRANGER], notes }, "nostr", { me: ME, follows: [FRIEND], filter: { who: "follows", when: "week" }, now })
  assert.deepEqual(r.people, [FRIEND])
  assert.deepEqual(r.notes.map(n => n.id), ["new"])
  assert.deepEqual(r.hashtags, ["nostrich"])
  assert.deepEqual(r.links, [])
  const you = shapeResults({ people: [FRIEND, ME], notes }, "x", { me: ME, follows: [FRIEND], filter: { who: "you", when: "any" }, now })
  assert.deepEqual(you.people, [ME])
  assert.deepEqual(you.notes, [])
})

test("the filter caption reads as the iPhone's, null when off", () => {
  assert.equal(filterCaption(NO_FILTER), null)
  assert.equal(filterCaption({ who: "follows", when: "week" }), "People you follow · Last week")
  assert.equal(filterCaption({ who: "everyone", when: "day" }), "Last 24 hours")
})

test("hashtags containing the query, lowercased and once; links once, titled without the scheme", () => {
  const notes = [note("a", ME, 1, "GM #Bitcoin and #bitcoiners, #zaps https://x.example/p?q=1"), note("b", ME, 1, "#BITCOIN http://x.example/p?q=1 https://x.example/p?q=1")]
  assert.deepEqual(hashtagsIn(notes, "#bitcoin"), ["bitcoin", "bitcoiners"])
  assert.deepEqual(linksIn(notes), [
    { url: "https://x.example/p?q=1", title: "x.example/p?q=1", noteId: "a" },
    { url: "http://x.example/p?q=1", title: "x.example/p?q=1", noteId: "b" },
  ])
})

function memStore() { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }

test("Recent keeps 8, newest first, one per query whatever the case, 2 characters or more", () => {
  const s = memStore()
  for (let i = 0; i < 10; i++) saveRecent(s, `q${i}`)
  assert.deepEqual(loadRecent(s), ["q9", "q8", "q7", "q6", "q5", "q4", "q3", "q2"])
  saveRecent(s, "Q5")
  assert.deepEqual(loadRecent(s).slice(0, 2), ["Q5", "q9"])
  assert.equal(loadRecent(s).length, 8)
  saveRecent(s, "x")
  assert.equal(loadRecent(s)[0], "Q5")
  assert.deepEqual(clearRecent(s), [])
  assert.deepEqual(loadRecent(s), [])
  assert.deepEqual(loadRecent({ getItem: () => "{bad" }), [])
})

test("Trending counts t tags; Active in your feed leaves out you and blocked people", () => {
  const t = (pubkey, ...tags) => ({ pubkey, tags: tags.map(x => ["t", x]) })
  assert.deepEqual(trendingTags([t(ME, "Nostr", "zaps"), t(FRIEND, "nostr"), t(STRANGER, "art")]).slice(0, 1), ["nostr"])
  const notes = [t(FRIEND), t(FRIEND), t(STRANGER), t(ME), t(ME), t(ME)]
  assert.deepEqual(activePosters(notes, ME), [FRIEND, STRANGER])
  assert.deepEqual(activePosters(notes, ME, new Set([FRIEND])), [STRANGER])
})
