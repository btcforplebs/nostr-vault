// relay.damus.io bans, and lists in public, an address that sends it too many requests in a day. The pool spends a
// per-host budget (a minute's and a day's share, shared by every tab), skips nostr-tools' keep-alive ping on a relay
// it has just heard from, and the Vault poll slows down in a hidden tab.
import test, { after } from "node:test"
import assert from "node:assert/strict"
import { relayBudget, RELAY_BUDGETS } from "../src/net/relay-budget.js"
import { LivePool, HIDDEN_PING_MS, pool } from "../src/net/pool.js"
import { pollDelay, pollOnReturn, POLL_MS, HIDDEN_POLL_MS } from "../src/net/notify-watch.js"

after(() => pool.destroy())

const memory = () => { const m = new Map(); return { getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)) } }
const DAMUS = "wss://relay.damus.io"
const clock = start => { let t = start; return { now: () => t, add: ms => { t += ms } } }

test("damus has a budget; other relays don't", () => {
  assert.ok(RELAY_BUDGETS["relay.damus.io"].perDay <= 1000)
  const b = relayBudget({ storage: memory() })
  assert.equal(b.left("wss://relay.primal.net"), null)
  for (let i = 0; i < 5000; i++) assert.equal(b.take("wss://relay.primal.net"), true)
})

test("a minute's share runs out, then comes back the next minute", () => {
  const c = clock(Date.parse("2026-10-31T10:00:00Z"))
  const b = relayBudget({ budgets: { "relay.damus.io": { perMinute: 3, perDay: 100 } }, storage: memory(), now: c.now })
  assert.deepEqual([1, 2, 3, 4].map(() => b.take(DAMUS)), [true, true, true, false])
  assert.equal(b.take("wss://relay.damus.io/"), false, "the same host however the url is written")
  c.add(60_000)
  assert.equal(b.take(DAMUS), true)
  assert.deepEqual(b.left(DAMUS), { day: 96, minute: 2 })
})

test("a day's share runs out until the next UTC day", () => {
  const c = clock(Date.parse("2026-10-31T23:00:00Z"))
  const b = relayBudget({ budgets: { "relay.damus.io": { perMinute: 100, perDay: 5 } }, storage: memory(), now: c.now })
  for (let i = 0; i < 5; i++) { assert.equal(b.take(DAMUS), true); c.add(61_000) }
  assert.equal(b.take(DAMUS), false)
  c.add(3600_000)
  assert.equal(b.take(DAMUS), true)
})

test("tabs and reloads on one browser share the day's count", () => {
  const s = memory(), c = clock(Date.parse("2026-10-31T10:00:00Z"))
  const budgets = { "relay.damus.io": { perMinute: 100, perDay: 4 } }
  const tabA = relayBudget({ budgets, storage: s, now: c.now }), tabB = relayBudget({ budgets, storage: s, now: c.now })
  assert.deepEqual([tabA.take(DAMUS), tabB.take(DAMUS), tabA.take(DAMUS), tabB.take(DAMUS), tabA.take(DAMUS)], [true, true, true, true, false])
})

test("storage that refuses (private mode) still keeps count in the tab", () => {
  const broken = { getItem() { throw new Error("denied") }, setItem() { throw new Error("denied") } }
  const b = relayBudget({ budgets: { "relay.damus.io": { perMinute: 2, perDay: 10 } }, storage: broken })
  assert.deepEqual([b.take(DAMUS), b.take(DAMUS), b.take(DAMUS)], [true, true, false])
})

// An in-memory relay: answers every REQ with EOSE and counts them.
const sent = []
class FakeSocket {
  static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3
  constructor(url) { this.url = url; this.readyState = 0; setTimeout(() => { this.readyState = 1; this.onopen?.() }) }
  send(raw) {
    const [type, id] = JSON.parse(raw)
    sent.push({ url: this.url, type })
    if (type === "REQ") setTimeout(() => this.onmessage?.({ data: JSON.stringify(["EOSE", id]) }))
  }
  close() { this.readyState = 3; this.onclose?.({}) }
}
const newPool = budgets => {
  sent.length = 0
  const p = new LivePool({ websocketImplementation: FakeSocket })
  p.budget = relayBudget({ budgets, storage: memory() })
  return p
}

