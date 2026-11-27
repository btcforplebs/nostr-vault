// The Vault's search: every word has to match (names/about/NIP-05 for people; text and title/summary/subject for
// notes), hits are re-checked even when a store hands back more than it should, sections split by kind, hashtags and
// links come from the matched notes. Throwaway keys and fake stores.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { decode, npubEncode } from "nostr-tools/nip19"
import { terms, matchesNote, keepsPerson, pubkeyIn, hashtags, links, trimUrl, searchVault, NOTE_KINDS } from "../src/net/vault-search.js"

const key = () => { const sk = generateSecretKey(); return { sk, pk: getPublicKey(sk) } }
const A = key(), B = key(), C = key()
let t = 1000
const ev = (who, kind, content, tags = []) => finalizeEvent({ kind, content, tags, created_at: t++ }, who.sk)
const profile = (who, p) => ev(who, 0, JSON.stringify(p))

// A store that ignores `search` (hands back everything its kinds/authors allow), so the re-check is what filters.
const store = evs => ({ asked: [], async query(f) { this.asked.push(f); return evs.filter(e => (!f.kinds || f.kinds.includes(e.kind)) && (!f.authors || f.authors.includes(e.pubkey))).slice(0, f.limit) } })

test("under two characters is no search; words are split and lowercased", () => {
  assert.equal(terms(""), null); assert.equal(terms(" a "), null)
  assert.deepEqual(terms("  Jane   DOE "), ["jane", "doe"])
})

test("a note matches on every word, in its text or headline tags, in any order", () => {
  const art = ev(A, 30023, "body text", [["title", "Sourdough Starter"], ["summary", "how to"], ["t", "bread"]])
  assert.ok(matchesNote(["starter", "body"], art))
  assert.ok(!matchesNote(["starter", "rye"], art))
  assert.ok(!matchesNote(["bread"], art), "a t tag isn't text")
})

test("people: words in names, about or NIP-05, never the hex key; a key query finds only that person", () => {
  const p = profile(A, { name: "jane", nip05: "doe@example.com" })
  assert.ok(keepsPerson(p, ["jane", "doe"]))
  assert.ok(!keepsPerson(p, [A.pk.slice(0, 4)]))
  assert.ok(keepsPerson(p, ["x"], A.pk) && !keepsPerson(p, ["jane"], B.pk))
  assert.equal(pubkeyIn(`nostr:${npubEncode(A.pk)}`, decode), A.pk)
  assert.equal(pubkeyIn(A.pk.toUpperCase(), decode), A.pk)
  assert.equal(pubkeyIn("npub1bad", decode), null)
})

test("hashtags that contain a word of the query, from text and t tags; # ignored", () => {
  const n = [ev(A, 1, "love #Bitcoin and #nostr"), ev(B, 1, "x", [["t", "bitcoiners"]])]
  assert.deepEqual(hashtags(n, "#bitcoin"), ["bitcoin", "bitcoiners"])
  assert.deepEqual(hashtags(n, ""), [])
})

test("links once each, sentence punctuation trimmed, a URL's own brackets kept", () => {
  assert.equal(trimUrl("https://x.y/a)."), "https://x.y/a")
  assert.equal(trimUrl("https://en.wikipedia.org/wiki/Foo_(bar)"), "https://en.wikipedia.org/wiki/Foo_(bar)")
  const n = [ev(A, 1, "see https://x.y/a, and (https://x.y/b)"), ev(B, 1, "again https://x.y/a!")]
  assert.deepEqual(links(n).map(l => [l.url, l.title, l.noteId]), [["https://x.y/a", "x.y/a", n[0].id], ["https://x.y/b", "x.y/b", n[0].id]])
})

