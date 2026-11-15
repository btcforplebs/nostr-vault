// Plan step 2 (OUTBOX/NV_WEB_ONE_PLAN.md): a note tapped in the Reader opens its thread beside the list, and a
// right-click in the Reader opens the shell's own menu. The shell side's checks: only the Reader may ask, only for a
// note id, a refusal falls back; the menu takes a signed note or a pubkey, at the page's coordinates, nothing else.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import { finalizeEvent, generateSecretKey, verifyEvent } from "nostr-tools/pure"
import { pageMenu, CTX_TOPIC } from "../src/napplet/napplet-keys.js"
import { createBus } from "../src/napplet/bus.js"
import { readerIntents, likedNote } from "../src/napplet/reader-intents.js"

const ID = "b".repeat(64), PK = "c".repeat(64)
const reader = { dTag: "nv-reader", send: () => {} }, other = { dTag: "someone-else", send: () => {} }
const wire = over => readerIntents({ bus: over.bus, openCompose: async () => ({}), onComposeDone: () => {}, openUrl: () => {}, verify: verifyEvent, ...over })

test("note/beside: the Reader's tap opens the thread beside the list; anyone else, or junk, is refused", async () => {
  const bus = createBus(), opened = []
  wire({ bus, beside: id => (opened.push(id), true) })
  assert.equal((await bus.invoke(reader, { archetype: "note", action: "beside", payload: { id: ID } })).ok, true)
  assert.equal((await bus.invoke(other, { archetype: "note", action: "beside", payload: { id: ID } })).ok, false)
  assert.equal((await bus.invoke(reader, { archetype: "note", action: "beside", payload: { id: "nope" } })).ok, false)
  assert.deepEqual(opened, [ID])
})

test("note/beside: with no room (or no side pane: the phone) the Reader hears no, and opens the thread in place", async () => {
  const bus = createBus()
  wire({ bus, beside: () => false })
  assert.equal((await bus.invoke(reader, { archetype: "note", action: "beside", payload: { id: ID } })).ok, false)
  const bare = createBus()
  wire({ bus: bare })
  assert.equal((await bare.invoke(reader, { archetype: "note", action: "beside", payload: { id: ID } })).error, "no handler")
  const html = fs.readFileSync(new URL("../napplets/reader/index.html", import.meta.url), "utf8")
  assert.match(html, /r\.then\(x => \{ if \(x\?\.ok\) markOpen\(id\); else go\(\{ kind: "thread", id, event: ev \}\) \}/)
})

test("pageMenu: a signed note or a pubkey, moved to the page and kept inside the frame; anything else nothing", () => {
  const ev = finalizeEvent({ kind: 1, created_at: 1, tags: [], content: "hi" }, generateSecretKey())
  const frame = { left: 200, top: 50, width: 600, height: 800 }
  const noteOf = x => likedNote(x, verifyEvent)
  assert.deepEqual(pageMenu({ x: 10, y: 20, event: ev }, frame, noteOf), { x: 210, y: 70, note: ev })
  assert.deepEqual(pageMenu({ x: 10, y: 20, pubkey: PK }, frame, noteOf), { x: 210, y: 70, pubkey: PK })
  assert.deepEqual(pageMenu({ x: 9999, y: -5, pubkey: PK }, frame, noteOf), { x: 800, y: 50, pubkey: PK })
  assert.equal(pageMenu({ x: 1, y: 1, event: { ...ev, content: "forged" } }, frame, noteOf), null)
  assert.equal(pageMenu({ x: 1, y: 1, pubkey: "x" }, frame, noteOf), null)
  assert.equal(pageMenu({ x: "1", y: 1, pubkey: PK }, frame, noteOf), null)
  assert.equal(pageMenu({ x: 1, y: 1, pubkey: PK }, null, noteOf), null)
})

test("the shell hears nv.ctx from the Reader; the menu and the desktop take it", () => {
  const bus = createBus(), got = []
  wire({ bus, onCtx: p => got.push(p) })
  bus.emit(reader, CTX_TOPIC, { x: 1, y: 2, pubkey: PK })
  assert.deepEqual(got, [{ x: 1, y: 2, pubkey: PK }])
  const menu = fs.readFileSync(new URL("../src/desktop/ContextMenu.jsx", import.meta.url), "utf8")
  assert.match(menu, /addEventListener\(CTX_EVENT, fromReader\)/)
  const shell = fs.readFileSync(new URL("../src/desktop/DesktopShell.jsx", import.meta.url), "utf8")
  assert.match(shell, /<ReaderPane ctx=\{ctx\} open=\{readerOpen\} beside=\{openBeside\} openId=\{note \?\? ""\} fullCompose \/>/)
  assert.match(shell, /reader \? <ReaderPane ctx=\{ctx\} open=\{\{ archetype: "note", action: "open", payload: \{ id, side: true \} \}\} keys=\{false\} fullCompose \/>/)
})
