// "Your space"'s editable layout (src/desktop/space/space-layout.js): order, on/off, collapsed, kept per account, and
// the saved shape a later vault sync shares with the iPad.
import test from "node:test"
import assert from "node:assert/strict"
import { defaultLayout, normalize, shownPanels, hiddenPanels, setOn, setOpen, moveBy, moveBefore, sameLayout, readLayout, writeLayout, LAYOUT_V, SYNC_D, setRail, resetPanels } from "../src/desktop/space/space-layout.js"
import { defaultRail } from "../src/desktop/rail/rail-favs.js"
import { PANEL_IDS } from "../src/desktop/space/panel-ids.js"
import { readFileSync } from "node:fs"
import { accountKeys } from "../src/haven/vault.js"

const IDS = ["live-vault", "wot-mini", "messages"]
const ids = l => l.panels.map(p => p.id)
const store = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k), key: i => [...m.keys()][i] ?? null, get length() { return m.size } } }

test("the panel ids are the ones the iPad shares, in the default order", () => {
  // panels.js pulls in the panels' JSX, so its ids are read from its text.
  const src = readFileSync(new URL("../src/desktop/space/panels.js", import.meta.url), "utf8")
  assert.deepEqual([...src.matchAll(/\{ id: "([^"]+)"/g)].map(m => m[1]), IDS)
  assert.deepEqual(PANEL_IDS, IDS)
  assert.equal(SYNC_D, "nostr-vault-space-layout")
})

test("the default layout: every panel, in order, shown and open, and the rail's default sections", () => {
  assert.deepEqual(defaultLayout(IDS), { v: LAYOUT_V, at: 0, panels: IDS.map(id => ({ id, on: true, open: true })), rail: defaultRail() })
})

test("the rail rides in the same layout: kept through normalize, and an edit of it moves `at`", () => {
  const rail = [{ type: "section", id: "feed" }, { type: "hashtag", tag: "nostr" }]
  const l = normalize({ at: 5, panels: [], rail }, IDS)
  assert.deepEqual(l.rail, rail)
  const next = setRail(l, [...rail, { type: "relay", url: "wss://nos.lol" }], 9)
  assert.equal(next.at, 9)
  assert.deepEqual(next.panels, l.panels)
  assert.equal(setRail(l, l.rail), l)
  // Resetting Your space's panels keeps the rail.
  assert.deepEqual(resetPanels(next, IDS, 10).rail, next.rail)
})

test("normalize: junk is the default; bad entries and repeats drop out; flags default to on/open", () => {
  for (const bad of [null, "x", 3, {}, { panels: "no" }]) assert.deepEqual(normalize(bad, IDS), defaultLayout(IDS))
  const l = normalize({ v: 1, at: 50, panels: [{ id: "messages", on: false }, null, { id: "" }, { id: 7 }, { id: "messages" }, { id: "live-vault", open: false }, { id: "wot-mini" }] }, IDS)
  assert.deepEqual(l, { v: 1, at: 50, panels: [{ id: "messages", on: false, open: true }, { id: "live-vault", on: true, open: false }, { id: "wot-mini", on: true, open: true }], rail: defaultRail() })
})

test("normalize: an id from a newer app is kept but not drawn; a panel added later goes in at its place, shown", () => {
  const l = normalize({ at: 9, panels: [{ id: "zaps-in" }, { id: "messages" }, { id: "live-vault" }] }, IDS)
  // wot-mini comes after live-vault in panels.js, so it goes in after it.
  assert.deepEqual(ids(l), ["zaps-in", "messages", "live-vault", "wot-mini"])
  assert.deepEqual(shownPanels(l, IDS).map(p => p.id), ["messages", "live-vault", "wot-mini"])
  // Nothing before it known: at the top.
  assert.deepEqual(ids(normalize({ panels: [{ id: "messages" }] }, IDS)), ["live-vault", "wot-mini", "messages"])
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
  const l = normalize({ panels: [{ id: "live-vault" }, { id: "zaps-in" }, { id: "wot-mini", on: false }, { id: "messages" }] }, IDS)
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
})
