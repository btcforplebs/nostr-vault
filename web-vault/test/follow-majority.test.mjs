// The follow list's majority rule (Logen 2026-11-27, b6e725ef; iOS and Android build the same, src/net/follows.js
// followListKnown): an own write relay that never connects drops out of the count; the edit needs more than half of
// the ones that connected answering, and at least 2 answering. A relay that connected but is slow still counts.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { setFollow, followsOf, followListKnown, socketFailed } from "../src/net/follows.js"

const me = generateSecretKey(), mePk = getPublicKey(me)
const pk = () => getPublicKey(generateSecretKey())
const nowS = () => Math.floor(Date.now() / 1000)
const base = finalizeEvent({ kind: 3, created_at: nowS() - 600, tags: [["p", pk()], ["p", pk()]], content: "" }, me)
const seven = Array.from({ length: 7 }, (_, i) => `wss://r${i}.example`)
function fakeVault(seed = []) {
  const route = evs => ({
    evs,
    async query(f) { return evs.filter(e => (!f.kinds || f.kinds.includes(e.kind)) && (!f.authors || f.authors.includes(e.pubkey))) },
    async event(ev) { evs.push(ev); return { ok: true, message: "" } },
  })
  return { outbox: route([...seed]), feed: route([]) }
}
// Each of the 7 own relays is "answer" (EOSE with the list), "dead" (never connected) or "slow" (connected, no EOSE in
// time), as askRelay reports them. purplepag.es and the other index relays stay silent.
const relays = states => async url => {
  const s = states[seven.indexOf(url)]
  if (s === "answer") return { events: [base], answered: true, connected: true }
  if (s === "slow") return { events: [], answered: false, connected: true }
  return { events: [], answered: false, connected: false }
}
const run = states => setFollow({ vault: fakeVault([base]), signer: { signEvent: async t => finalizeEvent(t, me) }, pubkey: mePk,
  target: pk(), follow: true, readRelays: [], writeRelays: seven, ownRelays: seven, ask: relays(states),
  publish: urls => urls.map(() => Promise.resolve("")) })
const times = (n, s) => Array(n).fill(s)

test("majority: 3 of 7 dead and the other 4 answering is enough", async () => {
  const r = await run([...times(3, "dead"), ...times(4, "answer")])
  assert.equal(followsOf(r.event).length, 3)
})

test("majority: 5 of 7 dead and 2 answering is enough (the old rule wanted 4 of 7)", async () => {
  const r = await run([...times(5, "dead"), ...times(2, "answer")])
  assert.equal(followsOf(r.event).length, 3)
})

test("majority: 1 answering is refused, even with every other relay dead", async () => {
  await assert.rejects(run(["answer", ...times(6, "dead")]),
    { code: "oneAnswer", message: "Couldn't follow: only 1 relay answered, and it takes 2 to check your newest follow list. Nothing changed. Try again in a moment." })
})

test("majority: 0 answering is refused", async () => {
  await assert.rejects(run(times(7, "dead")), { code: "noAnswer", message: /^Couldn.t follow: no relay answered, so your newest follow list can.t be checked\. Nothing changed\. Check your connection, then try again\.$/ })
  await assert.rejects(run(times(7, "slow")), { code: "noAnswer", message: /^Couldn.t follow: no relay answered, so your newest follow list can.t be checked\. Nothing changed\. Check your connection, then try again\.$/ })
})

test("majority: a slow relay that connected still counts against the majority", async () => {
  // 3 dead drop out, 4 reached: 2 answering of 4 is not more than half.
  await assert.rejects(run([...times(3, "dead"), "answer", "answer", "slow", "slow"]), { code: "relays" })
  // 3 of 4 reached is.
  const r = await run([...times(3, "dead"), "answer", "answer", "answer", "slow"])
  assert.equal(followsOf(r.event).length, 3)
})

test("followListKnown: the cases on the rule alone", () => {
  assert.equal(followListKnown({ asked: 7, reached: 4, answered: 4, found: true }), true)
  assert.equal(followListKnown({ asked: 7, reached: 2, answered: 2, found: true }), true)
  assert.equal(followListKnown({ asked: 7, reached: 1, answered: 1, found: true }), false, "below 2")
  assert.equal(followListKnown({ asked: 7, reached: 4, answered: 2, found: true }), false, "half is not a majority")
  // No list found: every own relay, dead ones too: a dead one may hold the only copy (Tron, PR 2611 review).
  assert.equal(followListKnown({ asked: 3, reached: 2, answered: 2, found: false }), false)
  assert.equal(followListKnown({ asked: 2, reached: 2, answered: 2, found: false }), true)
})

