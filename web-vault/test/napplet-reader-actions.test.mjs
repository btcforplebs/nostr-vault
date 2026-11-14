// Gap run after P8, Reader group: the shell's Send Delay with Undo for what napplets post (publish-delay.js, dispatch),
// and the Reader's Repost / Zap / ⋯ as shell flows that only ever act on a note whose signature checks
// (reader-intents.js actionNote).
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import { finalizeEvent, generateSecretKey, verifyEvent } from "nostr-tools/pure"
import { delayActionOf, DELAYED_KINDS } from "../src/napplet/publish-delay.js"
import { createHandlers } from "../src/napplet/dispatch.js"
import { defaultGrant } from "../src/napplet/policy.js"
import { createBus } from "../src/napplet/bus.js"
import { readerIntents, actionNote } from "../src/napplet/reader-intents.js"

const sk = generateSecretKey()
const note = finalizeEvent({ kind: 1, created_at: 100, tags: [], content: "real" }, sk)
const H = c => c.repeat(64)

test("delay: which pill a napplet's post gets; reactions and others aren't delayed", () => {
  assert.equal(delayActionOf({ kind: 1, tags: [] }), "newPost")
  assert.equal(delayActionOf({ kind: 1, tags: [["e", H("a"), "", "root"]] }), "reply")
  assert.equal(delayActionOf({ kind: 1, tags: [["q", H("a")]] }), "quote")
  assert.equal(delayActionOf({ kind: 6, tags: [] }), "repost")
  assert.equal(delayActionOf({ kind: 1111, tags: [] }), "reply")
  assert.deepEqual([...DELAYED_KINDS].sort((a, b) => a - b), [1, 6, 16, 1111])
})

function rig(delayAnswer) {
  const signed = [], delayed = []
  const deps = {
    pubkey: "p".repeat(64), account: () => ({}), blocked: () => new Set(), verify: () => true,
    async sign(t) { signed.push(t); return { ...t, id: H("1"), pubkey: "p".repeat(64), sig: "s" } },
    async publish() { return { ok: true, relays: {} } },
    vaultQuery: async () => [], netQuery: async () => [],
    delay: async t => { delayed.push(t.kind); return delayAnswer },
    ask: async () => true, bus: createBus(),
  }
  const { handlers } = createHandlers({ ident: { publisher: "nostr-vault", dTag: "nv-compose", hash: H("c"), title: "Compose" }, grant: defaultGrant({ firstParty: true }), domains: ["outbox"], deps })
  return { handlers, signed, delayed }
}

test("delay: a post waits for the countdown and isn't signed at all on Undo; a reaction goes straight through", async () => {
  const undone = rig(false)
  const r = await undone.handlers.outbox({ type: "outbox.publish", id: "1", event: { kind: 1, content: "hi", tags: [] } })
  assert.deepEqual([r.ok, r.error, undone.signed.length, undone.delayed], [false, "undone", 0, [1]])
  const sent = rig(true)
  const t0 = Math.floor(Date.now() / 1000)
  const ok = await sent.handlers.outbox({ type: "outbox.publish", id: "2", event: { kind: 1, content: "hi", tags: [] } })
  assert.equal(ok.ok, true)
  assert.ok(sent.signed[0].created_at >= t0, "stamped when it goes, not when it was asked")
  await sent.handlers.outbox({ type: "outbox.publish", id: "3", event: { kind: 7, content: "+", tags: [["e", H("a")]] } })
  assert.deepEqual(sent.delayed, [1])
  assert.equal(sent.signed.length, 2)
})

test("note actions: only a note whose signature checks (or the signed kind 1 inside a kind 6)", () => {
  assert.equal(actionNote(note, verifyEvent).id, note.id)
  assert.equal(actionNote({ ...note, content: "forged" }, verifyEvent), null) // the spread keeps nostr-tools' "verified" symbol
  assert.equal(actionNote(JSON.parse(JSON.stringify({ ...note, content: "forged" })), verifyEvent), null)
  const repost = finalizeEvent({ kind: 6, created_at: 101, tags: [["e", note.id]], content: JSON.stringify(note) }, sk)
  assert.equal(actionNote(repost, verifyEvent).id, note.id)
  const badInner = finalizeEvent({ kind: 6, created_at: 101, tags: [], content: JSON.stringify({ ...note, content: "x" }) }, sk)
  assert.equal(actionNote(badInner, verifyEvent), null)
  assert.equal(actionNote(finalizeEvent({ kind: 0, created_at: 1, tags: [], content: "{}" }, sk), verifyEvent), null)
  assert.equal(actionNote(null, verifyEvent), null)
})

test("note actions: repost, zap and ⋯ run the shell's flow for a signed note and refuse a made-up one", async () => {
  const bus = createBus(), ran = []
  readerIntents({ bus, openCompose: async () => ({ send: () => {} }), onComposeDone: () => {}, openUrl: () => {}, verify: verifyEvent,
    onRepost: n => ran.push(["repost", n.id]), onZap: n => ran.push(["zap", n.id]), onMenu: n => ran.push(["menu", n.id]) })
  const reader = { dTag: "nv-reader", send: () => {} }
  for (const action of ["repost", "zap", "menu"]) {
    assert.equal((await bus.invoke(reader, { archetype: "note", action, payload: { event: note } })).ok, true)
    assert.equal((await bus.invoke(reader, { archetype: "note", action, payload: { event: { ...note, id: H("9") } } })).ok, false)
  }
  assert.deepEqual(ran, [["repost", note.id], ["zap", note.id], ["menu", note.id]])
})

test("reader napplet: Repost, Quote, Zap and ⋯ hand the note to the shell or Compose; quotes show as cards; a deleted note goes", () => {
  const html = fs.readFileSync(new URL("../napplets/reader/index.html", import.meta.url), "utf8")
  assert.match(html, /ACT\("⟲", "Repost", \(\) => shellAct\("repost", shown\)\)/)
  assert.match(html, /ACT\("❝", "Quote", \(\) => compose\("quote", shown\)\)/)
  assert.match(html, /ACT\("⚡", "Zap", \(\) => shellAct\("zap", shown\)\)/)
  assert.match(html, /ACT\("⋯", "More", \(\) => shellAct\("menu", shown\)\)/)
  assert.match(html, /else if \(p\.t === "note"\) media\.append\(quoteCard\(p\.v\)\)/)
  assert.match(html, /d\.archetype === "note" && d\.action === "removed"/)
})
