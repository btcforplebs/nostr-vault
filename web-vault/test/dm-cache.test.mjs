// The inbox kept between reloads (dm-cache.js): a reload asks the signer once per chunk, not twice per message; what
// is stored is NIP-44 to the user's own key, never the text; a chunk that doesn't open is dropped and its messages come
// from their wraps again; sign-out and Reset Everything delete it. Throwaway keys, a fake /chat, nothing published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import { rumorFor, wrapFor, loadMessages, getMessages, resetMessages } from "../src/net/dms.js"
import { dmCache, cacheKey, CHUNK_BYTES } from "../src/net/dm-cache.js"
import { BunkerSigner } from "nostr-tools/nip46"
import { isAppKey } from "../src/net/reset-all.js"
import { accountKeys } from "../src/haven/vault.js"

const A = generateSecretKey(), B = generateSecretKey(), C = generateSecretKey()
const pk = sk => getPublicKey(sk)
const ME = pk(A)
// A NIP-07 extension with the key in hand, counting what it's asked.
const cryptoOf = (sk, asked = { enc: 0, dec: 0 }, { refuse = false } = {}) => ({
  asked,
  encrypt: async (peer, t) => { asked.enc++; return nip44.encrypt(t, nip44.getConversationKey(sk, peer)) },
  decrypt: async (peer, c) => { asked.dec++; if (refuse) throw new Error("declined"); return nip44.decrypt(c, nip44.getConversationKey(sk, peer)) },
})
const fakeStorage = (session = { pubkey: ME }) => {
  const m = new Map([["nv-session", JSON.stringify(session)]])
  return { m, get length() { return m.size }, key: i => [...m.keys()][i] ?? null, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }
}
const fakeChat = seed => ({ query: async () => seed, event: async () => ({ ok: true }) })
const ctx = { vault: {}, session: { method: "nip07", pubkey: ME }, signer: { signEvent: async t => finalizeEvent(t, A) } }
const wrapsFrom = async (n, text = i => `secret message ${i}`) => {
  const env = { signer: { signEvent: async t => finalizeEvent(t, B) }, crypto: cryptoOf(B), me: pk(B) }
  return Promise.all(Array.from({ length: n }, (_, i) => wrapFor(rumorFor(pk(B), ME, text(i), 1000 + i), env, ME)))
}
const reload = () => resetMessages(pk(C)) // another account in between: the module forgets everything in memory
const load = (wraps, crypto, storage) => loadMessages(ctx, [], { crypto, chat: fakeChat(wraps), cache: { storage, writeAfter: 0 } })
const settle = () => new Promise(r => setTimeout(r, 30))

test("a reload opens the kept chunk with one signer request instead of two per message", async () => {
  const storage = fakeStorage(), wraps = await wrapsFrom(12)
  reload()
  const first = cryptoOf(A)
  await load(wraps, first, storage)
  assert.equal(getMessages().messages.size, 12)
  assert.equal(first.asked.dec, 24, "two per message the first time")
  await settle()
  assert.equal(first.asked.enc, 1, "one chunk written")

  reload()
  const again = cryptoOf(A)
  await load(wraps, again, storage)
  assert.equal(getMessages().messages.size, 12)
  assert.equal(again.asked.dec, 1, "one request: the chunk")
  assert.deepEqual([...getMessages().messages.values()].map(m => m.content).sort(), wraps.map((_, i) => `secret message ${i}`).sort())

  // A new message after the reload is the only one opened, and joins the kept chunk.
  const [extra] = await wrapsFrom(1, () => "a new one")
  reload()
  const third = cryptoOf(A)
  await load([...wraps, extra], third, storage)
  assert.equal(third.asked.dec, 1 + 2)
  assert.equal(getMessages().messages.size, 13)
})

test("nothing stored is plain text: chunks are NIP-44 to the user's own key, per account", async () => {
  const storage = fakeStorage(), wraps = await wrapsFrom(3)
  reload()
  await load(wraps, cryptoOf(A), storage)
  await settle()
  const raw = storage.getItem(cacheKey(ME))
  assert.ok(raw)
  assert.doesNotMatch(raw, /secret message/)
  assert.doesNotMatch(raw, new RegExp(pk(B)), "not even who wrote")
  const { chunks } = JSON.parse(raw)
  const opened = JSON.parse(nip44.decrypt(chunks[0], nip44.getConversationKey(A, ME)))
  assert.equal(opened.me, ME)
  assert.equal(opened.m.length, 3)
  // Someone else's key opens nothing.
  assert.throws(() => nip44.decrypt(chunks[0], nip44.getConversationKey(C, ME)))
})

