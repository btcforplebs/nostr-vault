// Following's live subscription (net/feed-live.js): what it asks for, what it saves, batching, and opening again after
// every relay has closed it. A fake subscribe and fake timers: no relay is opened, nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { watchFollowing } from "../src/net/feed-live.js"

const hex = n => n.toString(16).padStart(64, "0")
const follows = Array.from({ length: 300 }, (_, i) => hex(i + 1))

function rig() {
  const subs = [], timers = [], saved = []
  const vault = { feed: { async event(ev) { if (saved.some(e => e.id === ev.id)) return { ok: false }; saved.push(ev); return { ok: true } } } }
  const subscribe = (urls, filter, params) => { const s = { urls, filter, params, closed: false, close() { s.closed = true } }; subs.push(s); return s }
  const setTimer = (fn, ms) => { const t = { fn, ms, done: false }; timers.push(t); return t }
  const clearTimer = t => { t.done = true }
  const run = async () => { for (const t of timers.splice(0)) if (!t.done) await t.fn(); await new Promise(r => setTimeout(r, 0)) }
  return { subs, timers, saved, vault, subscribe, setTimer, clearTimer, run }
}

test("one REQ per 250 follows, for the feed's kinds, from `since`", () => {
  const r = rig()
  const close = watchFollowing({ vault: r.vault, follows, relays: ["wss://a", "wss://b"], since: 1000, onNotes() {}, subscribe: r.subscribe, setTimer: r.setTimer, clearTimer: r.clearTimer })
  assert.deepEqual(r.subs.map(s => s.filter.authors.length), [250, 50])
  assert.ok(r.subs.every(s => s.filter.since === 1000 && s.filter.kinds.includes(1) && s.filter.kinds.includes(6)))
  assert.deepEqual(r.subs[0].urls, ["wss://a", "wss://b"])
  close()
  assert.ok(r.subs.every(s => s.closed))
})

test("a burst is saved and handed on once; repeats, strangers and other kinds are dropped", async () => {
  const r = rig(), got = []
  watchFollowing({ vault: r.vault, follows, relays: [], since: 0, onNotes: evs => got.push(evs.map(e => e.id)), subscribe: r.subscribe, setTimer: r.setTimer, clearTimer: r.clearTimer })
  const on = r.subs[0].params.onevent
  on({ id: "1", pubkey: follows[0], kind: 1, created_at: 5 })
  on({ id: "1", pubkey: follows[0], kind: 1, created_at: 5 })
  on({ id: "2", pubkey: follows[1], kind: 6, created_at: 6 })
  on({ id: "3", pubkey: hex(9999), kind: 1, created_at: 7 })
  on({ id: "4", pubkey: follows[2], kind: 7, created_at: 8 })
  assert.equal(r.timers.length, 1, "one batch timer for the burst")
  await r.run()
  assert.deepEqual(got, [["1", "2"]])
  assert.deepEqual(r.saved.map(e => e.id), ["1", "2"])
})

test("nothing new saved (all already in /feed) hands nothing on", async () => {
  const r = rig(), got = []
  r.saved.push({ id: "1" })
  watchFollowing({ vault: r.vault, follows, relays: [], onNotes: evs => got.push(evs), subscribe: r.subscribe, setTimer: r.setTimer, clearTimer: r.clearTimer })
  r.subs[0].params.onevent({ id: "1", pubkey: follows[0], kind: 1, created_at: 5 })
  await r.run()
  assert.deepEqual(got, [])
})

test("once every REQ has closed, it opens again later and asks for a catch-up", async () => {
  const r = rig()
  let reopened = 0
  watchFollowing({ vault: r.vault, follows, relays: [], since: 0, onNotes() {}, onReopen: () => reopened++, subscribe: r.subscribe, setTimer: r.setTimer, clearTimer: r.clearTimer, retryMs: 30_000 })
  r.subs[0].params.onclose(["relay gone"])
  assert.equal(r.timers.length, 0, "one REQ still open: wait")
  r.subs[1].params.onclose(["relay gone"])
  assert.equal(r.timers.length, 1)
  assert.equal(r.timers[0].ms, 30_000)
  await r.run()
  assert.equal(reopened, 1)
  assert.equal(r.subs.length, 4, "both REQs opened again")
  assert.ok(r.subs[2].filter.since > 0, "from about now, not from the start")
})

test("closed before a batch or a retry is due: nothing more happens", async () => {
  const r = rig(), got = []
  let reopened = 0
  const close = watchFollowing({ vault: r.vault, follows: follows.slice(0, 10), relays: [], onNotes: evs => got.push(evs), onReopen: () => reopened++, subscribe: r.subscribe, setTimer: r.setTimer, clearTimer: r.clearTimer })
  r.subs[0].params.onevent({ id: "1", pubkey: follows[0], kind: 1, created_at: 5 })
  close()
  r.subs[0].params.onclose(["closed by us"])
  await r.run()
  assert.deepEqual(got, [])
  assert.equal(reopened, 0)
  assert.equal(r.subs.length, 1)
})

test("no follows opens nothing", () => {
  const r = rig()
  watchFollowing({ vault: r.vault, follows: [], relays: ["wss://a"], onNotes() {}, subscribe: r.subscribe })
  assert.equal(r.subs.length, 0)
})
