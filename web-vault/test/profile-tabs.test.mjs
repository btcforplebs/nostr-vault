// A profile's tabs (src/net/profile-tabs.js): the iPhone's order, Notes and Replies split by NIP-10, Reposts, Media from
// their own notes and replies, Tagged, Articles one per `d` and only when there are some; paging and empty wording;
// someone else's articles fetched once and the notes that tag a profile (src/net/person.js), your own older pages.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { splitProfileNotes, latestArticles, isReply, PROFILE_TABS, visibleTabs, taggedNotes, mergeOlder, emptyText } from "../src/net/profile-tabs.js"
import { fetchPersonArticles, fetchTagged, ownOlder, syncOwnPage, syncPersonNotes, readPersonNotes } from "../src/net/person.js"

const sk = generateSecretKey(), pk = getPublicKey(sk)
const ID = "a".repeat(64), ID2 = "b".repeat(64)
const note = (content, at, tags = []) => finalizeEvent({ kind: 1, created_at: at, tags, content }, sk)
const article = (d, at, title) => finalizeEvent({ kind: 30023, created_at: at, tags: [["d", d], ["title", title]], content: "body" }, sk)

test("the tabs are the iPhone's, in its order; Articles only once the profile has some", () => {
  assert.deepEqual(PROFILE_TABS.map(t => t.label), ["Notes", "Media", "Replies", "Reposts", "Tagged", "Articles"])
  assert.deepEqual(visibleTabs([]).map(t => t.id), ["notes", "media", "replies", "reposts", "tagged"])
  assert.deepEqual(visibleTabs(null).map(t => t.id), ["notes", "media", "replies", "reposts", "tagged"])
  assert.deepEqual(visibleTabs([article("a", 1, "t")]).map(t => t.id).at(-1), "articles")
})

test("a repost goes to Reposts, and its media stays out of Media", () => {
  const pic = note("https://x.example/a.jpg", 5)
  const repost = finalizeEvent({ kind: 6, created_at: 9, tags: [["e", ID], ["p", pk]], content: JSON.stringify(note("https://x.example/b.jpg", 1)) }, sk)
  const { notes, reposts, media } = splitProfileNotes([repost, pic])
  assert.deepEqual(reposts.map(n => n.id), [repost.id])
  assert.deepEqual(notes.map(n => n.id), [pic.id])
  assert.deepEqual(media.map(t => t.id), [pic.id])
})

test("Tagged leaves out the profile's own notes and anyone blocked", () => {
  const a = generateSecretKey(), b = generateSecretKey()
  const byA = finalizeEvent({ kind: 1, created_at: 3, tags: [["p", pk]], content: "hi" }, a)
  const byB = finalizeEvent({ kind: 1, created_at: 2, tags: [["p", pk]], content: "hey" }, b)
  const own = note("me", 1, [["p", pk]])
  assert.deepEqual(taggedNotes([byA, byB, own], pk, new Set([getPublicKey(b)])).map(n => n.id), [byA.id])
})

test("an older page joins once each, newest first; a page with nothing new didn't grow", () => {
  const a = note("a", 30), b = note("b", 20), c = note("c", 10), tie = note("tie", 10)
  const first = mergeOlder([a, b], [b, c, tie])
  assert.equal(first.grew, true)
  assert.deepEqual(first.list.map(n => n.id), [a.id, b.id, ...[c.id, tie.id].sort().reverse()])
  const again = mergeOlder(first.list, [c])
  assert.equal(again.grew, false)
  assert.equal(again.list, first.list)
})

test("an empty tab reads as the iPhone's: Loading…, None in the latest posts, then No … yet", () => {
  assert.equal(emptyText("replies", { loading: true, olderLeft: true }), "Loading…")
  assert.equal(emptyText("replies", { loading: false, olderLeft: true }), "None in the latest posts")
  assert.equal(emptyText("replies", { loading: false, olderLeft: false }), "No replies yet")
  assert.equal(emptyText("tagged", { loading: false, olderLeft: false }), "No tagged yet")
  assert.equal(emptyText("media", { loading: false, olderLeft: false }), "No media yet")
})

test("their notes and reposts are fetched together; a stranger's kind 6 or a like is not theirs", async () => {
  const them = generateSecretKey(), them_pk = getPublicKey(them)
  const n = finalizeEvent({ kind: 1, created_at: 10, tags: [], content: "n" }, them)
  const r = finalizeEvent({ kind: 6, created_at: 20, tags: [["e", ID]], content: "" }, them)
  const like = finalizeEvent({ kind: 7, created_at: 30, tags: [["e", ID]], content: "+" }, them)
  let asked
  const vault = { feed: { query: async () => [] } }
  await syncPersonNotes(vault, them_pk, [], { query: async (r_, f) => { asked = f; return [n, r, like] } })
  assert.deepEqual(asked.kinds, [1, 6])
  assert.deepEqual((await readPersonNotes(vault, them_pk)).map(e => e.kind), [6, 1])
})

