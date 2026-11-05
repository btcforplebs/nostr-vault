// Settings › Import and the dashboard's Import notes: the phone's Moving in (haven-go/import_owner.go, a572c1b0).
// NIP-77 first where a relay speaks it, every other relay paging its whole history on its own, the old ten-day walk
// only for a lane that didn't finish. Fake relays: nothing is opened or published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent, getEventHash } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"
import { importOwn, importNet, IMPORT_START_DATE, IMPORT_PAGE_LIMIT, IMPORT_SILENT_WINDOWS } from "../src/net/sync.js"

const sk = generateSecretKey()
const me = getPublicKey(sk)
const strangerSk = generateSecretKey()
const now = Math.floor(Date.now() / 1000)
const start = Date.parse("2023-01-01T00:00:00Z") / 1000
const KINDS = [1, 6, 7, 30023, 1111]
let n = 0
const ev = (created_at, key = sk) => finalizeEvent({ kind: KINDS[n++ % KINDS.length], created_at, tags: [], content: `note ${n}` }, key)

/** Haven's outbox, enough of it: a kind 5 removes its targets, and a target already deleted is refused. */
function fakeVault({ delayMs = 0 } = {}) {
  const stored = new Map()
  const deleted = new Set()
  const wait = () => delayMs ? new Promise(r => setTimeout(r, Math.random() * delayMs)) : null
  return {
    stored,
    outbox: {
      async event(e) {
        const dead = deleted.has(e.id)
        await wait()
        if (stored.has(e.id)) return { ok: false, message: "duplicate:" }
        if (dead) return { ok: false, message: "blocked: deleted" }
        if (e.kind === 5) for (const t of e.tags) if (t[0] === "e") { deleted.add(t[1]); stored.delete(t[1]) }
        await wait()
        stored.set(e.id, e)
        return { ok: true }
      },
      async query(f) {
        return [...stored.values()].filter(e => f.authors.includes(e.pubkey) && e.created_at >= f.since && (f.until === undefined || e.created_at <= f.until))
          .sort((a, b) => b.created_at - a.created_at).slice(0, f.limit)
      },
    },
  }
}

/** Relays that answer newest first and stop at their cap; none speaks NIP-77 unless `neg` says. -> asks per relay */
function fakeRelays(t, byRelay, { caps = {}, neg = {}, page } = {}) {
  const asks = {}, negAsks = {}, tagAsks = {}
  let published = 0
  t.mock.method(pool, "ensureRelay", async () => ({}))
  t.mock.method(pool, "publish", () => { published++; return [] })
  t.mock.method(importNet, "page", page ?? (async (url, f) => {
    if (f["#p"]) tagAsks[url] = (tagAsks[url] ?? 0) + 1 // the tagged-notes lane, counted apart
    else asks[url] = (asks[url] ?? 0) + 1
    const who = e => f["#p"] ? e.tags.some(t => t[0] === "p" && f["#p"].includes(t[1])) : f.authors.includes(e.pubkey)
    const hits = (byRelay[url] ?? []).filter(e => f.ids ? f.ids.includes(e.id)
      : who(e) && e.created_at >= f.since && (f.until === undefined || e.created_at <= f.until))
      .sort((a, b) => b.created_at - a.created_at)
    return { events: hits.slice(0, Math.min(f.limit ?? Infinity, caps[url] ?? Infinity)), eose: true }
  }))
  t.mock.method(importNet, "negentropy", async (url, f, have) => {
    negAsks[url] = (negAsks[url] ?? 0) + 1
    if (!neg[url]) throw Object.assign(new Error("no NIP-77"), { unsupported: true })
    const mine = new Set(have.map(h => h.id))
    return neg[url](f).filter(id => !mine.has(id))
  })
  return { asks, negAsks, tagAsks, published: () => published }
}

const within = (evs, since) => evs.filter(e => e.created_at >= since)

