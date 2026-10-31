// A repost waits out the send delay with Undo, then says Reposted (PendingPostManager.startRepost, PostActionPill).
// Throwaway keys, relays stubbed, a fake clock: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { actionState, repostAfterDelay } from "../src/net/actions.js"
import { pool } from "../src/net/pool.js"

registerHooks({ load(url, context, next) {
  if (!url.endsWith(".jsx")) return next(url, context)
  const { code } = transformSync(fileURLToPath(url), readFileSync(fileURLToPath(url), "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
  return { format: "module", source: code, shortCircuit: true }
} })
const { currentToasts, hideToast } = await import("../src/components/Toast.jsx")
const { repostWithUndo } = await import("../src/components/repost-undo.js")

const me = generateSecretKey(), author = generateSecretKey()
let n0 = 0
const note = () => finalizeEvent({ kind: 1, created_at: Math.floor(Date.now() / 1000) - 60, tags: [], content: `n ${++n0}` }, author)
const ctxFor = () => {
  const kept = []
  return { kept, session: { pubkey: getPublicKey(me) }, signer: { signEvent: async t => finalizeEvent(t, me) },
    account: { relays: { read: ["wss://relay.example.com"], write: ["wss://relay.example.com"] } },
    vault: { outbox: { event: async ev => { kept.push(ev); return { ok: true } }, query: async () => [] }, feed: { query: async () => [] } } }
}
const relaysSay = (t, answer) => {
  const sent = []
  t.mock.method(pool, "publish", (urls, ev) => { sent.push(ev); return urls.map(answer) })
  globalThis.location = { hostname: "vault.example.com", hash: "" }
  t.after(() => { delete globalThis.location })
  return sent
}
// A countdown you end by hand: { countdown, ticks, finish() }.
function fakeCountdown() {
  const c = { ticks: [], running: null }
  c.countdown = ({ seconds, onTick, onDone }) => {
    if (!(seconds > 0)) { onDone(); return { cancel: () => false } }
    c.running = { onTick, onDone, live: true }
    return { cancel: () => { if (!c.running?.live) return false; c.running.live = false; return true } }
  }
  c.tick = s => c.running.onTick(s)
  c.finish = () => { c.running.live = false; c.running.onDone() }
  return c
}
const clear = () => { for (const t of currentToasts()) hideToast(t.key) }

test("nothing is signed during the countdown; the pill counts down with Undo; then it goes out and says Reposted", async t => {
  const sent = relaysSay(t, () => Promise.resolve(""))
  clear()
  const c = fakeCountdown(), n = note()
  const h = repostWithUndo(ctxFor(), n, { seconds: 5, countdown: c.countdown })
  assert.equal(actionState(n.id).repost, "pending")
  assert.equal(sent.length, 0)
  const pill = () => currentToasts().find(x => x.key === `repost:${n.id}`)
  assert.equal(pill().message, "Reposting in 5s")
  assert.equal(pill().action.label, "Undo")
  c.tick(2.2)
  assert.equal(pill().message, "Reposting in 3s")
  c.finish()
  assert.equal(await h.done, "sent")
  assert.equal(sent.length, 1)
  assert.equal(sent[0].kind, 6)
  assert.equal(actionState(n.id).repost, "sent")
  assert.deepEqual([pill().message, pill().tone, pill().action], ["Reposted", "success", null])
  clear()
})

test("Undo before the end: nothing signed or sent, the button is as it was, the pill goes", async t => {
  const sent = relaysSay(t, () => Promise.resolve(""))
  clear()
  let signs = 0
  const c = fakeCountdown(), n = note(), ctx = { ...ctxFor(), signer: { signEvent: async tm => { signs++; return finalizeEvent(tm, me) } } }
  const h = repostWithUndo(ctx, n, { seconds: 5, countdown: c.countdown })
  currentToasts().find(x => x.key === `repost:${n.id}`).action.onClick()
  assert.equal(await h.done, "undone")
  assert.equal(actionState(n.id).repost, undefined)
  assert.deepEqual([signs, sent.length], [0, 0])
  await new Promise(r => setTimeout(r, 0))
  assert.equal(currentToasts().some(x => x.key === `repost:${n.id}`), false)
  assert.equal(h.cancel(), false) // already undone
})

test("a second tap while counting down does nothing", async t => {
  relaysSay(t, () => Promise.resolve(""))
  const c = fakeCountdown(), n = note(), ctx = ctxFor()
  repostAfterDelay(ctx, n, { seconds: 5, countdown: c.countdown })
  const again = repostAfterDelay(ctx, n, { seconds: 5, countdown: () => assert.fail("second countdown") })
  assert.equal(await again.done, "skipped")
})

test("Off (0 s) sends at once; a repost no relay took says so in red and can be tried again", async t => {
  relaysSay(t, () => Promise.reject(new Error("down")))
  clear()
  const n = note()
  const h = repostWithUndo(ctxFor(), n, { seconds: 0 })
  assert.equal(await h.done, "failed")
  assert.match(actionState(n.id).repost.error, /No relay took it/)
  const pill = currentToasts().find(x => x.key === `repost:${n.id}`)
  assert.deepEqual([pill.message, pill.tone], ["Repost failed: no relay took it", "error"])
  t.mock.method(pool, "publish", urls => urls.map(() => Promise.resolve("")))
  assert.equal(await repostWithUndo(ctxFor(), n, { seconds: 0 }).done, "sent")
  clear()
})

test("the note card's Repost goes through the countdown", () => {
  const src = readFileSync(new URL("../src/components/NoteCard.jsx", import.meta.url), "utf8")
  assert.match(src, /kind="repost" state=\{s\.repost\} icon=\{ICONS\.repost\} onClick=\{\(\) => repostWithUndo\(ctx, note\)\}/)
})
