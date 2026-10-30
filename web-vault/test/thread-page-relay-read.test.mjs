// The public post page's relay read (thread-page/relay-read.js): it ends at the post's first good copy, or once every
// relay answered, or once most did plus a short grace, never at the slowest relay's timeout. And the page's reads pass
// those limits (fetch.js). A fake subscribe stands in for the pool.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, finalizeEvent } from "nostr-tools/pure"
import { relayRead } from "../thread-page/relay-read.js"
import { loadThread, REPLY_WAIT_MS, PROFILE_WAIT_MS } from "../thread-page/fetch.js"

// url -> { after: ms, events: [], eose: true | false (false: never answers) }
function fakeRelays(plan) {
  const closed = []
  const subscribe = (url, filter, h) => {
    const p = plan[url] ?? { after: 0, events: [], eose: true }
    const t = setTimeout(() => { for (const ev of p.events) h.onevent(ev); if (p.eose) h.oneose() }, p.after)
    return { close: () => { clearTimeout(t); closed.push(url) } }
  }
  return { subscribe, closed }
}
const sk = generateSecretKey()
const note = finalizeEvent({ kind: 1, created_at: 1, tags: [], content: "hi" }, sk)

test("the post's first good copy ends the read; a relay that never answers holds nothing", async () => {
  const { subscribe, closed } = fakeRelays({ "wss://fast": { after: 20, events: [note], eose: true }, "wss://dead": { after: 0, events: [], eose: false }, "wss://slow": { after: 2000, events: [note], eose: true } })
  const t0 = Date.now()
  const evs = await relayRead(subscribe, ["wss://fast", "wss://dead", "wss://slow"], { ids: [note.id] }, { maxWait: 3500, first: ev => ev.id === note.id })
  assert.ok(Date.now() - t0 < 300, `took ${Date.now() - t0} ms`)
  assert.deepEqual(evs.map(e => e.id), [note.id])
  assert.deepEqual(closed.sort(), ["wss://dead", "wss://fast", "wss://slow"], "every subscription closed")
})

test("without `first`: ends when all relays answered, or most plus the grace, or maxWait", async () => {
  let r = fakeRelays({ "wss://a": { after: 10, events: [note], eose: true }, "wss://b": { after: 30, events: [], eose: true } })
  let t0 = Date.now()
  assert.equal((await relayRead(r.subscribe, ["wss://a", "wss://b"], {}, { maxWait: 3000 })).length, 1)
  assert.ok(Date.now() - t0 < 200, "all answered")
  r = fakeRelays({ "wss://a": { after: 10, events: [], eose: true }, "wss://b": { after: 10, events: [], eose: true }, "wss://dead": { after: 0, events: [], eose: false } })
  t0 = Date.now()
  await relayRead(r.subscribe, ["wss://a", "wss://b", "wss://dead"], {}, { maxWait: 3000, graceMs: 100 })
  const took = Date.now() - t0
  assert.ok(took >= 100 && took < 400, `most answered + grace: ${took} ms`)
  r = fakeRelays({ "wss://dead1": { eose: false, events: [], after: 0 }, "wss://dead2": { eose: false, events: [], after: 0 } })
  t0 = Date.now()
  await relayRead(r.subscribe, ["wss://dead1", "wss://dead2"], {}, { maxWait: 150 })
  assert.ok(Date.now() - t0 >= 140, "nobody answered: the cap")
  assert.deepEqual(await relayRead(r.subscribe, [], {}), [])
})

test("a relay that closes or throws counts as answered with nothing", async () => {
  const subscribe = (url, f, h) => { if (url === "wss://boom") throw new Error("refused"); setTimeout(() => (url === "wss://closes" ? h.onclose(["blocked"]) : h.oneose()), 5); return { close() {} } }
  const t0 = Date.now()
  await relayRead(subscribe, ["wss://boom", "wss://closes", "wss://ok"], {}, { maxWait: 3000 })
  assert.ok(Date.now() - t0 < 200)
})

test("the page's reads say how long they may wait: the post ends at its first copy, the rest are capped", async () => {
  const seen = []
  const query = async (relays, filter, opts = {}) => { seen.push([Object.keys(filter).sort().join(","), opts.maxWait ?? null, typeof opts.first]); return filter.ids ? [note] : [] }
  await loadThread({ id: note.id, relays: [] }, query)
  assert.deepEqual(seen[0], ["ids", null, "function"], "the post: first good copy")
  assert.ok(seen.some(([k, w]) => k.includes("#e") && w === REPLY_WAIT_MS), "replies capped")
  assert.ok(seen.some(([k, w]) => k === "authors,kinds" && w === PROFILE_WAIT_MS), "names capped")
})