test("imports everything since the start date from every relay, past a relay's cap, and publishes nothing", async t => {
  const span = now - start
  const spread = Array.from({ length: 700 }, (_, i) => ev(start + Math.floor((i + 0.5) * span / 700)))
  const burst = Array.from({ length: 350 }, (_, i) => ev(now - 30 * 86400 - i * 60))
  const old = Array.from({ length: 20 }, (_, i) => ev(start - 86400 - i))
  const all = [...spread, ...burst, ...old]
  const net = fakeRelays(t, {
    "wss://a.example": all.filter((_, i) => i % 3 !== 0),
    "wss://b.example": [...all.filter((_, i) => i % 3 !== 1), ev(now - 100, strangerSk)],
  }, { caps: { "wss://a.example": 100 } })
  const vault = fakeVault()
  const progress = []
  const r = await importOwn(vault, me, ["wss://a.example", "wss://b.example"], { onProgress: p => progress.push(p) })

  assert.equal(IMPORT_START_DATE, "2023-01-01")
  assert.equal(r.found, 1050)
  assert.equal(r.stored, 1050)
  assert.deepEqual(new Set(vault.stored.keys()), new Set([...spread, ...burst].map(e => e.id)), "everything since the start date, nothing before it")
  assert.ok([...vault.stored.values()].every(e => e.pubkey === me), "only the account's own events")
  assert.equal(net.published(), 0)
  assert.ok(progress.every((p, i) => i === 0 || p.progress >= progress[i - 1].progress), "progress only goes up")
  assert.equal(progress.at(-1).progress, 1)
  assert.equal(progress.at(-1).from, "2023-01-01")
})

test("a sparse history costs a relay a few requests, not one per ten days", async t => {
  const notes = Array.from({ length: 700 }, (_, i) => ev(now - i * 86400))
  const net = fakeRelays(t, { "wss://a.example": notes })
  const vault = fakeVault()
  const startDate = new Date((now - 730 * 86400) * 1000).toISOString().slice(0, 10)
  await importOwn(vault, me, ["wss://a.example"], { startDate })
  assert.equal(vault.stored.size, 700)
  assert.ok(net.asks["wss://a.example"] <= 4, `asked ${net.asks["wss://a.example"]} times (73 windows used to mean 73+)`)
})

test("a rerun stores nothing new", async t => {
  const recent = Array.from({ length: 40 }, (_, i) => ev(now - i * 86400))
  fakeRelays(t, { "wss://a.example": recent })
  const vault = fakeVault()
  const startDate = new Date((now - 20.5 * 86400) * 1000).toISOString().slice(0, 10)
  const first = await importOwn(vault, me, ["wss://a.example"], { startDate })
  const since = Date.parse(`${startDate}T00:00:00Z`) / 1000
  assert.equal(first.stored, within(recent, since).length)
  const again = await importOwn(vault, me, ["wss://a.example"], { startDate })
  assert.equal(again.stored, 0)
})

test("no relay reachable or a bad date is an error, not an empty import", async t => {
  t.mock.method(pool, "ensureRelay", async () => { throw new Error("down") })
  await assert.rejects(importOwn(fakeVault(), me, ["wss://a.example"]), /no relay reachable/)
  await assert.rejects(importOwn(fakeVault(), me, ["wss://a.example"], { startDate: "soon" }), /not a date/)
})

test("a NIP-77 relay hands over by id what the vault lacks and is not paged", async t => {
  const notes = Array.from({ length: 1200 }, (_, i) => ev(now - i * 3600))
  const url = "wss://neg.example"
  const net = fakeRelays(t, { [url]: notes }, { neg: { [url]: () => notes.map(e => e.id) } })
  const vault = fakeVault()
  const r = await importOwn(vault, me, [url])
  assert.equal(vault.stored.size, 1200)
  assert.equal(r.stored, 1200)
  // 1200 ids at 500 a request: three by-id asks, no paging.
  assert.equal(net.asks[url], 3)
  // Rerun: the vault's copy goes into the vector, nothing is needed, nothing asked.
  const again = await importOwn(vault, me, [url])
  assert.equal(again.stored, 0)
  assert.equal(net.asks[url], 3)
})