test("majority: no list found and one own relay cooling down is refused, never a first list over its copy (Tron #2)", async () => {
  // A and B answer empty, C (which may hold a 300-follow list) is skipped by the pool's cool-down; a fresh browser.
  const abc = ["wss://a.example", "wss://b.example", "wss://c.example"]
  const ask = async url => url === abc[2] ? { events: [], answered: false, connected: socketFailed(new Error(`relay skipped, its last connect failed: ${url}`)) ? false : true }
    : { events: [], answered: abc.includes(url), connected: abc.includes(url) }
  await assert.rejects(setFollow({ vault: fakeVault(), signer: { signEvent: async t => finalizeEvent(t, me) }, pubkey: mePk, target: pk(), follow: true,
    readRelays: [], writeRelays: abc, ownRelays: abc, ask, publish: () => assert.fail("published") }), { code: "relays" })
  // Even if C's socket really failed, it may hold the list: still refused.
  const dead = async url => ({ events: [], answered: url !== abc[2] && abc.includes(url), connected: url !== abc[2] })
  await assert.rejects(setFollow({ vault: fakeVault(), signer: { signEvent: async t => finalizeEvent(t, me) }, pubkey: mePk, target: pk(), follow: true,
    readRelays: [], writeRelays: abc, ownRelays: abc, ask: dead, publish: () => assert.fail("published") }), { code: "relays" })
})

test("socketFailed: only a real socket error or close drops a relay out of the count (Tron #1)", () => {
  for (const e of ["connection failed", "websocket closed"]) assert.equal(socketFailed(e), true, e)
  for (const e of ["connection timed out", "relay skipped, its last connect failed: wss://c", "relay skipped, read budget used: wss://damus",
    "relay skipped, 24 sockets busy: wss://c", "dead relay skipped: wss://c", "relay slow to connect, skipped for this ask: wss://c"])
    assert.equal(socketFailed(new Error(e)), false, e)
  assert.equal(socketFailed(Object.assign(new Error("connection failed"), { refused: true })), false, "a gate refusal")
})

test("real pool: a second follow inside a socket failure's cool-down counts the same as the first (rd, Tod 11-27)", async () => {
  const { pool } = await import("../src/net/pool.js")
  const { askRelay } = await import("../src/net/follows.js")
  // 4 of 7 own relays refuse the connection (real sockets on closed ports); the other 3 answer with the list.
  const dead = ["ws://127.0.0.1:11", "ws://127.0.0.1:12", "ws://127.0.0.1:13", "ws://127.0.0.1:14"]
  const live = ["wss://l1.example", "wss://l2.example", "wss://l3.example"], own = [...dead, ...live]
  for (const u of dead) pool.coolDowns.delete(u.replace(/\/?$/, "/"))
  const ask = (url, filter) => live.includes(url) ? Promise.resolve({ events: [base], answered: true, connected: true }) : askRelay(url, filter, 1500)
  const follow = () => setFollow({ vault: fakeVault([base]), signer: { signEvent: async t => finalizeEvent(t, me) }, pubkey: mePk, target: pk(),
    follow: true, readRelays: [], writeRelays: own, ownRelays: own, ask, publish: urls => urls.map(() => Promise.resolve("")) })
  assert.equal(followsOf((await follow()).event).length, 3, "first follow: 3 of 3 reached")
  assert.ok(dead.every(u => pool.coolingDown(u.replace(/\/?$/, "/")) || pool.coolingDown(u)), "the dead relays are cooling down now")
  assert.equal(followsOf((await follow()).event).length, 3, "second follow inside the cool-down: still 3 of 3")
})

test("real pool: a cool-down that wasn't a socket failure (a timeout) still counts as reached", async () => {
  const { pool } = await import("../src/net/pool.js")
  const { askRelay } = await import("../src/net/follows.js")
  const url = "ws://127.0.0.1:15", key = "ws://127.0.0.1:15/"
  for (const k of [url, key]) pool.coolDowns.set(k, { n: 1, socket: false, until: Date.now() + 60000 })
  assert.deepEqual(await askRelay(url, { kinds: [3] }, 1500), { events: [], answered: false, connected: true })
  for (const k of [url, key]) pool.coolDowns.set(k, { n: 1, socket: true, until: Date.now() + 60000 })
  assert.deepEqual(await askRelay(url, { kinds: [3] }, 1500), { events: [], answered: false, connected: false })
  for (const k of [url, key]) pool.coolDowns.delete(k)
})
