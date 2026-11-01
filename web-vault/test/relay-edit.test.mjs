// Settings › Relays: a typed address read as the iPhone reads it, the list's rows and tags round-tripping, an edit
// starting from the newest copy anywhere, and a publish that comes after the old copy. Throwaway keys, fake stores
// and a stubbed pool: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"
import { askRelay } from "../src/net/follows.js"
import { latestList, publishList, NO_RELAY_LIST, listKnown, ListNotSaved, relayUrl, relayUrlError, relayEntries, addRelay, setJob, removeRelay, relayTags, relayProblem } from "../src/net/list-edit.js"

const SK = generateSecretKey(), ME = getPublicKey(SK)
const OTHER_SK = generateSecretKey()
const list = (sk, created_at, tags) => finalizeEvent({ kind: 10002, content: "", tags, created_at }, sk)

function fakeCtx({ outbox = [] } = {}) {
  const stored = []
  return {
    stored,
    session: { pubkey: ME },
    account: { relays: { read: ["wss://r.example"], write: ["wss://w.example"], listed: ["wss://r.example", "wss://w.example"] } },
    signer: { signEvent: async t => finalizeEvent(t, SK) },
    vault: { outbox: { query: async () => outbox, event: async ev => { stored.push(ev); return { ok: true } } } },
  }
}

/** A fake relay answer: events with an EOSE. */
const says = events => ({ events, answered: true })
const down = async () => ({ events: [], answered: false })

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
  const asked = []
  const r = await latestList(ctx, 10002, { online: true, ask: async (relay, filter) => { asked.push({ relays: [relay], filter }); return says([fresh, list(OTHER_SK, 999, [])]) } })
  assert.equal(r.event.id, fresh.id)
  assert.equal(r.checked, true)
  assert.deepEqual(asked[0].filter, { kinds: [10002], authors: [ME] })
  assert.ok(asked.every(a => a.relays.length === 1), "each relay is asked on its own")
  const all = asked.flatMap(a => a.relays)
  assert.ok(all.includes("wss://r.example") && all.includes("wss://w.example") && all.includes("wss://purplepag.es"))
  assert.deepEqual(ctx.stored.map(e => e.id), [fresh.id])
})

test("the page can draw Haven's copy at once and each newer copy as it lands; the answer waits for every relay", async () => {
  const mine = list(SK, 100, [["r", "wss://mine.example"]])
  const newer = list(SK, 200, [["r", "wss://newer.example"]])
  const ctx = fakeCtx({ outbox: [mine] })
  let release
  const slow = new Promise(r => { release = r })
  const seen = []
  let done = false
  const p = latestList(ctx, 10002, { online: true, on: x => seen.push(x.event.created_at), ask: async relay => says(relay === "wss://w.example" ? (await slow, [list(SK, 150, [])]) : relay === "wss://r.example" ? [newer] : []) })
  p.then(() => { done = true })
  await new Promise(r => setTimeout(r, 10))
  assert.deepEqual(seen, [100, 200], "Haven's copy, then the newer one, before the slow relay answers")
  assert.equal(done, false, "not checked until every relay has answered")
  release()
  const r = await p
  assert.deepEqual([r.event.id, r.checked], [newer.id, true])
  assert.deepEqual(seen, [100, 200], "an older copy from the slow relay doesn't redraw")
})

test("Haven's copy stands when it's newer or the relays have none; offline it isn't checked", async () => {
  const mine = list(SK, 300, [["r", "wss://mine.example"]])
  const ctx = fakeCtx({ outbox: [mine] })
  assert.equal((await latestList(ctx, 10002, { online: true, ask: async () => says([list(SK, 100, [])]) })).event.id, mine.id)
  const gone = await latestList(ctx, 10002, { online: true, ask: async () => { throw new Error("down") } })
  assert.deepEqual([gone.event.id, gone.checked], [mine.id, false], "every relay failed: Haven's copy shown, not checked")
  const off = await latestList(ctx, 10002, { online: false, ask: () => assert.fail("asked offline") })
  assert.deepEqual([off.event.id, off.checked], [mine.id, false])
  assert.deepEqual(ctx.stored, [])
})

