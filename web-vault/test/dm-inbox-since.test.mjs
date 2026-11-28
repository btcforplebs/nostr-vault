// Messages perf review 2026-11-28 #1: a look at an inbox relay already read in full asks only for what is newer, so
// coming back to Messages doesn't download the whole inbox again. Refresh reads in full. Throwaway keys, a fake /chat
// and a stubbed network: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import * as nip04 from "nostr-tools/nip04"
import { rumorFor, wrapFor, loadMessages, getMessages, resetMessages, inboxSince, WATCH_SINCE } from "../src/net/dms.js"

const A = generateSecretKey(), B = generateSecretKey()
const pk = sk => getPublicKey(sk)
const cryptoOf = sk => ({
  encrypt: async (peer, t) => nip44.encrypt(t, nip44.getConversationKey(sk, peer)),
  decrypt: async (peer, c) => nip44.decrypt(c, nip44.getConversationKey(sk, peer)),
  decrypt04: async (peer, c) => nip04.decrypt(sk, peer, c),
})
const envOf = sk => ({ signer: { signEvent: async t => finalizeEvent(t, sk) }, crypto: cryptoOf(sk), me: pk(sk) })
const fakeChat = () => ({ query: async () => [], event: async () => ({ ok: true, message: "" }) })
const ctxOf = sk => ({ vault: {}, session: { method: "nip07", pubkey: pk(sk) }, signer: envOf(sk).signer, account: { relays: { read: [], write: [] } } })

test("inboxSince: nothing held is a full read; else WATCH_SINCE before the earlier read or its newest message", () => {
  assert.equal(inboxSince(undefined), undefined)
  assert.equal(inboxSince({ at: 10_000_000 }), 10_000_000 - WATCH_SINCE)
  assert.equal(inboxSince({ at: 10_000_000, newest: 9_000_000 }), 9_000_000 - WATCH_SINCE)
  // A message dated ahead of our clock never moves `since` past when we read.
  assert.equal(inboxSince({ at: 10_000_000, newest: 11_000_000 }), 10_000_000 - WATCH_SINCE)
  assert.ok(WATCH_SINCE >= 2 * 86400, "reaches back past NIP-59's two days")
})

test("a second look asks each relay read in full only for what is newer; full: true asks for everything", async () => {
  const wrap = await wrapFor(rumorFor(pk(B), pk(A), "hi", 1000), envOf(B), pk(A))
  const asked = []
  const query = async ([url], f) => { asked.push({ url, f }); return f.kinds[0] === 1059 ? [wrap] : [] }
  resetMessages(pk(A))
  let t = 1_800_000_000_000
  const clock = () => t
  const opts = { crypto: cryptoOf(A), query, chat: fakeChat(), clock, cache: false }

  await loadMessages(ctxOf(A), ["wss://a.example", "wss://b.example"], opts)
  assert.equal(asked.length, 6)
  assert.ok(asked.every(a => a.f.since === undefined), "the first look reads in full")
  assert.equal(getMessages().messages.size, 1)

  asked.length = 0; t += 120_000
  await loadMessages(ctxOf(A), ["wss://a.example", "wss://b.example"], opts)
  assert.equal(asked.length, 6)
  // The wrap is dated before the first read (NIP-59 dates it up to two days back), so `since` is WATCH_SINCE before it.
  assert.ok(wrap.created_at < 1_800_000_000)
  assert.ok(asked.every(a => a.f.since === wrap.created_at - WATCH_SINCE), "since from the newest message held")
  assert.ok(asked.every(a => a.f.limit), "the limits stay")

  asked.length = 0; t += 120_000
  await loadMessages(ctxOf(A), ["wss://a.example"], { ...opts, full: true })
  assert.ok(asked.every(a => a.f.since === undefined), "Refresh reads in full")
})

test("a relay with nothing for us is asked from when it was read; a relay that missed an ask is read in full again", async () => {
  const asked = []
  let failB = true
  const query = async ([url], f) => {
    asked.push({ url, f })
    if (url === "wss://b.example" && failB && f.authors) throw new Error("timeout")
    return []
  }
  resetMessages(pk(A))
  let t = 1_800_000_000_000
  const opts = { crypto: cryptoOf(A), query, chat: fakeChat(), clock: () => t, cache: false }
  await loadMessages(ctxOf(A), ["wss://a.example", "wss://b.example"], opts)
  asked.length = 0; failB = false; t += 120_000
  await loadMessages(ctxOf(A), ["wss://a.example", "wss://b.example", "wss://new.example"], opts)
  const sinceOf = url => [...new Set(asked.filter(a => a.url === url).map(a => a.f.since))]
  assert.deepEqual(sinceOf("wss://a.example"), [1_800_000_000 - WATCH_SINCE])
  assert.deepEqual(sinceOf("wss://b.example"), [undefined], "one of its asks failed, so it wasn't counted as read")
  assert.deepEqual(sinceOf("wss://new.example"), [undefined], "an inbox relay found later is read in full")
})

test("another account starts over with full reads", async () => {
  const asked = []
  const query = async ([url], f) => { asked.push(f); return [] }
  const opts = { query, chat: fakeChat(), cache: false }
  resetMessages(pk(A))
  await loadMessages(ctxOf(A), ["wss://a.example"], { ...opts, crypto: cryptoOf(A) })
  asked.length = 0
  await loadMessages(ctxOf(B), ["wss://a.example"], { ...opts, crypto: cryptoOf(B) })
  assert.ok(asked.every(f => f.since === undefined))
})
