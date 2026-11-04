// The desktop layout (src/desktop/space/space-layout.js): Your space's panels (order, on/off, collapsed), the rail's
// pins riding along, kept per account, and docs/SPACE_LAYOUT.md's normalising, the same cases as the iPad's
// SpaceLayoutTests.
import test from "node:test"
import assert from "node:assert/strict"
import { defaultLayout, normalize, shownPanels, hiddenPanels, setOn, setOpen, moveBy, moveBefore, sameLayout, readLayout, writeLayout, LAYOUT_V, SYNC_D, setPins, resetPanels, clampAt, MAX_SKEW_S } from "../src/desktop/space/space-layout.js"
import { defaultPins } from "../src/desktop/rail/rail-favs.js"
import { PANEL_IDS } from "../src/desktop/space/panel-ids.js"
import { readFileSync } from "node:fs"
import { accountKeys } from "../src/haven/vault.js"

const IDS = ["live-vault", "wot-mini", "messages"]
// The panels the app ships (panels.js, panel-ids.js); the layout rules below run on IDS.
const SHIPPED = [...IDS, "my-devices"]
const ids = l => l.panels.map(p => p.id)
const store = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k), key: i => [...m.keys()][i] ?? null, get length() { return m.size } } }

test("the panel ids are the ones the iPad shares, in the default order", () => {
  // panels.js pulls in the panels' JSX, so its ids are read from its text.
  const src = readFileSync(new URL("../src/desktop/space/panels.js", import.meta.url), "utf8")
  assert.deepEqual([...src.matchAll(/\{ id: "([^"]+)"/g)].map(m => m[1]), SHIPPED)
  assert.deepEqual(PANEL_IDS, SHIPPED)
  assert.equal(SYNC_D, "nostr-vault-space-layout")
})

test("the default layout: the default pins, every panel in order, shown and open", () => {
  assert.deepEqual(defaultLayout(IDS), { v: LAYOUT_V, at: 0, pins: defaultPins(), panels: IDS.map(id => ({ id, on: true, open: true })) })
})

test("the pins ride in the same layout: kept through normalize, and an edit of them moves `at`", () => {
  const l = normalize({ v: 1, at: 5, panels: [], pins: [{ type: "hashtag", t: "nostr" }] }, IDS)
  // Sections left out go back in ahead of it (none comes before them by default).
  assert.deepEqual(l.pins.at(-1), { type: "hashtag", t: "nostr" })
  assert.equal(l.pins.filter(p => p.type === "section").length, 9)
  const next = setPins(l, [...l.pins, { type: "relay", url: "wss://nos.lol" }], 9)
  assert.equal(next.at, 9)
  assert.deepEqual(next.panels, l.panels)
  assert.equal(setPins(l, l.pins), l)
  // Resetting Your space's panels keeps the pins.
  assert.deepEqual(resetPanels(next, IDS, 10).pins, next.pins)
})

test("normalize: not an object or no whole-number v is the default; a newer v is left alone", () => {
  for (const bad of [null, "x", 3, [], {}, { panels: [] }, { v: "1" }, { v: 1.5 }, { v: -1 }, { v: NaN }, { v: Infinity }]) {
    assert.deepEqual(normalize(bad, IDS), defaultLayout(IDS), JSON.stringify(bad))
  }
  assert.equal(normalize({ v: 2, at: 9, pins: [], panels: [] }, IDS), null, "a newer format: leave it alone")
  assert.ok(normalize({ v: 0, panels: [] }, IDS), "v 0 is a whole number at or under ours")
})

test("normalize: bad panel entries and repeats drop out; on/open default to true; extra fields kept", () => {
  const l = normalize({ v: 1, at: 50, panels: [{ id: "messages", on: false, h: 3 }, null, [], { id: "" }, { id: 7 }, { id: "messages" }, { id: "live-vault", open: false }, { id: "wot-mini", on: "yes" }] }, IDS)
  assert.deepEqual(l.panels, [{ id: "messages", on: false, open: true, h: 3 }, { id: "live-vault", on: true, open: false }, { id: "wot-mini", on: true, open: true }])
})

test("normalize keeps every top-level key it doesn't use, exactly as read (a newer app's, the iPad's)", () => {
  const saved = { v: 1, at: 7, pins: [], panels: [], theme: { dark: true }, ipad: [1, 2] }
  const l = normalize(saved, IDS)
  assert.deepEqual(l.theme, { dark: true })
  assert.deepEqual(l.ipad, [1, 2])
  // ... and through an edit and a save.
  assert.deepEqual(setOn(l, "messages", false, 8).theme, { dark: true })
  assert.deepEqual(JSON.parse(JSON.stringify(setPins(l, defaultPins(), 9))).ipad, [1, 2])
})

test("normalize clamps at to whole seconds from 0 to now + 15 min (the iPad's maxSkew)", () => {
  const now = 1_000_000
  assert.equal(MAX_SKEW_S, 900)
  assert.equal(clampAt(5.9, now), 5)
  assert.equal(clampAt(now + 10_000, now), now + 900)
  assert.equal(clampAt(1e300, now), now + 900)
  for (const bad of [-5, 0, NaN, Infinity, "7", null, undefined]) assert.equal(clampAt(bad, now), 0, String(bad))
  assert.equal(normalize({ v: 1, at: now + 5000, panels: [] }, IDS, { now }).at, now + 900)
  assert.equal(normalize({ v: 1, at: "soon", panels: [] }, IDS, { now }).at, 0)
})

test("normalize: an id from a newer app is kept but not drawn; a panel added later goes in at its place, shown", () => {
  const l = normalize({ v: 1, at: 9, panels: [{ id: "zaps-in" }, { id: "messages" }, { id: "live-vault" }] }, IDS)
  // wot-mini comes after live-vault in panels.js, so it goes in after it.
  assert.deepEqual(ids(l), ["zaps-in", "messages", "live-vault", "wot-mini"])
  assert.deepEqual(shownPanels(l, IDS).map(p => p.id), ["messages", "live-vault", "wot-mini"])
  // Nothing before it known: at the top.
  assert.deepEqual(ids(normalize({ v: 1, panels: [{ id: "messages" }] }, IDS)), ["live-vault", "wot-mini", "messages"])
})

test("take a panel off, add it back where it was; collapse one", () => {
  let l = setOn(defaultLayout(IDS), "wot-mini", false, 10)
  assert.equal(l.at, 10)
  assert.deepEqual(shownPanels(l, IDS).map(p => p.id), ["live-vault", "messages"])
  assert.deepEqual(hiddenPanels(l, IDS), ["wot-mini"])
  l = setOn(l, "wot-mini", true, 11)
  assert.deepEqual(shownPanels(l, IDS).map(p => p.id), IDS)
  assert.deepEqual(hiddenPanels(l, IDS), [])
  l = setOpen(l, "messages", false, 12)
  assert.equal(l.panels.find(p => p.id === "messages").open, false)
  assert.ok(!sameLayout(l, defaultLayout(IDS)))
  assert.ok(sameLayout(setOpen(l, "messages", true, 13), defaultLayout(IDS)))
})

test("up/down moves among the drawn panels, stepping over hidden and unknown ones; ends do nothing", () => {
  const l = normalize({ v: 1, panels: [{ id: "live-vault" }, { id: "zaps-in" }, { id: "wot-mini", on: false }, { id: "messages" }] }, IDS)
  const up = moveBy(l, "messages", -1, IDS, 5)
  assert.deepEqual(ids(up), ["messages", "zaps-in", "wot-mini", "live-vault"])
  assert.equal(up.at, 5)
  assert.equal(moveBy(l, "live-vault", -1, IDS), l)
  assert.equal(moveBy(l, "messages", 1, IDS), l)
  assert.equal(moveBy(l, "wot-mini", 1, IDS), l) // hidden: not drawn, not moved
})

test("drag: drop before a panel or at the end; on itself or its own spot changes nothing", () => {
  const l = defaultLayout(IDS)
  assert.deepEqual(ids(moveBefore(l, "messages", "live-vault", 3)), ["messages", "live-vault", "wot-mini"])
  assert.deepEqual(ids(moveBefore(l, "live-vault", null, 3)), ["wot-mini", "messages", "live-vault"])
  assert.equal(moveBefore(l, "wot-mini", "wot-mini"), l)
  assert.equal(moveBefore(l, "wot-mini", "messages"), l) // already right before it
  assert.equal(moveBefore(l, "nope", "messages"), l)
  assert.equal(moveBefore(l, "messages", "nope"), l)
})

test("kept per account in this browser, and wiped with the account's keys at sign-out", () => {
  const s = store(), me = "f".repeat(64), other = "e".repeat(64)
  assert.deepEqual(readLayout(me, IDS, s), defaultLayout(IDS))
  const l = setOn(defaultLayout(IDS), "messages", false, 77)
  writeLayout(me, l, s)
  assert.deepEqual(readLayout(me, IDS, s), l)
  assert.deepEqual(readLayout(other, IDS, s), defaultLayout(IDS))
  assert.ok(accountKeys(me, s).includes(`nv-space-layout:${me}`))
  s.setItem(`nv-space-layout:${other}`, "{not json")
  assert.deepEqual(readLayout(other, IDS, s), defaultLayout(IDS))
  s.setItem(`nv-space-layout:${other}`, JSON.stringify({ v: 2, pins: [] }))
  assert.deepEqual(readLayout(other, IDS, s), defaultLayout(IDS), "a newer format draws the default")
})
