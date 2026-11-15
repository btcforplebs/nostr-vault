// Bug run group 4: the Reader napplet's article, highlight and poll cards. The shell works each card out from the
// signed event with the classic card's functions (kind-cards.js); the Reader asks by intent, only it may.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import vm from "node:vm"
import { finalizeEvent, generateSecretKey, getPublicKey, verifyEvent } from "nostr-tools/pure"
import { createBus } from "../src/napplet/bus.js"
import { readerIntents } from "../src/napplet/reader-intents.js"
import { articleCard, highlightCard, pollCard } from "../src/napplet/kind-cards.js"

const sk = generateSecretKey(), pk = getPublicKey(sk), other = getPublicKey(generateSecretKey())
const sign = (t) => finalizeEvent({ created_at: 1000, content: "", tags: [], ...t }, sk)
const A = "a".repeat(64)

test("articleCard: title, picture (https only), minutes, summary or the start of the text", () => {
  const ev = sign({ kind: 30023, content: "# Heading\n\n" + "word ".repeat(450), tags: [["d", "x"], ["title", "Bees in town"], ["image", "https://p.example/c.jpg"], ["summary", "Rooftop hives."]] })
  assert.deepEqual(articleCard(ev), { type: "article", title: "Bees in town", image: "https://p.example/c.jpg", meta: "Long-form · 3 min read", preview: "Rooftop hives." })
  const bare = articleCard(sign({ kind: 30023, content: "First line here\n\nmore", tags: [["d", "y"], ["image", "http://p.example/c.jpg"]] }))
  assert.equal(bare.title, "First line here")
  assert.equal(bare.image, null)
  assert.ok(bare.preview.startsWith("First line here"))
})

test("highlightCard: comment, passage, source as note / article address / page", () => {
  assert.deepEqual(highlightCard(sign({ kind: 9802, content: " the passage ", tags: [["comment", " so true "], ["e", A]] })), { type: "highlight", comment: "so true", passage: "the passage", source: { note: A } })
  assert.deepEqual(highlightCard(sign({ kind: 9802, content: "p", tags: [["a", `30023:${pk}:my-post`], ["e", A]] })).source, { addr: { kind: 30023, pubkey: pk, d: "my-post" } })
  assert.deepEqual(highlightCard(sign({ kind: 9802, content: "p", tags: [["r", "https://x.example/p"]] })).source, { url: "https://x.example/p" })
  assert.equal(highlightCard(sign({ kind: 9802, content: "p", tags: [["r", "javascript:x"]] })).source, null)
})

test("pollCard: hidden counts until you voted or it closed; blocked voters left out; newest vote per person", () => {
  const poll = sign({ kind: 1068, content: "Which?", tags: [["option", "y", "Yes"], ["option", "n", "No"], ["endsAt", "5000"]] })
  const vote = (who, pick, at = 2000, id = who.slice(0, 8) + at) => ({ id, pubkey: who, kind: 1018, created_at: at, tags: [["e", poll.id], ["response", pick]] })
  const votes = [vote(other, "y"), vote("b".repeat(64), "n"), vote("b".repeat(64), "y", 2100), vote("c".repeat(64), "n")]
  const before = pollCard(poll, votes, { me: pk, now: 3000 })
  assert.equal(before.results, false)
  assert.equal(before.voters, 3)
  assert.deepEqual(before.options.map(o => o.pct), [null, null])
  const mine = pollCard(poll, [...votes, vote(pk, "n")], { me: pk, now: 3000, blocked: new Set(["c".repeat(64)]) })
  assert.deepEqual(mine.mine, ["n"])
  assert.equal(mine.voters, 3)
  assert.deepEqual(mine.options.map(o => [o.id, o.votes, o.pct]), [["y", 2, 67], ["n", 1, 33]])
  assert.equal(pollCard(poll, votes, { now: 6000 }).closed, true)
  assert.equal(pollCard(sign({ kind: 1068, content: "no options" }), []), null)
})

