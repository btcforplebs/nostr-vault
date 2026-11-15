// Bug run group 7: the desktop's keys and hover card over the Reader napplet (napplet-keys.js). The Reader passes key
// presses and hovers over the bus; the shell reads them with its one key map and draws its one hover card.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import { nappletKey, pageHover, ROW_CMDS, KEY_TOPIC, HOVER_TOPIC } from "../src/napplet/napplet-keys.js"
import { keyCommand } from "../src/desktop/keys.js"
import { createBus } from "../src/napplet/bus.js"
import { readerIntents } from "../src/napplet/reader-intents.js"

const PK = "a".repeat(64)

test("nappletKey: only the fields keyCommand reads, booleans strict; long or missing keys dropped", () => {
  assert.deepEqual(nappletKey({ key: "j", metaKey: "yes", typing: true, extra: 1 }), { key: "j", metaKey: false, ctrlKey: false, altKey: false, typing: true })
  assert.equal(nappletKey({ key: "x".repeat(13) }), null)
  assert.equal(nappletKey({}), null)
  assert.equal(nappletKey(null), null)
})

test("the Reader's keys read the same as the page's: rows go back to the Reader, the rest stay the shell's", () => {
  const cmd = k => keyCommand(nappletKey(k))
  for (const [k, c] of [["j", "next"], ["k", "prev"], ["Enter", "open"], ["o", "open"], ["r", "reply"], ["l", "like"], ["z", "zap"]]) {
    assert.equal(cmd({ key: k }).cmd, c); assert.ok(ROW_CMDS.has(c), c)
  }
  for (const [k, c] of [["/", "search"], ["n", "compose"], ["?", "help"], ["Escape", "close"], ["]", "foldSpace"]]) {
    assert.equal(cmd({ key: k }).cmd, c); assert.ok(!ROW_CMDS.has(c), c)
  }
  assert.equal(cmd({ key: "j", typing: true }), null, "typing in a field: no shortcut")
  assert.deepEqual(keyCommand({ ...nappletKey({ key: "f" }), pending: "g" }), { cmd: "go", arg: "feed" })
})

test("pageHover: a hover in the frame lands at the same spot on the page; junk is ignored", () => {
  assert.deepEqual(pageHover({ pubkey: PK, rect: { left: 10, top: 20, right: 50, bottom: 40 } }, { left: 300, top: 60 }), { pubkey: PK, rect: { left: 310, top: 80, right: 350, bottom: 100 } })
  assert.deepEqual(pageHover({ out: true }), { out: true })
  assert.equal(pageHover({ pubkey: "x", rect: { left: 0, top: 0, right: 1, bottom: 1 } }, { left: 0, top: 0 }), null)
  assert.equal(pageHover({ pubkey: PK, rect: { left: NaN, top: 0, right: 1, bottom: 1 } }, { left: 0, top: 0 }), null)
  assert.equal(pageHover({ pubkey: PK, rect: { left: 0, top: 0, right: 1, bottom: 1 } }, undefined), null)
})

test("readerIntents: the shell hears nv.key and nv.hover from the Reader", () => {
  const bus = createBus(), keys = [], hovers = []
  readerIntents({ bus, openCompose: async () => ({}), onComposeDone: () => {}, openUrl: () => {}, onKey: p => keys.push(p), onHover: p => hovers.push(p) })
  const reader = { dTag: "nv-reader", send: () => {} }
  bus.emit(reader, KEY_TOPIC, { key: "j" }); bus.emit(reader, HOVER_TOPIC, { out: true })
  assert.deepEqual(keys, [{ key: "j" }]); assert.deepEqual(hovers, [{ out: true }])
})

test("desktop shell: row commands fall to the Reader when its pane is the list; PeekCard takes the Reader's hovers", () => {
  const shell = fs.readFileSync(new URL("../src/desktop/DesktopShell.jsx", import.meta.url), "utf8")
  assert.match(shell, /if \(ROW_CMDS\.has\(c\.cmd\) && !listRows\(\)\.length && readerShown\(\)\) return void dispatchEvent\(new CustomEvent\(READER_CMD_EVENT/)
  assert.match(shell, /addEventListener\(NAPPLET_KEY_EVENT, onNappletKey\)/)
  assert.match(fs.readFileSync(new URL("../src/desktop/PeekCard.jsx", import.meta.url), "utf8"), /addEventListener\(PEEK_EVENT, fromNapplet\)/)
})
