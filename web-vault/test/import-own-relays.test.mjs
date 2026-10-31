// A sign-in pulls the account's old posts from the relays it published as its own (kind 10002, write or unmarked) on
// top of the apps' five and the Mac vault: net/own-relays.js, used by prepareVault and both Import buttons. Read only:
// nothing is published. Fake Haven routes, pool mocked; throwaway pubkey.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { pool, DEFAULT_RELAYS, relayLists } = await import("../src/net/pool.js")
const { ownPostRelays, relayKey } = await import("../src/net/own-relays.js")
const { prepareVault } = await import("../src/net/vault-ready.js")

Object.defineProperty(globalThis.navigator, "onLine", { value: true, configurable: true })
const m = new Map()
globalThis.localStorage = { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }
const ME = "b".repeat(64)
const now = Math.floor(Date.now() / 1000)

// Their list, as kind 10002 tags: two write relays of their own (one written twice), one read-only, plain ws://, LAN,
// .local, .onion, loopback (the Mac vault) and a dead host.
const TAGS = [
  ["r", "wss://their.relay.example/"], ["r", "wss://Their.Relay.Example"], ["r", "wss://outbox.example", "write"],
  ["r", "wss://inbox-only.example", "read"], ["r", "ws://plain.example"], ["r", "wss://192.168.1.20:4848"],
  ["r", "wss://10.0.0.5"], ["r", "wss://box.local"], ["r", "wss://hidden.onion"], ["r", "ws://localhost:3355"],
  ["r", "wss://relay.damus.io/"], ["r", "wss://nos.lol"],
]
const account = { relays: relayLists({ tags: TAGS }) }

test("their write and unmarked public relays, then the five, once each; not read-only, ws://, LAN, .local or .onion", () => {
  assert.deepEqual(ownPostRelays(account, "nostrvault.app"), ["wss://their.relay.example", "wss://outbox.example", "wss://relay.damus.io", ...DEFAULT_RELAYS.filter(u => u !== "wss://relay.damus.io")])
  const got = ownPostRelays(account, "nostrvault.app")
  assert.equal(new Set(got).size, got.length, "no relay twice")
  for (const u of DEFAULT_RELAYS) assert.ok(got.includes(u), u)
  for (const bad of ["inbox-only", "plain.example", "192.168", "10.0.0.5", "box.local", "onion", "localhost", "nos.lol"]) assert.ok(!got.some(u => u.includes(bad)), bad)
})

test("the Mac vault (their loopback relay) only from a page on that machine", () => {
  assert.ok(!ownPostRelays(account, "nostrvault.app").includes("ws://localhost:3355"))
  assert.ok(ownPostRelays(account, "localhost").includes("ws://localhost:3355"))
})

test("no list of their own: the five", () => {
  assert.deepEqual(ownPostRelays({ relays: relayLists(undefined) }, "nostrvault.app"), DEFAULT_RELAYS)
  assert.deepEqual(ownPostRelays(undefined, "nostrvault.app"), DEFAULT_RELAYS)
})

test("relayKey: one spelling per relay", () => {
  assert.equal(relayKey(" WSS://Relay.Example:443/inbox/ "), "wss://relay.example/inbox")
  assert.equal(relayKey("https://relay.example"), null)
  assert.equal(relayKey("junk"), null)
})

test("a sign-in pulls old posts from their own relay as well as the five, and publishes nothing", async t => {
  m.clear()
  const asked = new Map() // url -> kinds asked
  let published = 0
  t.mock.method(pool, "ensureRelay", async () => ({}))
  t.mock.method(pool, "publish", () => { published++; return [] })
  t.mock.method(pool, "querySync", async (urls, f) => {
    for (const u of urls) asked.set(u, [...(asked.get(u) ?? []), f.kinds.join()])
    const k = f.kinds.join()
    if (k === "0,3,10002,10006") return [{ id: "1".repeat(64), kind: 10002, pubkey: ME, created_at: now - 100, tags: TAGS, content: "", sig: "" }]
    // Only their own relay still has this old note.
    if (k === "1") return urls.includes("wss://their.relay.example") ? [{ id: "2".repeat(64), kind: 1, pubkey: ME, created_at: now - 9e7, tags: [], content: "from 2023", sig: "" }] : []
    return []
  })
  // Haven routes in memory: the account is read back from here once stored.
  const route = () => { const evs = []; return { evs, async event(e) { evs.push(e); return { ok: true } },
    async query(f) { return evs.filter(e => (!f.kinds || f.kinds.includes(e.kind)) && (!f.authors || f.authors.includes(e.pubkey))) } } }
  const v = { outbox: route(), feed: route(), inbox: route() }
  const { filled } = await prepareVault({ vault: v, pubkey: ME, local: { contacts: undefined, follows: [], relays: { read: [], write: [] } }, onStep: () => {} })
  await filled
  const notesAsked = [...asked].filter(([, kinds]) => kinds.includes("1")).map(([u]) => u)
  assert.ok(notesAsked.includes("wss://their.relay.example"), "their own relay was asked for their notes")
  assert.ok(notesAsked.includes("wss://outbox.example"))
  for (const u of DEFAULT_RELAYS) assert.ok(notesAsked.includes(u), u)
  assert.ok(!notesAsked.some(u => /inbox-only|plain\.example|192\.168|box\.local/.test(u)), notesAsked.join())
  assert.deepEqual(v.outbox.evs.filter(e => e.kind === 1).map(e => e.content), ["from 2023"])
  assert.equal(published, 0, "read only: nothing published")
})
