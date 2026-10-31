// Follow / Unfollow from someone's profile (src/net/follows.js) and their notes (src/net/person.js). A kind 3
// replaces the whole follow list, so most of this is the wipe guard: what may never be published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { editedTags, wipeGuard, setFollow, followsOf, newestList, relation, askRelay, MAX_SKEW } from "../src/net/follows.js"
import { pool, PROFILE_RELAYS } from "../src/net/pool.js"
import { readPersonNotes, syncPersonNotes, fetchPersonLists, openPersonNotes } from "../src/net/person.js"
import { DEFAULT_RELAYS } from "../src/net/pool.js"

const me = generateSecretKey(), mePk = getPublicKey(me)
const pk = () => getPublicKey(generateSecretKey())
const nowS = () => Math.floor(Date.now() / 1000)
// Fixture dates: an hour ago plus a small offset, inside MAX_LOCAL_AGE (a vault copy older than that is refused).
const T0 = nowS() - 3600
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

test("editedTags keeps every other tag and adds or removes only the target", () => {
  const a = pk(), b = pk(), t = pk()
  const base = contacts([a, b], T0 + 100, [["t", "nostr"]])
  assert.deepEqual(editedTags(base, t, true), [["p", a], ["p", b], ["t", "nostr"], ["p", t]])
  assert.deepEqual(editedTags(base, a, false), [["p", b], ["t", "nostr"]])
  assert.deepEqual(editedTags(contacts([a, t], 1), t, true), [["p", a], ["p", t]], "following twice adds no duplicate")
})

test("newestList picks the newest of the user's own kind 3s and ignores anyone else's", () => {
  const old = contacts([pk()], T0 + 100), nu = contacts([pk()], T0 + 200)
  const other = finalizeEvent({ kind: 3, created_at: 999, tags: [], content: "" }, generateSecretKey())
  assert.equal(newestList([old, other, nu], mePk), nu)
})

