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
const opened = [] // sockets this file's tests created, in order
class FakeSocket {
  static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3
  constructor(url) { this.url = url; this.readyState = 0; opened.push(url); setTimeout(() => { this.readyState = 1; this.onopen?.() }) }
  send(raw) {
    const [type, id] = JSON.parse(raw)
    sent.push({ url: this.url, type })
    if (type === "REQ") setTimeout(() => this.onmessage?.({ data: JSON.stringify(["EOSE", id]) }))
  }
  close() { this.readyState = 3; this.onclose?.({}) }
}
const newPool = budgets => {
  sent.length = 0
  opened.length = 0
  const p = new LivePool({ websocketImplementation: FakeSocket })
  p.budget = relayBudget({ budgets, storage: memory() })
  return p
}
// A pool that reconnects by itself, as the app's own pool is built (pool.js: net/pool.js pool = new LivePool({...,
// enableReconnect: true})). Only these tests need it: the others patch handleHardClose' reconnect away by not enabling it.
const newReconnectPool = budgets => {
  sent.length = 0
  opened.length = 0
  const p = new LivePool({ websocketImplementation: FakeSocket, enableReconnect: true })
  p.budget = relayBudget({ budgets, storage: memory() })
  return p
}
const reqs = () => sent.filter(s => s.type === "REQ").length
const flush = () => new Promise(r => setTimeout(r, 0)) // nostr-tools sends on a promise tick (abstract-relay.js send)
// A relay opens, then the socket drops: what nostr-tools does on a flapping link (abstract-relay.js handleHardClose ->
// reconnect, :208-209). ConnectionPromise is cleared, reconnectAttempts is 1, and a 10 s timer now holds connect().
const drop = r => r.ws.close()

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

test("takeMany reserves all or nothing", () => {
  const c = clock(Date.parse("2026-10-31T10:00:00Z"))
  const b = relayBudget({ budgets: { "relay.damus.io": { perMinute: 5, perDay: 100 } }, storage: memory(), now: c.now })
  assert.equal(b.takeMany(DAMUS, 4), true)
  assert.equal(b.takeMany(DAMUS, 2), false)
  assert.deepEqual(b.left(DAMUS), { day: 96, minute: 1 }, "the refused reservation spent nothing")
  assert.equal(b.takeMany(DAMUS, 1), true)
  assert.equal(b.takeMany("wss://relay.primal.net", 10_000), true, "no budget: any number may go")
})

test("a reconnect pays for every REQ it will re-fire, and is refused when the budget is out", async () => {
  const p = newReconnectPool({ "relay.damus.io": { perMinute: 2, perDay: 100 } })
  try {
    const r = await p.ensureRelay(DAMUS) // 1 unit
    const sub = r.subscribe([{ kinds: [1] }], { onevent() {} }) // one open sub -> one REQ on the new socket
    await flush()
    const before = reqs()
    assert.equal(before, 1, "the first connect's one REQ")

    drop(r) // nostr-tools: handleHardClose -> reconnect(), connectionPromise cleared, reconnectAttempts 1
    assert.equal(r.reconnectAttempts, 1)
    await r.connect() // the 2nd unit, and the socket re-fires the open sub
    await flush()
    assert.equal(reqs(), before + 1, "the reconnect went through and re-fired the sub")
    assert.equal(r.reconnectAttempts, 0, "nostr-tools reset it on open")

    drop(r)
    await assert.rejects(() => r.connect(), /reconnect budget used/) // 2 + 1 > 2
    await flush()
    assert.equal(reqs(), before + 1, "the refused reconnect sent nothing")
    assert.equal(p.retryTimers.size, 1, "and the pool holds a retry for it instead of dropping the relay")
    sub.close()
  } finally { p.destroy() }
})

test("a refused reconnect is retried by the pool at once when the minute turns over", async () => {
  const c = clock(Date.parse("2026-10-31T10:00:00Z"))
  const p = newReconnectPool({ "relay.damus.io": { perMinute: 1, perDay: 100 } })
  p.budget = relayBudget({ budgets: { "relay.damus.io": { perMinute: 1, perDay: 100 } }, storage: memory(), now: c.now })
  try {
    const r = await p.ensureRelay(DAMUS) // the minute's only unit
    const sub = r.subscribe([{ kinds: [1] }], { onevent() {} })
    await flush()
    const before = reqs()
    drop(r)
    await assert.rejects(() => r.connect(), /reconnect budget used/)
    assert.equal(opened.length, 1, "no socket for the refused reconnect")

    c.add(60_000) // the next minute's share
    p.retryAllNow() // what `online` does (see pool.js): try the waiting relays at once
    await flush()
    assert.equal(opened.length, 2, "retried at once, no backoff wait")
    await flush()
    assert.equal(reqs(), before + 1, "and re-fired the open sub")
    assert.equal(p.retryCounts.size, 0, "the backoff resets once it is through")
    sub.close()
  } finally { p.destroy() }
})

test("a reconnect checks Never Connect, the dead list and the plain-ws rule, not just the budget", async () => {
  const p = newReconnectPool({})
  try {
    const r = await p.ensureRelay("wss://quiet.example")
    p.neverConnect = url => url.includes("quiet.example") // the user's kind 10006 list, arriving after the relay opened
    drop(r)
    await assert.rejects(() => r.connect(), /Never Connect/)
    assert.equal(p.relays.get(r.url), r, "a relay refused mid-reconnect is not dropped")

    const plain = await p.ensureRelay("ws://plain.example") // allowed while the page is not https
    p.pageProtocol = () => "https:" // a redirect to https, or the page was opened over it all along
    drop(plain)
    await assert.rejects(() => plain.connect(), /plain ws:\/\//)
  } finally { p.destroy() }
})

test("a reconnect the pool cannot open keeps the subscriptions it was re-firing", async () => {
  const p = newReconnectPool({ "relay.damus.io": { perMinute: 1, perDay: 100 } })
  try {
    const r = await p.ensureRelay(DAMUS)
    r.subscribe([{ kinds: [1] }], { onevent() {} })
    await flush()
    drop(r)
    await assert.rejects(() => p.ensureRelay(DAMUS), /reconnect budget used/)
    // ensureRelay drops a relay whose connect threw; a refusal must not, or the feed's open subs are orphaned.
    assert.equal(p.relays.get(r.url), r, "still the same relay, still in the pool")
    assert.equal(r.openSubs.size, 1, "and its subscription is still open")
  } finally { p.destroy() }
})
