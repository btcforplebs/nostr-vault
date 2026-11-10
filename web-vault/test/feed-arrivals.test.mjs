// New notes joining the Following feed: a reload's page and a live subscription's batch (feed-window.js freshNotes and
// insertNotes). The bug this pins, measured on nostrvault.app 2026-11-10 with a throwaway account: a note posted as
// another account, stamped 15 s behind the list's top, reached the page in two relay frames and was never drawn — only
// after a reload. The watermark that keeps a ceiling-trimmed page from coming back was also dropping live notes whose
// `created_at` sat behind the top.
import test from "node:test"
import assert from "node:assert/strict"
import { freshNotes, insertNotes, capNotes, MAX_NOTES } from "../src/net/feed-window.js"

const note = (id, created_at) => ({ id, kind: 1, created_at, tags: [], content: id })
const ids = list => list.map(n => n.id)

test("a live note behind the list's top is still new: the watermark guards the reload page only", () => {
  const shown = [note("a", 100), note("b", 90)]
  // A reload page older than the top: dropped, as mergeReload needs (the ceiling trimmed it, it must not come back).
  assert.deepEqual(ids(freshNotes({ read: [note("old", 80)], seenTop: 100 })), [])
  assert.deepEqual(ids(freshNotes({ read: [note("new", 101)], seenTop: 100 })), ["new"])
  // The same note, delivered live: new to this screen whatever its timestamp, and placed by it.
  assert.deepEqual(ids(freshNotes({ live: [note("late", 85)], seenTop: 100 })), ["late"])
  assert.deepEqual(ids(freshNotes({ live: [note("late", 85), note("newer", 105)], seenTop: 100 })), ["newer", "late"])
  // A live note Haven already had is not added twice; newest first.
  assert.deepEqual(ids(freshNotes({ read: [note("new", 101)], live: [note("new", 101), note("late", 95)], seenTop: 100 })), ["new", "late"])
  assert.deepEqual(freshNotes({ read: shown, live: [], seenTop: 100 }), [], "nothing new, nothing to draw")
})

test("a note older than the top goes in at its place, not on top of newer notes", () => {
  const list = [note("a", 100), note("b", 90), note("c", 80)]
  assert.deepEqual(ids(insertNotes(list, [note("late", 85)])), ["a", "b", "late", "c"])
  assert.deepEqual(ids(insertNotes(list, [note("top", 110)])), ["top", "a", "b", "c"])
  assert.deepEqual(ids(insertNotes(list, [note("tail", 70)])), ["a", "b", "c", "tail"])
  // Two at once, and one already on screen: no duplicate, order kept.
  assert.deepEqual(ids(insertNotes(list, [note("late", 95), note("b", 90), note("gap", 85)])), ["a", "late", "b", "gap", "c"])
  // A tie never moves what is already on screen.
  assert.deepEqual(ids(insertNotes(list, [note("same", 90)])), ["a", "b", "same", "c"])
  assert.deepEqual(insertNotes(null, [note("first", 1)]).length, 1, "an empty list takes them")
  assert.equal(insertNotes(list, []), list, "nothing to add: the same list, so nothing redraws")
})

test("the ceiling still holds: notes going in at the top drop the oldest, and never the note being read", () => {
  const list = Array.from({ length: MAX_NOTES }, (_, i) => note(`n${i}`, 10_000 - i))
  const grown = insertNotes(list, [note("fresh", 20_000)])
  assert.equal(grown.length, MAX_NOTES)
  assert.equal(grown[0].id, "fresh")
  assert.equal(grown.at(-1).id, `n${MAX_NOTES - 2}`, "the oldest gave way")
  // A reader on the last note holds the list one note past them rather than lose what they are reading.
  const kept = insertNotes(list, [note("fresh", 20_000)], { protect: `n${MAX_NOTES - 1}` })
  assert.equal(kept.length, MAX_NOTES + 1)
  assert.equal(kept.at(-1).id, `n${MAX_NOTES - 1}`)
  assert.deepEqual(insertNotes(list, [], { max: 3 }), list, "no additions, no work")
  assert.equal(capNotes(grown, MAX_NOTES).length, MAX_NOTES)
})
