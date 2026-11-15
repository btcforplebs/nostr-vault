// One plan step 6a: Bookmarks in the Reader. The shell hands over signed notes only (a tampered one becomes a "no
// relay had it" gap), answers the Reader alone, and tells it when the list changes.
import test from "node:test"
import assert from "node:assert/strict"
import { finalizeEvent, generateSecretKey, verifyEvent } from "nostr-tools/pure"
import { bookmarksAnswer, bookmarkIntents, BOOKMARKS_TOPIC } from "../src/napplet/reader-bookmarks.js"
import { createBus } from "../src/napplet/bus.js"
import { READER_DTAG } from "../src/napplet/first-party-list.js"

const sk = generateSecretKey()
const note = text => finalizeEvent({ kind: 1, created_at: 1700000000, tags: [], content: text }, sk)

test("answer: signed events pass, a tampered one is a gap, the private note is a short string", () => {
  const good = note("kept"), bad = { ...note("orig"), content: "edited" }
  const a = bookmarksAnswer({ public: [good, bad, null], private: [note("p")] }, "x".repeat(500), verifyEvent)
  assert.equal(a.public[0].id, good.id)
  assert.equal(a.public[1], null)
  assert.equal(a.public[2], null)
  assert.equal(a.private.length, 1)
  assert.equal(a.privateNote.length, 200)
  assert.equal(bookmarksAnswer({ public: [], private: [] }, undefined, verifyEvent).privateNote, "")
})

test("only the Reader gets the list; a change is told to it; off() removes both", async () => {
  const bus = createBus(), heard = []
  const reader = { dTag: READER_DTAG, send: m => heard.push(m) }
  bus.subscribe(reader, BOOKMARKS_TOPIC)
  let fire = null
  const off = bookmarkIntents({ bus, me: { dTag: "shell", send: () => {} }, verify: verifyEvent, read: async () => ({ public: [note("a")], private: [], privateNote: "" }), onChange: cb => { fire = cb; return () => { fire = null } } })
  const no = await bus.invoke({ dTag: "nv-compose", send: () => {} }, { archetype: "bookmarks", action: "list", payload: {} })
  assert.equal(no.ok, false)
  const yes = await bus.invoke(reader, { archetype: "bookmarks", action: "list", payload: {} })
  assert.equal(yes.ok, true); assert.equal(yes.data.public.length, 1)
  fire()
  assert.equal(heard.filter(m => m.topic === BOOKMARKS_TOPIC).length, 1)
  off()
  assert.equal(fire, null)
  assert.equal((await bus.invoke(reader, { archetype: "bookmarks", action: "list", payload: {} })).ok, false)
})
