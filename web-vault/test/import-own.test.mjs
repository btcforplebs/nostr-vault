// Settings › Import walks back from now to the start date ten days at a time, like the phone's Import
// (haven-go/import.go importOwnerNotes), and asks a capped relay again until a busy window comes back whole.
import test from "node:test"
import assert from "node:assert/strict"
import { pool } from "../src/net/pool.js"
import { importOwn, IMPORT_START_DATE, IMPORT_WINDOW } from "../src/net/sync.js"

const me = "a".repeat(64)
const other = "b".repeat(64)
const now = Math.floor(Date.now() / 1000)
const start = Date.parse("2023-01-01T00:00:00Z") / 1000
const KINDS = [1, 6, 7, 30023, 0, 3, 1111]
let n = 0
const ev = (created_at, pubkey = me) => ({ id: `e${n++}`, pubkey, kind: KINDS[n % KINDS.length], created_at, tags: [], content: "", sig: "" })

function fakeVault() {
  const stored = new Map()
  return { stored, outbox: { async event(e) { if (stored.has(e.id)) return { ok: false, message: "duplicate:" }; stored.set(e.id, e); return { ok: true } } } }
}

/** Relays that answer a filter newest first and stop at their cap (100 unless `caps` says), as most do. */
function fakeRelays(t, byRelay, caps = {}) {
  const filters = []
  t.mock.method(pool, "ensureRelay", async () => ({}))
  t.mock.method(pool, "querySync", async (relays, f) => {
    filters.push(f)
    return relays.flatMap(url => (byRelay[url] ?? [])
      .filter(e => f.authors.includes(e.pubkey) && (!f.kinds || f.kinds.includes(e.kind)) && e.created_at >= f.since && e.created_at <= f.until)
      .sort((a, b) => b.created_at - a.created_at).slice(0, caps[url] ?? 100))
  })
  return filters
}

test("imports every event back to the start date, more than 300, across a capped relay's busy window", async t => {
  const span = now - start
  const spread = Array.from({ length: 700 }, (_, i) => ev(start + Math.floor((i + 0.5) * span / 700)))
  const burst = Array.from({ length: 350 }, (_, i) => ev(now - 30 * 86400 - i * 60)) // one window, 3.5x the cap
  const old = Array.from({ length: 20 }, (_, i) => ev(start - 86400 - i)) // before the start date
  const all = [...spread, ...burst, ...old]
  const filters = fakeRelays(t, {
    "wss://a.example": all.filter((_, i) => i % 3 !== 0),
    "wss://b.example": [...all.filter((_, i) => i % 3 !== 1), ev(now - 100, other)],
  }, { "wss://b.example": 1000 }) // b reaching a window's start must not end a's paging
  const vault = fakeVault()
  const progress = []
  const r = await importOwn(vault, me, ["wss://a.example", "wss://b.example"], { onProgress: p => progress.push(p) })

  assert.equal(IMPORT_START_DATE, "2023-01-01")
  assert.equal(r.found, 1050)
  assert.equal(r.stored, 1050)
  assert.deepEqual(new Set(vault.stored.keys()), new Set([...spread, ...burst].map(e => e.id)), "everything since the start date, nothing before it")
  assert.ok([...vault.stored.values()].every(e => e.pubkey === me), "only the account's own events")
  assert.ok(filters.every(f => !f.kinds && f.authors.length === 1 && f.authors[0] === me), "no kinds in the filter, like the phone")
  assert.ok(filters.every(f => f.until - f.since <= IMPORT_WINDOW && f.since >= start), "ten-day windows, none before the start date")
  assert.equal(progress.length, Math.ceil(span / IMPORT_WINDOW), "one progress report per window")
  assert.ok(progress.every((p, i) => i === 0 || p.progress >= progress[i - 1].progress), "progress only goes up")
  assert.equal(progress.at(-1).progress, 1)
  assert.equal(progress.at(-1).from, "2023-01-01")
  assert.ok(progress[0].from > progress.at(-1).from, "walks back from now")
})

test("a later start date stops there; a rerun stores nothing new", async t => {
  const recent = Array.from({ length: 40 }, (_, i) => ev(now - i * 86400))
  fakeRelays(t, { "wss://a.example": recent })
  const vault = fakeVault()
  const startDate = new Date((now - 20.5 * 86400) * 1000).toISOString().slice(0, 10)
  const first = await importOwn(vault, me, ["wss://a.example"], { startDate })
  const since = Date.parse(`${startDate}T00:00:00Z`) / 1000
  assert.equal(first.stored, recent.filter(e => e.created_at >= since).length)
  const again = await importOwn(vault, me, ["wss://a.example"], { startDate })
  assert.equal(again.stored, 0)
  assert.equal(again.found, first.found)
})

test("no relay reachable or a bad date is an error, not an empty import", async t => {
  t.mock.method(pool, "ensureRelay", async () => { throw new Error("down") })
  await assert.rejects(importOwn(fakeVault(), me, ["wss://a.example"]), /no relay reachable/)
  await assert.rejects(importOwn(fakeVault(), me, ["wss://a.example"], { startDate: "soon" }), /not a date/)
})
