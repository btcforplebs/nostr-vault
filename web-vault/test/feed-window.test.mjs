// The feed's ceiling and its draw window (net/feed-window.js): a long session must not grow the DOM, the heap or the
// per-sync read without bound, and neither end of the list may eat the notes the reader is on.
import test from "node:test"
import assert from "node:assert/strict"
import { MAX_NOTES, DRAW_NOTES, GROW_PX, capNotes, capOlder, readLimit, drawNotes, nextDraw, mergeReload } from "../src/net/feed-window.js"

const many = n => Array.from({ length: n }, (_, i) => ({ id: String(i), created_at: 1_000_000 - i }))

test("the ceiling keeps the newest and drops the oldest", () => {
  const notes = many(MAX_NOTES + 250)
  const kept = capNotes(notes)
  assert.equal(kept.length, MAX_NOTES)
  assert.equal(kept[0].id, "0", "newest first")
  assert.equal(kept.at(-1).id, String(MAX_NOTES - 1), "the bottom goes, which Older re-reads")
  assert.equal(capNotes(notes, 10).length, 10)
  assert.equal(capNotes(null), null)
  const under = many(3)
  assert.equal(capNotes(under), under, "under the ceiling: same array, no copy")
})

// Spec 2 as first written applied capNotes to the Older append, which dropped exactly the page Older had just read:
// 500 held + 100 fetched = 600, slice(0, 500) = the 500 already held, nothing new drawn, cursor unmoved, load again.
// That is D1, and these two assertions are the regression.
test("Older's ceiling keeps the page just read, and the head cap is what would have thrown it away", () => {
  const held = many(MAX_NOTES).map((n, i) => ({ ...n, id: `h${i}` }))
  const older = Array.from({ length: 100 }, (_, i) => ({ id: `o${i}`, created_at: 900_000 - i }))
  const joined = [...held, ...older]
  const kept = capOlder(joined)
  assert.equal(kept.length, MAX_NOTES)
  assert.equal(kept.at(-1).id, "o99", "the page just fetched is the bottom of what is kept: `until` moves on")
  assert.equal(kept[0].id, "h100", "the newest are what goes: 100 of the 500 already held")
  const head = capNotes(joined)
  assert.ok(!head.some(n => n.id.startsWith("o")), "head-capping the same list drops the whole fetched page (D1)")
})

test("neither cap takes the note the reader is on", () => {
  const notes = many(MAX_NOTES + 40)
  const reading = String(MAX_NOTES + 20)
  const head = capNotes(notes, MAX_NOTES, { protect: reading })
  assert.equal(head.at(-1).id, reading, "the list holds one note past the reader rather than delete it")
  assert.ok(head.length <= MAX_NOTES + 21, "and only that far: the overflow is what sits below the reader, not a new list")
  const tail = capOlder(notes, MAX_NOTES, { protect: "5" })
  assert.equal(tail[0].id, "5", "the first note in view is not trimmed off the top either")
  assert.equal(capOlder(notes, MAX_NOTES, { protect: "nope" }).length, MAX_NOTES, "an id that is not there changes nothing")
})

test("a sync never asks Haven for more than the ceiling", () => {
  assert.equal(readLimit(100, 0), 100)
  assert.equal(readLimit(100, 240), 240)
  assert.equal(readLimit(100, MAX_NOTES + 900), MAX_NOTES)
  assert.equal(readLimit(300, 50), 300, "Media's bigger first page still fits")
})

test("the draw window grows to the ceiling and no further", () => {
  const notes = many(MAX_NOTES)
  assert.equal(drawNotes(notes).length, DRAW_NOTES)
  assert.equal(drawNotes(notes, DRAW_NOTES * 2).length, DRAW_NOTES * 2)
  assert.equal(drawNotes(notes, 10_000).length, MAX_NOTES)
  assert.equal(drawNotes(null).length, 0)
})

