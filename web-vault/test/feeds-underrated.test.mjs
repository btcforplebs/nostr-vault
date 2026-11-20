// The Underrated feed: Popular turned over, as haven-go feed_underrated.go ranks it. People one step out (your follows
// follow them, you don't), Popular's trusted tally over two days, scored against the author's own usual, and an empty
// answer that says why. Nothing is written to Haven /feed.
import test from "node:test"
import { readFileSync } from "node:fs"
import assert from "node:assert/strict"
import { isBridged, oneStepOut, scoreUnderrated, emptyReason, fetchUnderrated, REASONS, EMPTY_TEXT, WINDOW, PER_AUTHOR, MAX_NOTES, BRIDGE_BOOST, MAX_CANDIDATES } from "../src/net/underrated.js"
import { noteBodies, MIN_REACTORS } from "../src/net/popular.js"
import { REACH_FEEDS, loadReach } from "../src/net/feed-gate.js"

const pk = n => n.toString(16).padStart(64, "0")
const ME = pk(1), F1 = pk(2), F2 = pk(3), F3 = pk(4)
const OUT = pk(10), OUT2 = pk(11), OUT3 = pk(12), FAR = pk(13)
const R = [pk(20), pk(21), pk(22), pk(23), pk(24), pk(25)]
const NOW = 2_000_000
let seq = 1000
const note = (pubkey, extra = {}) => ({ id: pk(seq++), kind: 1, pubkey, created_at: NOW - 3600, tags: [], content: "", ...extra })
const contacts = (who, ...named) => ({ kind: 3, pubkey: who, created_at: 1, tags: named.map(p => ["p", p]) })
const lists = (...evs) => new Map(evs.map(e => [e.pubkey, e]))
/** A tally: note id -> Map(reactor -> weight). */
const votes = entries => new Map(entries.map(([id, rs]) => [id, new Map(rs)]))
const likes = (n, ...who) => [n.id, who.map(w => [w, 1])]

test("a NIP-48 proxy tag with a source is bridged; an empty or short one is not", () => {
  assert.equal(isBridged({ tags: [["proxy", "https://mastodon.example/1", "activitypub"]] }), true)
  assert.equal(isBridged({ tags: [["proxy", "", "activitypub"]] }), false)
  assert.equal(isBridged({ tags: [["proxy", "x"]] }), false)
})

test("one step out: followed by a follow, not you, not a follow; counts follows once each; a blocked follow vouches for nobody", () => {
  const got = oneStepOut(ME, [F1, F2, F3], lists(contacts(F1, OUT, OUT, F2, ME), contacts(F2, OUT, OUT2), contacts(F3, OUT3)), new Set([F3]))
  assert.deepEqual([...got].sort(), [[OUT, 2], [OUT2, 1]])
})

test("only people one step out, at Popular's bar of three, the author's own like left out", () => {
  const reach = new Map([[OUT, 1]])
  const follow = note(F1), stranger = note(FAR), short = note(OUT), selfLift = note(OUT), ok = note(OUT)
  const t = votes([likes(follow, ...R.slice(0, 3)), likes(stranger, ...R.slice(0, 3)), likes(short, R[0], R[1]),
    [selfLift.id, [[OUT, 1], [R[0], 1], [R[1], 1]]], likes(ok, ...R.slice(0, 3))])
  assert.equal(MIN_REACTORS, 3)
  assert.deepEqual(scoreUnderrated([follow, stranger, short, selfLift, ok], t, { reach, now: NOW }).map(n => n.id), [ok.id])
})

test("a quiet author's one good note beats a busy author's usual one with the same likes (lift and posts)", () => {
  const reach = new Map([[OUT, 1], [OUT2, 1]])
  const quiet = note(OUT), busy = note(OUT2), busyOther = note(OUT2)
  const t = votes([likes(quiet, ...R.slice(0, 3)), likes(busy, ...R.slice(0, 3)), likes(busyOther, ...R.slice(0, 6))])
  const posts = new Map([[OUT, 10], [OUT2, 40]])
  const scores = new Map()
  const got = scoreUnderrated([busy, quiet, busyOther], t, { reach, posts, now: NOW, scores })
  const at = n => got.findIndex(g => g.id === n.id)
  assert.ok(at(quiet) >= 0 && at(quiet) < at(busy), "same three likes: the quiet author's note is above the busy one's")
  // quiet: log2(1+3) · (3+1)/(0.3+1) · 1/(1+log2 10) · 1/(1+log2 2), usual = 3 over 10 posts
  const want = 2 * (4 / 1.3) * (1 / (1 + Math.log2(10))) * 0.5
  assert.ok(Math.abs(scores.get(quiet.id) - want) < 1e-9, String(scores.get(quiet.id)))
})