test("sign-out, removing the account and Reset Everything delete it", () => {
  const storage = fakeStorage()
  storage.setItem(cacheKey(ME), "x")
  assert.ok(accountKeys(ME, storage).includes(cacheKey(ME)), "sign-out drops every key ending :<pubkey>")
  assert.ok(isAppKey(cacheKey(ME)), "Reset Everything drops nv- keys")
})

test("a chunk that doesn't open is dropped, never blocks the inbox, and is rebuilt from the wraps", async () => {
  const storage = fakeStorage(), wraps = await wrapsFrom(4)
  reload()
  await load(wraps, cryptoOf(A), storage)
  await settle()

  // The signer refuses the chunk (and then opens the wraps): the inbox still fills.
  reload()
  let n = 0
  const picky = cryptoOf(A)
  const dec = picky.decrypt
  picky.decrypt = async (peer, c) => { if (n++ === 0) throw new Error("declined"); return dec(peer, c) }
  await load(wraps, picky, storage)
  assert.equal(getMessages().messages.size, 4)
  await settle()

  // Garbage where a chunk was: dropped, and the messages come from the wraps.
  storage.setItem(cacheKey(ME), JSON.stringify({ v: 1, chunks: ["not a chunk"] }))
  reload()
  const c2 = cryptoOf(A)
  await load(wraps, c2, storage)
  assert.equal(getMessages().messages.size, 4)
  assert.equal(c2.asked.dec, 1 + 8)
  await settle()
  const { chunks } = JSON.parse(storage.getItem(cacheKey(ME)))
  assert.equal(chunks.length, 1)
  assert.notEqual(chunks[0], "not a chunk")

  // A signer that never answers: the chunk is given up on after `wait`, the inbox loads anyway.
  const k = dmCache(ME, { decrypt: () => new Promise(() => {}) }, { storage, wait: 20 })
  assert.deepEqual(await k.restore(), { messages: [], junk: [] })
})

test("wraps that aren't the user's are kept as settled, so a reload doesn't ask about them", async () => {
  const storage = fakeStorage()
  const [mine] = await wrapsFrom(1)
  // A wrap and seal to me holding a message that names someone else: it opens, and it isn't mine.
  const env = { signer: { signEvent: async t => finalizeEvent(t, B) }, crypto: cryptoOf(B), me: pk(B) }
  const junk = await wrapFor(rumorFor(pk(B), pk(C), "not for A", 5), env, ME)
  reload()
  await load([mine, junk], cryptoOf(A), storage)
  await settle()
  reload()
  const again = cryptoOf(A)
  await load([mine, junk], again, storage)
  assert.equal(again.asked.dec, 1, "the chunk only")
})

test("nothing is written once the account isn't the signed-in one (another tab signed out)", async () => {
  const storage = fakeStorage({ pubkey: pk(C) }), wraps = await wrapsFrom(2)
  reload()
  await load(wraps, cryptoOf(A), storage)
  await settle()
  assert.equal(storage.getItem(cacheKey(ME)), null)
})

test("chunks stay under the NIP-44 limit and fill before a new one starts", async () => {
  const storage = fakeStorage()
  const k = dmCache(ME, cryptoOf(A), { storage, writeAfter: 0 })
  const big = "x".repeat(5000)
  for (let i = 0; i < 30; i++) k.add({ id: i.toString(16).padStart(64, "0"), from: pk(B), peer: pk(B), content: big, at: i, legacy: false })
  await k.flush()
  const { chunks } = JSON.parse(storage.getItem(cacheKey(ME)))
  assert.equal(chunks.length, 3)
  const sizes = chunks.map(c => new TextEncoder().encode(nip44.decrypt(c, nip44.getConversationKey(A, ME))).length)
  assert.ok(sizes.every(s => s <= CHUNK_BYTES.other), String(sizes))
  const k2 = dmCache(ME, cryptoOf(A), { storage })
  assert.equal((await k2.restore()).messages.length, 30)
})

