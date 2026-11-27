// A Follow / Unfollow that can't go out says why, in the iPhone app's wording (src/net/follow-failure.js; Tory's
// FollowPublishFailure, nv-apple 2026-11-27): a slow relay set, a signer that didn't sign, every relay refusing.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { setFollow, followsOf } from "../src/net/follows.js"
import { followFailure } from "../src/net/follow-failure.js"

const me = generateSecretKey(), mePk = getPublicKey(me)
const pk = () => getPublicKey(generateSecretKey())
const nowS = () => Math.floor(Date.now() / 1000)
const contacts = (follows, at) => finalizeEvent({ kind: 3, created_at: at, tags: follows.map(p => ["p", p]), content: "" }, me)
function fakeVault(seed = []) {
  const route = evs => ({
    evs,
    async query(f) { return evs.filter(e => (!f.kinds || f.kinds.includes(e.kind)) && (!f.authors || f.authors.includes(e.pubkey))).sort((a, b) => b.created_at - a.created_at) },
    async event(ev) { evs.push(ev); return { ok: true, message: "" } },
  })
  return { outbox: route([...seed]), feed: route([]) }
}
const seven = Array.from({ length: 7 }, (_, i) => `wss://r${i}.example`)
const base = contacts([pk(), pk()], nowS() - 600)
const signer = { signEvent: async t => finalizeEvent(t, me) }
const okPublish = urls => urls.map(() => Promise.resolve(""))
// The first `n` of the user's 7 write relays answer with the list; the rest stay silent.
const answering = n => async url => seven.includes(url) && seven.indexOf(url) < n ? { events: [base], answered: true } : { events: [], answered: false }
const run = over => setFollow({ vault: fakeVault([base]), signer, pubkey: mePk, target: pk(), follow: true, readRelays: [],
  writeRelays: seven, ownRelays: seven, ask: answering(7), publish: okPublish, ...over })

test("follow failure: 3 of 7 relays answering names the counts and the fix (rd's report, 11-27)", async () => {
  await assert.rejects(run({ ask: answering(3) }), {
    code: "relays",
    message: "Couldn't follow: only 3 of your 7 relays answered, so your newest follow list can't be checked. Nothing changed. Remove dead relays in Settings › Relays, then try again.",
  })
  await assert.rejects(run({ ask: answering(0), follow: false, target: followsOf(base)[0] }), { code: "relays", message: /^Couldn.t unfollow: only 0 of your 7 relays answered/ })
})

test("follow failure: one relay of one answered reads 'not enough relays'", async () => {
  await assert.rejects(run({ writeRelays: [seven[0]], ownRelays: [seven[0]], ask: answering(1) }),
    { code: "relays", message: /^Couldn't follow: not enough relays answered, so your newest follow list can't be checked\. Nothing changed\. Try again in a moment\.$/ })
})

test("follow failure: the signer not signing, or signing with another key", async () => {
  const refuse = { signEvent: async () => { throw new Error("bunker timed out") } }
  await assert.rejects(run({ signer: refuse }), { code: "signer", message: "Couldn't follow: your signer didn't sign it. Nothing changed. Check your signer, then try again." })
  await assert.rejects(run({ signer: { signEvent: async () => undefined } }), { code: "signer" })
  const other = generateSecretKey()
  await assert.rejects(run({ signer: { signEvent: async t => finalizeEvent(t, other) } }),
    { code: "signerKey", message: "Couldn't follow: your signer signed with a different key. Nothing changed. Check which account your signer is on." })
})

test("follow failure: every relay refusing it", async () => {
  const refuseAll = urls => urls.map(() => Promise.reject(new Error("blocked: not allowed")))
  await assert.rejects(run({ publish: refuseAll }), { code: "refused", message: "Couldn't follow: every relay refused it. Nothing changed. Check your relays in Settings › Relays." })
})

test("follow failure: the shrink guard and the other exits say Couldn't follow and keep their reason", async () => {
  const many = Array.from({ length: 30 }, pk)
  await assert.rejects(run({ appCount: many.length }),
    { code: "shrink", message: "Couldn't follow: the new list would have less than half the people of your last one, so it was stopped to protect your follows. Nothing changed." })
  await assert.rejects(run({ ownRelays: [] }), { code: "noOwnRelays", message: /^Couldn't follow\. Your own relays aren't known/ })
  assert.match(followFailure("other", { follow: false }), /^Couldn't unfollow\. Nothing changed\. Try again\.$/)
})

test("follow failure: a follow that goes out still works", async () => {
  const r = await run({})
  assert.equal(followsOf(r.event).length, 3)
})