/** A Save-time read that finds the same copy the page had. */
const same = event => async () => ({ event, checked: true })

test("no 10002 yet: a list is unknown, not decided by the defaults, and Save refuses with the reason", async t => {
  const realList = finalizeEvent({ kind: 10063, content: "", created_at: 100, tags: [["server", "https://mine.example"]] }, SK)
  // The account's relays are the defaults (relayLists(undefined)): they answer "none", the real list is elsewhere.
  const ctx = { ...fakeCtx(), account: { relays: { read: ["wss://default.example"], write: ["wss://default.example"], listed: [] } } }
  const r = await latestList(ctx, 10063, { online: true, ask: async () => says([]) })
  assert.deepEqual([r.event, r.checked, r.asked, r.noRelayList], [undefined, false, 0, true])
  // A copy found on a default relay doesn't make it known either.
  const found = await latestList(ctx, 10063, { online: true, ask: async () => says([realList]) })
  assert.deepEqual([found.event?.id, found.checked, found.noRelayList], [realList.id, false, true])
  // An account context without `listed` at all is the same: unknown.
  const bare = { ...fakeCtx(), account: { relays: { read: ["wss://default.example"], write: ["wss://default.example"] } } }
  assert.equal((await latestList(bare, 10050, { online: true, ask: async () => says([]) })).checked, false)
  // The 10002 itself is still looked for on the relays the account has (where it is found when there is none yet).
  const relays = await latestList(ctx, 10002, { online: true, ask: async () => says([]) })
  assert.deepEqual([relays.checked, relays.noRelayList], [true, false])
  // Save refuses with the reason, before signing.
  t.mock.method(pool, "publish", () => assert.fail("published"))
  const e = await publishList(ctx, 10063, [["server", "https://x.example"]], { latest: async () => r }).catch(x => x)
  assert.ok(e instanceof ListNotSaved && e.checked === false && /no relay list yet/.test(e.message), String(e))
  assert.match(NO_RELAY_LIST, /Settings › Relays/)
})

test("the list pages say why when there's no relay list", async () => {
  const { readFileSync } = await import("node:fs")
  for (const f of ["MediaServersPage.jsx", "RelayUrlList.jsx"])
    assert.match(readFileSync(new URL(`../src/screens/${f}`, import.meta.url), "utf8"), /loaded\.noRelayList && <p [^>]*>\{NO_RELAY_LIST\}/, f)
})

test("only the account's own relays count: a copy from one of them, or most answering; every one to say there is none", async () => {
  const mine = list(SK, 100, [["r", "wss://mine.example"]])
  const ctx = fakeCtx() // own relays: r.example and w.example
  const by = map => async relay => (map[relay] ?? down)()
  const none = async () => says([])
  // Every relay failed and there's no copy: unknown, not "you have none".
  assert.deepEqual(await latestList(ctx, 10002, { online: true, ask: down }), { event: undefined, checked: false, asked: 2, answered: 0, noRelayList: false })
  // The defaults and purplepag.es all say "none" but the user's relays are down: unknown (Tron #1456 2).
  const publicOnly = await latestList(ctx, 10002, { online: true, ask: async relay => relay.endsWith(".example") ? down() : none() })
  assert.deepEqual([publicOnly.event, publicOnly.checked, publicOnly.answered], [undefined, false, 0])
  // One of the two own relays says "none": still unknown; both: known to have none.
  const one = await latestList(ctx, 10002, { online: true, ask: by({ "wss://r.example": none }) })
  assert.deepEqual([one.event, one.checked, one.answered], [undefined, false, 1])
  const both = await latestList(ctx, 10002, { online: true, ask: by({ "wss://r.example": none, "wss://w.example": none }) })
  assert.deepEqual([both.event, both.checked, both.answered], [undefined, true, 2])
  // One own relay sent a copy: known, that copy.
  const found = await latestList(ctx, 10002, { online: true, ask: by({ "wss://w.example": async () => says([mine]) }) })
  assert.deepEqual([found.event.id, found.checked], [mine.id, true])
  // A copy from a default relay only, the own relays down: shown, not known.
  const elsewhere = await latestList(ctx, 10002, { online: true, ask: async relay => relay.endsWith(".example") ? down() : says([mine]) })
  assert.deepEqual([elsewhere.event.id, elsewhere.checked], [mine.id, false])
  // Haven's copy and one own relay of two answering empty: not most of them, so not known (Tron #1456 2).
  const local = await latestList(fakeCtx({ outbox: [mine] }), 10002, { online: true, ask: by({ "wss://r.example": none }) })
  assert.deepEqual([local.event.id, local.checked], [mine.id, false])
  assert.deepEqual([listKnown({ asked: 0, answered: 0, found: false }), listKnown({ asked: 3, answered: 2, found: true }), listKnown({ asked: 3, answered: 1, found: true, netFound: true }), listKnown({ asked: 4, answered: 2, found: true }), listKnown({ asked: 3, answered: 2, found: false }), listKnown({ asked: 3, answered: 3, found: false })], [false, true, true, false, false, true])
})

