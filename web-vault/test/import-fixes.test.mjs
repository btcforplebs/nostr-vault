// Web import fixes from the 2026-11-05 audits (RESEARCH/NV_IMPORT_AUDIT_RELAYS_AND_OVERLAP_2026_11_05.md):
// Tidy 3 (notes that tag you, paged), 5 (had only once Haven answered), 6 (store errors counted, not thrown),
// 8 (follows feed paged), 20 (one import lock), and the complete / partial / failed result. Fake relays, throwaway keys.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"
import { importOwn, importNet, importResult, syncFeed, FEED_PAGE, IMPORT_PAGE_LIMIT } from "../src/net/sync.js"
import { withImportLock, IMPORT_BUSY } from "../src/net/import-lock.js"

const sk = generateSecretKey(), me = getPublicKey(sk)
const other = generateSecretKey()
const now = Math.floor(Date.now() / 1000)
let n = 0
const note = (t, key = sk, tags = [], kind = 1) => finalizeEvent({ kind, created_at: t, tags, content: `n${n++}` }, key)
const startDate = new Date((now - 30 * 86400) * 1000).toISOString().slice(0, 10)

function route({ fail = () => false } = {}) {
  const stored = new Map()
  return {
    stored,
    async event(e) {
      if (fail(e)) throw new Error("no answer to EVENT in 15000 ms")
      if (stored.has(e.id)) return { ok: false, message: "duplicate:" }
      stored.set(e.id, e); return { ok: true }
    },
    async query(f) { return [...stored.values()].filter(e => (!f.authors || f.authors.includes(e.pubkey))) },
  }
}

function relays(t, byRelay) {
  const asks = []
  t.mock.method(pool, "ensureRelay", async () => ({}))
  t.mock.method(importNet, "negentropy", async () => { throw Object.assign(new Error("no"), { unsupported: true }) })
  t.mock.method(importNet, "page", async (url, f) => {
    asks.push({ url, f })
    const who = e => f["#p"] ? e.tags.some(t => t[0] === "p" && f["#p"].includes(t[1])) : f.authors.includes(e.pubkey)
    const hits = (byRelay[url] ?? []).filter(e => f.ids ? f.ids.includes(e.id) : who(e) && e.created_at >= f.since && (f.until === undefined || e.created_at <= f.until))
      .sort((a, b) => b.created_at - a.created_at)
    return { events: hits.slice(0, f.limit), eose: true }
  })
  return asks
}

test("notes that tag you come into the inbox, paged past one page; your own and messages stay out (Tidy 3)", async t => {
  const tagged = Array.from({ length: IMPORT_PAGE_LIMIT + 120 }, (_, i) => note(now - 100 - i * 60, other, [["p", me]], 7))
  const dm = note(now - 50, other, [["p", me]], 4)
  const mineTagged = note(now - 40, sk, [["p", me]])
  const forgedTag = { ...note(now - 30, other, [["p", me]]), content: "changed" }
  relays(t, { "wss://a": [...tagged, dm, mineTagged, forgedTag] })
  const vault = { outbox: route(), inbox: route() }
  const r = await importOwn(vault, me, ["wss://a"], { startDate })
  assert.equal(vault.inbox.stored.size, tagged.length)
  assert.ok(!vault.inbox.stored.has(dm.id) && !vault.inbox.stored.has(mineTagged.id) && !vault.inbox.stored.has(forgedTag.id))
  assert.deepEqual(r.tagged, { found: tagged.length, stored: tagged.length })
  assert.equal(r.result, "complete")
})

test("a note whose store failed is stored from the next relay that sends it (Tidy 5), and the failure is counted (Tidy 6)", async t => {
  const x = note(now - 500)
  let first = true
  relays(t, { "wss://a": [x], "wss://b": [x] })
  const outbox = route({ fail: e => e.id === x.id && first && !(first = false) })
  const r = await importOwn({ outbox, inbox: route() }, me, ["wss://a", "wss://b"], { startDate })
  assert.ok(outbox.stored.has(x.id), "the second relay's copy went in")
  assert.equal(r.failed, 1)
  assert.equal(r.found, 1)
  assert.equal(r.result, "partial", "a write that didn't land is not complete")
})

