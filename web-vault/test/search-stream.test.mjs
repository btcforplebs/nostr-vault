// Global search (startSearch): this browser's Haven and every search relay at once, one status each, merged and
// published as they answer, never waited on past the cap.
import test from "node:test"
import assert from "node:assert/strict"
import { startSearch, shortReason, shapeResults, forgetAnswers } from "../src/net/search.js"

const pk = c => c.repeat(64)
const note = (id, author, at = 100) => ({ id: id.repeat(64), kind: 1, pubkey: pk(author), created_at: at, content: "bitcoin", tags: [] })
const person = (author, at = 100) => ({ id: `p${author}${at}`, kind: 0, pubkey: pk(author), created_at: at, content: "{}", tags: [] })
const tick = () => new Promise(r => setTimeout(r, 0))

/** A fake pool: each REQ is kept so the test answers it; and manual timers. */
function rig({ feed = [], own = [] } = {}) {
  const reqs = [], timers = new Map(), updates = []
  let n = 0
  const vault = {
    feed: { query: async () => feed },
    outbox: { query: async () => own },
  }
  return {
    reqs, updates, vault,
    opts: {
      vault, me: pk("m"), relays: ["wss://a.example", "wss://b.example"], onUpdate: u => updates.push(u),
      subscribe: (urls, filter, params) => { const r = { url: urls[0], filter, params, closed: false }; reqs.push(r); return { close: () => { r.closed = true } } },
      setTimer: (fn, ms) => { const id = ++n; timers.set(id, { fn, ms }); return id },
      clearTimer: id => timers.delete(id),
    },
    flush: () => { for (const [id, t] of [...timers]) if (t.ms < 1000) { timers.delete(id); t.fn() } },
    cap: () => { for (const [id, t] of [...timers]) if (t.ms >= 1000) { timers.delete(id); t.fn() } },
    last: () => updates.at(-1),
  }
}

test("every source starts searching at once, each kind its own REQ, and the first update comes before any answer", async () => {
  forgetAnswers()
  const r = rig()
  startSearch("bitcoin", r.opts)
  assert.equal(r.reqs.length, 4)
  assert.deepEqual(r.reqs.map(q => q.filter.kinds[0]).sort(), [0, 0, 1, 1])
  await Promise.resolve()
  const first = r.updates[0]
  assert.deepEqual(first.sources.map(s => s.label), ["This browser", "a.example", "b.example"])
  assert.ok(first.sources.every(s => s.state === "searching"))
  assert.equal(first.finished, false)
})

test("Haven's hits show before any relay answers, own notes included", async () => {
  forgetAnswers()
  const r = rig({ feed: [note("a", "f"), person("f")], own: [note("b", "m", 200)] })
  startSearch("bitcoin", r.opts)
  await tick()
  const u = r.last()
  assert.deepEqual(u.notes.map(n => n.id), ["b".repeat(64), "a".repeat(64)]) // newest first
  assert.deepEqual(u.people.map(p => p.pubkey), [pk("f")])
  assert.deepEqual(u.sources[0], { id: "haven", label: "This browser", state: "found", count: 3, reason: undefined })
  assert.equal(u.finished, false)
})

test("relay events merge by id and newest kind 0, count per source, and finish when every REQ closes", async () => {
  forgetAnswers()
  const r = rig({ feed: [note("a", "f")] })
  startSearch("bitcoin", r.opts)
  await tick()
  const [a1, a0, b1, b0] = r.reqs
  a1.params.onevent(note("a", "f")); a1.params.onevent(note("c", "s"))
  a0.params.onevent(person("s", 1)); a0.params.onevent(person("s", 5))
  r.flush()
  assert.equal(r.last().sources[1].count, 3) // c, a, person s
  assert.equal(r.last().sources[1].state, "searching")
  assert.equal(r.last().notes.length, 2)
  assert.equal(r.last().people[0].created_at, 5)
  a1.params.onclose(["closed automatically on eose"]); a0.params.onclose(["closed automatically on eose"])
  assert.equal(r.last().sources[1].state, "found")
  b1.params.onclose(["CLOSED: we support only kind:0 search queries"]); b0.params.onclose(["closed automatically on eose"])
  const end = r.last()
  assert.deepEqual([end.sources[2].state, end.sources[2].count], ["found", 0], "a people-only service with no match is 0 found, not a failure")
  assert.equal(end.finished, true)
})

test("a relay that answers neither REQ says why; the cap ends a silent one as timed out", async () => {
  forgetAnswers()
  const r = rig()
  startSearch("bitcoin", r.opts)
  await tick()
  const [a1, a0] = r.reqs
  a1.params.onclose(["relay connection failed"]); a0.params.onclose(["relay connection failed"])
  assert.deepEqual([r.last().sources[1].state, r.last().sources[1].reason], ["failed", "can't connect"])
  r.cap()
  const end = r.last()
  assert.deepEqual([end.sources[2].state, end.sources[2].reason], ["failed", "timed out"])
  assert.equal(end.finished, true)
  assert.ok(r.reqs.every(q => q.closed), "the cap closes every REQ")
})

test("offline: Haven still searches, each relay says offline and nothing is asked", async () => {
  forgetAnswers()
  const r = rig({ feed: [note("a", "f")] })
  startSearch("bitcoin", { ...r.opts, online: false })
  assert.equal(r.reqs.length, 0)
  await tick()
  const u = r.last()
  assert.equal(u.finished, true)
  assert.deepEqual(u.sources.map(s => s.state), ["found", "failed", "failed"])
  assert.equal(u.sources[1].reason, "offline")
  assert.equal(u.notes.length, 1)
})

test("cancel: nothing is published after it, and every REQ is closed", async () => {
  forgetAnswers()
  const r = rig()
  const cancel = startSearch("bitcoin", r.opts)
  await tick()
  const seen = r.updates.length
  cancel()
  r.reqs[0].params.onevent(note("z", "s"))
  for (const q of r.reqs) q.params.onclose(["closed by caller"])
  r.flush(); await tick()
  assert.equal(r.updates.length, seen)
  assert.ok(r.reqs.every(q => q.closed))
})

test("a query asked again shows what it found last time in its first update", async () => {
  forgetAnswers()
  const r = rig({ feed: [note("a", "f")] })
  startSearch("Bitcoin", { ...r.opts, online: false })
  await tick()
  const again = rig()
  startSearch("bitcoin ", again.opts)
  await Promise.resolve()
  assert.deepEqual(again.updates[0].notes.map(n => n.id), ["a".repeat(64)])
  assert.equal(again.updates[0].finished, false)
})

test("results rank you, follows, then your web of trust, then everyone", () => {
  const people = [pk("s"), pk("w"), pk("f"), pk("m")]
  const r = shapeResults({ people, notes: [] }, "x", { me: pk("m"), follows: [pk("f")], wot: new Set([pk("w")]) })
  assert.deepEqual(r.people, [pk("m"), pk("f"), pk("w"), pk("s")])
})

test("a relay's reason fits a chip", () => {
  assert.equal(shortReason("relay connection failed"), "can't connect")
  assert.equal(shortReason(""), "no answer")
  assert.equal(shortReason("CLOSED: blocked: " + "x".repeat(60)).length, 40)
})