test("searchVault: re-checked hits, split into sections, newest first, blocked left out, follows first", async () => {
  const outbox = store([ev(A, 1, "my sourdough loaf"), ev(A, 6, "sourdough repost JSON"), ev(A, 30023, "x", [["title", "Sourdough guide"]])])
  const inbox = store([ev(B, 1, "your sourdough? https://bake.example/r."), ev(C, 20, "sourdough picture"), ev(C, 1, "sourdough from someone blocked")])
  const feed = store([profile(B, { name: "Sourdough Sam" }), profile(C, { name: "Sourdough Blocked" }), profile(A, { name: "zed", about: "sourdough fan" }), ev(B, 1, "nothing here")])
  const r = await searchVault([outbox, inbox, feed], "Sourdough", { follows: [A.pk], blocked: new Set([C.pk]), decode })
  assert.deepEqual(r.people, [A.pk, B.pk], "follow first, then by name; blocked dropped")
  assert.deepEqual(r.notes.map(n => n.content), ["your sourdough? https://bake.example/r.", "my sourdough loaf"])
  assert.equal(r.articles.length, 1)
  assert.equal(r.media.length, 0, "the blocked author's picture is left out")
  assert.deepEqual(r.links.map(l => l.url), ["https://bake.example/r"])
  assert.equal(r.cut, false)
  // Each store was asked with Haven's NIP-50 search and kinds to anchor it, reposts not among them.
  for (const s of [outbox, inbox, feed]) {
    assert.ok(s.asked.every(f => f.search === "sourdough" && f.kinds?.length))
    assert.ok(!s.asked.some(f => f.kinds.includes(6)))
  }
  assert.ok(NOTE_KINDS.includes(1) && NOTE_KINDS.includes(30023) && NOTE_KINDS.includes(20))
})

test("searchVault: an npub finds its person, even with no profile here; a full page says there may be more", async () => {
  const r = await searchVault([store([])], npubEncode(B.pk), { decode })
  assert.deepEqual(r.people, [B.pk])
  const many = store(Array.from({ length: 5 }, (_, i) => ev(A, 1, `bread ${i}`)))
  assert.equal((await searchVault([many], "bread", { decode, limit: 5 })).cut, true)
  assert.equal((await searchVault([many], "b", { decode })).notes.length, 0)
})

test("searchVault mine (My notes): only the account in use's notes, asked by author; no People; nothing for a pasted npub", async () => {
  const outbox = store([ev(A, 1, "my bread loaf"), ev(A, 30023, "x", [["title", "Bread guide"]])])
  const inbox = store([ev(B, 1, "your bread? https://bake.example/b"), ev(C, 20, "bread picture")])
  const feed = store([profile(B, { name: "Bread Ben" }), profile(A, { name: "bread me" })])
  const all = await searchVault([outbox, inbox, feed], "bread", { decode })
  assert.equal(all.notes.length, 2, "Notes: everything in the Vault")
  assert.equal(all.people.length, 2)
  for (const s of [outbox, inbox, feed]) s.asked.length = 0
  const r = await searchVault([outbox, inbox, feed], "bread", { decode, mine: A.pk })
  assert.deepEqual(r.notes.map(n => n.content), ["my bread loaf"])
  assert.equal(r.articles.length, 1)
  assert.equal(r.media.length, 0, "someone else's picture isn't yours")
  assert.deepEqual(r.people, [], "My notes has no People")
  assert.deepEqual(r.links, [], "links only from your own notes")
  for (const s of [outbox, inbox, feed]) {
    assert.ok(s.asked.length && s.asked.every(f => f.kinds.includes(1) && f.authors?.length === 1 && f.authors[0] === A.pk), "the store is asked by author, never kind 0")
  }
  // A store that ignores authors too: the re-check still keeps only yours.
  const loose = { async query() { return [ev(B, 1, "bread from B"), ev(A, 1, "bread from A")] } }
  assert.deepEqual((await searchVault([loose], "bread", { decode, mine: A.pk })).notes.map(n => n.pubkey), [A.pk])
  assert.deepEqual((await searchVault([store([])], npubEncode(B.pk), { decode, mine: A.pk })).people, [])
})

test("the Notes / My notes switch remembers its last setting; default Notes", async () => {
  const { searchesMine, setSearchesMine } = await import("../src/net/vault-search.js")
  const m = new Map(), storage = { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, v) }
  assert.equal(searchesMine(storage), false)
  setSearchesMine(true, storage); assert.equal(searchesMine(storage), true)
  setSearchesMine(false, storage); assert.equal(searchesMine(storage), false)
  assert.equal(searchesMine({ getItem() { throw new Error("blocked") } }), false)
})
