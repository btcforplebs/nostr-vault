// Muted words from the web (net/muted-words.js): `word` entries in the kind 10000, private by default, every other
// entry kept, through blocking's guarded publish. A fake bunker with a throwaway key signs; nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import { wrap } from "../src/signer/nip46.js"
import { loadBlocks, getBlocks, resetBlocks } from "../src/net/blocks.js"
import { editedWordList, setMutedWord, mutedWordKey, mutedWordProblem, mutedWordSections, MUTED_WORD_MAX } from "../src/net/muted-words.js"

const sk = generateSecretKey()
const ME = getPublicKey(sk)
const A = "a".repeat(64), C = "c".repeat(64), E = "e".repeat(64)
const key = nip44.getConversationKey(sk, ME)
const open44 = c => JSON.parse(nip44.decrypt(c, key))
const seal44 = tags => nip44.encrypt(JSON.stringify(tags), key)
function fakeBunker(calls = []) {
  return {
    signEvent: async t => { calls.push(["sign_event", t.kind]); return finalizeEvent(t, sk) },
    nip44Encrypt: async (peer, text) => { calls.push(["nip44_encrypt", peer]); return nip44.encrypt(text, nip44.getConversationKey(sk, peer)) },
    nip44Decrypt: async (peer, c) => { calls.push(["nip44_decrypt", peer]); return nip44.decrypt(c, nip44.getConversationKey(sk, peer)) },
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
const askWith = (byUrl = {}) => async url => (url in byUrl ? byUrl[url] : { events: [], answered: true })
const okPublish = sent => (urls, ev) => { sent.push(ev); return urls.map(() => Promise.resolve("")) }
const ctxOf = (vault, bunker = fakeBunker()) => ({ vault, session: { method: "nip46", pubkey: ME }, signer: wrap(Promise.resolve(bunker)),
  account: { relays: { read: ["wss://r1.example"], write: ["wss://w1.example"] } } })

test("a word is stored lowercased, trimmed and with its spaces folded; empty, symbol-only, too long and duplicate are refused", () => {
  assert.equal(mutedWordKey("  Crypto   SCAM "), "crypto scam")
  assert.equal(mutedWordKey("Ｅ́"), "ｅ́".normalize("NFC"))
  assert.match(mutedWordProblem("   "), /Type a word/)
  assert.match(mutedWordProblem("!!!"), /no letters or numbers/)
  assert.match(mutedWordProblem("x".repeat(MUTED_WORD_MAX + 1)), /longer than/)
  assert.equal(mutedWordProblem("x".repeat(MUTED_WORD_MAX)), "")
  assert.match(mutedWordProblem("Scam", ["scam"]), /already muted/)
  assert.match(mutedWordProblem("foo bar", ["foo  bar"]), /already muted/, "another app's spacing is the same word")
  assert.equal(mutedWordProblem("日本"), "", "any script's letters")
})

test("muting a word privately adds it to the encrypted part only; every other entry, public and private, is kept", async () => {
  const signer = wrap(Promise.resolve(fakeBunker()))
  const base = list([["p", A], ["t", "nsfw"], ["word", "spoilers"], ["e", E]], seal44([["p", C], ["word", "election"]]))
  const { tags, content } = await editedWordList(base, { word: " Crypto Scam ", mute: true, crypto: signer.crypto, me: ME })
  assert.deepEqual(tags, base.tags, "nothing public changed")
  assert.deepEqual(open44(content), [["p", C], ["word", "election"], ["word", "crypto scam"]])
})

test("muting publicly adds a word tag and takes the word out of the private part; unmuting takes it out of both, in any case", async () => {
  const signer = wrap(Promise.resolve(fakeBunker()))
  const base = list([["p", A], ["word", "Spoilers"]], seal44([["word", "spoilers"], ["word", "election"]]))
  const pub = await editedWordList(base, { word: "election", mute: true, isPrivate: false, crypto: signer.crypto, me: ME })
  assert.deepEqual(pub.tags, [["p", A], ["word", "Spoilers"], ["word", "election"]])
  assert.deepEqual(open44(pub.content), [["word", "spoilers"]])
  const un = await editedWordList(base, { word: "SPOILERS", mute: false, crypto: signer.crypto, me: ME })
  assert.deepEqual(un.tags, [["p", A]])
  assert.deepEqual(open44(un.content), [["word", "election"]])
})

test("a private part that can't be opened: a private mute and unmuting a word not in the public part refuse; public changes keep it", async () => {
  const base = list([["word", "spoilers"]], "unreadable")
  await assert.rejects(editedWordList(base, { word: "x", mute: true, crypto: null, me: ME }), /Couldn't mute it privately/)
  await assert.rejects(editedWordList(base, { word: "election", mute: false, crypto: null, me: ME }), /Couldn't unmute it/)
  const pub = await editedWordList(base, { word: "x", mute: true, isPrivate: false, crypto: null, me: ME })
  assert.deepEqual(pub.tags, [["word", "spoilers"], ["word", "x"]]); assert.equal(pub.content, "unreadable")
  const un = await editedWordList(base, { word: "Spoilers", mute: false, crypto: null, me: ME })
  assert.deepEqual(un.tags, []); assert.equal(un.content, "unreadable", "a private part this signer can't open is kept")
})

test("setMutedWord: built on the relays' newest list, private by default, sent, kept and shown at once; unmute removes it", async () => {
  const old = list([["p", A]], "", 100)
  const newer = list([["p", A], ["p", C], ["word", "spoilers"]], "", 200)
  const vault = fakeVault([old])
  const calls = [], sent = []
  const ctx = ctxOf(vault, fakeBunker(calls))
  resetBlocks()
  await loadBlocks(ctx, [], { query: async () => [] })
  const { event } = await setMutedWord(ctx, "Election", { ask: askWith({ "wss://r1.example": { events: [newer], answered: true } }), publish: okPublish(sent) })
  assert.deepEqual(event.tags, newer.tags, "C and the public word aren't lost; the new word isn't public")
  assert.deepEqual(open44(event.content), [["word", "election"]])
  assert.ok(event.created_at > newer.created_at)
  assert.equal(sent.length, 1)
  assert.ok(vault.outbox.stored.some(e => e.id === event.id))
  assert.deepEqual(getBlocks().publicWords, ["spoilers"])
  assert.deepEqual(getBlocks().privateWords, ["election"])
  assert.deepEqual(getBlocks().blocked.words.sort(), ["election", "spoilers"], "the screens' muteSet hides it at once")
  assert.ok(calls.some(c => c[0] === "nip44_encrypt"))

  const { event: un } = await setMutedWord(ctx, "election", { mute: false, ask: askWith(), publish: okPublish(sent) })
  assert.deepEqual(open44(un.content), [])
  assert.deepEqual(getBlocks().privateWords, [])
  assert.deepEqual(un.tags, newer.tags)
})

test("setMutedWord: a bad word, a private mute without encryption, or a refused guard sign and send nothing", async () => {
  const vault = fakeVault([list([["p", A]])])
  const calls = [], sent = []
  const ctx = ctxOf(vault, fakeBunker(calls))
  resetBlocks()
  await assert.rejects(setMutedWord(ctx, "  ", { ask: askWith(), publish: okPublish(sent) }), /Type a word/)
  await assert.rejects(setMutedWord({ ...ctx, signer: { signEvent: ctx.signer.signEvent } }, "x", { ask: askWith(), publish: okPublish(sent) }), /can't encrypt/)
  await assert.rejects(setMutedWord(ctx, "x", { ask: async () => ({ events: [], answered: false }), publish: okPublish(sent) }), /None of your relays answered/)
  assert.equal(sent.length, 0)
  assert.ok(!calls.some(c => c[0] === "sign_event"))
})

test("sections: public words first; a word in both parts shows once, under Public", () => {
  assert.deepEqual(mutedWordSections({ publicWords: ["a", "b"], privateWords: ["b", "c"] }), { publicWords: ["a", "b"], privateWords: ["c"] })
  assert.deepEqual(mutedWordSections(), { publicWords: [], privateWords: [] })
})
