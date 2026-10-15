// A bunker (NIP-46) sign-in encrypts and decrypts through the bunker, so Messages and the private block list work
// as they do with an extension. The bunker here is a fake holding a throwaway key: nothing is published, and no real
// account signs anything.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import * as nip04 from "nostr-tools/nip04"
import { wrap } from "../src/signer/nip46.js"
import { cryptoFor, rumorFor, wrapFor, unwrap, loadMessages, getMessages, resetMessages, sendMessage, forgetUnopened, openMore, watchMessages, OPEN_BATCH, OPEN_LIMIT, LIVE_PER_MINUTE, MAX_REFUSALS, TROUBLE_UNREACHABLE } from "../src/net/dms.js"
import { decrypterFor, privateBlocks, loadBlocks, getBlocks } from "../src/net/blocks.js"

const A = generateSecretKey(), B = generateSecretKey()
const pk = sk => getPublicKey(sk)
const plain = ev => JSON.parse(JSON.stringify(ev))

// What a bunker app does with the user's key when asked over NIP-46: each method as BunkerSigner names it.
function fakeBunker(sk, calls = []) {
  const key = peer => nip44.getConversationKey(sk, peer)
  return {
    calls,
    signEvent: async t => { calls.push(["sign_event", t.kind]); return finalizeEvent(t, sk) },
    nip44Encrypt: async (peer, text) => { calls.push(["nip44_encrypt", peer]); return nip44.encrypt(text, key(peer)) },
    nip44Decrypt: async (peer, c) => { calls.push(["nip44_decrypt", peer]); return nip44.decrypt(c, key(peer)) },
    nip04Encrypt: async (peer, text) => { calls.push(["nip04_encrypt", peer]); return nip04.encrypt(sk, peer, text) },
    nip04Decrypt: async (peer, c) => { calls.push(["nip04_decrypt", peer]); return nip04.decrypt(sk, peer, c) },
    close() {},
  }
}
const bunkerSession = sk => ({ method: "nip46", pubkey: pk(sk), bunker: { pubkey: "e".repeat(64), relays: ["wss://bunker.invalid"] } })
// What an extension does for B, the other side of the conversation.
const extOf = sk => ({
  encrypt: async (peer, t) => nip44.encrypt(t, nip44.getConversationKey(sk, peer)),
  decrypt: async (peer, c) => nip44.decrypt(c, nip44.getConversationKey(sk, peer)),
  decrypt04: async (peer, c) => nip04.decrypt(sk, peer, c),
})
function fakeChat(seed = []) {
  const stored = [...seed]
  return {
    stored,
    query: async f => stored.filter(e => (!f.kinds || f.kinds.includes(e.kind)) && (!f["#p"] || e.tags.some(t => t[0] === "p" && f["#p"].includes(t[1])))),
    event: async ev => { if (ev.kind === 4) return { ok: false, message: "blocked" }; if (!stored.some(e => e.id === ev.id)) stored.push(plain(ev)); return { ok: true, message: "" } },
  }
}
const offline = async () => { throw new Error("network used") }
const slow = (chat, ms = 50) => ({ ...chat, query: async f => { await new Promise(r => setTimeout(r, ms)); return chat.query(f) } })

test("a bunker signer offers its nip44 and nip04 as Messages' crypto", async () => {
  const signer = wrap(Promise.resolve(fakeBunker(A)))
  assert.equal(cryptoFor(bunkerSession(A), { signer }), signer.crypto)
  for (const f of ["encrypt", "decrypt", "encrypt04", "decrypt04"]) assert.equal(typeof signer.crypto[f], "function", f)
})

test("a message both ways: the bunker seals and opens, the other side uses an extension", async () => {
  const calls = []
  const signer = wrap(Promise.resolve(fakeBunker(A, calls)))
  const env = { signer, crypto: signer.crypto, me: pk(A) }
  const toB = await wrapFor(rumorFor(pk(A), pk(B), "from the bunker"), env, pk(B))
  assert.equal((await unwrap(toB, extOf(B), pk(B))).content, "from the bunker")
  assert.deepEqual(calls, [["nip44_encrypt", pk(B)], ["sign_event", 13]], "the seal is encrypted to B and signed by the bunker")

  const benv = { signer: { signEvent: async t => finalizeEvent(t, B) }, crypto: extOf(B), me: pk(B) }
  const toA = await wrapFor(rumorFor(pk(B), pk(A), "to the bunker"), benv, pk(A))
  calls.length = 0
  const got = await unwrap(toA, signer.crypto, pk(A))
  assert.deepEqual({ from: got.from, peer: got.peer, content: got.content }, { from: pk(B), peer: pk(B), content: "to the bunker" })
  assert.deepEqual(calls.map(c => c[0]), ["nip44_decrypt", "nip44_decrypt"], "wrap, then seal")
  assert.equal(calls[1][1], pk(B), "the seal is opened against its signer")
})

