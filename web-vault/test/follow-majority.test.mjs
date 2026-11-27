// The follow list's majority rule (Logen 2026-11-27, b6e725ef; iOS and Android build the same, src/net/follows.js
// followListKnown): an own write relay that never connects drops out of the count; the edit needs more than half of
// the ones that connected answering, and at least 2 answering. A relay that connected but is slow still counts.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { setFollow, followsOf, followListKnown } from "../src/net/follows.js"

const me = generateSecretKey(), mePk = getPublicKey(me)
const pk = () => getPublicKey(generateSecretKey())
const nowS = () => Math.floor(Date.now() / 1000)
const base = finalizeEvent({ kind: 3, created_at: nowS() - 600, tags: [["p", pk()], ["p", pk()]], content: "" }, me)
const seven = Array.from({ length: 7 }, (_, i) => `wss://r${i}.example`)
function fakeVault(seed = []) {
  const route = evs => ({
    evs,
    async query(f) { return evs.filter(e => (!f.kinds || f.kinds.includes(e.kind)) && (!f.authors || f.authors.includes(e.pubkey))) },
    async event(ev) { evs.push(ev); return { ok: true, message: "" } },
  })
  return { outbox: route([...seed]), feed: route([]) }
}
// Each of the 7 own relays is "answer" (EOSE with the list), "dead" (never connected) or "slow" (connected, no EOSE in
// time), as askRelay reports them. purplepag.es and the other index relays stay silent.
const relays = states => async url => {
  const s = states[seven.indexOf(url)]
  if (s === "answer") return { events: [base], answered: true, connected: true }
  if (s === "slow") return { events: [], answered: false, connected: true }
  return { events: [], answered: false, connected: false }
}
const run = states => setFollow({ vault: fakeVault([base]), signer: { signEvent: async t => finalizeEvent(t, me) }, pubkey: mePk,
  target: pk(), follow: true, readRelays: [], writeRelays: seven, ownRelays: seven, ask: relays(states),
  publish: urls => urls.map(() => Promise.resolve("")) })
const times = (n, s) => Array(n).fill(s)

test("majority: 3 of 7 dead and the other 4 answering is enough", async () => {
  const r = await run([...times(3, "dead"), ...times(4, "answer")])
  assert.equal(followsOf(r.event).length, 3)
})

test("majority: 5 of 7 dead and 2 answering is enough (the old rule wanted 4 of 7)", async () => {
  const r = await run([...times(5, "dead"), ...times(2, "answer")])
  assert.equal(followsOf(r.event).length, 3)
})

test("majority: 1 answering is refused, even with every other relay dead", async () => {
  await assert.rejects(run(["answer", ...times(6, "dead")]),
    { code: "relays", message: /^Couldn't follow: only 1 of your 7 relays answered, so your newest follow list can't be checked\. Nothing changed\. Remove dead relays in Settings › Relays, then try again\.$/ })
})

test("majority: 0 answering is refused", async () => {
  await assert.rejects(run(times(7, "dead")), { code: "relays", message: /^Couldn't follow: only 0 of your 7 relays answered/ })
  await assert.rejects(run(times(7, "slow")), { code: "relays", message: /^Couldn't follow: only 0 of your 7 relays answered/ })
})

test("majority: a slow relay that connected still counts against the majority", async () => {
  // 3 dead drop out, 4 reached: 2 answering of 4 is not more than half.
  await assert.rejects(run([...times(3, "dead"), "answer", "answer", "slow", "slow"]), { code: "relays" })
  // 3 of 4 reached is.
  const r = await run([...times(3, "dead"), "answer", "answer", "answer", "slow"])
  assert.equal(followsOf(r.event).length, 3)
})

test("followListKnown: the cases on the rule alone", () => {
  assert.equal(followListKnown({ reached: 4, answered: 4, found: true }), true)
  assert.equal(followListKnown({ reached: 2, answered: 2, found: true }), true)
  assert.equal(followListKnown({ reached: 1, answered: 1, found: true }), false, "below 2")
  assert.equal(followListKnown({ reached: 4, answered: 2, found: true }), false, "half is not a majority")
  assert.equal(followListKnown({ reached: 3, answered: 2, found: false }), false, "no list found: every reached relay")
  assert.equal(followListKnown({ reached: 2, answered: 2, found: false }), true)
})
