// The desktop's two side columns (src/desktop/space/columns.js, plan NV_WEB_ONE_PLAN.md step 3): which cards each
// column draws, moving within and across columns, sizes, + Add's groups, taking off and Reset.
import test from "node:test"
import assert from "node:assert/strict"
import { LEFT, RIGHT, columnCards, moveInColumn, dropCard, moveAcross, setSize, addCard, takeOff, dropApp, resetColumns, isDefaultColumns, surfaceOf, appSize, addGroups, appCardId, lineOfCard, isAppCard } from "../src/desktop/space/columns.js"
import { defaultLayout, normalize, readLayout, writeLayout } from "../src/desktop/space/space-layout.js"
import { PANEL_IDS } from "../src/desktop/space/panel-ids.js"

const IDS = PANEL_IDS
const PUB = "a".repeat(64)
const APP = appCardId(`${PUB}:clock`)
const ours = id => IDS.includes(id)
const drawable = id => ours(id) || id === APP
const col = (l, side) => columnCards(l, side, drawable).map(p => p.id)
const base = () => defaultLayout(IDS)

test("a layout from before this step: every card on the right, the left column empty", () => {
  const l = base()
  assert.deepEqual(col(l, RIGHT), IDS)
  assert.deepEqual(col(l, LEFT), [])
  // Nothing new is written into an entry that stays on the right at its own size.
  assert.deepEqual(l.panels[0], { id: "live-vault", on: true, open: true })
})

test("app card ids carry the app's line, colons in its d tag and all", () => {
  assert.equal(lineOfCard(appCardId(`${PUB}:a:b`)), `${PUB}:a:b`)
  assert.equal(isAppCard("live-vault"), false)
  assert.equal(lineOfCard("live-vault"), null)
})

test("drop across: a card goes to the other column, before the card it was dropped on or at its end", () => {
  let l = dropCard(base(), "messages", LEFT, null, 5)
  assert.deepEqual(col(l, LEFT), ["messages"])
  assert.equal(l.panels.find(p => p.id === "messages").side, LEFT)
  assert.equal(l.at, 5)
  l = dropCard(l, "live-now", LEFT, "messages", 6)
  assert.deepEqual(col(l, LEFT), ["live-now", "messages"])
  // Back to the right: the side field goes, so the entry is as it was.
  l = dropCard(l, "messages", RIGHT, "live-vault", 7)
  assert.deepEqual(col(l, RIGHT), ["messages", "live-vault", "wot-mini", "my-devices", "on-this-day"])
  assert.deepEqual(l.panels.find(p => p.id === "messages"), { id: "messages", on: true, open: true })
  // Dropped where it already is: the same object, nothing saved.
  assert.equal(dropCard(l, "messages", RIGHT, "live-vault"), l)
  assert.equal(dropCard(l, "messages", RIGHT, "messages"), l)
  assert.equal(dropCard(l, "nope", RIGHT, null), l)
})

test("move across: the other column's end", () => {
  const l = moveAcross(moveAcross(base(), "wot-mini", 1), "live-vault", 2)
  assert.deepEqual(col(l, LEFT), ["wot-mini", "live-vault"])
  assert.deepEqual(col(moveAcross(l, "wot-mini", 3), RIGHT).at(-1), "wot-mini")
})

test("up and down stay inside the card's own column", () => {
  let l = moveAcross(base(), "messages", 1) // left: messages; right: the other five
  assert.equal(moveInColumn(l, "messages", -1, drawable), l)
  assert.equal(moveInColumn(l, "messages", 1, drawable), l)
  l = moveInColumn(l, "my-devices", -1, drawable, 2)
  assert.deepEqual(col(l, RIGHT), ["live-vault", "my-devices", "wot-mini", "live-now", "on-this-day"])
  assert.deepEqual(col(l, LEFT), ["messages"])
})

test("sizes: S, M or L; null back to the card's own; anything else refused", () => {
  let l = setSize(base(), "live-now", "S", 3)
  assert.equal(l.panels.find(p => p.id === "live-now").size, "S")
  assert.equal(setSize(l, "live-now", "S"), l)
  assert.equal(setSize(l, "live-now", "XL"), l)
  l = setSize(l, "live-now", null, 4)
  assert.deepEqual(l.panels.find(p => p.id === "live-now"), { id: "live-now", on: true, open: true })
})

