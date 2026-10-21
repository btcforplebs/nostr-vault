// Unread messages: what the iPhone counts (DMConversation.unreadCount), cleared by opening the conversation or by
// "Mark all read", kept per account across reloads. Only ids and a time are stored, never text or anyone's pubkey.
import test, { beforeEach } from "node:test"
import assert from "node:assert/strict"
import { readState, unreadCounts, unreadTotal, markRead, forgetReadCache, MAX_READ_IDS } from "../src/net/dm-read.js"

const ME = "a".repeat(64), BOB = "b".repeat(64), CAROL = "c".repeat(64)
const fakeStorage = () => { const m = new Map(); return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }
const msg = (id, from, peer, at) => ({ id: id.padStart(64, "0"), from, peer, at, content: "secret text" })
let storage
const opts = (clock = () => 1000) => ({ storage, clock })
beforeEach(() => { forgetReadCache(); storage = fakeStorage() })

test("the first time, older history is read and only what comes after counts", () => {
  readState(ME, opts(() => 1000))
  const ms = new Map([
    ["1", msg("1", BOB, BOB, 900)], ["2", msg("2", BOB, BOB, 1001)], ["3", msg("3", BOB, BOB, 1002)],
    ["4", msg("4", ME, BOB, 1003)], ["5", msg("5", CAROL, CAROL, 1004)],
  ])
  assert.deepEqual([...unreadCounts(ms, ME, new Set(), opts())], [[BOB, 2], [CAROL, 1]])
  assert.equal(unreadTotal(ms, ME, new Set([CAROL]), opts()), 2, "blocked people don't count")
})

test("opening a conversation reads it, and that survives a reload", () => {
  readState(ME, opts(() => 1000))
  const ms = new Map([["2", msg("2", BOB, BOB, 1001)], ["5", msg("5", CAROL, CAROL, 1004)]])
  assert.equal(markRead(ME, [ms.get("2")], opts()), 1)
  assert.equal(markRead(ME, [ms.get("2")], opts()), 0, "already read")
  forgetReadCache()
  const reloaded = { storage, clock: () => 5000 }
  assert.deepEqual([...unreadCounts(ms, ME, new Set(), reloaded)], [[CAROL, 1]])
})

test("mark all read reads what's open; a message opened later with an older time still counts", () => {
  readState(ME, opts(() => 1000))
  const ms = new Map([["2", msg("2", BOB, BOB, 1001)], ["5", msg("5", CAROL, CAROL, 1004)]])
  markRead(ME, [...ms.values()], opts())
  assert.equal(unreadTotal(ms, ME, new Set(), opts()), 0)
  ms.set("3", msg("3", BOB, BOB, 1002)) // was waiting behind "Open more"
  assert.equal(unreadTotal(ms, ME, new Set(), opts()), 1)
})

test("what's stored is ids and a time: no text, no pubkeys", () => {
  readState(ME, opts(() => 1000))
  markRead(ME, [msg("2", BOB, BOB, 1001)], opts())
  const [[key, raw]] = [...storage.m]
  assert.equal(key, `nv-dm-read:${ME}`)
  assert.doesNotMatch(raw, /secret text/)
  assert.doesNotMatch(raw, new RegExp(BOB))
  assert.deepEqual(Object.keys(JSON.parse(raw)).sort(), ["before", "read"])
})

test("past the cap the oldest ids go, and they stay read", () => {
  readState(ME, opts(() => 1000))
  const many = Array.from({ length: MAX_READ_IDS + 5 }, (_, i) => msg(`x${i}`, BOB, BOB, 1001 + i))
  markRead(ME, many, opts())
  assert.equal(JSON.parse(storage.m.get(`nv-dm-read:${ME}`)).read.length, MAX_READ_IDS)
  forgetReadCache() // a reload
  assert.equal(unreadTotal(new Map(many.map(m => [m.id, m])), ME, new Set(), opts()), 0, "the dropped ones are under `before`")
})

test("two tabs: what one tab read isn't undone by the other saving", () => {
  readState(ME, opts(() => 1000))
  markRead(ME, [msg("2", BOB, BOB, 1001)], opts()) // tab A
  const raw = storage.m.get(`nv-dm-read:${ME}`)
  storage.m.set(`nv-dm-read:${ME}`, JSON.stringify({ ...JSON.parse(raw), read: [...JSON.parse(raw).read, ["9".padStart(64, "0"), 1009]] })) // tab B saved
  markRead(ME, [msg("5", CAROL, CAROL, 1004)], opts()) // tab A again, with its old copy
  const ids = JSON.parse(storage.m.get(`nv-dm-read:${ME}`)).read.map(e => e[0])
  assert.deepEqual(ids.sort(), ["2", "5", "9"].map(i => i.padStart(64, "0")).sort())
})

test("accounts are kept apart", () => {
  readState(ME, opts(() => 1000))
  assert.equal(unreadTotal(new Map([["n", msg("n", ME, ME, 1001)]]), BOB, new Set(), opts()), 1, "another account has its own marker")
})

test("a broken or missing localStorage still works for this visit", () => {
  storage = { getItem: () => { throw new Error("denied") }, setItem: () => { throw new Error("quota") } }
  readState(ME, opts(() => 1000))
  const ms = new Map([["2", msg("2", BOB, BOB, 1001)]])
  assert.equal(unreadTotal(ms, ME, new Set(), opts()), 1)
  markRead(ME, [ms.get("2")], opts())
  assert.equal(unreadTotal(ms, ME, new Set(), opts()), 0)
})