// D2: the window has to be grown by a step that runs after every draw. A scroll-only trigger cannot fire at exactly a
// window's worth of notes — the page cannot scroll any further — so the list would stop at DRAW_NOTES for good.
test("the window steps once per draw, stops at what there is, and never passes the ceiling", () => {
  assert.equal(nextDraw(DRAW_NOTES, MAX_NOTES), DRAW_NOTES * 2)
  assert.equal(nextDraw(0, 400), DRAW_NOTES, "a screen taller than its notes fills in steps, not at once")
  assert.equal(nextDraw(DRAW_NOTES, DRAW_NOTES), DRAW_NOTES, "nothing more to draw: no state change, no re-render")
  assert.equal(nextDraw(MAX_NOTES - 10, 10_000), MAX_NOTES, "clamped at the ceiling")
  assert.equal(nextDraw(100, 120), 120, "clamped at what there is")
  assert.equal(GROW_PX > 0, true)
})

// A sync used to replace the whole list (setNotes(read)): 145 px of jump on a reload. The anchored reload keeps the
// note objects on screen and only lets genuinely new notes in above. These are the cases that decides.
const page = (n, top, prefix = "p") => Array.from({ length: n }, (_, i) => ({ id: `${prefix}${i}`, created_at: top - i }))

test("a reload keeps the objects on screen and puts only new notes in above them", () => {
  const list = page(100, 1_000_000)                       // what the screen holds
  const read = page(100, 1_000_000)                       // Haven's answer: the same notes, new objects
  const newNote = { id: "new", created_at: 1_000_100 }
  const { notes, fresh, changed } = mergeReload(list, [newNote, ...read], { seenTop: 1_000_000 })
  assert.deepEqual(fresh.map(n => n.id), ["new"])
  assert.equal(changed, true)
  assert.equal(notes.length, 101)
  assert.equal(notes[0].id, "new")
  assert.equal(notes[1], list[0], "the row the reader is on keeps its object, so its card is not redrawn")
})

test("a note the phone deleted is dropped from the list", () => {
  const list = page(4, 1_000_000)
  const read = [list[0], list[2], list[3]]                // p1 is gone from Haven
  const { notes } = mergeReload(list, read, { seenTop: 1_000_000 })
  assert.deepEqual(notes.map(n => n.id), ["p0", "p2", "p3"])
})

// The case the ceiling creates: the list is the older block "Older" read (the top was trimmed), and Haven's page is
// the whole newest 500 — all of it newer than the list's top. Adding that page back above the reader is what pushed
// them down the list: the reload must add only what is actually new (nothing here), and leave their block alone.
test("a reload does not put the page the ceiling dropped back above the reader", () => {
  const older = page(500, 900_000, "o")                   // held: notes 500..999 (oldest at the bottom)
  const read = [page(500, 1_000_000, "p")[0], ...page(500, 1_000_000, "p")]
  const reader = older[10].id
  const { notes, fresh, changed } = mergeReload(older, read.slice(0, 500), { seenTop: 1_000_000, protect: reader })
  assert.deepEqual(fresh, [], "nothing in the page is new to the reader")
  assert.equal(changed, false, "the list is left exactly as it was")
  assert.equal(notes, older)
  assert.equal(notes.findIndex(n => n.id === reader), 10, "the reader's note has not moved")
})

test("at the ceiling the reader's own note is the one that survives, from either end", () => {
  const older = page(MAX_NOTES, 900_000, "o")
  const fresh = [{ id: "new", created_at: 1_000_000 }]
  const read = [{ id: "new", created_at: 1_000_000 }]
  // The reader at the top of the block: the oldest note goes, the list stays at the ceiling.
  const top = mergeReload(older, read, { seenTop: 900_000, protect: older[0].id })
  assert.equal(top.notes.length, MAX_NOTES)
  assert.equal(top.notes[0].id, "new")
  assert.ok(top.notes.some(n => n.id === older[0].id), "the note in view is still there")
  // The reader at the bottom of it: the newest gives way instead, so the note under the thumb is not deleted.
  const bottom = mergeReload(older, read, { seenTop: 900_000, protect: older.at(-1).id })
  assert.equal(bottom.notes.length, MAX_NOTES)
  assert.equal(bottom.notes.at(-1).id, older.at(-1).id, "the bottom note the reader is on is kept")
  assert.equal(bottom.notes[0].id, older[0].id, "and the new note from above is what went")
  assert.ok(!bottom.notes.some(n => n.id === "new"), "the list is the block the reader is reading, unchanged")
  assert.equal(fresh.length, 1)
})