test("a Haven timeout doesn't end the import: the rest is stored and the result says partial (Tidy 6)", async t => {
  const notes = Array.from({ length: 30 }, (_, i) => note(now - 1000 - i))
  relays(t, { "wss://a": notes })
  const outbox = route({ fail: e => e.id === notes[3].id })
  const r = await importOwn({ outbox, inbox: route() }, me, ["wss://a"], { startDate })
  assert.equal(outbox.stored.size, 29)
  assert.equal(r.failed, 1)
  assert.equal(r.result, "partial")
})

test("complete / partial / failed, as the apps", () => {
  assert.equal(importResult({ relays: 2, cut: [], failed: 0, stored: 0, found: 0 }), "complete")
  assert.equal(importResult({ relays: 2, cut: ["wss://a"], failed: 0, stored: 0, found: 0 }), "partial")
  assert.equal(importResult({ relays: 2, cut: [], failed: 3, stored: 10, found: 13 }), "partial")
  assert.equal(importResult({ relays: 1, cut: ["wss://a"], failed: 0, stored: 0, found: 0 }), "failed")
  assert.equal(importResult({ relays: 1, cut: ["wss://a"], failed: 0, stored: 4, found: 4 }), "partial")
})

test("a relay that never answers leaves the import partial, never complete", async t => {
  relays(t, { "wss://a": [note(now - 10)] })
  const page = importNet.page
  t.mock.method(importNet, "page", async (url, f) => url === "wss://dead" ? { events: [], eose: false } : page(url, f))
  const r = await importOwn({ outbox: route(), inbox: route() }, me, ["wss://a", "wss://dead"], { startDate })
  assert.deepEqual(r.cut, ["wss://dead"])
  assert.equal(r.result, "partial")
})

test("one import at a time across tabs and screens (Tidy 20)", async () => {
  // A navigator.locks stand-in: ifAvailable hands null when it is held.
  let held = false
  const locks = { request: async (name, opts, cb) => { assert.equal(name, "nv-import"); if (held) return cb(null); held = true; try { return await cb({ name }) } finally { held = false } } }
  let release
  const first = withImportLock(() => new Promise(r => { release = r }), { locks })
  await assert.rejects(withImportLock(async () => "second", { locks }), new RegExp(IMPORT_BUSY.slice(0, 30)))
  release("first")
  assert.equal(await first, "first")
  assert.equal(await withImportLock(async () => "after", { locks }), "after")
  // No navigator.locks: this tab alone.
  let r2
  const a = withImportLock(() => new Promise(r => { r2 = r }), { locks: null })
  await assert.rejects(withImportLock(async () => 1, { locks: null }))
  r2(); await a
})

test("follows' feed: a relay that sends a full page is paged until a short one (Tidy 8); a timeout is counted", async t => {
  const follow = getPublicKey(other)
  const notes = Array.from({ length: FEED_PAGE * 2 + 37 }, (_, i) => note(now - 10 - i, other))
  const asks = []
  const query = async (urls, f) => {
    asks.push(f.until)
    return notes.filter(e => e.created_at >= f.since && (f.until === undefined || e.created_at <= f.until)).sort((a, b) => b.created_at - a.created_at).slice(0, f.limit)
  }
  const feed = route({ fail: e => e.id === notes[5].id })
  const tally = {}
  const stored = await syncFeed({ feed, outbox: route() }, [follow], ["wss://a"], { query, reach: async () => {}, tally })
  assert.equal(feed.stored.size, notes.length - 1)
  assert.equal(stored, notes.length - 1)
  assert.equal(asks.length, 3, "two full pages, then a short one")
  assert.deepEqual(tally, { failed: 1, capped: 0 })
})

test("a restore whose writes time out counts them and goes on, under the import lock (Tron 18, Tidy 20)", async () => {
  const { importNotes, zip } = await import("../src/net/backup.js")
  const evs = [note(now - 3), note(now - 2), note(now - 1)]
  const bytes = await zip([{ name: "outbox.jsonl", data: new TextEncoder().encode(evs.map(e => JSON.stringify(e)).join("\n")) }])
  const kept = []
  const open = () => ({ query: async () => [], event: async e => { if (e.id === evs[1].id) throw new Error("no answer to EVENT in 15000 ms"); kept.push(e.id); return { ok: true } } })
  const r = await importNotes({ vault: {}, pubkey: me, bytes, sk: generateSecretKey(), open })
  assert.deepEqual(r.counts.outbox, { stored: 2, refused: 0, bad: 0, failed: 1 })
  assert.equal(kept.length, 2)
})
