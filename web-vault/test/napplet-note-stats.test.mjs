// Bug run group 6: Like + zap totals in the Reader napplet. The shell reports your Like and the zap total
// (note-stats.js, from the classic card's state) and runs the classic Like when the Reader asks.
import test from "node:test"
import assert from "node:assert/strict"
import { finalizeEvent, generateSecretKey, verifyEvent } from "nostr-tools/pure"
import { createBus } from "../src/napplet/bus.js"
import { readerIntents, likedNote } from "../src/napplet/reader-intents.js"
import { statsOf, askedEmoji } from "../src/napplet/note-stats.js"

const sk = generateSecretKey()
const sign = t => finalizeEvent({ created_at: 1, content: "", tags: [], ...t }, sk)
const ID = "a".repeat(64)

test("statsOf: your Like as a word, the emoji only when it's yours, zap sats as a whole number", () => {
  assert.deepEqual(statsOf(ID), { id: ID, like: null, error: "", emoji: "", zapSats: 0, zapMine: false })
  assert.deepEqual(statsOf(ID, { state: { like: "sent" }, reaction: "+", total: { sats: 2100.7, mine: true } }, () => "❤️"), { id: ID, like: "sent", error: "", emoji: "❤️", zapSats: 2100, zapMine: true })
  assert.equal(statsOf(ID, { state: { like: { error: "no relay took it", unlike: true } } }).like, "error")
  assert.equal(statsOf(ID, { state: { like: "busy" }, reaction: "🔥" }).emoji, "")
  assert.equal(statsOf(ID, { total: { sats: NaN } }).zapSats, 0)
})

test("askedEmoji: one emoji only; text, markup and long strings are no emoji", () => {
  assert.equal(askedEmoji("🔥"), "🔥")
  assert.equal(askedEmoji(" ❤️ "), "❤️")
  assert.equal(askedEmoji("👩‍👩‍👧"), "👩‍👩‍👧", "a ZWJ family is one emoji")
  assert.equal(askedEmoji("🇺🇸"), "🇺🇸")
  for (const x of ["+", "hello", "<img>", "🔥".repeat(10), "🔥🔥", "❤️ buy now", "🤙\u202e", "\u202e🤙", "🤙\u200b", 5, null, ""]) assert.equal(askedEmoji(x), undefined, JSON.stringify(x))
  // Tron #2088: text riding along, repeats under the old 16-char cap, and a right-to-left override are no emoji.
  for (const x of ["❤️ buy now", "🔥".repeat(8), "🔥🔥", "🤙\u202E", "\u202E🤙", "🤙\u200B", "a"]) assert.equal(askedEmoji(x), undefined, JSON.stringify(x))
  // Still one emoji: ZWJ sequences, skin tones, flags, keycaps.
  for (const x of ["👨‍👩‍👧‍👦", "👍🏽", "🇺🇸", "1️⃣", "🤙"]) assert.equal(askedEmoji(x), x, x)
})

test("note/stats and note/like: Reader only, signed notes (and article/highlight/poll, repost's inner); emoji passed through", async () => {
  const bus = createBus(), liked = [], asked = []
  const wire = readerIntents({ bus, openCompose: async () => ({}), onComposeDone: () => {}, openUrl: () => {}, verify: verifyEvent,
    stats: note => { asked.push(note.id); return statsOf(note.id) }, like: (note, emoji) => { liked.push([note.id, emoji]); return "" } })
  const reader = { dTag: "nv-reader", send: () => {} }, outsider = { dTag: "x", send: () => {} }
  const note = sign({ kind: 1, content: "hi" }), poll = sign({ kind: 1068, content: "Q", tags: [["option", "y", "Y"]] })
  const repost = sign({ kind: 6, content: JSON.stringify(note) })
  const ask = (who, action, payload) => bus.invoke(who, { archetype: "note", action, payload })
  assert.equal((await ask(reader, "stats", { event: note })).data.id, note.id)
  assert.equal((await ask(reader, "stats", { event: repost })).data.id, note.id, "a repost's stats are its note's")
  assert.equal((await ask(outsider, "stats", { event: note })).ok, false)
  assert.equal((await ask(reader, "like", { event: note })).ok, true)
  assert.equal((await ask(reader, "like", { event: poll, emoji: "🔥" })).ok, true)
  assert.equal((await ask(reader, "like", { event: note, emoji: "<b>" })).ok, true)
  assert.equal((await ask(reader, "like", { event: { ...note, content: "edited" } })).ok, false)
  assert.equal((await ask(outsider, "like", { event: note })).ok, false)
  assert.deepEqual(liked, [[note.id, undefined], [poll.id, "🔥"], [note.id, undefined]])
  assert.deepEqual(asked, [note.id, note.id])
  wire.close()
})

test("note/like: a refusal (read-only) comes back as the reason", async () => {
  const bus = createBus()
  readerIntents({ bus, openCompose: async () => ({}), onComposeDone: () => {}, openUrl: () => {}, verify: verifyEvent, like: () => "Read-only: sign in to react." })
  const r = await bus.invoke({ dTag: "nv-reader", send: () => {} }, { archetype: "note", action: "like", payload: { event: sign({ kind: 1 }) } })
  assert.deepEqual([r.ok, r.error], [false, "Read-only: sign in to react."])
})

test("likedNote: kinds the Reader draws only", () => {
  assert.equal(likedNote(sign({ kind: 7, content: "+" }), verifyEvent), null)
  assert.equal(likedNote(sign({ kind: 30023, content: "x", tags: [["d", "a"]] }), verifyEvent).kind, 30023)
})
