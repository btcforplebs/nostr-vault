// A relay that accepts TCP and never finishes the WebSocket handshake (nostr-pub.wellorder.net on 2026-11-12, 10-12 s
// per connect) must not hold a quote or a feed read: a one-shot ask waits at most QUICK_CONNECT_MS for it, a quote
// ends on its first verified copy, and a relay whose connect failed is skipped for a cool-down
// (Tron, RESEARCH/NV_WEB_SLOW_LOAD_2026_11_12.md).
import test, { after, before } from "node:test"
import assert from "node:assert/strict"
import { createServer } from "node:net"
import { finalizeEvent, generateSecretKey } from "nostr-tools/pure"
import { LivePool, QUICK_CONNECT_MS, COOL_DOWN_MS, DEFAULT_RELAYS, pool } from "../src/net/pool.js"
import { fetchQuote } from "../src/net/quotes.js"
import { cachedDmRelays, dmRelaysFor, forgetDmRelays } from "../src/net/dms.js"
import { syncFeed, readFeed } from "../src/net/sync.js"
import { memoryStore } from "../src/guest/memory-vault.js"

after(() => pool.destroy())

// The hanging relay: a real TCP server that reads the HTTP upgrade and never answers it.
let hangServer, hangUrl, accepted = 0
const held = new Set()
before(async () => {
  hangServer = createServer(s => { accepted++; held.add(s); s.on("error", () => {}); s.on("close", () => held.delete(s)) })
  await new Promise(r => hangServer.listen(0, "127.0.0.1", r))
  hangUrl = `ws://127.0.0.1:${hangServer.address().port}`
})
after(() => { for (const s of held) s.destroy(); hangServer.close() })

// The good relay: in memory, answers each REQ with what it holds and EOSE.
const sk = generateSecretKey()
const note = text => finalizeEvent({ kind: 1, created_at: Math.floor(Date.now() / 1000), tags: [], content: text }, sk)
const stored = [note("one"), note("two"), note("three")]
const GOOD = "wss://good.example"
const matchesFilter = (ev, f) => (!f.ids || f.ids.includes(ev.id)) && (!f.kinds || f.kinds.includes(ev.kind)) && (!f.authors || f.authors.includes(ev.pubkey))
class GoodSocket {
  static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3
  constructor(url, openAfter = 5) { this.url = url; this.readyState = 0; setTimeout(() => { this.readyState = 1; this.onopen?.() }, openAfter) }
  send(raw) {
    const [type, id, ...filters] = JSON.parse(raw)
    if (type === "EVENT") return setTimeout(() => this.onmessage?.({ data: JSON.stringify(["OK", id.id, true, ""]) }), 5)
    if (type !== "REQ") return
    setTimeout(() => {
      for (const ev of stored) if (filters.some(f => matchesFilter(ev, f))) this.onmessage?.({ data: JSON.stringify(["EVENT", id, ev]) })
      this.onmessage?.({ data: JSON.stringify(["EOSE", id]) })
    }, 5)
  }
  close() { if (this.readyState >= 2) return; this.readyState = 3; setTimeout(() => this.onclose?.({}), 0) }
}
// Real WebSocket for the hanging relay (the handshake really never finishes), the in-memory one for the good relay.
function Socket(url) { return url.startsWith(GOOD) ? new GoodSocket(url) : new WebSocket(url) }

const newPool = () => {
  const p = new LivePool({ websocketImplementation: Socket })
  p.pageProtocol = () => "http:" // the hanging relay is plain ws:// on loopback
  return p
}
const timed = async work => { const t = Date.now(); const out = await work(); return { out, ms: Date.now() - t } }

test("wellorder is out of the default read set", () => {
  assert.ok(!DEFAULT_RELAYS.some(u => u.includes("wellorder")), DEFAULT_RELAYS.join())
})

