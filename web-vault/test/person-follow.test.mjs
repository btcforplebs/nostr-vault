// Follow / Unfollow from someone's profile (src/net/follows.js) and their notes (src/net/person.js). A kind 3
// replaces the whole follow list, so most of this is the wipe guard: what may never be published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { editedTags, wipeGuard, setFollow, followsOf, newestList, relation, askRelay, MAX_SKEW } from "../src/net/follows.js"
import { pool, PROFILE_RELAYS } from "../src/net/pool.js"
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
const run = (over) => setFollow({ vault: fakeVault(), signer, pubkey: mePk, readRelays: [], writeRelays: ["wss://w.example"], ask: relaysAnswer([]), publish: okPublish, ...over })
// Every relay asked sends these events and its EOSE.
function relaysAnswer(events) { return async () => ({ events, answered: true }) }
const nowS = () => Math.floor(Date.now() / 1000)

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
  assert.match(wipeGuard({ base: undefined, tags: [["p", pk()]], target: pk(), follow: true, answered: 1, asked: 1 }), /wasn't found/)
  let signed = false
  await assert.rejects(run({ target: pk(), follow: true, signer: { signEvent: async t => { signed = true; return finalizeEvent(t, me) } } }), /wasn't found/)
  assert.equal(signed, false, "the signer is never asked")
})

test("guard: relays all down and only an old vault copy -> nothing is signed or sent (Tron's 40 -> 5 case)", async () => {
  const many = Array.from({ length: 40 }, pk)
  const old = contacts(many.slice(0, 4), 100) // the vault's stale copy; the real 40-follow list is on the relays
  const vault = fakeVault([old])
  let signed = false, sent = false
  await assert.rejects(run({ vault, target: pk(), follow: true, known: old, appCount: 4,
    ask: async () => ({ events: [], answered: false }),
    signer: { signEvent: async t => { signed = true; return finalizeEvent(t, me) } },
    publish: urls => { sent = true; return okPublish(urls) } }), /None of your relays answered/)
  assert.equal(signed, false)
  assert.equal(sent, false)
  assert.deepEqual(vault.outbox.evs, [old])
})

test("guard: an answer from purplepag.es alone doesn't count; one of the user's relays does", async () => {
  const base = contacts([pk()], 100)
  const onlyIndex = async url => ({ events: [], answered: PROFILE_RELAYS.includes(url) })
  await assert.rejects(run({ vault: fakeVault([base]), target: pk(), follow: true, ask: onlyIndex }), /None of your relays answered/)
  const oneOwn = async url => ({ events: [], answered: url === "wss://w.example" })
  const r = await run({ vault: fakeVault([base]), target: pk(), follow: true, ask: oneOwn })
  assert.equal(followsOf(r.event).length, 2)
})

test("guard: one own relay times out, the other answers empty, the vault has an old copy -> refused (Tron's 2-relay case)", async () => {
  const many = Array.from({ length: 40 }, pk)
  const old = contacts(many.slice(0, 4), nowS() - 30 * 86400) // a month-old 4-follow copy; the real 40 is on wss://a
  const vault = fakeVault([old])
  let signed = false, sent = false
  const ask = async url => url === "wss://b.example" ? { events: [], answered: true } : { events: [], answered: false }
  await assert.rejects(run({ vault, readRelays: ["wss://a.example"], writeRelays: ["wss://b.example"], target: pk(), follow: true, known: old, appCount: 4, ask,
    signer: { signEvent: async t => { signed = true; return finalizeEvent(t, me) } },
    publish: urls => { sent = true; return okPublish(urls) } }), /Only 1 of your 2 relays answered/)
  assert.equal(signed, false)
  assert.equal(sent, false)
  assert.deepEqual(vault.outbox.evs, [old])
})

test("guard: own relays both time out, purplepag.es has an old copy -> refused, signer never asked (Tron's index-relay case)", async () => {
  const many = Array.from({ length: 40 }, pk)
  const old = contacts(many.slice(0, 4), nowS() - 30 * 86400) // the real 40 is on wss://a, which timed out
  const vault = fakeVault([old])
  let signed = false, sent = false
  const ask = async url => PROFILE_RELAYS.includes(url) ? { events: [old], answered: true } : { events: [], answered: false }
  await assert.rejects(run({ vault, readRelays: ["wss://a.example"], writeRelays: ["wss://b.example"], target: pk(), follow: true, known: old, appCount: 4, ask,
    signer: { signEvent: async t => { signed = true; return finalizeEvent(t, me) } },
    publish: urls => { sent = true; return okPublish(urls) } }), /None of your relays answered/)
  assert.equal(signed, false)
  assert.equal(sent, false)
  assert.deepEqual(vault.outbox.evs, [old])
})