test("ids a NIP-77 relay listed but didn't send are asked again once, then the relay is paged", async t => {
  const url = "wss://neg.example"
  const notes = Array.from({ length: 10 }, (_, i) => ev(now - i * 3600))
  const ghost = "f".repeat(64)
  const asked = []
  fakeRelays(t, {}, {
    neg: { [url]: () => [...notes.map(e => e.id), ghost] },
    page: async (u, f) => {
      asked.push(f.ids ? `ids:${f.ids.length}` : "page")
      if (f.ids) return { events: notes.filter(e => f.ids.includes(e.id)), eose: true }
      return { events: notes.filter(e => e.created_at >= f.since && (f.until === undefined || e.created_at <= f.until)), eose: true }
    },
  })
  const vault = fakeVault()
  await importOwn(vault, me, [url])
  assert.equal(vault.stored.size, 10)
  assert.deepEqual(asked.slice(0, 2), ["ids:11", "ids:1"], "the missing one asked for again, once")
  assert.ok(asked.includes("page"), "still missing after that: paged")
})

test("a relay that doesn't speak NIP-77 is paged, and isn't asked again that day", async t => {
  const url = "wss://plain.example"
  const notes = Array.from({ length: 30 }, (_, i) => ev(now - i * 3600))
  const net = fakeRelays(t, { [url]: notes })
  const vault = fakeVault()
  await importOwn(vault, me, [url])
  await importOwn(vault, me, [url])
  assert.equal(vault.stored.size, 30)
  assert.equal(net.negAsks[url], 1)
})

test("a lane that goes quiet partway, or never answers a wide scan, is read ten days at a time", async t => {
  const notes = Array.from({ length: 1200 }, (_, i) => ev(now - i * 3600)) // 50 days
  let lanePages = 0
  fakeRelays(t, {}, {
    page: async (url, f) => {
      const wide = f.until === undefined || f.until - f.since > 30 * 86400
      if (wide && url === "wss://narrow.example") return { events: [], eose: false } // times out on a wide scan
      if (wide && url === "wss://tired.example" && ++lanePages > 1) return { events: [], eose: false } // second page never comes
      const hits = notes.filter(e => e.created_at >= f.since && (f.until === undefined || e.created_at <= f.until)).sort((a, b) => b.created_at - a.created_at)
      return { events: hits.slice(0, f.limit), eose: true }
    },
  })
  for (const url of ["wss://narrow.example", "wss://tired.example"]) {
    const vault = fakeVault()
    const startDate = new Date((now - 100 * 86400) * 1000).toISOString().slice(0, 10)
    await importOwn(vault, me, [url], { startDate })
    assert.equal(vault.stored.size, 1200, url)
  }
})

test("a dead relay is asked once for its lane, then dropped after a few silent windows", async t => {
  let asks = 0
  fakeRelays(t, {}, { page: async () => { asks++; return { events: [], eose: false } } })
  const startDate = new Date((now - 730 * 86400) * 1000).toISOString().slice(0, 10)
  await importOwn(fakeVault(), me, ["wss://dead.example"], { startDate })
  assert.equal(asks, 1 + IMPORT_SILENT_WINDOWS + 1, "its lane, the silent windows, and one ask for the notes that tag you")
})

test("made-up notes (unsigned, or someone else's) never count: they can't keep a lane paging", async t => {
  let asks = 0
  fakeRelays(t, {}, {
    page: async (url, f) => {
      asks++
      const events = Array.from({ length: IMPORT_PAGE_LIMIT }, (_, i) => {
        const e = { pubkey: me, kind: 1, created_at: (f.until ?? now) - asks * 1000 - i, tags: [], content: `${asks} ${i}`, sig: "00".repeat(64) }
        e.id = getEventHash(e) // a real id, never signed
        return e
      })
      events.push(ev(now - 5, strangerSk))
      return { events, eose: true }
    },
  })
  const vault = fakeVault()
  await importOwn(vault, me, ["wss://hostile.example"])
  assert.equal(vault.stored.size, 0)
  assert.ok(asks <= 2, `forged notes drove ${asks} requests`)
})