test("someone /feed knows nothing about counts as 8 posts, not 1", () => {
  const reach = new Map([[OUT, 1]])
  const n = note(OUT), scores = new Map()
  scoreUnderrated([n], votes([likes(n, ...R.slice(0, 3))]), { reach, now: NOW, scores })
  // log2(4) · (4/4) · 1/(1+log2 8) · 0.5 = 2 · 0.25 · 0.5
  assert.ok(Math.abs(scores.get(n.id) - 0.25) < 1e-9, String(scores.get(n.id)))
})

test("known to fewer of your follows ranks higher; a bridged note gets 1.5×; old notes decay to a fifth", () => {
  const reach = new Map([[OUT, 1], [OUT2, 7]])
  const few = note(OUT), many = note(OUT2)
  const t = votes([likes(few, ...R.slice(0, 3)), likes(many, ...R.slice(0, 3))])
  assert.deepEqual(scoreUnderrated([many, few], t, { reach, now: NOW }).map(n => n.id), [few.id, many.id])
  const plain = note(OUT), bridged = note(OUT3, { tags: [["proxy", "https://m.example/2", "activitypub"]] }), old = note(OUT2, { created_at: NOW - 40 * 3600 })
  const s = new Map()
  const r2 = new Map([[OUT, 1], [OUT2, 1], [OUT3, 1]])
  scoreUnderrated([plain, bridged, old], votes([likes(plain, ...R.slice(0, 3)), likes(bridged, ...R.slice(0, 3)), likes(old, ...R.slice(0, 3))]), { reach: r2, now: NOW, scores: s })
  assert.ok(Math.abs(s.get(bridged.id) / s.get(plain.id) - BRIDGE_BOOST) < 1e-9)
  assert.ok(Math.abs(s.get(old.id) / s.get(plain.id) - 0.2) < 1e-9, "40 h old: 1 - 28·0.05 is under the 0.2 floor")
})

test("at most two per author, ties broken on id, and at most 300 in all", () => {
  const reach = new Map([[OUT, 1]])
  const a = note(OUT), b = note(OUT), c = note(OUT)
  const t = votes([likes(a, ...R.slice(0, 3)), likes(b, ...R.slice(0, 3)), likes(c, ...R.slice(0, 3))])
  const got = scoreUnderrated([c, b, a], t, { reach, now: NOW })
  assert.equal(PER_AUTHOR, 2)
  assert.deepEqual(got.map(n => n.id), [a.id, b.id].sort())
  const people = Array.from({ length: MAX_NOTES + 20 }, (_, i) => pk(5000 + i))
  const many = people.map(p => note(p))
  const all = scoreUnderrated(many, votes(many.map(n => likes(n, ...R.slice(0, 3)))), { reach: new Map(people.map(p => [p, 1])), now: NOW })
  assert.equal(all.length, MAX_NOTES)
})

test("why it's empty: no lists back, nobody one step out, or nothing cleared the bar; each has its words", () => {
  assert.equal(emptyReason(new Map(), new Map()), REASONS.webNotReady)
  assert.equal(emptyReason(lists(contacts(F1)), new Map()), REASONS.webIncomplete)
  assert.equal(emptyReason(lists(contacts(F1, OUT)), new Map([[OUT, 1]])), REASONS.nothingQualified)
  for (const r of Object.values(REASONS)) assert.ok(EMPTY_TEXT[r], r)
})

test("no follow lists back: withheld before any engagement is asked (fails closed)", async () => {
  const asked = []
  const got = await fetchUnderrated({ me: pk(901), follows: [F1], relays: ["wss://r"], lists: new Map(), now: NOW, trust: async e => e, query: async (r, f) => { asked.push(f); return [] } })
  assert.deepEqual(got.notes, [])
  assert.equal(got.reason, REASONS.webNotReady)
  assert.deepEqual(asked, [])
})