test("guard: a list from one of your relays, or every own relay answering, is enough", async () => {
  const many = Array.from({ length: 40 }, pk)
  const real = contacts(many, nowS() - 60), old = contacts(many.slice(0, 4), nowS() - 30 * 86400)
  const relays = { readRelays: ["wss://a.example"], writeRelays: ["wss://b.example"] }
  // wss://a times out but wss://b holds the real list: built on it.
  const found = await run({ vault: fakeVault([old]), ...relays, target: pk(), follow: true, known: old,
    ask: async url => url === "wss://b.example" ? { events: [real], answered: true } : { events: [], answered: false } })
  assert.equal(followsOf(found.event).length, 41)
  // Both answer, neither has a list: the vault's copy is the newest there is (iOS loadConfirmsList).
  const small = contacts(many.slice(0, 2), 100)
  const all = await run({ vault: fakeVault([small]), ...relays, target: pk(), follow: true, ask: relaysAnswer([]) })
  assert.equal(followsOf(all.event).length, 3)
})

test("a relay's kind 3 with a forged signature and a 'verified' flag is not taken", async () => {
  const { verifiedSymbol } = await import("nostr-tools/pure")
  const many = Array.from({ length: 40 }, pk)
  const forged = { ...contacts(many.slice(0, 3), nowS() - 10), sig: "00".repeat(64), [verifiedSymbol]: true }
  const real = contacts(many, nowS() - 3600)
  const r = await run({ vault: fakeVault([real]), target: pk(), follow: true, ask: relaysAnswer([forged]) })
  assert.equal(followsOf(r.event).length, 41, "built on the vault's real list, not the forged newer one")
})

test("askRelay: answered only on the relay's own EOSE, never on a timeout or a dead relay", async t => {
  assert.deepEqual(await askRelay("ws://127.0.0.1:1", { kinds: [3] }, 2000), { events: [], answered: false })
  const ev = contacts([pk()], 100)
  // As nostr-tools does: a subscription whose eoseTimeout runs out calls oneose too.
  const relay = eose => ({ subscribe: (f, p) => { p.onevent(ev); const h = setTimeout(p.oneose, eose ? 10 : p.eoseTimeout); return { close() { clearTimeout(h) } } } })
  t.mock.method(pool, "ensureRelay", async () => relay(false))
  assert.deepEqual(await askRelay("wss://silent.example", { kinds: [3] }, 50), { events: [ev], answered: false })
  t.mock.method(pool, "ensureRelay", async () => relay(true))
  assert.deepEqual(await askRelay("wss://ok.example", { kinds: [3] }, 1000), { events: [ev], answered: true })
})

test("guard: a stale list newer-dated than a much bigger one is refused (most > 10, result < half)", () => {
  const many = Array.from({ length: 40 }, pk), t = pk()
  const big = contacts(many, 100), stale = contacts(many.slice(0, 5), 200)
  assert.match(wipeGuard({ base: stale, tags: editedTags(stale, t, true), target: t, follow: true, seen: [big, stale], answered: 1, asked: 1 }), /had 40/)
  assert.match(wipeGuard({ base: stale, tags: editedTags(stale, t, true), target: t, follow: true, seen: [stale], appCount: 40, answered: 1, asked: 1 }), /had 40/, "the app's own count counts too")
  // Small lists are under the threshold, as on iOS: 10 -> 4 is allowed.
  const ten = contacts(many.slice(0, 10), 100), four = contacts(many.slice(0, 4), 200)
  assert.equal(wipeGuard({ base: four, tags: editedTags(four, t, true), target: t, follow: true, seen: [ten, four], answered: 1, asked: 1 }), "")
})

test("guard: one deliberate unfollow always passes, even the last follow; an empty list otherwise never does", () => {
  const a = pk()
  const one = contacts([a], 100)
  assert.equal(wipeGuard({ base: one, tags: editedTags(one, a, false), target: a, follow: false, seen: [one], answered: 1, asked: 1 }), "")
  const none = contacts([], 100)
  assert.match(wipeGuard({ base: none, tags: editedTags(none, a, false), target: a, follow: false, seen: [none], answered: 1, asked: 1 }), /empty/)
})

