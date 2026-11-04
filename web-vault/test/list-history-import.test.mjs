// Moving in pulls the user's older list versions from the relays into the vault's list history (net/list-history-
// import.js; Logen 2026-11-04, Lazarus follow-up). Throwaway keys, fake relays and a fake vault: nothing is opened,
// nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { scanListHistory, importListHistory, scanRelays, historyLine, HISTORY_RELAYS, HISTORY_KINDS, PAGE, MAX_PAGES } from "../src/net/list-history-import.js"

const sk = generateSecretKey(), me = getPublicKey(sk)
const strangerSk = generateSecretKey()
const T = Math.floor(Date.now() / 1000) - 86_400 * 30
const follows = (n, at, key = sk) => finalizeEvent({ kind: 3, created_at: at, tags: Array.from({ length: n }, (_, i) => ["p", (i + 1).toString(16).padStart(64, "0")]), content: "" }, key)
const mutes = at => finalizeEvent({ kind: 10000, created_at: at, tags: [["p", "a".repeat(64)]], content: "" }, sk)

/** A relay holding `events`, answering like a NIP-01 relay (newest first, `until` inclusive, `limit`). */
const relay = events => (filter) => {
  const hits = events.filter(e => filter.kinds.includes(e.kind) && filter.authors.includes(e.pubkey) && (filter.until === undefined || e.created_at <= filter.until))
    .sort((a, b) => b.created_at - a.created_at).slice(0, filter.limit)
  return { events: hits, answered: true }
}
const relays = map => { const asked = []; return { asked, ask: async (url, filter) => { asked.push({ url, filter }); const r = map[url]; return r ? r(filter) : { events: [], answered: false } } } }

test("the scan asks the user's relays, the defaults and the archival set; kinds: follows, mutes, relays and Recover's", () => {
  const urls = scanRelays({ relays: { read: ["wss://mine.example"], write: ["wss://mine.example", "wss://out.example"] } })
  for (const u of ["wss://mine.example", "wss://out.example", ...HISTORY_RELAYS]) assert.ok(urls.includes(u), u)
  assert.equal(new Set(urls).size, urls.length)
  assert.deepEqual(HISTORY_RELAYS, ["wss://hist.nostr.land", "wss://relay.ditto.pub"])
  for (const k of [3, 10000, 10002, 10003, 10063]) assert.ok(HISTORY_KINDS.includes(k), String(k))
  assert.ok(!HISTORY_KINDS.includes(0), "a profile isn't a list")
})

test("one request per kind, limit ≥ 50; a full page asks again with until at its oldest; nothing older stops it", async () => {
  const history = Array.from({ length: 250 }, (_, i) => follows(3, T + i))
  const r = relays({ "wss://hist": relay(history) })
  const { versions, outcomes } = await scanListHistory({ pubkey: me, relays: ["wss://hist"], kinds: [3], ask: r.ask })
  assert.ok(PAGE >= 50)
  assert.ok(r.asked.every(a => a.filter.kinds.length === 1 && a.filter.authors[0] === me && a.filter.limit === PAGE))
  assert.equal(r.asked[0].filter.until, undefined)
  assert.equal(r.asked[1].filter.until, T + 150, "inclusive: the oldest of the first page")
  assert.equal(versions.length, 250)
  assert.ok(versions[0].created_at > versions.at(-1).created_at, "newest first")
  assert.equal(outcomes.get("wss://hist"), "answered")
})

test("paging stops at MAX_PAGES and when a page brings nothing older", async () => {
  const many = Array.from({ length: PAGE * (MAX_PAGES + 2) }, (_, i) => follows(1, T + i))
  const r = relays({ "wss://deep": relay(many) })
  await scanListHistory({ pubkey: me, relays: ["wss://deep"], kinds: [3], ask: r.ask })
  assert.equal(r.asked.length, MAX_PAGES)
  // A relay that ignores until and sends the same page again is exhausted, not asked forever.
  const same = Array.from({ length: PAGE }, (_, i) => follows(1, T + i))
  const r2 = relays({ "wss://stuck": () => ({ events: same, answered: true }) })
  await scanListHistory({ pubkey: me, relays: ["wss://stuck"], kinds: [3], ask: r2.ask })
  assert.equal(r2.asked.length, 2)
})

