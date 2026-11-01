// Ted's web sweep 2026-11-01, items 1, 2, 3 and 6: an empty answer settles without the slowest relay (settle-early.js,
// eachRelay, Messages), own notes land per relay (syncOwn), plain ws:// is skipped on an https page (pool.js), and an
// empty Media grid says why (media-empty-reason.js). Throwaway keys, stubbed relays and timers: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { SETTLE_GRACE_MS, settleWatch } from "../src/net/settle-early.js"
import { eachRelay, fetchVault } from "../src/net/vault-lists.js"
import { blockedPlain, LivePool } from "../src/net/pool.js"
import { emptyMediaReason } from "../src/net/media-empty-reason.js"
import { syncOwn } from "../src/net/sync.js"
import { loadMessages, getMessages, onMessages, resetMessages } from "../src/net/dms.js"

const fakeTimer = () => {
  const due = []
  return { timer: (f, ms) => { due.push({ f, ms }); return due.length }, clear: id => { if (due[id - 1]) due[id - 1].f = null }, run: () => due.forEach(d => d.f?.()), due }
}
const later = (ms, v) => new Promise(r => setTimeout(() => r(v), ms))

test("settleWatch: half the relays answered settles, once", () => {
  let n = 0
  const t = fakeTimer()
  const w = settleWatch(4, () => n++, t)
  w.answered(); assert.equal(n, 0); assert.equal(t.due[0].ms, SETTLE_GRACE_MS, "the grace starts at the first answer")
  w.answered(); assert.equal(n, 1, "2 of 4")
  w.answered(); w.answered(); t.run(); assert.equal(n, 1, "never twice")
})

test("settleWatch: the grace after the first answer settles; failures never do until all are done", () => {
  let n = 0
  const t = fakeTimer()
  const w = settleWatch(5, () => n++, t)
  w.failed(); w.failed(); assert.equal(n, 0, "a refused relay is not an answer")
  w.answered(); assert.equal(n, 0)
  t.run(); assert.equal(n, 1, "grace ran out")
  let m = 0
  const all = settleWatch(2, () => m++, fakeTimer())
  all.failed(); assert.equal(m, 0); all.failed(); assert.equal(m, 1, "every relay done, even failing")
  let z = 0
  settleWatch(0, () => z++); assert.equal(z, 1, "no relays: nothing to wait for")
})

test("eachRelay: an empty answer from the fast relays settles before the slow one finishes", async () => {
  const at = {}, t0 = Date.now()
  const query = async ([url]) => url.includes("slow") ? later(300, []) : later(5, [])
  const done = eachRelay(["wss://a", "wss://b", "wss://slow"], { kinds: [1] }, () => {}, { query, onSettled: () => { at.settled = Date.now() - t0 } })
  await done
  at.done = Date.now() - t0
  assert.ok(at.settled < 100, `settled at ${at.settled} ms`)
  assert.ok(at.done >= 290, "the slow relay was still waited for in full")
})

test("eachRelay: a relay's events are handed on before it counts as answered", async () => {
  const order = []
  const query = async ([url]) => [{ id: url, kind: 1 }]
  await eachRelay(["wss://a"], {}, async evs => { await later(5); order.push(`on ${evs[0].id}`) }, { query, onSettled: () => order.push("settled") })
  assert.deepEqual(order, ["on wss://a", "settled"])
})

test("fetchVault tells the screen each kind settled; zaps given wait for their checks", async () => {
  const kinds = []
  const stub = async (...args) => { const o = args.at(-1); o.onSettled?.(); return [] }
  await fetchVault({}, "me", ["wss://a"], { on: { settled: k => kinds.push(k) }, fetchers: { fetchInbound: stub, fetchFollowerLists: stub, fetchGivenZaps: stub, fetchOwnExtras: async (...a) => { a.at(-1).onSettled?.(); return 0 } } })
  assert.deepEqual(kinds.sort(), ["inbound", "lists", "own"])
})

