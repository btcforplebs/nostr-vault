// Nuclear unfollow (RESEARCH/NV_NUCLEAR_UNFOLLOW_SPEC.md): who it would cut, the warnings, and the publish: the newest
// list as the base, a backup saved and read back before anything is signed, ONE kind 3 with only the checked people
// (and X) gone, every other tag and the content exact, and Undo putting the backup back.
// Throwaway keys, a fake store and a stubbed pool: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"
import { followersOfAmong, warningsFor, cutTags, nuclearUnfollow, undoNuclear, DOUBLE_WARN_AT } from "../src/net/nuclear-unfollow.js"

const SK = generateSecretKey(), ME = getPublicKey(SK)
const P = n => n.toString(16).padStart(64, "0")
const X = P(999)
const CONTENT = '{"wss://r.example":{"read":true,"write":true}}'
const list = (pks, created_at, extra = []) => finalizeEvent({ kind: 3, created_at, content: CONTENT, tags: [...pks.map(p => ["p", typeof p === "string" ? p : P(p)]), ...extra] }, SK)
const theirs = pks => ({ kind: 3, tags: pks.map(p => ["p", typeof p === "string" ? p : P(p)]) })
function memStore() {
  const m = new Map()
  return { m, all: async () => [...m.values()].sort((a, b) => b.created_at - a.created_at), put: async s => { m.set(s.id, s) }, remove: async id => { m.delete(id) } }
}
function ctxWith({ follows = [], signed = [] } = {}) {
  const stored = []
  return {
    stored, signed,
    session: { pubkey: ME },
    account: { follows, contacts: null, relays: { read: ["wss://r.example"], write: ["wss://w.example"], listed: ["wss://r.example", "wss://w.example"] } },
    signer: { signEvent: async t => { signed.push(t); return finalizeEvent(t, SK) } },
    vault: { outbox: { query: async () => [], event: async ev => { stored.push(ev); return { ok: true } } } },
  }
}
const sendOk = urls => urls.map(() => Promise.resolve(""))
const now = () => Math.floor(Date.now() / 1000)

test("who it would cut: your follows whose own list follows X, in your order, never you or X", () => {
  const lists = new Map([[P(1), theirs([X])], [P(2), theirs([5])], [P(3), theirs([X, 4])], [X, theirs([X])], [ME, theirs([X])]])
  assert.deepEqual(followersOfAmong(X, [P(3), P(2), P(1), X, ME, P(7)], lists, ME), [P(3), P(1)])
  assert.deepEqual(followersOfAmong(X, [P(1)], new Map(), ME), [], "a follow whose list didn't load isn't guessed at")
})

test("warnings: always one, a second from 25 people", () => {
  assert.equal(DOUBLE_WARN_AT, 25)
  assert.equal(warningsFor(1), 1)
  assert.equal(warningsFor(24), 1)
  assert.equal(warningsFor(25), 2)
})

test("cutTags: only those p tags go; other tags, order and petnames stay", () => {
  const base = { tags: [["p", P(1), "wss://a", "ann"], ["t", "nostr"], ["p", P(2)], ["p", X], ["e", "x"], ["p", P(3)]] }
  assert.deepEqual(cutTags(base, new Set([P(2), X])), [["p", P(1), "wss://a", "ann"], ["t", "nostr"], ["e", "x"], ["p", P(3)]])
})

test("nuclear unfollow: newest list as base, backup saved before signing, one list without the checked people and X", async () => {
  const old = list([1, 2], now() - 500)
  const newest = list([1, 2, 3, 4, X], now() - 100, [["t", "keep-me"]])
  const ctx = ctxWith({ follows: [P(1), P(2)] }), s = memStore()
  const order = []
  let sent
  const publish = (urls, ev) => { order.push("publish"); sent = { urls, ev }; return sendOk(urls) }
  const ask = async () => ({ events: [old, newest], answered: true })
  const signer = ctx.signer.signEvent
  ctx.signer.signEvent = async t => { order.push("sign"); return signer(t) }
  const r = await nuclearUnfollow({ ctx, target: X, remove: new Set([P(2), P(4), X, P(77)]), store: s, ask, publish, onBackup: b => order.push(`backup:${b.id === newest.id}`) })
  assert.deepEqual(order, ["backup:true", "sign", "publish"], "backup saved first, then one signature, one publish")
  assert.deepEqual(r.event.tags, [["p", P(1)], ["p", P(3)], ["t", "keep-me"]])
  assert.equal(r.event.content, CONTENT, "content exactly as it was")
  assert.equal(r.event.created_at >= newest.created_at + 1, true)
  assert.deepEqual(r.removed, [P(2), P(4), X], "P(77) isn't in the list: ignored, not invented")
  assert.ok(s.m.has(newest.id), "the backup is the list it replaced")
  assert.ok(sent.urls.includes("wss://w.example"))
  assert.equal(ctx.signed.length, 1)
})

