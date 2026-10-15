// Blocking, unblocking and reporting from the web: the kind 10000 built on the newest list with every other entry kept,
// public blocks where the phone reads them (p tags), private ones NIP-44 encrypted to the user, the stale-list guard,
// and the iPhone's Report & Block. A fake bunker with a throwaway key signs; nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import * as nip04 from "nostr-tools/nip04"
import { wrap } from "../src/signer/nip46.js"
import { editedBlockList, blockGuard, setBlock, loadBlocks, getBlocks, resetBlocks, pTags, newestBlockList } from "../src/net/blocks.js"
import { REASONS, reportTemplate, reportAndBlock } from "../src/net/reports.js"

const sk = generateSecretKey()
const ME = getPublicKey(sk)
const A = "a".repeat(64), B = "b".repeat(64), C = "c".repeat(64)
const key = nip44.getConversationKey(sk, ME)
const open44 = c => JSON.parse(nip44.decrypt(c, key))
const seal44 = tags => nip44.encrypt(JSON.stringify(tags), key)

function fakeBunker(calls = []) {
  return {
    signEvent: async t => { calls.push(["sign_event", t.kind]); return finalizeEvent(t, sk) },
    nip44Encrypt: async (peer, text) => { calls.push(["nip44_encrypt", peer]); return nip44.encrypt(text, nip44.getConversationKey(sk, peer)) },
    nip44Decrypt: async (peer, c) => { calls.push(["nip44_decrypt", peer]); return nip44.decrypt(c, nip44.getConversationKey(sk, peer)) },
    nip04Encrypt: async (peer, text) => nip04.encrypt(sk, peer, text),
    nip04Decrypt: async (peer, c) => { calls.push(["nip04_decrypt", peer]); return nip04.decrypt(sk, peer, c) },
    close() {},
  }
}
const list = (tags, content = "", created_at = 100) => finalizeEvent({ kind: 10000, created_at, tags, content }, sk)
function fakeVault(seed = []) {
  const evs = [...seed]
  return { outbox: {
    stored: evs,
    query: async f => evs.filter(e => f.kinds.includes(e.kind) && f.authors.includes(e.pubkey)),
    event: async ev => { if (evs.some(e => e.id === ev.id)) return { ok: false, message: "duplicate: have it" }; evs.push(ev); return { ok: true, message: "" } },
  } }
}
// Each of the user's relays answers with its EOSE and whatever it holds.
const askWith = (byUrl = {}) => async url => (url in byUrl ? byUrl[url] : { events: [], answered: true })
const okPublish = sent => (urls, ev) => { sent.push(ev); return urls.map(() => Promise.resolve("")) }
const ctxOf = (vault, calls = []) => ({ vault, session: { method: "nip46", pubkey: ME }, signer: wrap(Promise.resolve(fakeBunker(calls))),
  account: { relays: { read: ["wss://r1.example"], write: ["wss://w1.example"] } } })

test("a public block adds a p tag and keeps every other entry and the private part as they were", async () => {
  const base = list([["p", A], ["t", "nsfw"], ["word", "scam"], ["e", "e".repeat(64)]], "unreadable-private-part")
  const { tags, content } = await editedBlockList(base, { target: B, block: true, crypto: null, me: ME })
  assert.deepEqual(tags, [["p", A], ["t", "nsfw"], ["word", "scam"], ["e", "e".repeat(64)], ["p", B]])
  assert.equal(content, "unreadable-private-part", "a private part this signer can't open is kept, not dropped")
})

test("a private block goes into the content, NIP-44 to the user, next to what was there", async () => {
  const signer = wrap(Promise.resolve(fakeBunker()))
  const base = list([["p", A]], seal44([["p", C], ["t", "spoilers"]]))
  const { tags, content } = await editedBlockList(base, { target: B, block: true, isPrivate: true, crypto: signer.crypto, me: ME })
  assert.deepEqual(tags, [["p", A]], "nothing public added")
  assert.deepEqual(open44(content), [["p", C], ["t", "spoilers"], ["p", B]])
})

