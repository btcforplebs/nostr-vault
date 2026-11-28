// A hidden tab puts its relay sockets down after a while (hidden-sockets.js) and brings them back when it is seen:
// idle relays close, relays with subscriptions are parked with them, and those subscriptions carry on afterwards.
import test, { after } from "node:test"
import assert from "node:assert/strict"
import { LivePool, pool } from "../src/net/pool.js"

after(() => pool.destroy())

// In-memory relays: answer every REQ with EOSE, log what each socket was sent, and can push an event to every open
// subscription that matches the kind, as a relay does.
const net = { open: new Set(), sent: [], made: 0 }
class FakeSocket {
  static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3
  constructor(url) {
    this.url = url; this.readyState = 0; this.subs = new Map(); net.made++
    setTimeout(() => { if (this.readyState === 0) { this.readyState = 1; net.open.add(this); this.onopen?.() } })
  }
  send(raw) {
    const m = JSON.parse(raw)
    net.sent.push({ url: this.url, m })
    if (m[0] === "REQ") { this.subs.set(m[1], m.slice(2)); setTimeout(() => this.onmessage?.({ data: JSON.stringify(["EOSE", m[1]]) })) }
    if (m[0] === "CLOSE") this.subs.delete(m[1])
  }
  close() {
    if (this.readyState >= 2) return
    this.readyState = 2; net.open.delete(this)
    setTimeout(() => { this.readyState = 3; this.onclose?.({}) })
  }
}
const push = ev => { for (const ws of net.open) for (const [id, fs] of ws.subs) if (fs.some(f => f.kinds?.includes(ev.kind))) ws.onmessage?.({ data: JSON.stringify(["EVENT", id, ev]) }) }
const tick = (ms = 30) => new Promise(r => setTimeout(r, ms))
const url = i => `wss://r${i}.example`

const newPool = () => {
  net.open.clear(); net.sent = []; net.made = 0
  const p = new LivePool({ websocketImplementation: FakeSocket, verifyEvent: () => true, enablePing: true, enableReconnect: true })
  let hidden = false
  p.isHidden = () => hidden
  p.hiddenParkMs = 60
  p.parkAgainMs = 60
  p.setHidden = h => { hidden = h; p.visibilityChanged() }
  return p
}
const ev = (kind, created_at = 1000) => ({ id: `${kind}-${created_at}`.padEnd(64, "0"), pubkey: "a".repeat(64), kind, created_at, tags: [], content: "", sig: "b".repeat(128) })

test("hidden for a while: idle relays close, a live one is parked with its subscription, no socket stays open", async () => {
  const p = newPool()
  try {
    const got = [], closed = []
    p.subscribe([url(0)], { kinds: [1] }, { onevent: e => got.push(e), onclose: r => closed.push(r) })
    await p.querySync([url(1)], { kinds: [0] }, { maxWait: 1000 })
    await tick()
    assert.equal(net.open.size, 2)
    p.setHidden(true)
    await tick(20)
    assert.equal(net.open.size, 2, "nothing closes at once")
    await tick(120)
    assert.equal(net.open.size, 0, "every socket is down")
    assert.deepEqual([...p.relays.keys()], [url(0) + "/"], "the idle relay is dropped, the live one kept")
    const r = p.relays.get(url(0) + "/")
    assert.equal(r.connected, false)
    assert.equal(r.pingIntervalHandle, undefined, "no ping timer while parked")
    assert.equal(r.openSubs.size, 1, "its subscription is still open")
    assert.deepEqual(closed, [], "nobody was told the subscription closed")
    await tick(200)
    assert.equal(net.made, 2, "nothing reconnects while hidden")
  } finally { p.destroy() }
})

test("seen again: the parked relay reconnects and its subscription goes on from its last event", async () => {
  const p = newPool()
  try {
    const got = []
    p.subscribe([url(0)], { kinds: [1] }, { onevent: e => got.push(e) })
    await tick()
    push(ev(1, 1500))
    await tick()
    assert.equal(got.length, 1)
    p.setHidden(true)
    await tick(150)
    assert.equal(net.open.size, 0)
    net.sent = []
    p.setHidden(false)
    await tick(60)
    assert.equal(net.open.size, 1, "reconnected")
    const req = net.sent.find(s => s.m[0] === "REQ")
    assert.ok(req, "the subscription was sent again")
    assert.equal(req.m[2].since, 1501, "from just after its last event")
    push(ev(1, 1600))
    await tick()
    assert.deepEqual(got.map(e => e.created_at), [1500, 1600], "events arrive again")
    assert.ok(p.relays.get(url(0) + "/").pingIntervalHandle, "pings again")
  } finally { p.destroy() }
})

test("a query while hidden (the notification poll) reconnects what it needs and is answered; the relay goes down again", async () => {
  const p = newPool()
  try {
    p.subscribe([url(0)], { kinds: [1] }, { onevent() {} })
    await tick()
    p.setHidden(true)
    await tick(150)
    assert.equal(net.open.size, 0)
    const answer = await p.querySync([url(0)], { kinds: [7] }, { maxWait: 1000 })
    assert.deepEqual(answer, [], "answered (EOSE), not held to its timeout")
    assert.equal(net.open.size, 1)
    await tick(200)
    assert.equal(net.open.size, 0, "down again once quiet")
    assert.equal(p.relays.get(url(0) + "/").openSubs.size, 1, "the live subscription is still kept")
  } finally { p.destroy() }
})

test("a signer's relay stays open while hidden", async () => {
  const p = newPool()
  try {
    p.keepForSigner([url(0)])
    p.subscribe([url(0)], { kinds: [24133] }, { onevent() {} })
    await p.querySync([url(1)], { kinds: [0] }, { maxWait: 1000 })
    await tick()
    p.setHidden(true)
    await tick(200)
    assert.deepEqual([...net.open].map(w => w.url), [url(0) + "/"])
  } finally { p.destroy() }
})

test("back online while hidden does not reconnect a parked relay; seen again does", async () => {
  const p = newPool()
  try {
    p.subscribe([url(0)], { kinds: [1] }, { onevent() {} })
    await tick()
    p.setHidden(true)
    await tick(150)
    p.onOnline()
    await tick(60)
    assert.equal(net.open.size, 0)
    p.setHidden(false)
    await tick(60)
    assert.equal(net.open.size, 1)
  } finally { p.destroy() }
})

test("shown again before the wait is up: nothing is put down", async () => {
  const p = newPool()
  try {
    p.subscribe([url(0)], { kinds: [1] }, { onevent() {} })
    await tick()
    p.setHidden(true)
    await tick(20)
    p.setHidden(false)
    await tick(150)
    assert.equal(net.open.size, 1)
    assert.equal(net.made, 1)
  } finally { p.destroy() }
})
