// Plan step 2b (OUTBOX/NV_WEB_ONE_PLAN.md): on the desktop the Reader's Post, Reply and Quote open the site's full
// composer (mentions, emoji, photos with ALT, preview, the other kinds) instead of the Compose napplet. The shell side's
// checks: new needs nothing, reply and quote need a signed note, and what's sent comes back to the Reader.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import { finalizeEvent, generateSecretKey, verifyEvent } from "nostr-tools/pure"
import { createBus } from "../src/napplet/bus.js"
import { COMPOSE_SENT, readerIntents } from "../src/napplet/reader-intents.js"
import { NOTE_SENT_EVENT } from "../src/net/actions.js"

const reader = { dTag: "nv-reader", send: () => {} }
const ev = finalizeEvent({ kind: 1, created_at: 1, tags: [], content: "hi" }, generateSecretKey())

test("fullCompose: new opens the full composer; reply and quote take only a signed note; the napplet never mounts", async () => {
  const bus = createBus(), opened = []
  let napplet = 0
  readerIntents({ bus, openCompose: async () => { napplet++; return {} }, onComposeDone: () => {}, openUrl: () => {}, verify: verifyEvent, fullCompose: (mode, note) => opened.push([mode, note?.id ?? null]) })
  assert.equal((await bus.invoke(reader, { archetype: "compose", action: "new", payload: {} })).ok, true)
  assert.equal((await bus.invoke(reader, { archetype: "compose", action: "reply", payload: { event: ev } })).ok, true)
  assert.equal((await bus.invoke(reader, { archetype: "compose", action: "quote", payload: { event: ev } })).ok, true)
  assert.equal((await bus.invoke(reader, { archetype: "compose", action: "reply", payload: { event: { ...ev, content: "forged" } } })).ok, false)
  assert.equal((await bus.invoke(reader, { archetype: "compose", action: "quote", payload: {} })).ok, false)
  assert.deepEqual(opened, [["new", null], ["reply", ev.id], ["quote", ev.id]])
  assert.equal(napplet, 0)
})

test("without fullCompose (no desktop shell) the Compose napplet answers as before", async () => {
  const bus = createBus()
  let napplet = 0
  readerIntents({ bus, openCompose: async () => { napplet++; return { send: () => {} } }, onComposeDone: () => {}, openUrl: () => {}, verify: verifyEvent })
  await bus.invoke(reader, { archetype: "compose", action: "new", payload: {} })
  assert.equal(napplet, 1)
})

test("a sent note reaches the Reader: the composer fires it, ReaderPane passes it on as inc nv.compose.sent", () => {
  assert.equal(COMPOSE_SENT, "nv.compose.sent")
  const composer = fs.readFileSync(new URL("../src/screens/ComposeScreen.jsx", import.meta.url), "utf8")
  assert.match(composer, /if \(reachedRelay\(sent\) && sent\.event\) globalThis\.dispatchEvent\?\.\(new CustomEvent\(NOTE_SENT_EVENT, \{ detail: sent\.event \}\)\)/)
  const pane = fs.readFileSync(new URL("../src/napplet/ReaderPane.jsx", import.meta.url), "utf8")
  assert.match(pane, /bus\.emit\(wire\.me, COMPOSE_SENT, \{ event: e\.detail \}\)/)
  assert.match(pane, /if \(fullCompose\) addEventListener\(NOTE_SENT_EVENT, sentNote\)/)
  assert.equal(NOTE_SENT_EVENT, "nv:note-sent")
  const reader = fs.readFileSync(new URL("../napplets/reader/index.html", import.meta.url), "utf8")
  assert.match(reader, /n\.inc\?\.on\?\.\("nv\.compose\.sent"/)
})
