import { test } from "node:test"
import assert from "node:assert/strict"
import { mkdtemp, readFile, writeFile, rm, access } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { main, RELAYS, MIN_RELAYS, parseArgs } from "../run.mjs"
import { downloadTotal, sumDownloads } from "../github.mjs"

const A = "a".repeat(64)
const B = "b".repeat(64)
const NOW = 1_800_000_000

// A fake relay network: Logen follows A; B tagged Nostr Vault shows up in the firehose sample; A posts from Android.
function fakeNetwork({ answering = RELAYS.length } = {}) {
  const calls = []
  const q = async (relays, filter) => {
    calls.push(filter)
    const answered = relays.slice(0, answering)
    let events = []
    if (filter.kinds?.includes(3) && filter.authors) events = [{ id: "f", pubkey: filter.authors[0], kind: 3, created_at: 1, tags: [["p", A]] }]
    else if (filter.since && filter.kinds?.includes(1) && !filter.authors && !filter["#p"]) events = [{ id: "n2", pubkey: B, kind: 1, created_at: NOW - 100, tags: [["client", "Nostr Vault on Web"]] }]
    else if (filter.authors) events = filter.authors.includes(A) ? [{ id: "n1", pubkey: A, kind: 1, created_at: NOW - 3 * 86400, tags: [["client", "Nostr Vault on Android"]] }] : []
    return { events, answered }
  }
  return { q, calls }
}

const fakeFetch = async () => ({ ok: true, json: async () => [{ assets: [{ download_count: 5 }, { download_count: 2 }] }] })

async function tmp() {
  const dir = await mkdtemp(join(tmpdir(), "nvstats-"))
  return { dir, out: join(dir, "stats.json"), state: join(dir, "posters.json") }
}

test("a full run writes totals and the local state", async t => {
  const { dir, out, state } = await tmp()
  t.after(() => rm(dir, { recursive: true, force: true }))
  const { q } = fakeNetwork()
  const code = await main(["--out", out, "--state", state], { q, fetchFn: fakeFetch, nowSec: () => NOW })
  assert.equal(code, 0)
  const totals = JSON.parse(await readFile(out, "utf8"))
  assert.equal(totals.posting_users, 2)
  assert.deepEqual(totals.by_platform, { Android: 1, iPhone: 0, iPad: 0, Mac: 0, Linux: 0, Web: 1 })
  assert.equal(totals.active_7d, 2)
  assert.equal(totals.github_downloads, 7)
  assert.equal(totals.relays, RELAYS.length)
  assert.deepEqual(Object.keys(JSON.parse(await readFile(state, "utf8"))).sort(), [A, B])
})

test("too few relays answering writes nothing and exits 2", async t => {
  const { dir, out, state } = await tmp()
  t.after(() => rm(dir, { recursive: true, force: true }))
  const { q } = fakeNetwork({ answering: MIN_RELAYS - 1 })
  const code = await main(["--out", out, "--state", state], { q, fetchFn: fakeFetch, nowSec: () => NOW })
  assert.equal(code, 2)
  await assert.rejects(access(out))
  await assert.rejects(access(state))
})

test("exactly MIN_RELAYS answering is enough (the gate is not off by one)", async t => {
  const { dir, out, state } = await tmp()
  t.after(() => rm(dir, { recursive: true, force: true }))
  const { q } = fakeNetwork({ answering: MIN_RELAYS })
  assert.equal(await main(["--out", out, "--state", state], { q, fetchFn: fakeFetch, nowSec: () => NOW }), 0)
})

test("yesterday's posters stay counted and are scanned again", async t => {
  const { dir, out, state } = await tmp()
  t.after(() => rm(dir, { recursive: true, force: true }))
  const C = "c".repeat(64)
  await writeFile(state, JSON.stringify({ [C]: { first: 1, last: NOW - 60 * 86400, notes: { Mac: 2 } } }))
  const { q, calls } = fakeNetwork()
  await main(["--out", out, "--state", state], { q, fetchFn: fakeFetch, nowSec: () => NOW })
  assert.ok(calls.some(f => f.authors?.includes(C)), "the known poster is in the scan")
  const totals = JSON.parse(await readFile(out, "utf8"))
  assert.equal(totals.posting_users, 3)
  assert.equal(totals.by_platform.Mac, 1)
  assert.equal(totals.active_30d, 2)
})

test("a GitHub failure leaves downloads null and still writes the user totals", async t => {
  const { dir, out, state } = await tmp()
  t.after(() => rm(dir, { recursive: true, force: true }))
  const { q } = fakeNetwork()
  const code = await main(["--out", out, "--state", state], { q, fetchFn: async () => ({ ok: false, status: 403 }), nowSec: () => NOW })
  assert.equal(code, 0)
  assert.equal(JSON.parse(await readFile(out, "utf8")).github_downloads, null)
})

test("--dry-run writes no file", async t => {
  const { dir, out, state } = await tmp()
  t.after(() => rm(dir, { recursive: true, force: true }))
  const { q } = fakeNetwork()
  const log = console.log
  console.log = () => {}
  try {
    assert.equal(await main(["--out", out, "--state", state, "--dry-run"], { q, fetchFn: fakeFetch, nowSec: () => NOW }), 0)
  } finally { console.log = log }
  await assert.rejects(access(out))
})

test("parseArgs refuses unknown arguments", () => {
  assert.throws(() => parseArgs(["--bogus"]))
  assert.throws(() => parseArgs(["--firehose-hours", "x"]))
})

test("downloadTotal sums every page and throws on an HTTP error", async () => {
  const full = Array.from({ length: 100 }, () => ({ assets: [{ download_count: 1 }] }))
  const pages = [full, [{ assets: [{ download_count: 7 }, {}] }]]
  let i = 0
  assert.equal(await downloadTotal(async () => ({ ok: true, json: async () => pages[i++] })), 107)
  await assert.rejects(downloadTotal(async () => ({ ok: false, status: 500 })))
  assert.throws(() => sumDownloads({ message: "rate limited" }))
})

test("a batch that runs past the page cap is split until each part fits", async () => {
  const { scanPosters } = await import("../run.mjs")
  const pool = Array.from({ length: 8 }, (_, i) => String(i).repeat(64))
  const busy = pool[5]
  const seen = []
  const q = async (relays, filter) => {
    seen.push(filter.authors.length)
    // Any group holding the busy author overflows, unless it is the busy author alone.
    const capped = filter.authors.includes(busy) && filter.authors.length > 1 ? relays : []
    const events = filter.authors.map(a => ({ id: a, pubkey: a, kind: 1, created_at: NOW, tags: [["client", "Nostr Vault on iOS"]] }))
    return { events, answered: relays, capped }
  }
  const res = await scanPosters({ relays: RELAYS, pool, q, batch: 8 })
  assert.deepEqual(seen, [8, 4, 4, 2, 1, 1, 2])
  assert.equal(new Set(res.events.map(e => e.pubkey)).size, 8, "every author is read once, none dropped")
  assert.equal(res.events.length, 8, "a capped read's partial notes are not kept twice")
  assert.equal(res.cutShort, 0)
})

test("one author busier than the page cap on their own is reported, not looped on", async () => {
  const { scanPosters } = await import("../run.mjs")
  const q = async (relays, filter) => ({ events: [], answered: relays, capped: relays })
  const res = await scanPosters({ relays: RELAYS, pool: ["1".repeat(64), "2".repeat(64)], q, batch: 2 })
  assert.equal(res.cutShort, 2)
})
