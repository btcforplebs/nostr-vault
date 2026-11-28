// Messages perf review 2026-11-28 #6: the list's names are asked in a few batches, each peer once, not once per
// decrypt round. Fake timers and a stubbed fetch: no network.
import test from "node:test"
import assert from "node:assert/strict"
import { dmProfileAsker, QUIET, MAX_WAIT } from "../src/net/dm-profiles.js"

function fakeTimers() {
  let seq = 0
  const timers = new Map()
  return {
    set: (f, ms) => { const id = ++seq; timers.set(id, { f, ms }); return id },
    clear: id => timers.delete(id),
    pending: () => [...timers.values()],
    fire: () => { const all = [...timers.values()]; timers.clear(); for (const t of all) t.f() },
  }
}
const tick = () => new Promise(r => setTimeout(r, 0))
const pks = (from, n) => Array.from({ length: n }, (_, i) => String(from + i).padStart(64, "0"))

test("rounds of eight peers become one ask once they stop coming; known peers aren't asked again", async () => {
  const t = fakeTimers(), calls = []
  const ask = dmProfileAsker({ fetch: async (v, peers, relays) => { calls.push({ peers, relays }) }, set: t.set, clear: t.clear })
  let now = 0
  for (let round = 1; round <= 5; round++) { ask({}, pks(0, round * 8), ["wss://r"], now); now += 50 }
  assert.equal(calls.length, 0, "nothing asked while rounds keep landing")
  assert.equal(t.pending().length, 1, "one timer, not one per round")
  t.fire(); await tick()
  assert.equal(calls.length, 1)
  assert.equal(calls[0].peers.length, 40, "every peer once, in one ask")
  ask({}, pks(0, 40), ["wss://r"], now)
  assert.equal(t.pending().length, 0, "the same peers again ask nothing")
  ask({}, pks(0, 44), ["wss://r"], now)
  t.fire(); await tick()
  assert.deepEqual(calls[1].peers, pks(40, 4), "only the new peers")
})

test("a steady stream is still asked within MAX_WAIT; an ask that failed is asked again", async () => {
  const t = fakeTimers(), calls = []
  let fail = true
  const ask = dmProfileAsker({ fetch: async (v, peers) => { calls.push(peers); if (fail) throw new Error("x") }, set: t.set, clear: t.clear })
  ask({}, pks(0, 8), [], 0)
  ask({}, pks(0, 16), [], MAX_WAIT - 100)
  assert.equal(t.pending()[0].ms, 100, "the wait never runs past MAX_WAIT from the first peer")
  assert.ok(QUIET <= MAX_WAIT)
  t.fire(); await tick(); await tick()
  fail = false
  ask({}, pks(0, 16), [], MAX_WAIT + 10)
  t.fire(); await tick()
  assert.equal(calls.length, 2)
  assert.equal(calls[1].length, 16, "the failed peers are asked again")
})