test("intents: note/card and poll/vote answer the Reader only, for signed events of the right kind; article/open opens", async () => {
  const bus = createBus(), cards = [], votes = [], articles = []
  const wire = readerIntents({ bus, openCompose: async () => ({}), onComposeDone: () => {}, openUrl: () => {}, verify: verifyEvent,
    card: async ev => { cards.push(ev.id); return { type: "x", id: ev.id } }, vote: async (ev, picks) => { votes.push(picks); return { type: "poll", voted: picks } }, onArticle: ev => articles.push(ev.id) })
  const reader = { dTag: "nv-reader", send: () => {} }, outsider = { dTag: "someone-else", send: () => {} }
  const art = sign({ kind: 30023, content: "x", tags: [["d", "a"]] }), poll = sign({ kind: 1068, content: "Q", tags: [["option", "y", "Y"]] }), note = sign({ kind: 1, content: "hi" })
  const ask = (who, archetype, action, payload) => bus.invoke(who, { archetype, action, payload })
  assert.deepEqual((await ask(reader, "note", "card", { event: art })).data, { type: "x", id: art.id })
  assert.equal((await ask(outsider, "note", "card", { event: art })).ok, false)
  assert.equal((await ask(reader, "note", "card", { event: note })).ok, false, "kind 1 has no card")
  assert.equal((await ask(reader, "note", "card", { event: { ...art, content: "edited" } })).ok, false, "edited after signing")
  assert.deepEqual((await ask(reader, "poll", "vote", { event: poll, picks: ["y", 5] })).data, { type: "poll", voted: ["y"] })
  assert.equal((await ask(outsider, "poll", "vote", { event: poll, picks: ["y"] })).ok, false)
  assert.equal((await ask(reader, "poll", "vote", { event: art, picks: ["y"] })).ok, false)
  assert.equal((await ask(reader, "poll", "vote", { event: poll, picks: [] })).ok, false)
  assert.equal((await ask(reader, "article", "open", { event: art })).ok, true)
  assert.equal((await ask(reader, "article", "open", { event: note })).ok, false)
  assert.deepEqual(cards, [art.id]); assert.deepEqual(votes, [["y"]]); assert.deepEqual(articles, [art.id])
  wire.close()
})

test("intents: a vote that fails (read-only, closed) comes back as the reason", async () => {
  const bus = createBus()
  readerIntents({ bus, openCompose: async () => ({}), onComposeDone: () => {}, openUrl: () => {}, verify: verifyEvent, vote: async () => { throw new Error("Read-only: sign in to vote.") } })
  const r = await bus.invoke({ dTag: "nv-reader", send: () => {} }, { archetype: "poll", action: "vote", payload: { event: sign({ kind: 1068, content: "Q", tags: [["option", "y", "Y"]] }), picks: ["y"] } })
  assert.equal(r.ok, false)
  assert.equal(r.error, "Read-only: sign in to vote.")
})

test("Reader: asks the feed for articles, highlights and polls; poll foot line", () => {
  const html = fs.readFileSync(new URL("../napplets/reader/index.html", import.meta.url), "utf8")
  const block = html.slice(html.indexOf("// ---- pure"), html.indexOf("// ---- end pure ----"))
  const box = {}
  vm.runInNewContext(`${block}\n;Object.assign(box, { FEED_KINDS, CARD_KINDS, pollMeta })`, { box, Date, URL, Intl })
  assert.deepEqual([...box.FEED_KINDS], [1, 6, 30023, 9802, 1068])
  assert.equal(box.pollMeta({ voters: 1, multiple: true, endsAt: null }), "1 vote · Pick any")
  assert.equal(box.pollMeta({ voters: 4, multiple: false, endsAt: 100, closed: true }), "4 votes · Final results")
  assert.match(box.pollMeta({ voters: 0, multiple: false, endsAt: 100 + 7200, closed: false }, 100), /^0 votes · Ends in 2 hours$/)
  assert.equal((html.match(/kinds: FEED_KINDS/g) ?? []).length, 4, "feed, live, older and profile all ask")
})
