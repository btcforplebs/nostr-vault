// Edit Profile (src/net/profile-edit.js): a kind 0 replaces the whole profile, so a save merges only the changed
// fields onto the newest copy, keeps its tags and other keys, and publishes nothing when that copy can't be found.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { merge, hasChanges, formFields, parseContent, latestProfile, saveProfile, localProfile } from "../src/net/profile-edit.js"
import { getProfile } from "../src/net/profiles.js"
import { PROFILE_RELAYS } from "../src/net/pool.js"

const me = generateSecretKey(), mePk = getPublicKey(me)
const T0 = Math.floor(Date.now() / 1000) - 3600
const kind0 = (content, at, tags = [], sk = me) => finalizeEvent({ kind: 0, created_at: at, tags, content: JSON.stringify(content) }, sk)

function fakeVault(outbox = [], feed = []) {
  const route = evs => ({
    evs,
    async query(f) { return evs.filter(e => (!f.kinds || f.kinds.includes(e.kind)) && (!f.authors || f.authors.includes(e.pubkey))) },
    async event(ev) { evs.push(ev); return { ok: true } },
  })
  return { outbox: route([...outbox]), feed: route([...feed]) }
}
const ctxWith = (vault, over = {}) => ({
  vault, session: { pubkey: mePk }, account: { relays: { read: ["wss://r.example"], write: ["wss://w.example"] } },
  signer: { signEvent: async t => finalizeEvent(t, me) }, ...over,
})
const okPublish = urls => urls.map(() => Promise.resolve(""))

test("merge changes only edited fields, removes cleared ones, keeps keys the form doesn't show", () => {
  const base = { name: "sat", about: "relay copy, newer", lud06: "lnurl1x", bot: false, website: "a.com" }
  const initial = { ...formFields(), name: "sat", about: "cached copy", website: "a.com" }
  const edited = { ...initial, name: "  satoshi ", website: "" }
  assert.deepEqual(merge(base, initial, edited), { name: "satoshi", about: "relay copy, newer", lud06: "lnurl1x", bot: false })
})

test("hasChanges ignores spaces a save trims", () => {
  const f = { ...formFields(), name: "sat" }
  assert.equal(hasChanges(f, { ...f, name: " sat\n" }), false)
  assert.equal(hasChanges(f, { ...f, about: "hi" }), true)
})

test("parseContent and formFields take only a JSON object's string fields", () => {
  assert.deepEqual(parseContent("[1]"), {})
  assert.deepEqual(parseContent("nope"), {})
  assert.equal(formFields({ content: JSON.stringify({ name: 5, about: "x" }) }).name, "")
  assert.equal(formFields({ content: JSON.stringify({ name: 5, about: "x" }) }).about, "x")
})

test("localProfile picks the newest of outbox and feed", async () => {
  const old = kind0({ name: "old" }, T0), fresh = kind0({ name: "new" }, T0 + 5)
  assert.equal((await localProfile(fakeVault([old], [fresh]), mePk)).id, fresh.id)
})

test("latestProfile: newest of Haven and relays; a forged or someone else's kind 0 doesn't count", async () => {
  const local = kind0({ name: "local" }, T0)
  const net = kind0({ name: "net" }, T0 + 10)
  const forged = { ...kind0({ name: "forged" }, T0 + 99), content: JSON.stringify({ name: "evil" }) }
  const other = kind0({ name: "other" }, T0 + 50, [], generateSecretKey())
  const r = await latestProfile(ctxWith(fakeVault([local])), { ask: async () => ({ events: [net, forged, other], answered: true }) })
  assert.equal(r.event.id, net.id)
  assert.equal(r.confirmedNone, false)
})

test("latestProfile: none anywhere is confirmed only when every relay answered", async () => {
  const all = await latestProfile(ctxWith(fakeVault()), { ask: async () => ({ events: [], answered: true }) })
  assert.equal(all.confirmedNone, true)
  let i = 0
  const some = await latestProfile(ctxWith(fakeVault()), { ask: async () => ({ events: [], answered: i++ > 0 }) })
  assert.equal(some.confirmedNone, false)
})

test("save refuses when the newest copy couldn't be found and not every relay said none", async () => {
  let published = false
  await assert.rejects(
    saveProfile(ctxWith(fakeVault()), formFields(), { ...formFields(), name: "x" }, { lookup: async () => ({ event: undefined, confirmedNone: false }), publish: urls => { published = true; return okPublish(urls) } }),
    /Couldn't load your current profile/)
  assert.equal(published, false)
})

test("save merges onto the newest copy, keeps its tags, dates after it, publishes to write + purplepag.es, shows it", async () => {
  const future = Math.floor(Date.now() / 1000) + 600
  const prev = kind0({ name: "sat", lud06: "lnurl1x", about: "hi" }, future, [["i", "github:sat", "proof"]])
  const vault = fakeVault()
  const initial = formFields(kind0({ name: "sat", about: "hi" }, T0))
  let sentTo
  const { event } = await saveProfile(ctxWith(vault), initial, { ...initial, display_name: "Satoshi" },
    { lookup: async () => ({ event: prev, confirmedNone: false }), publish: (urls, ev) => { sentTo = urls; return okPublish(urls) } })
  assert.deepEqual(JSON.parse(event.content), { name: "sat", lud06: "lnurl1x", about: "hi", display_name: "Satoshi" })
  assert.deepEqual(event.tags, [["i", "github:sat", "proof"]])
  assert.equal(event.created_at, future + 1)
  assert.ok(sentTo.includes("wss://w.example") && PROFILE_RELAYS.every(u => sentTo.includes(u)))
  assert.equal(vault.outbox.evs[0].id, event.id)
  assert.equal(getProfile(mePk).name, "Satoshi")
})

test("save with no profile anywhere (confirmed) publishes just the typed fields", async () => {
  const { event } = await saveProfile(ctxWith(fakeVault()), formFields(), { ...formFields(), name: "new" },
    { lookup: async () => ({ event: undefined, confirmedNone: true }), publish: okPublish })
  assert.deepEqual(JSON.parse(event.content), { name: "new" })
  assert.deepEqual(event.tags, [])
})

test("save throws when no relay took it, and keeps nothing in the outbox", async () => {
  const vault = fakeVault()
  await assert.rejects(saveProfile(ctxWith(vault), formFields(), { ...formFields(), name: "n" },
    { lookup: async () => ({ event: undefined, confirmedNone: true }), publish: urls => urls.map(() => Promise.reject(new Error("blocked"))) }), /No relay took it/)
  assert.equal(vault.outbox.evs.length, 0)
})

test("save refuses a signer that signs as another account", async () => {
  const other = generateSecretKey()
  await assert.rejects(saveProfile(ctxWith(fakeVault(), { signer: { signEvent: async t => finalizeEvent(t, other) } }), formFields(), { ...formFields(), name: "n" },
    { lookup: async () => ({ event: undefined, confirmedNone: true }), publish: okPublish }), /different account/)
})