test("a relay trickling real notes can't hold its lane: past the deadline it's read ten days at a time", async t => {
  const notes = Array.from({ length: 100 }, (_, i) => ev(now - i * 3600))
  fakeRelays(t, {}, {
    page: async (url, f) => {
      if (f.until === undefined || f.until - f.since > 30 * 86400) {
        await new Promise(r => setTimeout(r, 20))
        return { events: [ev((f.until ?? now) - 1)], eose: false } // always one more, older
      }
      return { events: notes.filter(e => e.created_at >= f.since && e.created_at <= f.until), eose: true }
    },
  })
  const vault = fakeVault()
  const startDate = new Date((now - 30 * 86400) * 1000).toISOString().slice(0, 10)
  const t0 = Date.now()
  await importOwn(vault, me, ["wss://trickle.example"], { startDate, laneDeadlineMs: 300 })
  assert.ok(Date.now() - t0 < 10_000, "held past the deadline")
  for (const e of notes) assert.ok(vault.stored.has(e.id), "a note only the window walk reaches is missing")
})

test("a deletion on one relay and its note on another never leave the note stored (one store batch at a time)", async t => {
  const targets = Array.from({ length: 300 }, (_, i) => ev(now - 100 - i))
  const deletions = targets.map(e => finalizeEvent({ kind: 5, created_at: e.created_at + 1, tags: [["e", e.id]], content: "" }, sk))
  const negUrl = "wss://neg.example", pagedUrl = "wss://paged.example"
  fakeRelays(t, {}, {
    neg: { [negUrl]: () => deletions.map(e => e.id) },
    page: async (url, f) => {
      if (url === negUrl && f.ids) return { events: deletions.filter(e => f.ids.includes(e.id)), eose: true }
      if (url !== pagedUrl) return { events: [], eose: true }
      const hits = targets.filter(e => e.created_at >= f.since && (f.until === undefined || e.created_at <= f.until))
      return { events: hits.slice(0, 25), eose: true } // small pages, interleaving with the deletions
    },
  })
  t.mock.method(importNet, "negentropy", async () => deletions.map(e => e.id))
  const vault = fakeVault({ delayMs: 3 })
  await importOwn(vault, me, [negUrl, pagedUrl])
  const kept = targets.filter(e => vault.stored.has(e.id)).length
  assert.equal(kept, 0, `${kept} deleted notes stayed beside their deletion`)
})

test("a note and its deletion in the same page: the deletion is stored after the note, so the note goes", async t => {
  const targets = Array.from({ length: 200 }, (_, i) => ev(now - 1000 - i * 2))
  const deletions = targets.map(e => finalizeEvent({ kind: 5, created_at: e.created_at + 1, tags: [["e", e.id]], content: "" }, sk))
  fakeRelays(t, { "wss://a.example": [...targets, ...deletions] })
  const vault = fakeVault({ delayMs: 3 })
  await importOwn(vault, me, ["wss://a.example"])
  const kept = targets.filter(e => vault.stored.has(e.id)).length
  assert.equal(kept, 0, `${kept} deleted notes stayed beside their deletion`)
})

test("a relay that only didn't answer NEG-OPEN in time is asked again next import", async t => {
  const url = "wss://slow-neg.example"
  let negAsks = 0
  fakeRelays(t, { [url]: [ev(now - 10)] })
  t.mock.method(importNet, "negentropy", async () => { negAsks++; throw Object.assign(new Error("no NIP-77 answer"), { unsupported: true, silent: true }) })
  await importOwn(fakeVault(), me, [url])
  await importOwn(fakeVault(), me, [url])
  assert.equal(negAsks, 2)
})