test("follow builds on the newest list (network beats an older vault copy), keeps content, and is newer than it", async () => {
  const a = pk(), b = pk(), t = pk()
  const vaultOld = contacts([a], 100), netNew = contacts([a, b], 300, [["t", "x"]])
  const vault = fakeVault([vaultOld])
  const sent = []
  const r = await run({ vault, target: t, follow: true, ask: relaysAnswer([netNew]), publish: (urls, ev) => { sent.push(...urls); return okPublish(urls) } })
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
  await assert.rejects(run({ vault, target: pk(), follow: true, ask: relaysAnswer([stale]) }), /had 30/)
  assert.equal(vault.outbox.evs.length, 1)
  assert.equal(followsOf(vault.outbox.evs[0]).length, 30)
})

test("a list dated past the skew is ignored, and a new list is never dated past it", async () => {
  const a = pk(), b = pk(), t = pk()
  const real = contacts([a, b], nowS() - 60)
  const rogue = contacts([a], nowS() + 5 * 365 * 86400) // a relay serving a kind 3 dated years ahead
  assert.equal(newestList([real, rogue], mePk), real)
  const r = await run({ vault: fakeVault([real]), target: t, follow: true, ask: relaysAnswer([rogue]) })
  assert.deepEqual(followsOf(r.event), [a, b, t], "built on the real list, not the rogue one")
  assert.ok(r.event.created_at <= nowS() + 1, "dated now, not after the rogue list")
})

test("a base slightly ahead (inside the skew) still gets a newer list, capped at now + skew", async () => {
  const ahead = contacts([pk()], nowS() + 600)
  const r = await run({ vault: fakeVault([ahead]), target: pk(), follow: true })
  assert.equal(r.event.created_at, ahead.created_at + 1)
  assert.ok(r.event.created_at <= nowS() + MAX_SKEW)
  const edge = contacts([pk()], nowS() + MAX_SKEW - 1)
  const r2 = await run({ vault: fakeVault([edge]), target: pk(), follow: true })
  assert.ok(r2.event.created_at > edge.created_at && r2.event.created_at <= nowS() + MAX_SKEW)
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

test("their notes: fetched from their write relays, kept out of Haven /feed, read newest first, paged by until", async () => {
  const them = generateSecretKey(), them_pk = getPublicKey(them)
  const notes = [100, 200, 300].map(at => finalizeEvent({ kind: 1, created_at: at, tags: [], content: `n${at}` }, them))
  const stranger = finalizeEvent({ kind: 1, created_at: 400, tags: [], content: "not theirs" }, generateSecretKey())
  const vault = fakeVault()
  let asked
  const got = await syncPersonNotes(vault, them_pk, ["wss://their.write"], { query: async (relays, f) => { asked = { relays, f }; return [...notes, stranger] } })
  assert.equal(got, 3)
  assert.equal(vault.feed.evs.length, 0, "a stranger's notes are not written into the Following feed's store")
  assert.ok(asked.relays.includes("wss://their.write"))
  assert.deepEqual(asked.f.authors, [them_pk])
  assert.deepEqual((await readPersonNotes(vault, them_pk)).map(n => n.created_at), [300, 200, 100])
  assert.deepEqual((await readPersonNotes(vault, them_pk, { until: 199 })).map(n => n.created_at), [100])
  await syncPersonNotes(vault, them_pk, [], { until: 199, query: async (r, f) => { asked = f; return [] } })
  assert.equal(asked.until, 199, "an older page asks the network before that note")
  // Notes feed sync already saved (someone you follow) are merged in, once each.
  await vault.feed.event(notes[1])
  const saved = finalizeEvent({ kind: 1, created_at: 250, tags: [], content: "saved by feed sync" }, them)
  await vault.feed.event(saved)
  assert.deepEqual((await readPersonNotes(vault, them_pk)).map(n => n.created_at), [300, 250, 200, 100])
})

test("their lists: newest 10002 gives their write relays; their kind 3 says whether they follow you", async () => {
  const them = generateSecretKey(), them_pk = getPublicKey(them)
  const rl = (at, url) => finalizeEvent({ kind: 10002, created_at: at, tags: [["r", url, "write"]], content: "" }, them)
  const k3 = finalizeEvent({ kind: 3, created_at: 5, tags: [["p", mePk]], content: "" }, them)
  const l = await fetchPersonLists(them_pk, [], { query: async () => [rl(1, "wss://old.example"), rl(2, "wss://new.example"), k3] })
  assert.deepEqual(l.relays.write, ["wss://new.example"])
  assert.ok(followsOf(l.contacts).includes(mePk))
})