test("a legacy kind 4 opens with the bunker's nip04", async () => {
  const signer = wrap(Promise.resolve(fakeBunker(A)))
  const old = finalizeEvent({ kind: 4, created_at: 100, tags: [["p", pk(A)]], content: nip04.encrypt(B, pk(A), "old style") }, B)
  resetMessages(pk(A))
  await loadMessages({ vault: {}, session: bunkerSession(A), signer }, ["wss://r"], { chat: fakeChat(), query: async (r, f) => (f.kinds.includes(4) && f["#p"] ? [old] : []) })
  assert.equal(getMessages().messages.get(old.id)?.content, "old style")
  assert.equal(getMessages().note, "")
})

test("send and read back with only the bunker: no extension, nothing published", async () => {
  const signer = wrap(Promise.resolve(fakeBunker(A)))
  const ctx = { vault: {}, session: bunkerSession(A), signer, account: { relays: { read: ["wss://read.example"], write: ["wss://write.example"] } } }
  const sent = []
  const publish = (urls, ev) => { sent.push(ev); return urls.map(() => Promise.resolve("")) }
  const chat = fakeChat()
  resetMessages(pk(A))
  await sendMessage(ctx, pk(B), "hello", { query: async () => [], chat, publish })
  const theirs = sent.find(e => e.tags.some(t => t[1] === pk(B)))
  assert.equal((await unwrap(theirs, extOf(B), pk(B))).content, "hello", "B opens what the bunker sent")
  // A fresh load reads the self-copy back out of /chat through the bunker.
  resetMessages(pk(A))
  await loadMessages(ctx, [], { chat, query: offline })
  assert.deepEqual([...getMessages().messages.values()].map(m => [m.peer, m.content]), [[pk(B), "hello"]])
})

test("the private block list opens through the bunker, NIP-44 or NIP-04", async () => {
  const B1 = "b".repeat(64), D1 = "d".repeat(64)
  const signer = wrap(Promise.resolve(fakeBunker(A)))
  const c44 = nip44.encrypt(JSON.stringify([["p", B1]]), nip44.getConversationKey(A, pk(A)))
  const c04 = nip04.encrypt(A, pk(A), JSON.stringify([["p", D1]]))
  const opener = await decrypterFor(bunkerSession(A), { signer })
  const list = content => finalizeEvent({ kind: 10000, created_at: 100, tags: [], content }, A)
  assert.deepEqual(await privateBlocks(list(c44), opener), { pubkeys: [B1], note: "" })
  assert.deepEqual(await privateBlocks(list(c04), opener), { pubkeys: [D1], note: "" })

  const stored = [finalizeEvent({ kind: 10000, created_at: 200, tags: [["p", "c".repeat(64)]], content: c44 }, A)]
  const vault = { outbox: { query: async () => stored, event: async () => ({ ok: true, message: "" }) } }
  await loadBlocks({ vault, session: bunkerSession(A), signer }, [], { query: async () => [] })
  assert.deepEqual([...getBlocks().blocked].sort(), [B1, "c".repeat(64)])
  assert.equal(getBlocks().privateNote, "")
})