test("a message kept while the cache was still opening isn't lost", async () => {
  const storage = fakeStorage()
  const k = dmCache(ME, cryptoOf(A), { storage, writeAfter: 0 })
  const m = i => ({ id: i.toString(16).padStart(64, "0"), from: pk(B), peer: pk(B), content: `m${i}`, at: i, legacy: false })
  k.add(m(1)); await k.flush()
  const k2 = dmCache(ME, cryptoOf(A), { storage, writeAfter: 0 })
  const restoring = k2.restore()
  k2.add(m(2)) // arrived live before the stored chunk opened
  assert.deepEqual((await restoring).messages.map(x => x.content), ["m1"])
  await k2.flush()
  const k3 = dmCache(ME, cryptoOf(A), { storage })
  assert.deepEqual((await k3.restore()).messages.map(x => x.content).sort(), ["m1", "m2"])
})

// Through a bunker each chunk is one NIP-46 request, and its ciphertext one answer: both NIP-44 (at most 65,535 bytes
// of plain text) inside a kind 24133, which relays such as strfry cap at 64 KB. A full chunk of the worst text (every
// character one JSON escapes doubles) goes through nostr-tools' own BunkerSigner here, and every leg must fit.
test("through a bunker a full chunk, its request and the bunker's answer all fit NIP-44 and a 64 KB event", async () => {
  // Text JSON escapes (the chunk's escaped size doubles), and plain text (then the chunk itself is largest).
  for (const big of ['"\\'.repeat(400) + "é🙂".repeat(100), "plain words ".repeat(100)]) await bunkerLegs(big)
})

async function bunkerLegs(big) {
  const LIMIT = 65_535, EVENT = 64 * 1024
  const written = []
  const k = dmCache(ME, { encrypt: async (peer, t) => { written.push(t); return nip44.encrypt(t, nip44.getConversationKey(A, peer)) } }, { storage: fakeStorage(), writeAfter: 0, chunkBytes: CHUNK_BYTES.nip46 })
  for (let i = 0; i < 80; i++) k.add({ id: i.toString(16).padStart(64, "0"), from: pk(B), peer: pk(B), content: big, at: i, legacy: false })
  await k.flush()
  const full = written.reduce((a, b) => (b.length > a.length ? b : a))
  assert.ok(written.length >= 2, "it filled at least one chunk")

  // The real BunkerSigner, its relay a stub that keeps what it would publish (nothing leaves this test).
  const client = generateSecretKey(), bunker = generateSecretKey()
  const sent = []
  const pool = { publish: (_r, ev) => { sent.push(ev); return [Promise.resolve("")] }, subscribe: () => ({ close() {} }), subscribeMany: () => ({ close() {} }) }
  const signer = BunkerSigner.fromBunker(client, { pubkey: pk(bunker), relays: ["wss://bunker.example"], secret: null }, { pool })
  const ciphertext = nip44.encrypt(full, nip44.getConversationKey(A, ME))
  signer.nip44Encrypt(ME, full).catch(() => {})
  signer.nip44Decrypt(ME, ciphertext).catch(() => {})
  await settle()
  assert.equal(sent.length, 2)
  const ck = nip44.getConversationKey(bunker, pk(client))
  const legs = sent.map(ev => ({ plain: new TextEncoder().encode(nip44.decrypt(ev.content, ck)).length, event: new TextEncoder().encode(JSON.stringify(ev)).length }))
  // The bunker's answers: the ciphertext to an encrypt, the chunk to a decrypt.
  for (const result of [ciphertext, full]) {
    const body = JSON.stringify({ id: "x".repeat(16), result })
    const ev = finalizeEvent({ kind: 24133, created_at: 1, tags: [["p", pk(client)]], content: nip44.encrypt(body, ck) }, bunker)
    legs.push({ plain: new TextEncoder().encode(body).length, event: new TextEncoder().encode(JSON.stringify(ev)).length })
  }
  for (const l of legs) assert.ok(l.plain <= LIMIT && l.event <= EVENT, JSON.stringify(legs))
  signer.close?.()
}