test("over budget, the query skips damus and still answers from the others", async () => {
  const p = newPool({ "relay.damus.io": { perMinute: 2, perDay: 100 } })
  try {
    for (let i = 0; i < 5; i++) await p.querySync([DAMUS, "wss://other.example"], { kinds: [1] }, { maxWait: 2000 })
    const reqs = host => sent.filter(s => s.type === "REQ" && s.url.includes(host)).length
    assert.equal(reqs("damus"), 2)
    assert.equal(reqs("other.example"), 5)
  } finally { p.destroy() }
})

test("a signer's own relay is never held back by the budget", async () => {
  const p = newPool({ "relay.damus.io": { perMinute: 1, perDay: 1 } })
  try {
    p.keepForSigner([DAMUS])
    for (let i = 0; i < 3; i++) await p.querySync([DAMUS], { kinds: [24133] }, { maxWait: 2000 })
    assert.equal(sent.filter(s => s.type === "REQ").length, 3)
  } finally { p.destroy() }
})

test("the keep-alive ping is skipped on a relay heard from recently, and slowed in a hidden tab", async () => {
  const p = newPool({})
  try {
    const r = await p.ensureRelay("wss://quiet.example")
    const pings = () => sent.filter(s => s.type === "REQ").length
    const heard = ms => p.heard.set(r.ws, Date.now() - ms)
    heard(1000)
    await r.pingpong()
    assert.equal(pings(), 0, "just heard from: no ping")
    heard(r.pingFrequency + 1)
    await r.pingpong()
    assert.equal(pings(), 1, "quiet for a ping interval: pinged")
    p.isHidden = () => true
    heard(r.pingFrequency + 1)
    await r.pingpong()
    assert.equal(pings(), 1, "hidden tab: not until HIDDEN_PING_MS")
    heard(HIDDEN_PING_MS + 1)
    await r.pingpong()
    assert.equal(pings(), 2)
  } finally { p.destroy() }
})

test("a message from the relay counts as hearing from it", async () => {
  const p = newPool({})
  try {
    const r = await p.ensureRelay("wss://chatty.example")
    p.heard.set(r.ws, 0)
    r.ws.onmessage({ data: JSON.stringify(["NOTICE", "hi"]) })
    assert.ok(Date.now() - p.heard.get(r.ws) < 1000)
  } finally { p.destroy() }
})

test("a ping to a budgeted host spends the budget, and is skipped when it is gone", async () => {
  const p = newPool({ "budgeted.example": { perMinute: 2, perDay: 100 } })
  try {
    const r = await p.ensureRelay("wss://budgeted.example") // takes 1
    p.heard.set(r.ws, 0)
    await r.pingpong() // takes 2
    p.heard.set(r.ws, 0)
    await r.pingpong() // none left
    assert.equal(sent.filter(s => s.type === "REQ").length, 1)
  } finally { p.destroy() }
})

test("the Vault poll waits longer in a hidden tab and asks at once on coming back", () => {
  assert.equal(pollDelay(false), POLL_MS)
  assert.equal(pollDelay(true), HIDDEN_POLL_MS)
  assert.ok(HIDDEN_POLL_MS >= 5 * POLL_MS)
  const now = 1_000_000
  assert.equal(pollOnReturn({ polling: false, lastPoll: now - POLL_MS, now }), true)
  assert.equal(pollOnReturn({ polling: false, lastPoll: now - 10_000, now }), false, "just polled")
  assert.equal(pollOnReturn({ polling: true, lastPoll: 0, now }), false, "one already running")
})
