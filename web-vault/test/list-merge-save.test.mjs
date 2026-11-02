// Saving a merged list: refuses an empty result, an unknown newest list, a list that changed since the merge, an
// undo copy that couldn't be kept, and a signer that signs as someone else; dates the new version after the one it
// replaces, keeps kind 3's content, encrypts private entries to the user, and judges success on the user's own
// relays. Throwaway keys, a fake vault and a stubbed publish: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import { saveMerged, keepUndoCopy } from "../src/net/list-merge-save.js"
import { ListNotSaved } from "../src/net/list-edit.js"
import { findVersions, listOverview } from "../src/net/list-versions.js"

const SK = generateSecretKey(), ME = getPublicKey(SK)
const OTHER = generateSecretKey()
const KEY = nip44.v2.utils.getConversationKey(SK, ME)
const P = n => n.toString(16).padStart(64, "0")
const ev = (kind, tags, created_at, content = "", sk = SK) => finalizeEvent({ kind, created_at, tags, content }, sk)
const now = () => Math.floor(Date.now() / 1000)

function fakeVault({ refuse = "", historyHolds = true } = {}) {
  const outbox = [], lists = []
  return {
    outbox: {
      stored: outbox,
      event: async e => { if (Object.keys(e).some(k => !["id", "pubkey", "created_at", "kind", "tags", "content", "sig"].includes(k))) throw new Error("haven: no answer to EVENT"); if (refuse) return { ok: false, message: refuse }; outbox.push(e); if (historyHolds) lists.push(e); return { ok: true, message: "" } },
      query: async () => outbox,
    },
    lists: { query: async f => lists.filter(e => !f.ids || f.ids.includes(e.id)) },
  }
}
function ctxFor({ vault = fakeVault(), sk = SK } = {}) {
  return {
    vault,
    session: { pubkey: ME },
    account: { relays: { read: ["wss://r1.example"], write: ["wss://w1.example", "wss://w2.example"], listed: ["wss://w1.example", "wss://w2.example"] } },
    signer: {
      signEvent: async t => finalizeEvent({ ...t }, sk),
      crypto: { encrypt: async (peer, text) => nip44.v2.encrypt(text, nip44.v2.utils.getConversationKey(SK, peer)) },
    },
  }
}
const memStore = () => { const m = new Map(); return { all: async () => [...m.values()], put: async s => { m.set(s.id, s) }, remove: async id => { m.delete(id) } } }
const okPublish = (urls) => urls.map(() => Promise.resolve(""))
const latestIs = (event, checked = true) => async () => ({ event, checked })

test("saves after the one it replaces, keeps kind 3's content, keeps the undo copy first", async () => {
  const base = ev(3, [["p", P(1)]], now() + 60, '{"wss://keep":{}}')
  const ctx = ctxFor(), store = memStore()
  const r = await saveMerged(ctx, 3, { base, tags: [["p", P(1)], ["p", P(2)]], latest: latestIs(base), publish: okPublish, store })
  assert.equal(r.event.created_at, base.created_at + 1)
  assert.equal(r.event.content, base.content)
  assert.deepEqual(r.event.tags, [["p", P(1)], ["p", P(2)]])
  assert.equal(r.took, 2)
  assert.ok(ctx.vault.outbox.stored.some(e => e.id === base.id), "the replaced version went to the vault (its history) first")
  assert.ok((await store.all()).some(s => s.id === base.id), "and to Following Backup")
  assert.ok(ctx.vault.outbox.stored.some(e => e.id === r.event.id))
})

test("a version as the page holds it (with where it was found) goes to the vault as a plain event", async () => {
  const base = ev(10003, [["e", P(1)]], 100)
  const r = await saveMerged(ctxFor(), 10003, { base: { ...base, from: ["relays"] }, tags: [["e", P(2)]], latest: latestIs(base), publish: okPublish })
  assert.equal(r.event.created_at > 100, true)
})