test("guard: no list anywhere -> a first list of one follow once every relay answered (iOS loadConfirmsList)", async () => {
  const first = over => wipeGuard({ base: undefined, tags: [["p", pk()]], target: pk(), follow: true, answered: 3, asked: 3, ...over })
  assert.equal(first(), "")
  assert.match(first({ answered: 2 }), /2 of your 3 relays answered/, "the majority isn't enough with no base to guard")
  assert.match(first({ follow: false, tags: [] }), /wasn't found/, "an unfollow needs a list")
  assert.match(first({ appCount: 12 }), /wasn't found/, "the app shows follows: a list exists somewhere")
  assert.match(first({ ahead: true }), /wasn't found/, "a future-dated list exists")
  const t = pk()
  const { event, follows } = await run({ target: t, follow: true })
  assert.deepEqual(follows, [t])
  assert.deepEqual(event.tags, [["p", t]])
  assert.equal(event.content, "")
})

test("guard: relays all down and only an old vault copy -> nothing is signed or sent (Tron's 40 -> 5 case)", async () => {
  const many = Array.from({ length: 40 }, pk)
  const old = contacts(many.slice(0, 4), T0 + 100) // the vault's stale copy; the real 40-follow list is on the relays
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
  const base = contacts([pk()], T0 + 100)
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

test("guard: a list from one of your relays, or all of them answering, is enough", async () => {
  const many = Array.from({ length: 40 }, pk)
  const real = contacts(many, nowS() - 60), old = contacts(many.slice(0, 4), nowS() - 30 * 86400)
  const relays = { readRelays: ["wss://a.example"], writeRelays: ["wss://b.example"] }
  // wss://a times out but wss://b holds the real list: built on it.
  const found = await run({ vault: fakeVault([old]), ...relays, target: pk(), follow: true, known: old,
    ask: async url => url === "wss://b.example" ? { events: [real], answered: true } : { events: [], answered: false } })
  assert.equal(followsOf(found.event).length, 41)
  // Both answer, neither has a list: the vault's copy is the newest there is (iOS loadConfirmsList).
  const small = contacts(many.slice(0, 2), T0 + 100)
  const all = await run({ vault: fakeVault([small]), ...relays, target: pk(), follow: true, ask: relaysAnswer([]) })
  assert.equal(followsOf(all.event).length, 3)
})

test("guard: most of your relays answering is enough, half or fewer is not", async () => {
  const relays = { readRelays: ["wss://a.example", "wss://b.example"], writeRelays: ["wss://c.example"] }
  const answering = (...urls) => async url => ({ events: [], answered: urls.includes(url) })
  // 2 of 3 answer empty, the third is down: the vault's copy is used.
  const small = contacts([pk(), pk()], nowS() - 3600)
  const two = await run({ vault: fakeVault([small]), ...relays, target: pk(), follow: true, ask: answering("wss://a.example", "wss://c.example") })
  assert.equal(followsOf(two.event).length, 3)
  // 1 of 3: refused before the signer is asked.
  let signed = false
  await assert.rejects(run({ vault: fakeVault([small]), ...relays, target: pk(), follow: true, ask: answering("wss://b.example"),
    signer: { signEvent: async t => { signed = true; return finalizeEvent(t, me) } } }), /Only 1 of your 3 relays answered/)
  assert.equal(signed, false)
  // The edges, on the guard alone: exactly half is not most.
  const base = contacts([pk()], T0 + 100), t = pk(), tags = editedTags(base, t, true)
  const guard = (answered, asked) => wipeGuard({ base, tags, target: t, follow: true, seen: [base], answered, asked })
  assert.equal(guard(2, 3), "")
  assert.equal(guard(3, 4), "")
  assert.match(guard(2, 4), /Only 2 of your 4/)
  assert.match(guard(1, 2), /Only 1 of your 2/)
  assert.match(guard(0, 0), /None of your relays/)
})

test("guard: with 2 of 3 answering, the old wipe cases still refuse", async () => {
  const many = Array.from({ length: 40 }, pk)
  const relays = { readRelays: ["wss://a.example", "wss://b.example"], writeRelays: ["wss://c.example"] }
  const twoOfThree = async url => ({ events: [], answered: url !== "wss://a.example" })
  let signed = false
  const signer = { signEvent: async t => { signed = true; return finalizeEvent(t, me) } }
  // No list anywhere and one relay silent: it may hold the real list, so no one-follow list.
  await assert.rejects(run({ ...relays, target: pk(), follow: true, ask: twoOfThree, signer }), /2 of your 3 relays answered/)
  // Only a day-old 4-follow copy while the app showed 40: the size rule refuses.
  const old = contacts(many.slice(0, 4), nowS() - 86400)
  await assert.rejects(run({ vault: fakeVault([old]), ...relays, target: pk(), follow: true, known: old, appCount: 40, ask: twoOfThree, signer }), /had 40/)
  // A future-dated copy is not a base, and only it was found: nothing to build on.
  const future = contacts(many, nowS() + MAX_SKEW + 60)
  await assert.rejects(run({ vault: fakeVault([future]), ...relays, target: pk(), follow: true, ask: twoOfThree, signer }), /wasn't found/)
  // purplepag.es alone can't confirm: 1 of 3 own relays answered, the index relay has a list.
  const idx = async url => PROFILE_RELAYS.includes(url) ? { events: [old], answered: true } : { events: [], answered: url === "wss://c.example" }
  await assert.rejects(run({ vault: fakeVault([old]), ...relays, target: pk(), follow: true, ask: idx, signer }), /Only 1 of your 3/)
  assert.equal(signed, false, "the signer is never asked")
})

test("guard: 2 of 3 answer empty and this browser's copy is a month old -> refused; a day old -> saved (Tron's unbounded-gap case)", async () => {
  const many = Array.from({ length: 40 }, pk)
  const relays = { readRelays: ["wss://a.example", "wss://b.example"], writeRelays: ["wss://c.example"] }
  const twoOfThree = async url => ({ events: [], answered: url !== "wss://a.example" }) // the real 40 is on wss://a, which is down
  let signed = false
  const signer = { signEvent: async t => { signed = true; return finalizeEvent(t, me) } }
  const month = contacts(many.slice(0, 4), nowS() - 30 * 86400)
  const vault = fakeVault([month])
  await assert.rejects(run({ vault, ...relays, target: pk(), follow: true, known: month, appCount: 4, ask: twoOfThree, signer }),
    /no longer have your follow list and this browser's copy is from .+, so nothing was changed/)
  assert.equal(signed, false, "the signer is never asked")
  assert.deepEqual(vault.outbox.evs, [month])
  const day = contacts(many.slice(0, 4), nowS() - 86400)
  const r = await run({ vault: fakeVault([day]), ...relays, target: pk(), follow: true, known: day, appCount: 4, ask: twoOfThree })
  assert.equal(followsOf(r.event).length, 5)
  // A list from one of the relays is never too old: it is the newest the network has.
  const net = await run({ vault: fakeVault([]), ...relays, target: pk(), follow: true,
    ask: async url => ({ events: url === "wss://c.example" ? [month] : [], answered: url !== "wss://a.example" }) })
  assert.equal(followsOf(net.event).length, 5)
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
  // A browser's close() on a failed socket does nothing; Node 22's fires "error" again and nostr-tools closes from
  // onerror, so on Node 22 the dead relay overflows the stack (see thread-page/server.mjs). Browser behaviour here.
  process.env.THREAD_PAGE_NO_LISTEN = "1"
  const { closeOnce } = await import("../thread-page/server.mjs")
  const real = pool._WebSocket
  pool._WebSocket = closeOnce(real)
  t.after(() => { pool._WebSocket = real })
  assert.deepEqual(await askRelay("ws://127.0.0.1:1", { kinds: [3] }, 2000), { events: [], answered: false })
  const ev = contacts([pk()], T0 + 100)
  // As nostr-tools does: a subscription whose eoseTimeout runs out calls oneose too.
  const relay = eose => ({ subscribe: (f, p) => { p.onevent(ev); const h = setTimeout(p.oneose, eose ? 10 : p.eoseTimeout); return { close() { clearTimeout(h) } } } })
  t.mock.method(pool, "ensureRelay", async () => relay(false))
  assert.deepEqual(await askRelay("wss://silent.example", { kinds: [3] }, 50), { events: [ev], answered: false })
  t.mock.method(pool, "ensureRelay", async () => relay(true))
  assert.deepEqual(await askRelay("wss://ok.example", { kinds: [3] }, 1000), { events: [ev], answered: true })
})

test("guard: a stale list newer-dated than a much bigger one is refused (most > 10, result < half)", () => {
  const many = Array.from({ length: 40 }, pk), t = pk()
  const big = contacts(many, T0 + 100), stale = contacts(many.slice(0, 5), T0 + 200)
  assert.match(wipeGuard({ base: stale, tags: editedTags(stale, t, true), target: t, follow: true, seen: [big, stale], answered: 1, asked: 1 }), /had 40/)
  assert.match(wipeGuard({ base: stale, tags: editedTags(stale, t, true), target: t, follow: true, seen: [stale], appCount: 40, answered: 1, asked: 1 }), /had 40/, "the app's own count counts too")
  // Small lists are under the threshold, as on iOS: 10 -> 4 is allowed.
  const ten = contacts(many.slice(0, 10), T0 + 100), four = contacts(many.slice(0, 4), T0 + 200)
  assert.equal(wipeGuard({ base: four, tags: editedTags(four, t, true), target: t, follow: true, seen: [ten, four], answered: 1, asked: 1 }), "")
})

test("guard: one deliberate unfollow always passes, even the last follow; an empty list otherwise never does", () => {
  const a = pk()
  const one = contacts([a], T0 + 100)
  assert.equal(wipeGuard({ base: one, tags: editedTags(one, a, false), target: a, follow: false, seen: [one], answered: 1, asked: 1 }), "")
  const none = contacts([], T0 + 100)
  assert.match(wipeGuard({ base: none, tags: editedTags(none, a, false), target: a, follow: false, seen: [none], answered: 1, asked: 1 }), /empty/)
})

test("follow builds on the newest list (network beats an older vault copy), keeps content, and is newer than it", async () => {
  const a = pk(), b = pk(), t = pk()
  const vaultOld = contacts([a], T0 + 100), netNew = contacts([a, b], T0 + 300, [["t", "x"]])
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
  const vault = fakeVault([contacts(many, T0 + 100)])
  const stale = contacts(many.slice(0, 3), T0 + 200)
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
  const r = await run({ vault: fakeVault([contacts([a, b, c], T0 + 100)]), target: b, follow: false })
  assert.deepEqual(followsOf(r.event), [a, c])
})

test("when no relay takes it, Haven isn't changed and the error says so", async () => {
  const base = contacts([pk()], T0 + 100)
  const vault = fakeVault([base])
  await assert.rejects(run({ vault, target: pk(), follow: true, publish: urls => urls.map(() => Promise.reject(new Error("blocked"))) }), /No relay took it/)
  assert.deepEqual(vault.outbox.evs, [base])
})

test("follow is done once one relay took it, while the others are still out; they all still get it", async () => {
  const base = contacts([pk()], T0 + 100)
  const vault = fakeVault([base])
  let release, sentTo
  const slow = new Promise((_, reject) => { release = () => reject(new Error("publish timed out")) })
  const t = pk()
  const r = await run({ vault, target: t, follow: true, writeRelays: ["wss://slow.example", "wss://quick.example"],
    publish: (urls, ev) => { sentTo = urls; return urls.map(u => (u === "wss://quick.example" ? Promise.resolve("") : slow)) } })
  assert.ok(followsOf(r.event).includes(t))
  assert.ok(sentTo.includes("wss://slow.example") && sentTo.includes("wss://quick.example"), "sent to every write relay")
  assert.equal(r.taken, "wss://quick.example")
  assert.equal(vault.outbox.evs.at(-1).id, r.event.id, "kept in Haven without waiting for the slow relay")
  release()
  const relays = await r.settled
  assert.deepEqual(relays.filter(x => x.ok).map(x => x.url), ["wss://quick.example"])
  assert.equal(relays.length, sentTo.length)
})

test("a signer that signs as another account is refused before anything is sent", async () => {
  const other = generateSecretKey()
  let sent = false
  await assert.rejects(run({ vault: fakeVault([contacts([pk()], T0 + 100)]), target: pk(), follow: true,
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
  // The screen asks the defaults at once, then only the write relays they didn't cover.
  let relays
  await syncPersonNotes(vault, them_pk, ["wss://their.write"], { defaults: false, query: async r => { relays = r; return [] } })
  assert.deepEqual(relays, ["wss://their.write"])
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

test("their lists: no 10002 on the first ask -> asked once more; found says whether one came back", async () => {
  const them = generateSecretKey(), them_pk = getPublicKey(them)
  const rl = finalizeEvent({ kind: 10002, created_at: 2, tags: [["r", "wss://theirs.example", "write"]], content: "" }, them)
  const k3 = finalizeEvent({ kind: 3, created_at: 5, tags: [["p", mePk]], content: "" }, them)
  let asks = 0
  const late = await fetchPersonLists(them_pk, [], { query: async () => (++asks === 1 ? [k3] : [rl]) })
  assert.equal(asks, 2)
  assert.deepEqual(late.relays.write, ["wss://theirs.example"])
  assert.ok(late.found)
  assert.ok(followsOf(late.contacts).includes(mePk), "the kind 3 from the first ask is kept")
  asks = 0
  const none = await fetchPersonLists(them_pk, [], { query: async () => { asks++; return [] } })
  assert.equal(asks, 2, "asked twice, no more")
  assert.equal(none.found, false)
  assert.deepEqual(none.relays.write, DEFAULT_RELAYS)
  asks = 0
  await fetchPersonLists(them_pk, [], { query: async () => { asks++; return [rl] } })
  assert.equal(asks, 1, "a 10002 on the first ask: no second")
})

test("their opening notes: waits for their write relays, and asks once more when it found nothing", async () => {
  const them = generateSecretKey(), them_pk = getPublicKey(them)
  const note = finalizeEvent({ kind: 1, created_at: 100, tags: [], content: "late" }, them)
  const lists = { relays: { read: DEFAULT_RELAYS, write: ["wss://theirs.example"] }, contacts: undefined, found: true }
  // Defaults empty, their relay answers: done after one pass, nothing re-asked.
  let calls = []
  const sync = (answer) => async (v, p, relays, o = {}) => { calls.push({ relays, o }); return syncPersonNotes(v, p, relays, { ...o, query: async () => answer(relays, o) }) }
  const got = await openPersonNotes(fakeVault(), them_pk, Promise.resolve(lists), { sync: sync(r => (r.includes("wss://theirs.example") ? [note] : [])) })
  assert.deepEqual(got.map(n => n.id), [note.id])
  assert.equal(calls.length, 2)
  assert.deepEqual(calls[1].relays, ["wss://theirs.example"])
  // Nothing anywhere on the first pass, the note on the retry: the retry asks theirs + defaults with a longer wait.
  const them2 = generateSecretKey(), pk2 = getPublicKey(them2)
  const note2 = finalizeEvent({ kind: 1, created_at: 100, tags: [], content: "retry" }, them2)
  calls = []
  const got2 = await openPersonNotes(fakeVault(), pk2, Promise.resolve(lists), { sync: sync((r, o) => (o.maxWait ? [note2] : [])) })
  assert.deepEqual(got2.map(n => n.id), [note2.id])
  assert.equal(calls.length, 3, "one retry")
  assert.equal(calls[2].o.maxWait, 12000)
  assert.notEqual(calls[2].o.defaults, false, "the retry also asks the defaults")
  assert.deepEqual(calls[2].relays, ["wss://theirs.example"])
  // Still nothing after the retry: no third ask.
  calls = []
  const pk3 = getPublicKey(generateSecretKey())
  assert.deepEqual(await openPersonNotes(fakeVault(), pk3, Promise.resolve(lists), { sync: sync(() => []) }), [])
  assert.equal(calls.length, 3)
})