test("a quote shows in under 1 s with a relay that never finishes its handshake", async () => {
  const p = newPool()
  try {
    const target = stored[1]
    const { out, ms } = await timed(() => fetchQuote({ type: "note", id: target.id, relays: [] },
      { relays: [hangUrl, GOOD], query: (u, f, o) => p.querySync(u, f, o) }))
    assert.equal(out?.id, target.id)
    assert.ok(ms < 1000, `quote took ${ms} ms`)
    assert.ok(accepted >= 1, "the hanging relay really was dialed")
  } finally { p.destroy() }
})

test("the Following feed shows its first notes in under 1 s with a relay that never finishes its handshake", async () => {
  const p = newPool()
  try {
    // syncFeed (the Following sync) as the app runs it, on this pool: notes are stored as each relay answers.
    const vault = { feed: memoryStore() }
    const t = Date.now()
    let firstNotesMs = null
    const done = syncFeed(vault, [stored[0].pubkey], [hangUrl, GOOD], {
      onProgress: ({ stored: n }) => { if (n && firstNotesMs == null) firstNotesMs = Date.now() - t },
      query: (r, f, o) => p.querySync(r, f, o),
      reach: urls => Promise.any(urls.map(url => p.ensureRelay(url, { connectionTimeout: 5000 }))),
    })
    const n = await done
    const totalMs = Date.now() - t
    assert.equal(n, 3)
    assert.ok(firstNotesMs != null && firstNotesMs < 1000, `first notes after ${firstNotesMs} ms`)
    assert.equal((await readFeed(vault, [stored[0].pubkey])).length, 3)
    // The whole sync is held only by the quick cap on the hanging relay, not its 5-6 s connect timeout.
    assert.ok(totalMs < QUICK_CONNECT_MS + 500, `sync done after ${totalMs} ms`)
  } finally { p.destroy() }
})

test("once a relay's connect has failed, asks skip it at once", async () => {
  const p = newPool()
  try {
    p.coolDown(hangUrl + "/") // what a failed or timed-out connect does (next test)
    const before = accepted
    const { out, ms } = await timed(() => p.querySync([GOOD, hangUrl], { kinds: [1] }, { maxWait: 6000 }))
    assert.equal(out.length, 3)
    assert.ok(ms < 300, `read took ${ms} ms`)
    assert.equal(accepted, before, "not dialed")
  } finally { p.destroy() }
})

test("a failed connect starts the cool-down, a good one ends it, and online clears them all", async () => {
  const p = newPool()
  try {
    // A connect that times out (the handshake never finishes) cools the relay down.
    await assert.rejects(p.ensureRelay(hangUrl, { connectionTimeout: 200 }))
    await new Promise(r => setTimeout(r, 20))
    const key = hangUrl + "/"
    assert.ok(p.coolingDown(key), "cooling down after the timeout")
    assert.equal(p.coolDowns.get(key).n, 1)
    const until = p.coolDowns.get(key).until - Date.now()
    assert.ok(until > COOL_DOWN_MS[0] - 1000 && until <= COOL_DOWN_MS[0], `${until} ms`)
    const before = accepted
    await assert.rejects(p.ensureRelay(hangUrl), /its last connect failed/)
    assert.equal(accepted, before, "no new socket while cooling down")
    // A signer's own relay is never skipped.
    p.keepForSigner([hangUrl])
    assert.equal(p.coolingDown(key), false)
    p.signerRelays.clear()
    // Back online: asked again at once.
    p.onOnline()
    assert.equal(p.coolingDown(key), false)
    // A relay that opens clears its cool-down.
    p.coolDown(GOOD + "/")
    p.coolDowns.get(GOOD + "/").until = 0 // its cool-down ran out
    await p.ensureRelay(GOOD)
    assert.equal(p.coolDowns.has(GOOD + "/"), false)
  } finally { p.destroy() }
})