test("a bunker that stops answering stops the run after one batch, says why, and a retry opens the rest", async () => {
  const benv = { signer: { signEvent: async t => finalizeEvent(t, B) }, crypto: extOf(B), me: pk(B) }
  const wraps = []
  for (let i = 0; i < OPEN_BATCH * 3; i++) wraps.push(await wrapFor(rumorFor(pk(B), pk(A), `m${i}`, 1000 + i), benv, pk(A)))
  const chat = fakeChat(wraps)
  const bunker = fakeBunker(A)
  const real = bunker.nip44Decrypt
  let asked = 0
  bunker.nip44Decrypt = () => { asked++; return new Promise(() => {}) } // gone: never answers
  const signer = wrap(Promise.resolve(bunker), { ms: 30 })
  resetMessages(pk(A))
  await loadMessages({ vault: {}, session: bunkerSession(A), signer }, [], { chat, query: offline })
  const m = getMessages()
  assert.equal(asked, OPEN_BATCH, "one batch asked, not every wrap waiting out the timeout")
  assert.match(m.trouble, /didn't answer/)
  assert.equal(m.messages.size, 0)
  assert.equal(m.loaded, true)

  bunker.nip44Decrypt = real // back online
  await loadMessages({ vault: {}, session: bunkerSession(A), signer }, [], { chat, query: offline })
  assert.equal(getMessages().messages.size, OPEN_BATCH * 3, "the wraps not opened before are asked again")
  assert.equal(getMessages().trouble, "")
})

test("a bunker that refuses at first (\"no permission\") loses nothing: the run goes on, trouble says so, Try again opens the rest", async () => {
  const benv = { signer: { signEvent: async t => finalizeEvent(t, B) }, crypto: extOf(B), me: pk(B) }
  const wraps = []
  for (let i = 0; i < 10; i++) wraps.push(await wrapFor(rumorFor(pk(B), pk(A), `m${i}`, 1000 + i), benv, pk(A)))
  const bunker = fakeBunker(A)
  const real = bunker.nip44Decrypt
  let calls = 0
  bunker.nip44Decrypt = async (...a) => { if (++calls <= 8) throw new Error("no permission"); return real(...a) }
  const ctx = { vault: {}, session: bunkerSession(A), signer: wrap(Promise.resolve(bunker), { ms: 1000 }) }
  const chat = fakeChat(wraps)
  resetMessages(pk(A))
  await loadMessages(ctx, [], { chat, query: offline })
  assert.equal(getMessages().messages.size, 2, "the first batch of 8 was refused, the last 2 opened")
  assert.equal(getMessages().trouble, "Your signer didn't open 8 messages.")
  // Try again (MessagesScreen retry): forget what isn't open, load again.
  forgetUnopened()
  assert.equal(getMessages().trouble, "")
  await loadMessages(ctx, [], { chat, query: offline })
  assert.equal(getMessages().messages.size, 10, "nothing was lost for the session")
  assert.equal(getMessages().trouble, "")
})

test("a message that isn't the user's stays settled on a plain reload; Try again asks about it again", async () => {
  const benv = { signer: { signEvent: async t => finalizeEvent(t, B) }, crypto: extOf(B), me: pk(B) }
  // B seals a rumor to A that names nobody: it decrypts, but it isn't a message for A.
  const stray = await wrapFor({ ...rumorFor(pk(B), pk(A), "x"), tags: [] }, benv, pk(A))
  const calls = []
  const ctx = { vault: {}, session: bunkerSession(A), signer: wrap(Promise.resolve(fakeBunker(A, calls))) }
  resetMessages(pk(A))
  await loadMessages(ctx, [], { chat: fakeChat([stray]), query: offline })
  const asked = calls.length
  assert.ok(asked > 0)
  await loadMessages(ctx, [], { chat: fakeChat([stray]), query: offline })
  assert.equal(calls.length, asked, "not asked again")
  assert.equal(getMessages().trouble, "")
  // Try again asks about everything that isn't open, this one included.
  forgetUnopened()
  await loadMessages(ctx, [], { chat: fakeChat([stray]), query: offline })
  assert.ok(calls.length > asked, "Try again asked again")
})

test("the first load opens at most the bunker ceiling, newest first; Open more opens the next", async () => {
  const benv = { signer: { signEvent: async t => finalizeEvent(t, B) }, crypto: extOf(B), me: pk(B) }
  const n = OPEN_LIMIT.nip46 + 5
  const wraps = []
  for (let i = 0; i < n; i++) wraps.push(await wrapFor(rumorFor(pk(B), pk(A), `m${i}`, 1000 + i), benv, pk(A)))
  const ctx = { vault: {}, session: bunkerSession(A), signer: wrap(Promise.resolve(fakeBunker(A))) }
  resetMessages(pk(A))
  // Half from /chat, half from the network: one ceiling for the whole load.
  await loadMessages(ctx, ["wss://r.example"], { chat: fakeChat(wraps.slice(0, 20)), query: async (r, f) => (f.kinds[0] === 1059 ? wraps.slice(20) : []) })
  assert.equal(getMessages().messages.size, OPEN_LIMIT.nip46)
  assert.equal(getMessages().more, 5)
  assert.equal(OPEN_LIMIT.nip46 < OPEN_LIMIT.other, true)
  await openMore(ctx)
  assert.equal(getMessages().messages.size, n)
  assert.equal(getMessages().more, 0)
})

test("live messages through a bunker: a few a minute open as they come, the rest wait for Open more", async () => {
  const benv = { signer: { signEvent: async t => finalizeEvent(t, B) }, crypto: extOf(B), me: pk(B) }
  const ctx = { vault: {}, session: bunkerSession(A), signer: wrap(Promise.resolve(fakeBunker(A))) }
  let onevent, t = 1_000_000
  resetMessages(pk(A))
  watchMessages(ctx, ["wss://r.example"], { chat: fakeChat(), subscribe: (r, f, o) => { onevent = o.onevent; return { close() {} } }, clock: () => t })
  const burst = LIVE_PER_MINUTE.nip46 + 4
  for (let i = 0; i < burst; i++) await onevent(await wrapFor(rumorFor(pk(B), pk(A), `live${i}`), benv, pk(A)))
  assert.equal(getMessages().messages.size, LIVE_PER_MINUTE.nip46)
  assert.equal(getMessages().more, 4)
  t += 61_000
  await onevent(await wrapFor(rumorFor(pk(B), pk(A), "a minute later"), benv, pk(A)))
  assert.equal(getMessages().messages.size, LIVE_PER_MINUTE.nip46 + 1, "the next minute opens again")
  await openMore(ctx)
  assert.equal(getMessages().messages.size, burst + 1)
})

test("the bunker's silence and an unreachable relay are marked; its own errors aren't", async () => {
  const silent = wrap(Promise.resolve({ ...fakeBunker(A), nip04Encrypt: () => new Promise(() => {}) }), { ms: 20 })
  await assert.rejects(silent.crypto.encrypt04(pk(B), "x"), e => e.unreachable === true && /didn't answer/.test(e.message))
  const noRelay = wrap(Promise.resolve({ ...fakeBunker(A), nip44Encrypt: () => Promise.reject(new AggregateError([], "none")) }))
  await assert.rejects(noRelay.crypto.encrypt(pk(B), "x"), e => e.unreachable === true && /Couldn't reach/.test(e.message))
  const refusing = wrap(Promise.resolve({ ...fakeBunker(A), nip44Decrypt: () => Promise.reject(new Error("no")) }))
  await assert.rejects(refusing.crypto.decrypt(pk(B), "x"), e => !e.unreachable && e.message === "no")
})

// A gift wrap nobody can open: right shape, addressed to A, content that isn't NIP-44 for anyone.
const junkWrap = (at, i) => finalizeEvent({ kind: 1059, created_at: at, tags: [["p", pk(A)]], content: `junk-${i}-` + "A".repeat(80) }, generateSecretKey())

test("forty junk wraps newer than five real messages don't starve the inbox: real ones open, junk is settled after two refusals", async () => {
  const benv = { signer: { signEvent: async t => finalizeEvent(t, B) }, crypto: extOf(B), me: pk(B) }
  const real = []
  for (let i = 0; i < 5; i++) real.push(await wrapFor(rumorFor(pk(B), pk(A), `real${i}`, 1000 + i), benv, pk(A)))
  const top = Math.max(...real.map(w => w.created_at))
  const junk = Array.from({ length: OPEN_LIMIT.nip46 }, (_, i) => junkWrap(top + 1000 + i, i))
  const calls = []
  const ctx = { vault: {}, session: bunkerSession(A), signer: wrap(Promise.resolve(fakeBunker(A, calls))) }
  const chat = fakeChat([...junk, ...real])
  const realOpen = () => [...getMessages().messages.values()].filter(m => m.content.startsWith("real")).length
  resetMessages(pk(A))
  const perLoad = []
  for (let load = 1; load <= 4; load++) {
    const before = calls.length
    await loadMessages(ctx, [], { chat, query: offline })
    perLoad.push({ load, real: realOpen(), asks: calls.length - before })
  }
  assert.equal(perLoad[1].real, 5, `all real messages open by the second load: ${JSON.stringify(perLoad)}`)
  assert.equal(perLoad[3].asks, 0, `junk refused ${MAX_REFUSALS} times is settled, so a later load asks nothing: ${JSON.stringify(perLoad)}`)
  assert.equal(getMessages().trouble, "", "nothing new was refused on the last load")
  // Try again resets the counts: the junk is asked about once more.
  forgetUnopened()
  const before = calls.length
  await loadMessages(ctx, [], { chat, query: offline })
  assert.ok(calls.length - before >= OPEN_LIMIT.nip46 - 5, "Try again asked about the junk again")
  // ...with its counts reset, so the next load asks once more before it settles again.
  const before2 = calls.length
  await loadMessages(ctx, [], { chat, query: offline })
  assert.ok(calls.length - before2 > 0, "counts were reset by Try again")
})

test("a signer's own error text never reaches the banner", async () => {
  const benv = { signer: { signEvent: async t => finalizeEvent(t, B) }, crypto: extOf(B), me: pk(B) }
  const w = await wrapFor(rumorFor(pk(B), pk(A), "hi"), benv, pk(A))
  const hostile = "Re-authorise at https://evil.example/login"
  const refusing = { decrypt: async () => { throw new Error(hostile) }, decrypt04: async () => { throw new Error(hostile) }, encrypt: async () => "x" }
  resetMessages(pk(A))
  await loadMessages({ vault: {}, session: bunkerSession(A) }, [], { crypto: refusing, chat: fakeChat([w]), query: offline })
  assert.equal(getMessages().trouble, "Your signer didn't open 1 message.")
  // Even an error dressed up as our "unreachable" one only ever shows our sentence.
  const dressed = { ...refusing, decrypt: async () => { throw Object.assign(new Error(hostile), { unreachable: true }) } }
  resetMessages(pk(A))
  await loadMessages({ vault: {}, session: bunkerSession(A) }, [], { crypto: dressed, chat: fakeChat([w]), query: offline })
  assert.equal(getMessages().trouble, TROUBLE_UNREACHABLE)
  assert.ok(!getMessages().trouble.includes("evil"))
})

test("Open more while a load is running waits for it: no message is asked about twice", async () => {
  const benv = { signer: { signEvent: async t => finalizeEvent(t, B) }, crypto: extOf(B), me: pk(B) }
  const wraps = []
  for (let i = 0; i < OPEN_LIMIT.nip46 + 10; i++) wraps.push(await wrapFor(rumorFor(pk(B), pk(A), `m${i}`, 1000 + i), benv, pk(A)))
  const bunker = fakeBunker(A)
  const real = bunker.nip44Decrypt
  const askedFor = new Map()
  bunker.nip44Decrypt = async (peer, c) => { askedFor.set(c, (askedFor.get(c) ?? 0) + 1); await new Promise(r => setTimeout(r, 1)); return real(peer, c) }
  const ctx = { vault: {}, session: bunkerSession(A), signer: wrap(Promise.resolve(bunker)) }
  resetMessages(pk(A))
  // Seed "more" with a first load, then start another load and Open more together.
  await loadMessages(ctx, [], { chat: fakeChat(wraps), query: offline })
  askedFor.clear()
  forgetUnopened()
  const order = []
  await Promise.all([
    // A slow /chat read: without the guard, Open more would run (and finish) inside the load.
    loadMessages(ctx, [], { chat: slow(fakeChat(wraps)), query: offline }).then(() => order.push("load")),
    openMore(ctx).then(() => order.push("more")),
  ])
  assert.deepEqual(order, ["load", "more"], "Open more waits for the running load")
  assert.ok([...askedFor.values()].every(n => n === 1), "each ciphertext asked about once")
  assert.equal(getMessages().messages.size, wraps.length)
})

test("the load's budget is charged only for messages actually asked about", async () => {
  const benv = { signer: { signEvent: async t => finalizeEvent(t, B) }, crypto: extOf(B), me: pk(B) }
  const local = [], net = []
  for (let i = 0; i < 10; i++) local.push(await wrapFor(rumorFor(pk(B), pk(A), `l${i}`, 1000 + i), benv, pk(A)))
  for (let i = 0; i < OPEN_LIMIT.nip46; i++) net.push(await wrapFor(rumorFor(pk(B), pk(A), `n${i}`, 2000 + i), benv, pk(A)))
  const bunker = fakeBunker(A)
  const real = bunker.nip44Decrypt
  let silent = true
  bunker.nip44Decrypt = (...a) => (silent ? new Promise(() => {}) : real(...a))
  const ctx = { vault: {}, session: bunkerSession(A), signer: wrap(Promise.resolve(bunker), { ms: 30 }) }
  resetMessages(pk(A))
  // /chat: the bunker goes silent on the first batch, so only 8 of its 10 were asked; the network then gets the rest of
  // the ceiling, not a budget spent on the 2 never asked.
  const query = async (r, f) => { if (f.kinds[0] === 1059) { silent = false; return net } return [] }
  await loadMessages(ctx, ["wss://r.example"], { chat: fakeChat(local), query })
  assert.equal(getMessages().messages.size, OPEN_LIMIT.nip46 - OPEN_BATCH)
})