test("syncOwn keeps each relay's notes as they land and calls on() for each that brought something", async () => {
  const kept = []
  const vault = { outbox: { event: async ev => { if (kept.some(e => e.id === ev.id)) return { ok: false }; kept.push(ev); return { ok: true } } } }
  let draws = 0, firstDrawAt = null
  const t0 = Date.now()
  const note = id => ({ id, kind: 1 })
  const query = async ([url], f) => f.kinds[0] !== 1 ? [] : url.includes("slow") ? later(250, [note("b"), note("a")]) : [note("a")]
  const stored = await syncOwn(vault, "me", ["wss://fast", "wss://slow"], { query, on: () => { draws++; firstDrawAt ??= Date.now() - t0 } })
  assert.equal(stored, 2, "each note once")
  assert.equal(draws, 2)
  assert.ok(firstDrawAt < 100, `first draw at ${firstDrawAt} ms, not after the slow relay`)
})

test("blockedPlain: ws:// is skipped on an https page, loopback and wss are not", () => {
  assert.equal(blockedPlain("ws://relay.example.com", "https:"), true)
  assert.equal(blockedPlain(" WS://Relay.example.com/", "https:"), true)
  assert.equal(blockedPlain("wss://relay.example.com", "https:"), false)
  assert.equal(blockedPlain("ws://localhost:3355", "https:"), false)
  assert.equal(blockedPlain("ws://127.0.0.1:3355", "https:"), false)
  assert.equal(blockedPlain("ws://relay.example.com", "http:"), false, "an http page (dev, the Mac) may open it")
})

test("the pool refuses a plain ws:// relay on an https page before opening a socket", async () => {
  const p = new LivePool()
  p.pageProtocol = () => "https:"
  await assert.rejects(p.ensureRelay("ws://jb55.example"), /plain ws:\/\/ relay skipped/)
  assert.equal(p.relays.size, 0, "no socket was made")
})

test("emptyMediaReason: says why the grid is empty, and nothing when the servers really hold nothing", () => {
  const a = "https://blossom.primal.net", b = "https://cdn.satellite.earth"
  assert.equal(emptyMediaReason({ servers: [a, b], status: { [a]: "ok", [b]: "ok" }, readOnly: true }), "")
  assert.match(emptyMediaReason({ servers: [a, b], status: { [a]: "HTTP 401", [b]: "Failed to fetch" }, readOnly: true }),
    /^None of your 2 media servers listed your files\. .*read-only sign-in can't sign\. Sign in with an extension or a bunker/)
  assert.match(emptyMediaReason({ servers: [a], status: { [a]: "HTTP 400" }, readOnly: true }), /^blossom\.primal\.net didn't list your files\./)
  assert.equal(emptyMediaReason({ servers: [a, b], status: { [a]: "ok", [b]: "didn't answer" } }), "1 of your 2 media servers didn't list your files (cdn.satellite.earth: didn't answer).")
})

test("loadMessages: an empty inbox shows once the fast relays answered, not after the slowest", async () => {
  const sk = generateSecretKey(), me = getPublicKey(sk)
  const ctx = { vault: {}, session: { method: "nip07", pubkey: me }, signer: {}, account: { relays: { read: [], write: [] } } }
  const crypto = { encrypt: async () => "", decrypt: async () => { throw new Error("nothing to open") }, decrypt04: async () => "" }
  const chat = { query: async () => [], event: async () => ({ ok: true }) }
  // A query over several relays waits for its slowest, as querySync does.
  const query = async urls => urls.some(u => u.includes("slow")) ? later(300, []) : later(5, [])
  resetMessages(me)
  const t0 = Date.now()
  let loadedAt = null
  const off = onMessages(() => { if (getMessages().loaded) loadedAt ??= Date.now() - t0 })
  await loadMessages(ctx, ["wss://a", "wss://b", "wss://slow"], { crypto, query, chat, cache: false })
  off()
  assert.ok(loadedAt != null && loadedAt < 100, `loaded at ${loadedAt} ms`)
  assert.ok(Date.now() - t0 >= 290, "the slow relay was still asked in full")
})