test("some follows' lists still on their way: withheld as not ready, nothing scored or asked (as Go's trust graph)", async () => {
  const asked = []
  // F1's list names someone one step out, but F2's hasn't come back: a half-loaded web would undercount vouches.
  const got = await fetchUnderrated({ me: pk(904), follows: [F1, F2], relays: ["wss://r"], lists: lists(contacts(F1, OUT)), now: NOW, trust: async e => e, query: async (r, f) => { asked.push(f); return [] } })
  assert.deepEqual(got.notes, [])
  assert.equal(got.reason, REASONS.webNotReady)
  assert.deepEqual(asked, [], "no engagement asked")
  // The same lists with F2's settled (a relay has none for them): scoring goes ahead.
  const settled = await fetchUnderrated({ me: pk(905), follows: [F1, F2], relays: ["wss://r"], lists: lists(contacts(F1, OUT)), pending: () => 0, now: NOW, trust: async e => e, query: async (r, f) => { asked.push(f); return [] } })
  assert.equal(settled.reason, REASONS.nothingQualified)
  assert.ok(asked.length > 0)
  assert.equal(emptyReason(lists(contacts(F1, OUT)), new Map([[OUT, 1]]), 1), REASONS.webNotReady)
})

test("a failed Underrated load drops the last load's empty reason", () => {
  const screen = readFileSync(new URL("../src/screens/FeedScreen.jsx", import.meta.url), "utf8")
  const fail = screen.slice(screen.indexOf("} catch (e) {", screen.indexOf("const loadStrange")))
  assert.match(fail.slice(0, 300), /underratedWhy\.current = ""/)
})

test("an Underrated page: two days of trusted engagement in, one-step-out notes out, Haven /feed only read", async () => {
  const me = pk(902), follows = [F1, F2]
  const good = note(OUT), byFollow = note(F1), byFar = note(FAR)
  const filters = [], writes = []
  const vault = { feed: {
    query: async f => (f.ids ? (f.ids.includes(good.id) ? [good] : []) : []),
    event: async ev => writes.push(ev),
  } }
  const query = async (r, f) => {
    filters.push(f)
    if (f.kinds?.[0] === 3) return [contacts(F1, OUT, R[0], R[1], R[2]), contacts(F2, OUT)]
    if (f.ids) return [byFollow, byFar]
    if (f.authors) return []
    return [good, byFollow, byFar].flatMap(n => R.slice(0, 3).map(w => ({ id: pk(seq++), kind: 7, pubkey: w, tags: [["e", n.id]] })))
  }
  const got = await fetchUnderrated({ me, follows, relays: ["wss://r"], vault, now: NOW, trust: async e => e, query })
  assert.deepEqual(got.notes.map(n => n.id), [good.id], "a follow's note and a stranger's (no follow follows them) stay out")
  assert.equal(got.reason, "")
  assert.ok(got.scores.get(good.id) > 0)
  assert.ok(filters.some(f => !f.authors && !f.ids && f.since === NOW - WINDOW && f.limit === 5000), "everyone's last two days")
  assert.deepEqual(writes, [], "nothing written to Haven /feed")
  // The same, with R[2] blocked: two trusted likes left, under the bar.
  const blocked = await fetchUnderrated({ me: pk(903), follows, relays: ["wss://r"], vault, now: NOW, trust: async e => e, query, blocked: new Set([R[2]]) })
  assert.deepEqual(blocked.notes, [])
  assert.equal(blocked.reason, REASONS.nothingQualified)
})

test("note bodies are asked of the relays in REQs of 250 ids", async () => {
  const ids = Array.from({ length: 600 }, (_, i) => pk(9000 + i)), sizes = []
  const found = await noteBodies(ids, { vault: null, relays: ["wss://r"], query: async (r, f) => { sizes.push(f.ids.length); return [{ id: f.ids[0], kind: 1 }, { id: pk(1), kind: 1 }] } })
  assert.deepEqual(sizes, [250, 250, 100])
  assert.equal(found.size, 3, "only ids that were asked for")
  assert.ok(MAX_CANDIDATES >= 1000)
})

test("note bodies include long-form articles (kind 30023), as Go's resolveNoteBodies", async () => {
  const [inHaven, onRelay, other] = [pk(9701), pk(9702), pk(9703)], kinds = []
  const vault = { feed: { query: async f => { kinds.push(f.kinds); return [{ id: inHaven, kind: 30023 }] } } }
  const found = await noteBodies([inHaven, onRelay, other], { vault, relays: ["wss://r"], query: async (r, f) => { kinds.push(f.kinds); return [{ id: onRelay, kind: 30023 }, { id: other, kind: 6 }] } })
  assert.deepEqual(kinds, [[1, 30023], [1, 30023]], "Haven and the relays both asked for notes and articles")
  assert.deepEqual([...found.keys()].sort(), [inHaven, onRelay].sort(), "another kind with an asked-for id stays out")
})

test("Underrated has a Reach setting, one step out by default", () => {
  assert.ok(REACH_FEEDS.some(([id]) => id === "underrated"))
  assert.equal(loadReach("underrated", { getItem: () => null }), "webAndHop3")
})
