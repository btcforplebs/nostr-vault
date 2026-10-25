// The page's streams to its in-browser Haven (src/haven/vault.js routeClient; DMs' /chat through it too) can close
// under it: Safari in the background or a locked phone for over a minute. The next save must open a new stream by
// itself, and a save cut off mid-way is sent once more, instead of every write failing "haven stream closed" until a
// reload. The real-Haven test is skipped until web-relay/tools/build-haven-wasm.sh has been run.
import { test, after } from "node:test"
import assert from "node:assert/strict"
import { existsSync, readFileSync } from "node:fs"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { wrap } from "../../web-relay/src/haven/haven.js"
import { routeClient } from "../src/haven/vault.js"
import { chatStore } from "../src/net/dms.js"

const enc = new TextEncoder(), dec = new TextDecoder()

/** A Haven whose conns answer like a NIP-01 relay: OK to EVENT, EOSE to REQ. `answer: false` leaves EVENTs unanswered,
 *  so a test can cut the stream mid-save. `refuse`: every conn comes back already closed (Haven not running). */
function fakeHaven({ refuse = false } = {}) {
  const conns = [], ids = []
  const h = {
    answer: true,
    conns, ids,
    conn(id, opts) {
      ids.push(id)
      let data = () => {}, closers = [], closed = false
      const close = () => { if (closed) return; closed = true; closers.forEach(f => f()) }
      const c = {
        opts, writes: [], close,
        write(b) {
          if (closed) return
          const m = JSON.parse(dec.decode(b))
          c.writes.push(m)
          const reply = x => queueMicrotask(() => !closed && data(enc.encode(JSON.stringify(x) + "\n")))
          if (m[0] === "EVENT" && h.answer) reply(["OK", m[1].id, true, ""])
          if (m[0] === "REQ") reply(h.blockReads ? ["CLOSED", m[1], h.blockReads] : ["EOSE", m[1]])
        },
        onData(cb) { data = cb },
        onClose(cb) { closers.push(cb); if (closed) queueMicrotask(cb) },
      }
      conns.push(c)
      if (refuse) { closed = true; c.error = "havenConn: relay is not running" }
      return c
    },
  }
  return h
}

const sk = generateSecretKey()
const note = (text, key = sk) => finalizeEvent({ kind: 1, created_at: Math.floor(Date.now() / 1000), tags: [], content: text }, key)

test("a stream that dropped is reopened by the next save, under a new id, and the save goes through", async () => {
  const h = fakeHaven()
  const feed = routeClient(h, "/feed", sk)
  assert.deepEqual(await feed.event(note("one")), { ok: true, message: "" })
  assert.deepEqual(h.ids, ["ui-feed"])
  h.conns[0].close() // Safari backgrounded: Haven drops the stream
  assert.deepEqual(await feed.event(note("two")), { ok: true, message: "" }, "no 'haven stream closed'")
  assert.deepEqual(h.ids, ["ui-feed", "ui-feed-2"], "Haven refuses an id still open, so the new stream has its own")
  assert.equal(h.conns[1].opts.route, "/feed")
  assert.deepEqual(await feed.query({ kinds: [1] }), [], "reads use the new stream too")
  assert.equal(h.conns.length, 2, "one new stream, kept for what follows")
})

test("a save cut off by the stream closing is sent once more on a new stream", async () => {
  const h = fakeHaven()
  const outbox = routeClient(h, "/", sk)
  await outbox.query({ kinds: [0] }) // the stream is open
  h.answer = false
  const ev = note("liked")
  const saving = outbox.event(ev)
  await new Promise(r => setTimeout(r, 0))
  h.answer = true
  h.conns[0].close() // dropped before Haven said OK
  assert.deepEqual(await saving, { ok: true, message: "" })
  assert.deepEqual(h.ids, ["ui-", "ui--2"], "the outbox's stream is \"ui-\", as before")
  assert.equal(h.conns[1].writes[0][1].id, ev.id, "the same event, so a save that did land is not doubled")
})

test("a Haven that refuses every stream fails the save after one retry, without a loop", async () => {
  const h = fakeHaven({ refuse: true })
  await assert.rejects(routeClient(h, "/", sk).event(note("x")), /haven stream closed/)
  assert.equal(h.ids.length, 2, "the first stream and one retry")
})

test("other errors are not retried", async () => {
  const h = fakeHaven()
  h.blockReads = "blocked: nope"
  await assert.rejects(routeClient(h, "/feed", sk).query({}), /blocked: nope/)
  assert.deepEqual(h.ids, ["ui-feed"], "the stream is fine: no new one, no second try")
})

test("DMs' /chat store reconnects the same way", async () => {
  const kept = new Map()
  globalThis.localStorage ??= { getItem: k => kept.get(k) ?? null, setItem: (k, v) => kept.set(k, String(v)), removeItem: k => kept.delete(k) }
  const h = fakeHaven()
  const chat = chatStore({ haven: h })
  assert.deepEqual(await chat.query({ kinds: [1059] }), [])
  h.conns[0].close()
  assert.deepEqual(await chat.query({ kinds: [1059] }), [])
  assert.deepEqual(h.ids, ["ui-chat", "ui-chat-2"])
})

// ---- the real Haven ----
const WASM = new URL("../../web-relay/public/haven.wasm", import.meta.url)
const SHIM = new URL("../../web-relay/src/haven/wasm_exec.js", import.meta.url)
const skip = !(existsSync(WASM) && existsSync(SHIM)) && "web-relay/public/haven.wasm not built"
let haven
after(() => { if (haven) setImmediate(() => process.exit(process.exitCode ?? 0)) })
async function boot() {
  if (haven) return haven
  await import(SHIM.href)
  const go = new globalThis.Go()
  const { instance } = await WebAssembly.instantiate(readFileSync(WASM), go.importObject)
  go.run(instance)
  for (let i = 0; typeof globalThis.havenStart !== "function"; i++) {
    if (i > 3000) throw new Error("entry point never registered")
    await new Promise(r => setTimeout(r, 10))
  }
  return (haven = wrap(globalThis))
}

test("real Haven: cut the outbox stream, the next save reopens it and lands", { skip }, async () => {
  const owner = generateSecretKey(), device = generateSecretKey()
  const h = await boot()
  await h.start({ ownerNpub: npubEncode(getPublicKey(owner)), whitelist: [npubEncode(getPublicKey(device))], env: { RELAY_URL: "vault.local" }, storePrefix: "reconnect" })
  const conns = []
  const cuttable = { conn: (id, opts) => { const c = h.conn(id, opts); conns.push(c); return c } }
  const outbox = routeClient(cuttable, "/", device)
  const first = note("before the cut", owner)
  assert.equal((await outbox.event(first)).ok, true)
  conns[0].close() // the stream drops, as when Safari is backgrounded
  const second = note("after the cut", owner)
  const r = await outbox.event(second)
  assert.equal(r.ok, true, r.message)
  assert.equal(conns.length, 2, "a new stream was opened")
  const got = (await outbox.query({ authors: [getPublicKey(owner)], kinds: [1] })).map(e => e.id).sort()
  assert.deepEqual(got, [first.id, second.id].sort(), "both saves are in the vault")
})
