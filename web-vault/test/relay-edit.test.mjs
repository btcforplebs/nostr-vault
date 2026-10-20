// Settings › Relays: a typed address read as the iPhone reads it, the list's rows and tags round-tripping, an edit
// starting from the newest copy anywhere, and a publish that comes after the old copy. Throwaway keys, fake stores
// and a stubbed pool: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"
import { latestList, publishList, relayUrl, relayUrlError, relayEntries, addRelay, setJob, removeRelay, relayTags, relayProblem } from "../src/net/list-edit.js"

const SK = generateSecretKey(), ME = getPublicKey(SK)
const OTHER_SK = generateSecretKey()
const list = (sk, created_at, tags) => finalizeEvent({ kind: 10002, content: "", tags, created_at }, sk)

function fakeCtx({ outbox = [] } = {}) {
  const stored = []
  return {
    stored,
    session: { pubkey: ME },
    account: { relays: { read: ["wss://r.example"], write: ["wss://w.example"] } },
    signer: { signEvent: async t => finalizeEvent(t, SK) },
    vault: { outbox: { query: async () => outbox, event: async ev => { stored.push(ev); return { ok: true } } } },
  }
}

test("a typed relay gets wss://, loses its trailing slash; other schemes, spaces and loopback are refused", () => {
  assert.equal(relayUrl("relay.example.com"), "wss://relay.example.com")
  assert.equal(relayUrl("  wss://Relay.Example.com/  "), "wss://relay.example.com")
  assert.equal(relayUrl("ws://relay.example.com:7777/sub/"), "ws://relay.example.com:7777/sub")
  for (const bad of ["", "   ", "https://relay.example.com", "relay example.com", "wss://localhost:3355", "ws://127.0.0.1", "wss://[::1]", "wss://u:p@relay.example.com", "wss://"])
    assert.equal(relayUrl(bad), null, bad)
  for (const own of ["localhost:3355", "ws://127.0.0.1:4869", "wss://[::1]"]) assert.match(relayUrlError(own), /this computer/, own)
  for (const bad of ["https://relay.example.com", "relay example.com"]) assert.match(relayUrlError(bad), /isn't a relay address/, bad)
})

test("rows merge marks per address and keep dead hosts; tags round-trip, other tags kept", () => {
  const ev = list(SK, 10, [["r", "wss://a.example/"], ["r", "wss://b.example", "read"], ["r", "wss://c.example", "write"], ["r", "wss://nos.lol"], ["r", "https://x"], ["client", "x"]])
  const rows = relayEntries(ev)
  assert.deepEqual(rows, [
    { url: "wss://a.example", read: true, write: true },
    { url: "wss://b.example", read: true, write: false },
    { url: "wss://c.example", read: false, write: true },
    { url: "wss://nos.lol", read: true, write: true },
  ])
  assert.deepEqual(relayTags(rows, ev), [["client", "x"], ["r", "wss://a.example"], ["r", "wss://b.example", "read"], ["r", "wss://c.example", "write"], ["r", "wss://nos.lol"]])
  // A relay listed once as read and once as write is one row with both.
  assert.deepEqual(relayEntries(list(SK, 10, [["r", "wss://a.example", "read"], ["r", "wss://a.example", "write"]])), [{ url: "wss://a.example", read: true, write: true }])
  assert.deepEqual(relayEntries(undefined), [])
})

test("add starts with read and write; a relay's last job can't be switched off; remove takes it out", () => {
  let rows = addRelay([], "wss://a.example")
  assert.deepEqual(rows, [{ url: "wss://a.example", read: true, write: true }])
  rows = setJob(rows, "wss://a.example", "read", false)
  assert.deepEqual(rows, [{ url: "wss://a.example", read: false, write: true }])
  assert.deepEqual(setJob(rows, "wss://a.example", "write", false), rows)
  assert.deepEqual(addRelay(rows, "wss://a.example"), [{ url: "wss://a.example", read: true, write: true }])
  assert.deepEqual(removeRelay(rows, "wss://a.example"), [])
})

test("the list needs a read relay and a write relay", () => {
  assert.match(relayProblem([]), /read/)
  assert.match(relayProblem([{ url: "a", read: false, write: true }]), /read/)
  assert.match(relayProblem([{ url: "a", read: true, write: false }]), /write/)
  assert.equal(relayProblem([{ url: "a", read: true, write: false }, { url: "b", read: false, write: true }]), "")
})

test("an edit starts from the newest copy: the relays' newer one wins and is kept in Haven", async () => {
  const old = list(SK, 100, [["r", "wss://old.example"]])
  const fresh = list(SK, 200, [["r", "wss://new.example"]])
  const ctx = fakeCtx({ outbox: [old] })
  let asked
  const r = await latestList(ctx, 10002, { online: true, query: async (relays, filter) => { asked = { relays, filter }; return [fresh, list(OTHER_SK, 999, [])] } })
  assert.equal(r.event.id, fresh.id)
  assert.equal(r.checked, true)
  assert.deepEqual(asked.filter, { kinds: [10002], authors: [ME] })
  assert.ok(asked.relays.includes("wss://r.example") && asked.relays.includes("wss://w.example") && asked.relays.includes("wss://purplepag.es"))
  assert.deepEqual(ctx.stored.map(e => e.id), [fresh.id])
})

test("Haven's copy stands when it's newer or the relays have none; offline it isn't checked", async () => {
  const mine = list(SK, 300, [["r", "wss://mine.example"]])
  const ctx = fakeCtx({ outbox: [mine] })
  assert.equal((await latestList(ctx, 10002, { online: true, query: async () => [list(SK, 100, [])] })).event.id, mine.id)
  assert.equal((await latestList(ctx, 10002, { online: true, query: async () => { throw new Error("down") } })).event.id, mine.id)
  const off = await latestList(ctx, 10002, { online: false, query: () => assert.fail("asked offline") })
  assert.deepEqual([off.event.id, off.checked], [mine.id, false])
  assert.deepEqual(ctx.stored, [])
})

test("publishing signs after the old copy, keeps its content, goes to the new write relays and lands in Haven", async t => {
  const previous = list(SK, Math.floor(Date.now() / 1000) + 600, [["r", "wss://old.example"]]) // a clock ahead of ours
  const ctx = fakeCtx()
  let sentTo
  t.mock.method(pool, "publish", (urls, ev) => { sentTo = urls; return urls.map(u => u === "wss://dead.example" ? Promise.reject(new Error("no")) : Promise.resolve("")) })
  const tags = [["r", "wss://new.example"]]
  const { event, relays } = await publishList(ctx, 10002, tags, { previous, also: ["wss://new.example", "wss://dead.example"] })
  assert.equal(event.created_at, previous.created_at + 1)
  assert.deepEqual(event.tags, tags)
  assert.ok(sentTo.includes("wss://new.example") && sentTo.includes("wss://w.example") && sentTo.includes("wss://purplepag.es"))
  assert.equal(relays.find(r => r.url === "wss://dead.example").ok, false)
  assert.deepEqual(ctx.stored.map(e => e.id), [event.id])
})

test("no relay took it: an error, and Haven keeps the old copy", async t => {
  const ctx = fakeCtx()
  t.mock.method(pool, "publish", urls => urls.map(() => Promise.reject(new Error("refused"))))
  await assert.rejects(publishList(ctx, 10002, [["r", "wss://a.example"]]), /No relay took it/)
  assert.deepEqual(ctx.stored, [])
})

test("a signer that signs as someone else is refused", async t => {
  const ctx = { ...fakeCtx(), signer: { signEvent: async tpl => finalizeEvent(tpl, OTHER_SK) } }
  t.mock.method(pool, "publish", () => assert.fail("published"))
  await assert.rejects(publishList(ctx, 10002, [["r", "wss://a.example"]]), /different account/)
})

test("plain relay lists (10050, 10006): relay tags in order, each once, other tags kept", async () => {
  const { urlEntries, urlTags, addUrl, removeUrl } = await import("../src/net/list-edit.js")
  const ev = finalizeEvent({ kind: 10050, content: "", created_at: 5, tags: [["relay", "wss://a.example/"], ["relay", "wss://a.example"], ["relay", "https://x"], ["relay", "wss://b.example"], ["alt", "x"]] }, SK)
  const urls = urlEntries(ev)
  assert.deepEqual(urls, ["wss://a.example", "wss://b.example"])
  assert.deepEqual(urlTags(removeUrl(addUrl(urls, "wss://c.example"), "wss://a.example"), ev), [["alt", "x"], ["relay", "wss://b.example"], ["relay", "wss://c.example"]])
  assert.deepEqual(urlEntries(undefined), [])
})
