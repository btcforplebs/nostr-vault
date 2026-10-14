// Follow / Unfollow from someone's profile (src/net/follows.js) and their notes (src/net/person.js). A kind 3
// replaces the whole follow list, so most of this is the wipe guard: what may never be published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { editedTags, wipeGuard, setFollow, followsOf, newestList, relation } from "../src/net/follows.js"
import { readPersonNotes, syncPersonNotes, fetchPersonLists } from "../src/net/person.js"

const me = generateSecretKey(), mePk = getPublicKey(me)
const pk = () => getPublicKey(generateSecretKey())
const contacts = (follows, at, extra = []) => finalizeEvent({ kind: 3, created_at: at, tags: [...follows.map(p => ["p", p]), ...extra], content: '{"wss://r.example":{"read":true}}' }, me)

// Haven's outbox and /feed as these modules use them: query by authors/kinds (+until/limit), event() stores.
function fakeVault(seed = []) {
  const route = evs => ({
    evs,
    async query(f) {
      return evs.filter(e => (!f.kinds || f.kinds.includes(e.kind)) && (!f.authors || f.authors.includes(e.pubkey)) && (!f.until || e.created_at <= f.until))
        .sort((a, b) => b.created_at - a.created_at).slice(0, f.limit ?? Infinity)
    },
    async event(ev) { if (evs.some(e => e.id === ev.id)) return { ok: false, message: "duplicate: have it" }; evs.push(ev); return { ok: true, message: "" } },
  })
  return { outbox: route([...seed]), feed: route([]) }
}
const signer = { method: "nip07", signEvent: async t => finalizeEvent(t, me) }
const okPublish = (urls) => urls.map(() => Promise.resolve(""))
const run = (over) => setFollow({ vault: fakeVault(), signer, pubkey: mePk, readRelays: [], writeRelays: ["wss://w.example"], query: async () => [], publish: okPublish, ...over })

test("editedTags keeps every other tag and adds or removes only the target", () => {
  const a = pk(), b = pk(), t = pk()
  const base = contacts([a, b], 100, [["t", "nostr"]])
  assert.deepEqual(editedTags(base, t, true), [["p", a], ["p", b], ["t", "nostr"], ["p", t]])
  assert.deepEqual(editedTags(base, a, false), [["p", b], ["t", "nostr"]])
  assert.deepEqual(editedTags(contacts([a, t], 1), t, true), [["p", a], ["p", t]], "following twice adds no duplicate")
})

test("newestList picks the newest of the user's own kind 3s and ignores anyone else's", () => {
  const old = contacts([pk()], 100), nu = contacts([pk()], 200)
  const other = finalizeEvent({ kind: 3, created_at: 999, tags: [], content: "" }, generateSecretKey())
  assert.equal(newestList([old, other, nu], mePk), nu)
})