test("private entries are encrypted to the user; none means an empty content", async () => {
  const base = ev(10000, [["p", P(1)]], 100, "old-cipher")
  await assert.rejects(saveMerged(ctxFor(), 10000, { base, tags: [["p", P(1)]], privateTags: [["p", P(2)]], latest: latestIs(base), publish: okPublish }),
    /couldn't be opened, so saving would wipe it/, "a private part not read is refused here, not only by the page (Tron, PR 1570)")
  const r = await saveMerged(ctxFor(), 10000, { base, baseOpened: true, tags: [["p", P(1)]], privateTags: [["p", P(2)]], latest: latestIs(base), publish: okPublish })
  assert.deepEqual(JSON.parse(nip44.v2.decrypt(r.event.content, KEY)), [["p", P(2)]])
  const r2 = await saveMerged(ctxFor(), 10000, { base, baseOpened: true, tags: [["p", P(1)]], privateTags: [], latest: latestIs(base), publish: okPublish })
  assert.equal(r2.event.content, "", "every private entry unticked: no private part")
})

test("refuses an empty result, an unknown list, and a list that changed since", async () => {
  const base = ev(10003, [["e", P(1)]], 100)
  await assert.rejects(saveMerged(ctxFor(), 10003, { base, tags: [["client", "x"]], latest: latestIs(base), publish: okPublish }), /would be empty/)
  await assert.rejects(saveMerged(ctxFor(), 10003, { base, tags: [["e", P(2)]], latest: latestIs(base, false), publish: okPublish }),
    e => e instanceof ListNotSaved && !e.checked)
  const newer = ev(10003, [["e", P(3)]], 200)
  await assert.rejects(saveMerged(ctxFor(), 10003, { base, tags: [["e", P(2)]], latest: latestIs(newer), publish: okPublish }),
    e => e instanceof ListNotSaved && e.checked && e.latest.id === newer.id)
})

test("nothing is signed when the undo copy can't be kept", async () => {
  const base = ev(10003, [["e", P(1)]], 100)
  let signed = 0
  for (const vault of [fakeVault({ refuse: "blocked: full" }), fakeVault({ historyHolds: false })]) {
    const ctx = ctxFor({ vault })
    const sign = ctx.signer.signEvent
    ctx.signer.signEvent = t => { signed++; return sign(t) }
    await assert.rejects(saveMerged(ctx, 10003, { base, tags: [["e", P(2)]], latest: latestIs(base), publish: okPublish }), /couldn't be kept first/)
  }
  assert.equal(signed, 0)
  assert.equal(await keepUndoCopy(ctxFor(), null), "", "no current list: nothing to keep")
})

test("a relay list is never saved from here", async () => {
  const base = ev(10002, [["r", "wss://a.example"]], 100)
  await assert.rejects(saveMerged(ctxFor(), 10002, { base, tags: [["r", "wss://b.example"]], latest: latestIs(base), publish: okPublish }), /can't be merged/)
})

test("a signer that signs as another account is refused", async () => {
  const base = ev(10003, [["e", P(1)]], 100)
  await assert.rejects(saveMerged(ctxFor({ sk: OTHER }), 10003, { base, tags: [["e", P(2)]], latest: latestIs(base), publish: okPublish }), /different account/)
})

test("success needs one of the user's own write relays; the profile index alone isn't a save", async () => {
  const base = ev(10003, [["e", P(1)]], 100)
  const indexOnly = urls => urls.map(u => (u === "wss://purplepag.es" ? Promise.resolve("") : Promise.reject(new Error("down"))))
  await assert.rejects(saveMerged(ctxFor(), 10003, { base, tags: [["e", P(2)]], latest: latestIs(base), publish: indexOnly }), /0 of 2/)
})

test("a vault refusal after sending is reported, not swallowed", async () => {
  const base = ev(10003, [["e", P(1)]], 100)
  const vault = fakeVault()
  const put = vault.outbox.event
  vault.outbox.event = async e => (e.id === base.id ? put(e) : { ok: false, message: "blocked: no" })
  await assert.rejects(saveMerged(ctxFor({ vault }), 10003, { base, tags: [["e", P(2)]], latest: latestIs(base), publish: okPublish }), /vault refused it/)
})

test("versions: own and validly signed only, each once with where it was found, newest first, not future-dated", async () => {
  const a = ev(10003, [["e", P(1)]], 100), b = ev(10003, [["e", P(2)]], 200)
  const theirs = ev(10003, [["e", P(3)]], 300, "", OTHER)
  const future = ev(10003, [["e", P(4)]], now() + 3600)
  const tampered = { ...a, tags: [["e", P(9)]] }
  const ctx = ctxFor()
  const got = await findVersions(ctx, 10003, { sources: { vault: async () => [a, b, future], relays: async () => [a, theirs, tampered], browser: async () => { throw new Error("x") } } })
  assert.deepEqual(got.map(e => e.id), [b.id, a.id])
  assert.deepEqual(got[1].from, ["vault", "relays"])
  const vault = fakeVault()
  await vault.outbox.event(a); await vault.outbox.event(b)
  const over = await listOverview({ ...ctx, vault })
  assert.deepEqual(over.find(o => o.kind === 10003), { kind: 10003, name: "Bookmarks", versions: 2, newest: 200 })
  assert.equal(over.find(o => o.kind === 3).versions, 0)
})
