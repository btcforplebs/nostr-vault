// A profile's tabs (src/net/profile-tabs.js): Notes and Replies split by NIP-10, Media from both, Articles one per `d`;
// someone else's articles fetched once (src/net/person.js fetchPersonArticles).
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { splitProfileNotes, latestArticles, isReply, PROFILE_TABS } from "../src/net/profile-tabs.js"
import { fetchPersonArticles } from "../src/net/person.js"

const sk = generateSecretKey(), pk = getPublicKey(sk)
const ID = "a".repeat(64), ID2 = "b".repeat(64)
const note = (content, at, tags = []) => finalizeEvent({ kind: 1, created_at: at, tags, content }, sk)
const article = (d, at, title) => finalizeEvent({ kind: 30023, created_at: at, tags: [["d", d], ["title", title]], content: "body" }, sk)

test("the tabs are the iPhone's first four, in its order", () => {
  assert.deepEqual(PROFILE_TABS.map(t => t.label), ["Notes", "Replies", "Media", "Articles"])
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
