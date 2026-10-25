// Brave Shields fail every WebSocket past 30 in a tab, at once and silently. The pool keeps itself under its cap:
// idle relays close, least recently used first; busy ones and a signer's relay stay; a new relay waits for a slot.
import test, { after } from "node:test"
import assert from "node:assert/strict"
import { LivePool, MAX_OPEN_RELAYS, pool } from "../src/net/pool.js"

after(() => pool.destroy())

// An in-memory relay: answers every REQ with EOSE, counts the sockets alive at once (connecting, open or closing,
// as Brave counts them). A close takes `closeMs` to finish, as a real closing handshake does.
const sockets = { live: 0, peak: 0, closeMs: 0 }
class FakeSocket {
  static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3
  constructor(url) {
    this.url = url; this.readyState = 0
    sockets.live++; sockets.peak = Math.max(sockets.peak, sockets.live)
    setTimeout(() => { if (this.readyState === 0) { this.readyState = 1; this.onopen?.() } })
  }
  send(raw) {
    const [type, id] = JSON.parse(raw)
    if (type === "REQ") setTimeout(() => this.onmessage?.({ data: JSON.stringify(["EOSE", id]) }))
  }
  close() {
    if (this.readyState >= 2) return
    this.readyState = 2
    setTimeout(() => { this.readyState = 3; sockets.live--; this.onclose?.({}) }, sockets.closeMs)
  }
}

// Brave's behaviour (strictCap) unless a test says otherwise: that is where the cap matters.
const newPool = (cap, closeMs = 0) => {
  sockets.live = 0; sockets.peak = 0; sockets.closeMs = closeMs
  const p = new LivePool({ websocketImplementation: FakeSocket })
  p.maxOpenRelays = cap
  p.strictCap = true
  return p
}
const url = i => `wss://r${i}.example`

test("the live pool's cap leaves room under Brave's 30", () => {
  assert.ok(MAX_OPEN_RELAYS <= 25)
  assert.equal(pool.maxOpenRelays, MAX_OPEN_RELAYS)
})

test("one query after another across more relays than the cap: idle relays close, oldest first", async () => {
  const p = newPool(3)
  try {
    for (let i = 0; i < 8; i++) await p.querySync([url(i)], { kinds: [0], limit: 1 }, { maxWait: 2000 })
    assert.ok(sockets.peak <= 3, `peak ${sockets.peak} sockets`)
    assert.deepEqual([...p.relays.keys()], [url(5), url(6), url(7)].map(u => u + "/"))
  } finally { p.destroy() }
})

test("many relays at once never pass the cap, and every query still answers", async () => {
  const p = newPool(4)
  try {
    const answers = await Promise.all(Array.from({ length: 12 }, (_, i) => p.querySync([url(i)], { kinds: [1] }, { maxWait: 4000 })))
    assert.equal(answers.length, 12)
    assert.ok(sockets.peak <= 4, `peak ${sockets.peak} sockets`)
  } finally { p.destroy() }
})

test("a relay with a live subscription is never closed; in Brave a new relay waits briefly for one to free up", async () => {
  const p = newPool(2)
  try {
    const live = [url(0), url(1)].map(u => p.subscribe([u], { kinds: [1] }, { onevent() {} }))
    await new Promise(r => setTimeout(r, 50))
    let opened = false
    const third = p.ensureRelay(url(2)).then(r => (opened = true, r))
    await new Promise(r => setTimeout(r, 150))
    assert.equal(opened, false, "waits while both relays are busy")
    assert.equal(p.relays.size, 2)
    await live[0].close()
    await third
    assert.deepEqual([...p.relays.keys()].sort(), [url(1), url(2)].map(u => u + "/"))
    assert.equal(sockets.peak, 2)
    await live[1].close()
  } finally { p.destroy() }
})

test("in Brave, when every relay stays busy, the new relay is skipped, not opened", async () => {
  const p = newPool(1)
  try {
    const live = p.subscribe([url(0)], { kinds: [1] }, { onevent() {} })
    await new Promise(r => setTimeout(r, 50))
    await assert.rejects(p.ensureRelay(url(1), { connectionTimeout: 3000 }), /relay skipped/)
    assert.equal(p.relays.size, 1)
    assert.equal(sockets.peak, 1)
    await live.close()
  } finally { p.destroy() }
})

test("elsewhere, when every relay is busy, the new relay opens at once, as before the cap", async () => {
  const p = newPool(1)
  p.strictCap = false
  try {
    const live = p.subscribe([url(0)], { kinds: [1] }, { onevent() {} })
    await new Promise(r => setTimeout(r, 50))
    const t0 = Date.now()
    await p.ensureRelay(url(1))
    assert.ok(Date.now() - t0 < 100, `took ${Date.now() - t0} ms`)
    assert.equal(p.relays.size, 2)
    await live.close()
  } finally { p.destroy() }
})

test("a signer's relay is never closed to make room, even when idle", async () => {
  const p = newPool(2)
  try {
    p.keepForSigner([url(0)])
    await p.querySync([url(0)], { kinds: [1] }, { maxWait: 2000 })
    for (let i = 1; i < 5; i++) await p.querySync([url(i)], { kinds: [1] }, { maxWait: 2000 })
    assert.ok(p.relays.has(url(0) + "/"))
    assert.ok(sockets.peak <= 2, `peak ${sockets.peak} sockets`)
  } finally { p.destroy() }
})

test("a socket still closing counts against the cap, and only as many idle relays close as a new one needs", async () => {
  const p = newPool(3, 300)
  try {
    for (let i = 0; i < 3; i++) await p.querySync([url(i)], { kinds: [1] }, { maxWait: 2000 })
    await new Promise(r => setTimeout(r, 300))
    await p.querySync([url(3)], { kinds: [1] }, { maxWait: 3000 })
    assert.ok(sockets.peak <= 3, `peak ${sockets.peak} sockets`)
    assert.deepEqual([...p.relays.keys()], [url(1), url(2), url(3)].map(u => u + "/"), "only the oldest closed")
  } finally { p.destroy() }
})

test("a relay whose subscription was closed twice still counts as idle and closes to make room", async () => {
  const p = newPool(2)
  try {
    for (const i of [0, 1]) {
      const sub = p.subscribe([url(i)], { kinds: [1] }, { onevent() {} })
      await new Promise(r => setTimeout(r, 50))
      await sub.close(); await sub.close() // nostr-tools counts this down twice: ongoingOperations -1
      const next = p.subscribe([url(i)], { kinds: [1] }, { onevent() {} }) // up to 0, idleSince cleared ...
      await new Promise(r => setTimeout(r, 50))
      await next.close() // ... and down to -1: idleSince is never set again
    }
    assert.ok([...p.relays.values()].every(r => r.ongoingOperations < 0 && !r.idleSince))
    await new Promise(r => setTimeout(r, 300))
    await p.querySync([url(2)], { kinds: [1] }, { maxWait: 2000 })
    assert.deepEqual([...p.relays.keys()], [url(1), url(2)].map(u => u + "/"))
    assert.ok(sockets.peak <= 2, `peak ${sockets.peak} sockets`)
  } finally { p.destroy() }
})