test("relays are untrusted: a forged, a stranger's or a wrong-kind event is dropped and doesn't move the cursor", async () => {
  const good = follows(2, T)
  const forged = { ...follows(9, T + 10), sig: "00".repeat(64) }
  const stranger = follows(9, T + 20, strangerSk)
  const wrongKind = mutes(T + 30)
  const r = relays({ "wss://bad": () => ({ events: [forged, stranger, wrongKind, good], answered: true }) })
  const { versions } = await scanListHistory({ pubkey: me, relays: ["wss://bad"], kinds: [3], ask: r.ask })
  assert.deepEqual(versions.map(v => v.id), [good.id])
})

test("each relay's outcome: only an EOSE is an answer; copies on two relays count once", async () => {
  const v = follows(3, T)
  const r = relays({ "wss://a": relay([v]), "wss://b": relay([v]) })
  const { versions, outcomes } = await scanListHistory({ pubkey: me, relays: ["wss://a", "wss://b", "wss://down"], kinds: [3], ask: r.ask })
  assert.equal(versions.length, 1)
  assert.deepEqual(Object.fromEntries(outcomes), { "wss://a": "answered", "wss://b": "answered", "wss://down": "failed" })
})

/** A vault: the outbox holds the current lists, /lists the history; /lists records what it is sent. */
function vault({ current = [], kept = [], refuse = () => null } = {}) {
  const filed = [], outboxWrites = []
  const q = evs => async f => evs.filter(e => f.kinds.includes(e.kind) && f.authors.includes(e.pubkey))
  return {
    filed, outboxWrites,
    outbox: { query: q(current), event: async ev => { outboxWrites.push(ev); return { ok: true } } },
    lists: { query: q(kept), event: async ev => { const why = refuse(ev); if (why) return { ok: false, message: why }; if (filed.some(e => e.id === ev.id)) return { ok: false, message: "duplicate:" }; filed.push(ev); return { ok: true } } },
  }
}

test("only versions the vault doesn't hold are filed, in /lists only; the outbox is never written", async () => {
  const cur = follows(50, T + 900), kept = follows(48, T + 800)
  const older = [follows(40, T + 700), follows(10, T + 600), mutes(T + 500)]
  const v = vault({ current: [cur], kept: [kept] })
  const r = relays({ "wss://hist": relay([cur, kept, ...older]) })
  const res = await importListHistory({ session: { pubkey: me }, vault: v, account: {} }, { relays: ["wss://hist"], kinds: [3, 10000], ask: r.ask })
  assert.deepEqual(v.filed.map(e => e.id).sort(), older.map(e => e.id).sort())
  assert.equal(v.outboxWrites.length, 0, "never the outbox: an old version never becomes the current list")
  assert.deepEqual(res, { found: 3, byKind: { 3: 2, 10000: 1 }, answered: 1, asked: 1, refused: 0 })
})

test("a version Haven refuses isn't counted as found; one it already has isn't either", async () => {
  const a = follows(5, T + 1), b = follows(6, T + 2)
  const v = vault({ refuse: ev => (ev.id === a.id ? "invalid: dated ahead of this vault's clock" : null) })
  const r = relays({ "wss://hist": relay([a, b]) })
  const ctx = { session: { pubkey: me }, vault: v, account: {} }
  assert.deepEqual(await importListHistory(ctx, { relays: ["wss://hist"], kinds: [3], ask: r.ask }), { found: 1, byKind: { 3: 1 }, answered: 1, asked: 1, refused: 1 })
  const again = await importListHistory(ctx, { relays: ["wss://hist"], kinds: [3], ask: r.ask })
  assert.equal(again.found, 0, "a second run finds nothing new")
})

test("nothing here signs or publishes: the module has no signer or pool publish in it", async () => {
  const { readFileSync } = await import("node:fs")
  const src = readFileSync(new URL("../src/net/list-history-import.js", import.meta.url), "utf8")
  assert.doesNotMatch(src, /signEvent|\.publish\(|publishAction|outbox\.event/)
})

test("the plain count", () => {
  assert.equal(historyLine({ found: 12, answered: 3 }), "Found 12 older versions of your lists. See them in Settings › Recover a List.")
  assert.equal(historyLine({ found: 1, answered: 3 }), "Found 1 older version of your lists. See them in Settings › Recover a List.")
  assert.equal(historyLine({ found: 0, answered: 3 }), "No older versions of your lists found.")
  assert.equal(historyLine({ found: 0, answered: 0 }), "Couldn't reach the relays to look for older versions of your lists.")
})
