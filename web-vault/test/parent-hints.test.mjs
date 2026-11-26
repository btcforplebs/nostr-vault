// A reply's parent that lives only on its author's relay loads: the thread screen and the Feed's thread roots ask the
// reply's `e`-tag hint and the parent author's write relays when the user's relays don't have it, as Android and the
// iPhone do. Case from 2026-11-22: a nostr.wine reply whose root is only on relay.ditto.pub. Test keys only; no real
// relay is reached (pool.subscribeEose and querySync are stubbed).
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { generateSecretKey, finalizeEvent, getPublicKey } from "nostr-tools/pure"
import { extraRelays, fetchFromParentRelays, MAX_EXTRA, parentRefs, reachableHint } from "../src/net/parent-hints.js"
import { syncThread } from "../src/net/thread.js"
import { pool } from "../src/net/pool.js"

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
const { forgetRoots, rootFetcher } = await import("../src/components/FeedRows.jsx")

const now = Math.floor(Date.now() / 1000)
const author = generateSecretKey(), replier = generateSecretKey()
const authorPk = getPublicKey(author)
const HINT = "wss://relay.ditto.pub/", OUTBOX = "wss://outbox.example"
const root = finalizeEvent({ kind: 1, created_at: now - 600, tags: [], content: "the root, only on its author's relay" }, author)
const reply = finalizeEvent({ kind: 1, created_at: now - 500, tags: [["e", root.id, HINT, "root", authorPk], ["p", authorPk, HINT]], content: "a reply" }, replier)
const bare = finalizeEvent({ kind: 1, created_at: now - 400, tags: [["e", root.id, "", "root"], ["p", authorPk]], content: "no hint, no author slot" }, replier)

test("the e-tag hint and the author's write relays are added, ours and mentions are not", () => {
  const refs = parentRefs([reply], [root.id])
  assert.deepEqual(refs, { hints: [HINT], authors: [authorPk] })
  const outbox = new Map([[authorPk, ["wss://relay.ditto.pub", OUTBOX]]])
  assert.deepEqual(extraRelays(refs, outbox, ["wss://nostr.wine"]), [HINT, OUTBOX])
  assert.deepEqual(extraRelays(refs, outbox, ["wss://RELAY.ditto.pub", OUTBOX + "/"]), [])
  const mention = { tags: [["e", root.id, "wss://mention.example", "mention"]] }
  assert.deepEqual(parentRefs([mention], [root.id]), { hints: [], authors: [] })
  // No author slot: the reply's p target.
  assert.deepEqual(parentRefs([bare], [root.id]), { hints: [], authors: [authorPk] })
  const many = { hints: Array.from({ length: 20 }, (_, i) => `wss://r${i}.example`), authors: [] }
  assert.equal(extraRelays(many, new Map()).length, MAX_EXTRA)
})

test("fetchFromParentRelays asks only the extra relays, and only when there are any", async () => {
  const asked = []
  const query = async (urls, f) => { asked.push(urls); return urls.includes(HINT) ? [root].filter(e => f.ids.includes(e.id)) : [] }
  const outboxes = async () => new Map([[authorPk, [OUTBOX]]])
  const got = await fetchFromParentRelays({ vault: {}, events: [reply], ids: [root.id], relays: ["wss://nostr.wine"], outboxes, query })
  assert.equal(got.get(root.id)?.id, root.id)
  assert.deepEqual(asked, [[HINT, OUTBOX]])
  const none = await fetchFromParentRelays({ vault: {}, events: [{ tags: [] }], ids: [root.id], relays: [], outboxes, query })
  assert.equal(none.size, 0)
  assert.equal(asked.length, 1, "nothing to add, nothing asked")
})

test("the thread screen's sync finds a root that only the hinted relay has", async t => {
  const store = [reply]
  const vault = { feed: { query: async f => store.filter(e => !f.ids || f.ids.includes(e.id)), event: async ev => { store.push(ev); return { ok: true } } } }
  t.mock.method(pool, "subscribeEose", (_urls, _f, p) => { queueMicrotask(() => p.onclose?.(["closed automatically on eose"])); return { close() {} } })
  const asked = []
  t.mock.method(pool, "querySync", async (urls, f) => {
    asked.push(urls)
    if (f.kinds?.includes(10002)) return []
    return urls.includes(HINT) ? [root].filter(e => f.ids?.includes(e.id)) : []
  })
  const synced = await syncThread(vault, reply.id, ["wss://nostr.wine"], { settle: 10, maxWait: 200 })
  await synced.done
  assert.equal(synced.rootId, root.id)
  assert.ok(store.some(e => e.id === root.id), "the root was stored from the hinted relay")
  assert.ok(asked.some(u => u.includes(HINT)))
})

test("the Feed's thread roots ask the replies' hints for a root the user's relays don't have", async t => {
  forgetRoots()
  const vault = { feed: { query: async () => [] }, outbox: { query: async () => [] } }
  t.mock.method(pool, "querySync", async () => [])
  const calls = []
  const parentRelays = async ({ events, ids }) => { calls.push({ events, ids }); return new Map([[root.id, root]]) }
  const found = await rootFetcher(vault, ["wss://nostr.wine"], { names: async () => {}, parentRelays })([root.id], [reply])
  assert.equal(found.get(root.id)?.id, root.id)
  assert.deepEqual(calls.map(c => c.ids), [[root.id]])
  assert.equal(calls[0].events[0].id, reply.id)
})

// 2026-11-26: an iPhone kind 1111 reply in a Mostr thread. Its parent `e` hint was the poster's own phone relay; only
// the `E` root named relay.ditto.pub, and both authors sit in the fourth slot.
test("a comment's E root hint is read, a loopback hint is dropped, fourth-slot authors count", () => {
  const parentPk = "b".repeat(64), parentId = "c".repeat(64)
  const comment = { kind: 1111, tags: [["E", root.id, HINT, authorPk], ["K", "1"], ["P", authorPk],
    ["e", parentId, "wss://127.0.0.1:3355", parentPk], ["k", "1111"], ["p", parentPk]] }
  assert.deepEqual(parentRefs([comment], [root.id, parentId]), { hints: [HINT], authors: [authorPk, parentPk] })
  for (const lan of ["ws://127.0.0.1:3355", "wss://localhost:4869", "ws://192.168.1.20:3355", "wss://box.local", "ws://[::1]:3355", "wss://10.0.0.4", "wss://nas"])
    assert.equal(reachableHint(lan), null, lan)
  assert.equal(reachableHint("wss://relay.mostr.pub"), "wss://relay.mostr.pub")
  // A NIP-10 marker is never an author.
  assert.equal(parentRefs([{ tags: [["e", root.id, "", "reply"]] }], [root.id]).authors.length, 0)
})