test("+ Add: ours comes back where it was in that column; an app goes at the column's end at M", () => {
  let l = takeOff(base(), "messages", 1)
  assert.deepEqual(col(l, RIGHT), IDS.filter(x => x !== "messages"))
  l = addCard(l, "messages", RIGHT, 2)
  assert.deepEqual(col(l, RIGHT), IDS)
  // Added to the other column: at its end.
  l = addCard(takeOff(l, "wot-mini", 3), "wot-mini", LEFT, 4)
  assert.deepEqual(col(l, LEFT), ["wot-mini"])
  l = addCard(l, APP, LEFT, 5)
  assert.deepEqual(col(l, LEFT), ["wot-mini", APP])
  assert.deepEqual(l.panels.find(p => p.id === APP), { id: APP, on: true, open: true, side: LEFT, size: "M" })
  assert.equal(addCard(l, APP, LEFT), l)
})

test("taking an app's card off drops its entry (the app stays installed); ours stays, off", () => {
  let l = addCard(base(), APP, RIGHT, 1)
  l = takeOff(l, APP, 2)
  assert.equal(l.panels.some(p => p.id === APP), false)
  l = takeOff(l, "live-now", 3)
  assert.deepEqual(l.panels.find(p => p.id === "live-now"), { id: "live-now", on: false, open: true })
})

test("removing an app takes its card from the layout", () => {
  const l = addCard(base(), APP, LEFT, 1)
  assert.equal(dropApp(l, `${PUB}:clock`, 2).panels.some(p => p.id === APP), false)
  const b = base()
  assert.equal(dropApp(b, `${PUB}:clock`), b)
})

test("Reset: our six on the right, in order; the left column empty; no app cards; the pins untouched", () => {
  const changed = addCard(moveAcross(setSize(base(), "live-now", "L", 1), "messages", 2), APP, LEFT, 3)
  assert.equal(isDefaultColumns(changed, IDS), false)
  const r = resetColumns({ ...changed, pins: [{ type: "hashtag", t: "x" }] }, IDS, 4)
  assert.equal(isDefaultColumns(r, IDS), true)
  assert.deepEqual(r.pins, [{ type: "hashtag", t: "x" }])
  assert.deepEqual(col(r, LEFT), [])
})

test("an app card and its side survive the save and read back (unknown ids kept, as the layout always did)", () => {
  const m = new Map(), storage = { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) }
  const l = addCard(moveAcross(base(), "messages", 1), APP, LEFT, 2)
  writeLayout(PUB, l, storage)
  const back = readLayout(PUB, IDS, storage)
  assert.deepEqual(col(back, LEFT), ["messages", APP])
  assert.deepEqual(normalize(back, IDS).panels, l.panels)
})

test("surface tag: a widget lists its sizes (none listed: all); any other app is a panel at M or L", () => {
  assert.deepEqual(surfaceOf({ tags: [["surface", "widget", "S", "M"]] }), { widget: true, sizes: ["S", "M"] })
  assert.deepEqual(surfaceOf({ tags: [["surface", "widget"]] }), { widget: true, sizes: ["S", "M", "L"] })
  assert.deepEqual(surfaceOf({ tags: [["surface", "page"]] }), { widget: false, sizes: ["M", "L"] })
  assert.deepEqual(surfaceOf({}), { widget: false, sizes: ["M", "L"] })
  assert.equal(appSize("S", ["M", "L"]), "M")
  assert.equal(appSize("S", ["S", "M"]), "S")
  assert.equal(appSize(undefined, ["L"]), "L")
})

test("+ Add's groups: ours not shown, installed apps without a card (widgets first), the catalog minus what's installed or can't run", () => {
  const ev = (d, widget) => ({ kind: 35129, pubkey: PUB, created_at: 1, tags: [["d", d], ...(widget ? [["surface", "widget"]] : [])] })
  const installed = [{ line: `${PUB}:clock`, event: ev("clock") }, { line: `${PUB}:notes`, event: ev("notes", true) }, { line: `${PUB}:on`, event: ev("on") }]
  const catalog = [
    { line: `${PUB}:clock`, event: ev("clock"), runs: true },
    { line: `${PUB}:new`, event: ev("new"), runs: true },
    { line: `${PUB}:w`, event: ev("w", true), runs: true },
    { line: `${PUB}:broken`, event: ev("broken"), runs: false },
  ]
  const layout = addCard(takeOff(base(), "live-now", 1), appCardId(`${PUB}:on`), LEFT, 2)
  const g = addGroups({ layout, ids: IDS, installed, catalog, manifestOf: e => ({ title: e.tags[0][1] }) })
  assert.deepEqual(g.ours, ["live-now"])
  assert.deepEqual(g.installed.map(a => a.line), [`${PUB}:notes`, `${PUB}:clock`])
  assert.deepEqual(g.catalog.map(e => e.line), [`${PUB}:w`, `${PUB}:new`])
})