test("guard: no list found means nothing is published", async () => {
  assert.match(wipeGuard({ base: undefined, tags: [["p", pk()]], target: pk(), follow: true }), /wasn't found/)
  let signed = false
  await assert.rejects(run({ target: pk(), follow: true, signer: { signEvent: async t => { signed = true; return finalizeEvent(t, me) } } }), /wasn't found/)
  assert.equal(signed, false, "the signer is never asked")
})

test("guard: a result that loses other follows is refused", () => {
  const a = pk(), b = pk(), t = pk()
  const base = contacts([a, b], 100)
  assert.match(wipeGuard({ base, tags: [["p", t]], target: t, follow: true }), /drop 2 other follows/)
  assert.equal(wipeGuard({ base, tags: editedTags(base, t, true), target: t, follow: true }), "")
})

test("guard: a stale list newer-dated than a much bigger one is refused (most > 10, result < half)", () => {
  const many = Array.from({ length: 40 }, pk), t = pk()
  const big = contacts(many, 100), stale = contacts(many.slice(0, 5), 200)
  assert.match(wipeGuard({ base: stale, tags: editedTags(stale, t, true), target: t, follow: true, seen: [big, stale] }), /had 40/)
  assert.match(wipeGuard({ base: stale, tags: editedTags(stale, t, true), target: t, follow: true, seen: [stale], appCount: 40 }), /had 40/, "the app's own count counts too")
  // Small lists are under the threshold, as on iOS: 10 -> 4 is allowed.
  const ten = contacts(many.slice(0, 10), 100), four = contacts(many.slice(0, 4), 200)
  assert.equal(wipeGuard({ base: four, tags: editedTags(four, t, true), target: t, follow: true, seen: [ten, four] }), "")
})

test("guard: one deliberate unfollow always passes, even the last follow; an empty list otherwise never does", () => {
  const a = pk()
  const one = contacts([a], 100)
  assert.equal(wipeGuard({ base: one, tags: editedTags(one, a, false), target: a, follow: false, seen: [one] }), "")
  const none = contacts([], 100)
  assert.match(wipeGuard({ base: none, tags: editedTags(none, a, false), target: a, follow: false, seen: [none] }), /empty/)
})

test("follow builds on the newest list (network beats an older vault copy), keeps content, and is newer than it", async () => {
  const a = pk(), b = pk(), t = pk()
  const vaultOld = contacts([a], 100), netNew = contacts([a, b], 300, [["t", "x"]])
  const vault = fakeVault([vaultOld])
  const sent = []
  const r = await run({ vault, target: t, follow: true, query: async () => [netNew], publish: (urls, ev) => { sent.push(...urls); return okPublish(urls) } })
  assert.deepEqual(followsOf(r.event), [a, b, t])
  assert.deepEqual(r.event.tags.find(x => x[0] === "t"), ["t", "x"])
  assert.equal(r.event.content, netNew.content)
  assert.ok(r.event.created_at > netNew.created_at)
  assert.ok(sent.includes("wss://w.example"))
  assert.ok(vault.outbox.evs.some(e => e.id === r.event.id), "stored in Haven after a relay took it")
})

test("a refused list is not written into Haven, so the app's follows don't shrink to it", async () => {
  const many = Array.from({ length: 30 }, pk)
  const vault = fakeVault([contacts(many, 100)])
  const stale = contacts(many.slice(0, 3), 200)
  await assert.rejects(run({ vault, target: pk(), follow: true, query: async () => [stale] }), /had 30/)
  assert.equal(vault.outbox.evs.length, 1)
  assert.equal(followsOf(vault.outbox.evs[0]).length, 30)
})

test("a base dated in the future still gets a strictly newer list", async () => {
  const future = contacts([pk()], Math.floor(Date.now() / 1000) + 3600)
  const r = await run({ vault: fakeVault([future]), target: pk(), follow: true })
  assert.equal(r.event.created_at, future.created_at + 1)
})

test("unfollow removes just that pubkey", async () => {
  const a = pk(), b = pk(), c = pk()
  const r = await run({ vault: fakeVault([contacts([a, b, c], 100)]), target: b, follow: false })
  assert.deepEqual(followsOf(r.event), [a, c])
})

test("when no relay takes it, Haven isn't changed and the error says so", async () => {
  const base = contacts([pk()], 100)
  const vault = fakeVault([base])
  await assert.rejects(run({ vault, target: pk(), follow: true, publish: urls => urls.map(() => Promise.reject(new Error("blocked"))) }), /No relay took it/)
  assert.deepEqual(vault.outbox.evs, [base])
})

test("a signer that signs as another account is refused before anything is sent", async () => {
  const other = generateSecretKey()
  let sent = false
  await assert.rejects(run({ vault: fakeVault([contacts([pk()], 100)]), target: pk(), follow: true,
    signer: { signEvent: async t => finalizeEvent(t, other) }, publish: urls => { sent = true; return okPublish(urls) } }), /different account/)
  assert.equal(sent, false)
})

test("yourself and non-hex targets are refused", async () => {
  await assert.rejects(run({ target: mePk, follow: true }), /yourself/)
  await assert.rejects(run({ target: "npub1xyz", follow: true }), /isn't a profile that can be followed/)
})

test("relation badges", () => {
  assert.equal(relation(true, true), "mutual")
  assert.equal(relation(true, false), "following")
  assert.equal(relation(false, true), "follows-you")
  assert.equal(relation(false, false), "")
})

test("their notes: fetched from their write relays into Haven /feed, read back newest first, paged by until", async () => {
  const them = generateSecretKey(), them_pk = getPublicKey(them)
  const notes = [100, 200, 300].map(at => finalizeEvent({ kind: 1, created_at: at, tags: [], content: `n${at}` }, them))
  const stranger = finalizeEvent({ kind: 1, created_at: 400, tags: [], content: "not theirs" }, generateSecretKey())
  const vault = fakeVault()
  let asked
  const got = await syncPersonNotes(vault, them_pk, ["wss://their.write"], { query: async (relays, f) => { asked = { relays, f }; return [...notes, stranger] } })
  assert.equal(got, 3)
  assert.ok(asked.relays.includes("wss://their.write"))
  assert.deepEqual(asked.f.authors, [them_pk])
  assert.deepEqual((await readPersonNotes(vault, them_pk)).map(n => n.created_at), [300, 200, 100])
  assert.deepEqual((await readPersonNotes(vault, them_pk, { until: 199 })).map(n => n.created_at), [100])
  await syncPersonNotes(vault, them_pk, [], { until: 199, query: async (r, f) => { asked = f; return [] } })
  assert.equal(asked.until, 199, "an older page asks the network before that note")
})

test("their lists: newest 10002 gives their write relays; their kind 3 says whether they follow you", async () => {
  const them = generateSecretKey(), them_pk = getPublicKey(them)
  const rl = (at, url) => finalizeEvent({ kind: 10002, created_at: at, tags: [["r", url, "write"]], content: "" }, them)
  const k3 = finalizeEvent({ kind: 3, created_at: 5, tags: [["p", mePk]], content: "" }, them)
  const l = await fetchPersonLists(them_pk, [], { query: async () => [rl(1, "wss://old.example"), rl(2, "wss://new.example"), k3] })
  assert.deepEqual(l.relays.write, ["wss://new.example"])
  assert.ok(followsOf(l.contacts).includes(mePk))
})