test("an older NIP-04 private part is read and written back as NIP-44", async () => {
  const signer = wrap(Promise.resolve(fakeBunker()))
  const base = list([], nip04.encrypt(sk, ME, JSON.stringify([["p", C]])))
  const { content } = await editedBlockList(base, { target: B, block: true, isPrivate: true, crypto: signer.crypto, me: ME })
  assert.doesNotMatch(content, /\?iv=/)
  assert.deepEqual(open44(content), [["p", C], ["p", B]])
})

test("unblocking takes the person out of both parts; blocking publicly takes them out of the private part", async () => {
  const signer = wrap(Promise.resolve(fakeBunker()))
  const base = list([["p", A], ["p", B]], seal44([["p", B], ["p", C]]))
  const un = await editedBlockList(base, { target: B, block: false, crypto: signer.crypto, me: ME })
  assert.deepEqual(un.tags, [["p", A]])
  assert.deepEqual(open44(un.content), [["p", C]])
  const pub = await editedBlockList(list([], seal44([["p", C]])), { target: C, block: true, crypto: signer.crypto, me: ME })
  assert.deepEqual(pub.tags, [["p", C]])
  assert.deepEqual(open44(pub.content), [], "not on the list twice")
})

test("a private block refuses when the private part can't be opened, rather than overwrite it", async () => {
  await assert.rejects(editedBlockList(list([], "AgAAAA"), { target: B, block: true, isPrivate: true, crypto: null, me: ME }), /Couldn't block privately/)
  const refusing = { decrypt: async () => { throw new Error("no") }, decrypt04: async () => { throw new Error("no") }, encrypt: async () => "x" }
  await assert.rejects(editedBlockList(list([], "AgAAAA"), { target: B, block: true, isPrivate: true, crypto: refusing, me: ME }), /couldn't be opened \(no\)/)
})

test("no list yet: the first block starts one", async () => {
  const { tags, content } = await editedBlockList(undefined, { target: B, block: true, crypto: null, me: ME })
  assert.deepEqual(tags, [["p", B]]); assert.equal(content, "")
})

test("the guard: a list from the user's relays, or most of them answering; and no building on a shrunken copy", () => {
  assert.equal(blockGuard({ asked: 3, answered: 0, netFound: true }), "")
  assert.equal(blockGuard({ asked: 3, answered: 2, netFound: false }), "", "most answered and none had one: there is none yet")
  assert.match(blockGuard({ asked: 3, answered: 0, netFound: false }), /None of your relays answered/)
  assert.match(blockGuard({ asked: 4, answered: 2, netFound: false }), /Only 2 of your 4/)
  const small = list([["p", A], ["p", B]])
  assert.match(blockGuard({ asked: 1, answered: 1, netFound: true, base: small, known: 12 }), /holds 2 people but you had 12/)
  assert.equal(blockGuard({ asked: 1, answered: 1, netFound: true, base: small, known: 4 }), "", "small lists aren't second-guessed")
})

test("newest list wins; one dated far in the future is ignored", () => {
  const at = 1_000_000
  const a = list([["p", A]], "", at - 10), b = list([["p", B]], "", at - 5), future = list([["p", C]], "", at + 3600)
  assert.equal(newestBlockList([a, future, b], ME, at).id, b.id)
})

test("setBlock: built on the newest list from the relays, signed by the bunker, sent, kept, and shown at once", async () => {
  const old = list([["p", A]], "", 100)
  const newer = list([["p", A], ["p", C]], "", 200)
  const vault = fakeVault([old])
  const calls = [], sent = []
  const ctx = ctxOf(vault, calls)
  resetBlocks()
  await loadBlocks(ctx, [], { query: async () => [] })
  assert.deepEqual([...getBlocks().blocked], [A])
  const { event } = await setBlock(ctx, B, { ask: askWith({ "wss://r1.example": { events: [newer], answered: true } }), publish: okPublish(sent) })
  assert.deepEqual(pTags(event.tags), [A, C, B], "built on the relays' newer list, so C isn't lost")
  assert.ok(event.created_at > newer.created_at)
  assert.equal(sent.length, 1)
  assert.ok(vault.outbox.stored.some(e => e.id === event.id), "kept in Haven's outbox")
  assert.deepEqual([...getBlocks().blocked].sort(), [A, B, C].sort(), "the screens see it without a reload")
  assert.deepEqual(calls.map(c => c[0]), ["sign_event"], "a public block asks the bunker only to sign")

  const { event: un } = await setBlock(ctx, C, { block: false, ask: askWith(), publish: okPublish(sent) })
  assert.deepEqual(pTags(un.tags), [A, B])
  assert.ok(!getBlocks().blocked.has(C))
})

test("setBlock privately through the bunker: encrypted to the user, and read back as blocked", async () => {
  const vault = fakeVault([list([["p", A]], "", 100)])
  const ctx = ctxOf(vault)
  resetBlocks()
  await loadBlocks(ctx, [], { query: async () => [] })
  const { event } = await setBlock(ctx, B, { isPrivate: true, ask: askWith(), publish: okPublish([]) })
  assert.deepEqual(pTags(event.tags), [A])
  assert.deepEqual(open44(event.content), [["p", B]])
  assert.ok(getBlocks().blocked.has(B) && getBlocks().privateBlocked.has(B))
})

test("setBlock publishes nothing when the guard refuses or no relay takes it", async () => {
  const vault = fakeVault()
  const calls = []
  const ctx = ctxOf(vault, calls)
  resetBlocks()
  await loadBlocks(ctx, [], { query: async () => [] })
  await assert.rejects(setBlock(ctx, B, { ask: async () => ({ events: [], answered: false }), publish: okPublish([]) }), /None of your relays answered/)
  assert.deepEqual(calls, [], "not even signed")
  await assert.rejects(setBlock(ctx, B, { ask: askWith(), publish: urls => urls.map(() => Promise.reject(new Error("closed"))) }), /No relay took it/)
  assert.equal(vault.outbox.stored.length, 0)
  assert.ok(!getBlocks().blocked.has(B))
  await assert.rejects(setBlock(ctx, ME, { ask: askWith() }), /yourself/)
  await assert.rejects(setBlock(ctx, "nope", { ask: askWith() }), /isn't a profile that can be blocked/)
})

test("reports carry the NIP-56 type on what's reported, and the iPhone's reason tag", () => {
  const note = finalizeEvent({ kind: 1, created_at: 1, tags: [], content: "x" }, generateSecretKey())
  const r = reportTemplate({ note, reason: "spam", at: 5 })
  assert.deepEqual(r.tags, [["e", note.id, "spam"], ["p", note.pubkey], ["reason", "spam"]])
  assert.equal(r.kind, 1984); assert.equal(r.content, "Reported for Spam")
  const u = reportTemplate({ pubkey: A, reason: "violence", details: "  threats  " })
  assert.deepEqual(u.tags, [["p", A, "other"], ["reason", "violence"]], "NIP-56 has no violence type")
  assert.equal(u.content, "threats")
  assert.deepEqual(REASONS.map(x => x.id), ["spam", "nudity", "violence", "illegal", "impersonation", "other"], "the iPhone's list")
  assert.throws(() => reportTemplate({ pubkey: A, reason: "bogus" }), /reason/)
})

test("Report & Block: the report goes out, then the person is blocked; a failed block still says the report went", async () => {
  const vault = fakeVault()
  const ctx = ctxOf(vault)
  resetBlocks()
  await loadBlocks(ctx, [], { query: async () => [] })
  const sent = [], blocks = []
  const block = async (c, who) => { blocks.push(who) }
  const done = await reportAndBlock(ctx, { pubkey: A, reason: "spam" }, { publish: okPublish(sent), block })
  assert.equal(sent[0].kind, 1984); assert.deepEqual(blocks, [A]); assert.equal(done.blocked, true)

  const failed = await reportAndBlock(ctx, { pubkey: B, reason: "spam" }, { publish: okPublish([]), block: async () => { throw new Error("relays down") } })
  assert.deepEqual({ blocked: failed.blocked, blockError: failed.blockError }, { blocked: false, blockError: "relays down" })

  blocks.length = 0
  await assert.rejects(reportAndBlock(ctx, { pubkey: C, reason: "spam" }, { publish: urls => urls.map(() => Promise.reject(new Error("x"))), block }), /didn't go out/)
  assert.deepEqual(blocks, [], "no block without a report")
  await assert.rejects(reportAndBlock(ctx, { pubkey: ME, reason: "spam" }, { publish: okPublish([]), block }), /yourself/)
})