test("a copy dated far ahead is skipped, so a bad clock can't pin the list", async () => {
  const at = 1_000_000
  const ahead = list(SK, at + 3600, [["r", "wss://future.example"]])
  const now = list(SK, at - 10, [["r", "wss://now.example"]])
  const r = await latestList(fakeCtx({ outbox: [ahead] }), 10002, { online: true, at, ask: async () => says([ahead, now]) })
  assert.equal(r.event.id, now.id)
})

test("real pool, no mocks: relays that refuse the connection are not answers (Tron #1456 1)", async () => {
  const ctx = fakeCtx()
  ctx.account.relays = { read: ["ws://127.0.0.1:1"], write: ["ws://127.0.0.1:2"] }
  const quick = (url, filter) => askRelay(url, filter, 1500)
  const r = await latestList(ctx, 10063, { online: true, ask: quick })
  assert.deepEqual([r.event, r.checked, r.answered], [undefined, false, 0])
  assert.deepEqual(await askRelay("ws://127.0.0.1:1", { kinds: [10063] }, 1500), { events: [], answered: false })
})

test("Save reads the list again: refuses when relays don't answer, or when it changed since the page opened", async t => {
  const previous = list(SK, 100, [["r", "wss://old.example"]])
  const elsewhere = list(SK, 200, [["r", "wss://other-app.example"]])
  const ctx = fakeCtx()
  t.mock.method(pool, "publish", () => assert.fail("published"))
  const signed = []
  ctx.signer = { signEvent: async tpl => { signed.push(tpl); return finalizeEvent(tpl, SK) } }
  const unknown = await publishList(ctx, 10002, [["r", "wss://a.example"]], { previous, latest: async () => ({ event: previous, checked: false }) }).catch(e => e)
  assert.ok(unknown instanceof ListNotSaved && unknown.checked === false && /didn't answer/.test(unknown.message))
  const newer = await publishList(ctx, 10002, [["r", "wss://a.example"]], { previous, latest: same(elsewhere) }).catch(e => e)
  assert.ok(newer instanceof ListNotSaved && newer.checked === true && /changed in another app/.test(newer.message))
  assert.equal(newer.latest.id, elsewhere.id, "the page gets the newer copy to edit")
  // A page that saw no list, but one exists now: refused, not signed over it.
  const appeared = await publishList(ctx, 10002, [["r", "wss://a.example"]], { latest: same(elsewhere) }).catch(e => e)
  assert.ok(appeared instanceof ListNotSaved && appeared.latest.id === elsewhere.id)
  assert.deepEqual(signed, [], "nothing was signed")
  // With no `latest` given it reads through latestList and the real askRelay (the own relays refuse here): refused.
  ctx.account.relays = { read: ["ws://127.0.0.1:1"], write: ["ws://127.0.0.1:2"] }
  const real = await publishList(ctx, 10002, [], { previous }).catch(e => e)
  assert.ok(real instanceof ListNotSaved && real.checked === false, String(real))
  assert.deepEqual(signed, [], "nothing was signed")
})

test("publishing signs after the old copy, keeps its content, goes to the new write relays and lands in Haven", async t => {
  const previous = list(SK, Math.floor(Date.now() / 1000) + 600, [["r", "wss://old.example"]]) // a clock ahead of ours
  const ctx = fakeCtx()
  let sentTo
  t.mock.method(pool, "publish", (urls, ev) => { sentTo = urls; return urls.map(u => u === "wss://dead.example" ? Promise.reject(new Error("no")) : Promise.resolve("")) })
  const tags = [["r", "wss://new.example"]]
  const { event, relays } = await publishList(ctx, 10002, tags, { previous, also: ["wss://new.example", "wss://dead.example"], latest: same(previous) })
  assert.equal(event.created_at, previous.created_at + 1)
  assert.deepEqual(event.tags, tags)
  assert.ok(sentTo.includes("wss://new.example") && sentTo.includes("wss://w.example") && sentTo.includes("wss://purplepag.es"))
  assert.equal(relays.find(r => r.url === "wss://dead.example").ok, false)
  assert.deepEqual(ctx.stored.map(e => e.id), [event.id])
})

test("no relay took it: an error, and Haven keeps the old copy", async t => {
  const ctx = fakeCtx()
  t.mock.method(pool, "publish", urls => urls.map(() => Promise.reject(new Error("refused"))))
  await assert.rejects(publishList(ctx, 10002, [["r", "wss://a.example"]], { latest: same(undefined) }), /No relay took it/)
  assert.deepEqual(ctx.stored, [])
})

test("a signer that signs as someone else is refused", async t => {
  const ctx = { ...fakeCtx(), signer: { signEvent: async tpl => finalizeEvent(tpl, OTHER_SK) } }
  t.mock.method(pool, "publish", () => assert.fail("published"))
  await assert.rejects(publishList(ctx, 10002, [["r", "wss://a.example"]], { latest: same(undefined) }), /different account/)
})

test("plain relay lists (10050, 10006): relay tags in order, each once, other tags kept", async () => {
  const { urlEntries, urlTags, addUrl, removeUrl } = await import("../src/net/list-edit.js")
  const ev = finalizeEvent({ kind: 10050, content: "", created_at: 5, tags: [["relay", "wss://a.example/"], ["relay", "wss://a.example"], ["relay", "https://x"], ["relay", "wss://b.example"], ["alt", "x"]] }, SK)
  const urls = urlEntries(ev)
  assert.deepEqual(urls, ["wss://a.example", "wss://b.example"])
  assert.deepEqual(urlTags(removeUrl(addUrl(urls, "wss://c.example"), "wss://a.example"), ev), [["alt", "x"], ["relay", "wss://b.example"], ["relay", "wss://c.example"]])
  assert.deepEqual(urlEntries(undefined), [])
})

// Settings › Relays: the three lists load side by side, draw from the first copy, and can't be edited until every
// relay has been asked (an edit must start from the newest copy). Never Connect uses the phone's words.
test("the Relays page draws early, locks editing while it checks, and loads its three lists at once", async () => {
  const { readFileSync } = await import("node:fs")
  const page = readFileSync(new URL("../src/screens/RelaysPage.jsx", import.meta.url), "utf8")
  const list = readFileSync(new URL("../src/screens/RelayUrlList.jsx", import.meta.url), "utf8")
  assert.match(page, /latestList\(ctx, 10002, \{ on: early \}\)/)
  assert.match(list, /latestList\(ctx, kind, \{ on: /)
  assert.match(page, /const locked = readOnly \|\| busy \|\| !!loaded\?\.pending/)
  for (const job of ["Read", "Write"]) assert.match(page, new RegExp(`label="${job}" disabled=\\{locked\\}`))
  assert.match(list, /const locked = busy \|\| !!loaded\?\.pending/)
  // The DMs and Never Connect lists aren't behind the main list's skeleton.
  assert.ok(page.indexOf("<RelayUrlList") > page.indexOf("</>}"), "RelayUrlList renders outside the loaded gate")
  assert.ok(!/if \(!loaded\) return/.test(page))
  assert.match(page, /title="Never Connect" removeLabel="Unblock"/)
})