test("Tagged asks for kind 1s that p-tag them, keeps only others' notes that do, and pages by until", async () => {
  const them = generateSecretKey(), them_pk = getPublicKey(them), a = generateSecretKey()
  const t1 = finalizeEvent({ kind: 1, created_at: 50, tags: [["p", them_pk]], content: "1" }, a)
  const t2 = finalizeEvent({ kind: 1, created_at: 40, tags: [["p", them_pk]], content: "2" }, a)
  const untagged = finalizeEvent({ kind: 1, created_at: 45, tags: [], content: "no tag" }, a)
  const theirOwn = finalizeEvent({ kind: 1, created_at: 44, tags: [["p", them_pk]], content: "self" }, them)
  const asks = []
  const query = async (relays, f) => { asks.push({ relays, f }); return f.until ? [t2] : [t1, untagged, theirOwn] }
  assert.deepEqual((await fetchTagged(them_pk, ["wss://their.read"], { query })).map(e => e.id), [t1.id])
  assert.deepEqual(asks[0].f, { kinds: [1], "#p": [them_pk], limit: 50 })
  assert.ok(asks[0].relays.includes("wss://their.read"))
  assert.deepEqual((await fetchTagged(them_pk, [], { until: 50, query })).map(e => e.id), [t1.id, t2.id])
  assert.equal(asks[1].f.until, 50)
})

test("your own older page: the network's page goes into the outbox, then the outbox is read before until", async () => {
  const kept = []
  const vault = { outbox: {
    event: async ev => { if (kept.some(e => e.id === ev.id)) return { ok: false }; kept.push(ev); return { ok: true } },
    query: async f => kept.filter(e => f.kinds.includes(e.kind) && f.authors.includes(e.pubkey) && (!f.until || e.created_at <= f.until)).slice(0, f.limit),
  } }
  const old = note("old", 5), repost = finalizeEvent({ kind: 6, created_at: 6, tags: [["e", ID]], content: "" }, sk), newer = note("new", 100)
  const stranger = finalizeEvent({ kind: 1, created_at: 7, tags: [], content: "x" }, generateSecretKey())
  let asked
  const page = await ownOlder(vault, pk, ["wss://w.example"], 50, { query: async (r, f) => { asked = f; return [old, repost, stranger] } })
  assert.deepEqual(asked, { kinds: [1, 6], authors: [pk], limit: 50, until: 50 })
  assert.deepEqual(page.map(e => e.id), [repost.id, old.id])
  assert.equal(kept.length, 2, "only your own events are stored")
  await vault.outbox.event(newer)
  const offline = await ownOlder(vault, pk, [], 50, { online: false, query: async () => assert.fail("offline asks no relay") })
  assert.deepEqual(offline.map(e => e.id), [repost.id, old.id])
  assert.equal(await syncOwnPage(vault, pk, [], { kinds: [6], query: async (r, f) => { asked = f; return [repost, old] } }), 0, "already stored; and a kind 1 isn't asked for")
  assert.deepEqual(asked.kinds, [6])
})

test("a reply goes to Replies; a plain note and a quote stay in Notes", () => {
  const plain = note("hi", 10)
  const marked = note("yes", 9, [["e", ID, "", "root"], ["e", ID2, "", "reply"]])
  const positional = note("old style", 8, [["e", ID]])
  const quote = note("look nostr:note1...", 7, [["e", ID, "", "mention"]])
  const { notes, replies } = splitProfileNotes([plain, marked, positional, quote])
  assert.deepEqual(notes.map(n => n.id), [plain.id, quote.id])
  assert.deepEqual(replies.map(n => n.id), [marked.id, positional.id])
  assert.equal(isReply(quote), false)
})

test("Media holds notes and replies with an image or video, newest first, and nothing else", () => {
  const pic = note("https://x.example/a.jpg", 5)
  const vid = note("reply https://x.example/b.mp4", 6, [["e", ID]])
  const text = note("no media", 7)
  const { media } = splitProfileNotes([text, vid, pic])
  assert.deepEqual(media.map(t => [t.id, t.type]), [[vid.id, "video"], [pic.id, "image"]])
})

test("Articles keep the newest edit of each, newest first", () => {
  const a1 = article("one", 100, "old"), a2 = article("one", 200, "new"), b = article("two", 150, "b")
  assert.deepEqual(latestArticles([a1, b, a2]).map(a => a.tags[1][1]), ["new", "b"])
  assert.deepEqual(latestArticles([note("x", 1)]), [])
})

test("someone's articles are asked for once, from their write relays, and only theirs are kept", async () => {
  const other = generateSecretKey()
  const stray = finalizeEvent({ kind: 30023, created_at: 5, tags: [["d", "x"]], content: "" }, other)
  const asks = []
  const query = async (relays, f) => { asks.push({ relays, f }); return [article("one", 100, "t"), stray] }
  const first = await fetchPersonArticles(pk, ["wss://w.example"], { query })
  const again = await fetchPersonArticles(pk, ["wss://w.example"], { query })
  assert.equal(first.length, 1)
  assert.equal(again, first)
  assert.equal(asks.length, 1)
  assert.ok(asks[0].relays.includes("wss://w.example"))
  assert.deepEqual(asks[0].f, { kinds: [30023], authors: [pk], limit: 50 })
})

test("Brainstorm opens their nprofile page, as NostrWebLink.profile", async () => {
  const { brainstormLink } = await import("../src/net/person.js")
  const { decode } = await import("nostr-tools/nip19")
  const url = brainstormLink(pk)
  assert.ok(url.startsWith("https://brainstorm.world/p/nprofile1"))
  assert.equal(decode(url.split("/p/")[1]).data.pubkey, pk)
})