test("a live subscription still waits the full connect: the quick cap is for one-shot asks", async () => {
  const p = newPool()
  try {
    assert.equal(QUICK_CONNECT_MS, 1500)
    let quickSeen = null
    const ensure = p.ensureRelay.bind(p)
    p.ensureRelay = (url, params) => { quickSeen = p.quickOpen; return ensure(url, params) }
    const sub = p.subscribe([GOOD], { kinds: [1] }, { onevent() {} })
    assert.equal(quickSeen, null)
    sub.close()
    await p.querySync([GOOD], { kinds: [1] }, { maxWait: 1000 })
    assert.ok(quickSeen, "the ask was seen")
    assert.equal(p.quickOpen, null, "the flag is down again after the ask")
  } finally { p.destroy() }
})

// Relays that open only after the quick cap: nothing else in the ask is open, so it waits for them (Tron M1).
const LATE = "wss://late.example"
const inboxKey = generateSecretKey()
const inbox = finalizeEvent({ kind: 10050, created_at: Math.floor(Date.now() / 1000), tags: [["relay", "wss://their-inbox.example"]], content: "" }, inboxKey)
class LateSocket extends GoodSocket {
  send(raw) {
    const [type, id] = JSON.parse(raw)
    if (type !== "REQ") return
    setTimeout(() => { this.onmessage?.({ data: JSON.stringify(["EVENT", id, inbox]) }); this.onmessage?.({ data: JSON.stringify(["EOSE", id]) }) }, 5)
  }
}
const latePool = (openAfter = QUICK_CONNECT_MS + 500) => {
  const p = new LivePool({ websocketImplementation: function (url) { return url.startsWith(LATE) ? new LateSocket(url, openAfter) : new WebSocket(url) } })
  p.pageProtocol = () => "http:"
  return p
}

test("a DM lookup whose relays all connect after the quick cap still finds the recipient's inbox", async () => {
  const p = latePool()
  try {
    const { out, ms } = await timed(() => dmRelaysFor(inbox.pubkey, [LATE, hangUrl], {
      fallback: ["wss://my-own-write.example"], query: (r, f, o) => p.querySync(r, f, o) }))
    assert.deepEqual([...out], ["wss://their-inbox.example"])
    assert.ok(ms >= QUICK_CONNECT_MS, `${ms} ms`)
  } finally { p.destroy() }
})

test("an ask with one relay open still skips a slow one after the quick cap", async () => {
  const p = newPool()
  try {
    await p.ensureRelay(GOOD)
    const { out, ms } = await timed(() => p.querySync([GOOD, hangUrl], { kinds: [1] }, { maxWait: 6000 }))
    assert.equal(out.length, 3)
    assert.ok(ms < QUICK_CONNECT_MS + 300, `${ms} ms`)
  } finally { p.destroy() }
})

test("a DM lookup that found no list is not cached; one that found the inbox is", async () => {
  forgetDmRelays()
  try {
    let asks = 0
    const answer = { evs: [] }
    const query = async () => { asks++; return answer.evs }
    const opts = { fallback: ["wss://my-own-write.example"], query }
    assert.deepEqual([...await cachedDmRelays(inbox.pubkey, ["wss://x.example"], opts)], ["wss://my-own-write.example"])
    await new Promise(r => setTimeout(r, 0))
    answer.evs = [inbox]
    assert.deepEqual([...await cachedDmRelays(inbox.pubkey, ["wss://x.example"], opts)], ["wss://their-inbox.example"])
    assert.equal(asks, 2, "the empty answer was not kept")
    await cachedDmRelays(inbox.pubkey, ["wss://x.example"], opts)
    assert.equal(asks, 2, "the found inbox was kept")
  } finally { forgetDmRelays() }
})

test("a publish still dials a relay that is cooling down", async () => {
  const p = newPool()
  try {
    p.coolDown(GOOD + "/")
    await assert.rejects(p.ensureRelay(GOOD), /its last connect failed/)
    const ev = note("write")
    const results = await Promise.allSettled(p.publish([GOOD], ev))
    assert.equal(results[0].status, "fulfilled", String(results[0].reason))
    assert.equal(p.coolDowns.has(GOOD + "/"), false, "its connect ended the cool-down")
  } finally { p.destroy() }
})
