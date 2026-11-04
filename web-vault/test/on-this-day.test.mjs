// The On this day panel's rules (src/desktop/space/on-this-day.js): today's date one and two years back as local days,
// the user's own top-level notes inside them, read from their own vault only.
import test from "node:test"
import assert from "node:assert/strict"
import { dayWindow, dayWindows, dayKey, notesOnDay, dayFilter, readOnThisDay, yearsText, lineText, PER_YEAR } from "../src/desktop/space/on-this-day.js"
import { PANEL_IDS } from "../src/desktop/space/panel-ids.js"

const ME = "a".repeat(64), OTHER = "b".repeat(64)
const at = (y, m, d, h = 12) => Math.floor(new Date(y, m, d, h).getTime() / 1000)
const note = (id, created_at, extra = {}) => ({ id, kind: 1, pubkey: ME, created_at, content: `${id} text`, tags: [], ...extra })
const NOW = new Date(2026, 10, 4, 15, 30).getTime()

test("the panel id is shared with the iPad and comes after Messages", () => {
  assert.equal(PANEL_IDS.at(-1), "on-this-day")
})

test("a window is the whole local day, that many years back", () => {
  const w = dayWindow(NOW, 1)
  assert.deepEqual(w, { years: 1, since: at(2025, 10, 4, 0), until: at(2025, 10, 5, 0) })
  assert.deepEqual(dayWindows(NOW).map(w => w.years), [1, 2])
  assert.equal(dayWindows(NOW)[1].since, at(2024, 10, 4, 0))
})

test("29 February has no day in a year without one", () => {
  const leap = new Date(2028, 1, 29, 9).getTime()
  assert.equal(dayWindow(leap, 1), null)
  assert.equal(dayWindow(leap, 4).since, at(2024, 1, 29, 0))
  assert.deepEqual(dayWindows(leap).map(w => w.years), [])
})

test("the day key changes at local midnight", () => {
  assert.equal(dayKey(new Date(2026, 10, 4, 0, 0).getTime()), dayKey(new Date(2026, 10, 4, 23, 59).getTime()))
  assert.notEqual(dayKey(new Date(2026, 10, 4, 23, 59).getTime()), dayKey(new Date(2026, 10, 5, 0, 0).getTime()))
})

test("only the user's own top-level kind 1 notes on that day, oldest first, capped", () => {
  const w = dayWindow(NOW, 1)
  const evs = [
    note("late", at(2025, 10, 4, 22)),
    note("early", at(2025, 10, 4, 7)),
    note("early", at(2025, 10, 4, 7)), // twice from the store
    note("day-before", at(2025, 10, 3, 23)),
    note("next-day", w.until),
    note("theirs", at(2025, 10, 4, 9), { pubkey: OTHER }),
    note("like", at(2025, 10, 4, 9), { kind: 7 }),
    note("reply", at(2025, 10, 4, 9), { tags: [["e", "c".repeat(64), "", "reply"]] }),
  ]
  assert.deepEqual(notesOnDay(evs, ME, w).map(e => e.id), ["early", "late"])
  const many = Array.from({ length: 6 }, (_, i) => note(`n${i}`, at(2025, 10, 4, 8 + i)))
  assert.equal(notesOnDay(many, ME, w).length, PER_YEAR)
})

test("it reads the user's own vault for each year, nothing else", async () => {
  const asked = []
  const vault = { outbox: { query: async f => { asked.push(f); return f.since === at(2025, 10, 4, 0) ? [note("x", at(2025, 10, 4, 10))] : [] } } }
  const years = await readOnThisDay(vault, ME, NOW)
  assert.deepEqual(years.map(y => [y.years, y.notes.map(n => n.id)]), [[1, ["x"]], [2, []]])
  assert.deepEqual(asked[0], dayFilter(ME, dayWindow(NOW, 1)))
  assert.deepEqual(asked[0].authors, [ME])
  assert.equal(asked[0].until, at(2025, 10, 5, 0) - 1)
})

test("a vault that fails to answer reads as nothing, not an error", async () => {
  const vault = { outbox: { query: async () => { throw new Error("closed") } } }
  const years = await readOnThisDay(vault, ME, NOW)
  assert.ok(years.every(y => y.notes.length === 0))
})

test("words for the year label and a picture-only note", () => {
  assert.equal(yearsText(1), "1 year ago")
  assert.equal(yearsText(2), "2 years ago")
  assert.equal(lineText(note("p", 0, { content: "https://x.example/a.jpg" })), "Photo")
  assert.equal(lineText(note("t", 0, { content: "gm https://x.example/a.jpg" })), "gm")
})
