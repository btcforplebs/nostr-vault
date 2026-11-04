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

test("the scan asks the user's relays and the defaults, the archival set only when ticked; kinds: follows, mutes, relays and Recover's", () => {
  const account = { relays: { read: ["wss://mine.example"], write: ["wss://mine.example", "wss://out.example"] } }
  const urls = scanRelays(account)
  for (const u of ["wss://mine.example", "wss://out.example"]) assert.ok(urls.includes(u), u)
  for (const u of HISTORY_RELAYS) assert.ok(!urls.includes(u), `${u}: off unless the user ticks it (Logen 2026-11-04)`)
  const ticked = scanRelays(account, { history: true })
  for (const u of HISTORY_RELAYS) assert.ok(ticked.includes(u), u)
  assert.equal(new Set(ticked).size, ticked.length)
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
  assert.deepEqual(res, { found: 3, byKind: { 3: 2, 10000: 1 }, answered: 1, asked: 1, refused: 0, skipped: false })
})

test("a version Haven refuses isn't counted as found; one it already has isn't either", async () => {
  const a = follows(5, T + 1), b = follows(6, T + 2)
  const v = vault({ refuse: ev => (ev.id === a.id ? "invalid: dated ahead of this vault's clock" : null) })
  const r = relays({ "wss://hist": relay([a, b]) })
  const ctx = { session: { pubkey: me }, vault: v, account: {} }
  assert.deepEqual(await importListHistory(ctx, { relays: ["wss://hist"], kinds: [3], ask: r.ask }), { found: 1, byKind: { 3: 1 }, answered: 1, asked: 1, refused: 1, skipped: false })
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
  assert.equal(historyLine({ found: 2, answered: 1, skipped: true }), "Skipped the rest of the search: kept 2 older versions of your lists found so far. See them in Settings › Recover a List.")
  assert.equal(historyLine({ found: 0, answered: 0, skipped: true }), "Skipped looking for older versions of your lists.")
})

// Logen 2026-11-04: the scan can be skipped while it runs; what it found so far is kept and filed, and the import ends.
test("Skip ends the scan at once, keeps what was found so far and files it", async () => {
  const a = follows(5, T + 1), b = follows(6, T + 2)
  const v = vault({})
  let release
  const slow = new Promise(r => { release = r })
  const ask = async (url, filter) => {
    if (url === "wss://fast") return filter.kinds[0] === 3 ? { events: [a, b], answered: true } : { events: [], answered: true }
    await slow // a history relay that takes its time
    return { events: [], answered: true }
  }
  const skip = new AbortController()
  const run = importListHistory({ session: { pubkey: me }, vault: v, account: {} }, { relays: ["wss://fast", "wss://slow"], kinds: [3, 10000], ask, signal: skip.signal })
  await new Promise(r => setTimeout(r, 20))
  skip.abort()
  const res = await run // without waiting for the slow relay
  assert.equal(res.skipped, true)
  assert.equal(res.found, 2)
  assert.deepEqual(v.filed.map(e => e.id).sort(), [a.id, b.id].sort())
  release()
  const pre = new AbortController(); pre.abort()
  const none = await scanListHistory({ pubkey: me, relays: ["wss://fast"], kinds: [3], ask, signal: pre.signal })
  assert.deepEqual(none.versions, [])
  assert.equal(none.outcomes.get("wss://fast"), "skipped")
})

test("the Import notes choice: off by default, the agreed words, and a Skip while the list search runs", async () => {
  const { readFileSync } = await import("node:fs")
  const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
  const dash = src("screens/VaultDashboard.jsx"), keep = src("components/dashboard/KeepFullSection.jsx")
  assert.match(dash, /const \[historyRelays, setHistoryRelays\] = useState\(false\)/)
  assert.match(dash, /importListHistory\(ctx, \{ history: historyRelays, signal: skip\.current\.signal/)
  assert.match(keep, /Also look for older versions of my lists on history relays \(\$\{hosts\}\)\. They will see your IP asked\. Adds about a minute\./)
  assert.match(keep, /importing\?\.skippable && onSkip[\s\S]*>Skip</)
})