test("no backup, no publish: a store that throws or keeps nothing stops it before signing", async () => {
  const newest = list([1, 2, X], now() - 100)
  const ask = async () => ({ events: [newest], answered: true })
  for (const store of [{ ...memStore(), put: async () => { throw new Error("QuotaExceededError") } }, { ...memStore(), put: async () => {} }]) {
    const ctx = ctxWith({ follows: [P(1), P(2)] })
    let backedUp = false
    await assert.rejects(nuclearUnfollow({ ctx, target: X, remove: new Set([P(2), X]), store, ask, publish: () => assert.fail("published"), onBackup: () => { backedUp = true } }), /couldn't be backed up.*nothing was published/)
    assert.equal(ctx.signed.length, 0)
    assert.equal(backedUp, false)
  }
})

test("refuses before backup or signing: relays unheard, no list, a shrunken base, nobody left, nobody checked", async () => {
  const fail = () => assert.fail("published")
  const tries = [
    [{ events: [list([1, X], now() - 10)], answered: false }, new Set([X]), /None of your relays answered/],
    [{ events: [], answered: true }, new Set([X]), /wasn't found on your relays/],
    [{ events: [list([1, 2], now() - 10)], answered: true }, new Set([P(1), P(2)]), /following nobody/],
    [{ events: [list([1, 2], now() - 10)], answered: true }, new Set([P(5)]), /None of them are in your newest follow list/],
    [{ events: [list([1], now() - 10)], answered: true }, new Set(), /Nobody is checked/],
  ]
  for (const [reply, remove, why] of tries) {
    const ctx = ctxWith({ follows: [P(1), P(2)] }), s = memStore()
    await assert.rejects(nuclearUnfollow({ ctx, target: X, remove, store: s, ask: async () => reply, publish: fail }), why)
    assert.equal(ctx.signed.length, 0)
    assert.equal(s.m.size, 0, "no backup taken for a cut that was refused")
  }
  // A one-relay-sized copy of a much bigger list (the app shows 40 follows): the base itself is refused.
  const ctx = ctxWith({ follows: Array.from({ length: 40 }, (_, i) => P(i + 1)) })
  await assert.rejects(nuclearUnfollow({ ctx, target: X, remove: new Set([P(1)]), store: memStore(), ask: async () => ({ events: [list([1, 2, 3], now() - 10)], answered: true }), publish: fail }), /drop most of them/)
  assert.equal(ctx.signed.length, 0)
})

test("a big cut the user checked is allowed: the size rule guards the base, not the user's choice", async () => {
  const pks = Array.from({ length: 40 }, (_, i) => i + 1)
  const newest = list(pks, now() - 10)
  const ctx = ctxWith({ follows: pks.map(P) })
  const remove = new Set(pks.slice(0, 30).map(P))
  const r = await nuclearUnfollow({ ctx, target: X, remove, store: memStore(), ask: async () => ({ events: [newest], answered: true }), publish: (u, ev) => sendOk(u) })
  assert.equal(r.event.tags.length, 10)
})

test("undo: the backup goes back as your follow list, only while the cut is still your newest", async t => {
  const newest = list([1, 2, X], now() - 100)
  const ctx = ctxWith({ follows: [P(1), P(2)] }), s = memStore()
  const r = await nuclearUnfollow({ ctx, target: X, remove: new Set([P(2), X]), store: s, ask: async () => ({ events: [newest], answered: true }), publish: (u) => sendOk(u) })
  t.mock.method(pool, "publish", urls => sendOk(urls))
  const back = await undoNuclear({ ctx, base: r.base, event: r.event, store: s, ask: async () => ({ events: [r.event], answered: true }) })
  assert.deepEqual(back.event.tags, newest.tags)
  assert.ok(back.event.created_at > r.event.created_at)
  const later = list([1], now() + 50)
  await assert.rejects(undoNuclear({ ctx, base: r.base, event: r.event, store: s, ask: async () => ({ events: [later], answered: true }) }), /changed since you looked/)
})
