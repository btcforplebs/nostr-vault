// The Catch Up feed: each follow's newest post of their own, newest first, as haven-go feed_catchup.go builds it.
// Haven /feed first, the relays only for the people with nothing there, and nothing written to /feed.
import test from "node:test"
import assert from "node:assert/strict"
import { fetchCatchUp, pickLatestPerAuthor, normalizeFollows, isReplyNote, WINDOW, MAX_NOTES, MAX_SKEW, PER_AUTHOR, FETCH_BATCH } from "../src/net/catchup.js"
import { feedList, FEEDS } from "../src/net/feeds.js"

const NOW = 1_800_000_000
const hex = c => c.repeat(64)
const A = hex("a"), B = hex("b"), C = hex("c"), D = hex("d")
let n = 0
const note = (pubkey, created_at, extra = {}) => ({ id: (++n).toString(16).padStart(64, "0"), kind: 1, pubkey, created_at, tags: [], content: "", ...extra })
const wanted = (...pks) => new Set(pks)

test("one post per person, their newest, newest person first", () => {
  const old = note(A, NOW - 500), newest = note(A, NOW - 100), b = note(B, NOW - 300)
  assert.deepEqual(pickLatestPerAuthor([old, b, newest], wanted(A, B), NOW).map(e => e.id), [newest.id, b.id])
})

test("a reply is stepped over for the person's latest post of their own; a mention-marked e tag is not a reply", () => {
  const post = note(A, NOW - 500), reply = note(A, NOW - 10, { tags: [["e", hex("1")]] })
  const quote = note(B, NOW - 10, { tags: [["e", hex("2"), "", "mention"]] })
  assert.equal(isReplyNote(reply), true)
  assert.equal(isReplyNote(quote), false)
  assert.deepEqual(pickLatestPerAuthor([post, reply, quote], wanted(A, B), NOW).map(e => e.id), [quote.id, post.id])
})

test("an article counts even with e tags; other kinds do not", () => {
  const art = note(A, NOW - 5, { kind: 30023, tags: [["e", hex("1")]] }), repost = note(B, NOW - 5, { kind: 6 })
  assert.deepEqual(pickLatestPerAuthor([art, repost], wanted(A, B), NOW).map(e => e.id), [art.id])
})

test("only the last 14 days, nothing dated more than the clock skew ahead, nobody not followed", () => {
  const edge = note(A, NOW - WINDOW), tooOld = note(B, NOW - WINDOW - 1)
  const ahead = note(C, NOW + MAX_SKEW + 1), justAhead = note(D, NOW + MAX_SKEW), stranger = note(hex("e"), NOW)
  assert.deepEqual(pickLatestPerAuthor([edge, tooOld, ahead, justAhead, stranger], wanted(A, B, C, D), NOW).map(e => e.pubkey), [D, A])
})

test("ties break on id so the order is total, and at most 500 people", () => {
  const x = { ...note(A, NOW), id: hex("2") }, y = { ...note(A, NOW), id: hex("1") }
  assert.equal(pickLatestPerAuthor([x, y], wanted(A), NOW)[0].id, hex("1"), "same second: lower id")
  const many = Array.from({ length: MAX_NOTES + 5 }, (_, i) => note(i.toString(16).padStart(64, "0"), NOW - i))
  const got = pickLatestPerAuthor(many, new Set(many.map(e => e.pubkey)), NOW)
  assert.equal(got.length, MAX_NOTES)
  assert.equal(got[0].created_at, NOW)
})

test("follows are lowercased, junk dropped, each once", () => {
  assert.deepEqual(normalizeFollows([A.toUpperCase(), " " + A, "npub1x", B, "", null]), [A, B])
})

/** A fake Haven /feed holding `evs`, answering as a relay would: kinds, one author, since, newest `limit`. */
const fakeVault = evs => {
  const reads = []
  return { reads, feed: { query: async f => {
    reads.push(f)
    return evs.filter(e => f.kinds.includes(e.kind) && f.authors.includes(e.pubkey) && e.created_at >= f.since)
      .sort((a, b) => b.created_at - a.created_at).slice(0, f.limit)
  }, event: () => { throw new Error("Catch Up must not write to /feed") } } }
}

test("Haven /feed first, PER_AUTHOR per person; the relays are asked only about people with nothing there", async () => {
  const mine = note(A, NOW - 60), fromRelay = note(B, NOW - 30)
  const vault = fakeVault([mine])
  const asked = []
  const query = async (relays, f) => { asked.push({ relays, f }); return [fromRelay, note(hex("e"), NOW)] }
  const got = await fetchCatchUp({ follows: [A, B], relays: ["wss://r.example", "wss://r.example"], vault, now: NOW, query })
  assert.deepEqual(got.map(e => e.id), [fromRelay.id, mine.id])
  assert.equal(vault.reads.length, 2)
  assert.ok(vault.reads.every(f => f.authors.length === 1 && f.limit === PER_AUTHOR && f.since === NOW - WINDOW))
  assert.equal(asked.length, 1)
  assert.deepEqual(asked[0].f.authors, [B], "only the person /feed had nothing for")
  assert.deepEqual(asked[0].relays, ["wss://r.example"])
  assert.equal(asked[0].f.since, NOW - WINDOW)
})

test("someone whose /feed posts are all replies is asked of the relays", async () => {
  const vault = fakeVault([note(A, NOW - 5, { tags: [["e", hex("1")]] })])
  const asked = []
  await fetchCatchUp({ follows: [A], relays: ["wss://r"], vault, now: NOW, query: async (r, f) => { asked.push(f); return [] } })
  assert.deepEqual(asked.map(f => f.authors), [[A]])
})

test("the relays are asked in REQs of 250, and a failed one costs only its people", async () => {
  const follows = Array.from({ length: FETCH_BATCH + 10 }, (_, i) => (i + 1).toString(16).padStart(64, "0"))
  const asks = []
  const query = async (r, f) => {
    asks.push(f.authors.length)
    if (asks.length === 1) throw new Error("relay down")
    return [note(f.authors[0], NOW - 1)]
  }
  const got = await fetchCatchUp({ follows, relays: ["wss://r"], vault: fakeVault([]), now: NOW, query })
  assert.deepEqual(asks, [FETCH_BATCH, 10])
  assert.equal(got.length, 1)
})

test("everyone found in /feed asks no relay; no follows ask nothing at all", async () => {
  let asked = 0
  const query = async () => { asked++; return [] }
  assert.equal((await fetchCatchUp({ follows: [A], relays: ["wss://r"], vault: fakeVault([note(A, NOW - 1)]), now: NOW, query })).length, 1)
  assert.deepEqual(await fetchCatchUp({ follows: [], relays: ["wss://r"], vault: fakeVault([]), now: NOW, query }), [])
  assert.equal(asked, 0)
})

test("Catch Up sits after Popular in the picker, as on the iPhone", () => {
  assert.equal(FEEDS.find(f => f.id === "catchup")?.label, "Catch Up")
  const ids = feedList().map(f => f.id)
  assert.equal(ids.indexOf("catchup"), ids.indexOf("popular") + 1)
})
