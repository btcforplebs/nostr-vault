// Messages: NIP-17 wraps built and opened the way the iPhone does, legacy kind 4 read, conversations grouped,
// blocked people left out, relays picked like DMService, wraps kept in Haven /chat and the decrypted text never
// written anywhere. Throwaway keys, a fake /chat and a stubbed network: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import * as nip04 from "nostr-tools/nip04"
import { makeAuthEvent } from "nostr-tools/nip42"
import {
  cryptoFor, rumorFor, wrapFor, unwrap, openLegacy, dmRelaysFor, extraRelays, loadMessages, getMessages, onMessages, resetMessages,
  conversations, thread, sendMessage, peerOf, watchMessages, WATCH_SINCE, OPEN_BATCH, authFor,
} from "../src/net/dms.js"

const A = generateSecretKey(), B = generateSecretKey(), C = generateSecretKey()
const pk = sk => getPublicKey(sk)
// What a NIP-07 extension does for its user, with the key in hand.
const cryptoOf = sk => ({
  encrypt: async (peer, t) => nip44.encrypt(t, nip44.getConversationKey(sk, peer)),
  decrypt: async (peer, c) => nip44.decrypt(c, nip44.getConversationKey(sk, peer)),
  decrypt04: async (peer, c) => nip04.decrypt(sk, peer, c),
})
const envOf = sk => ({ signer: { signEvent: async t => finalizeEvent(t, sk) }, crypto: cryptoOf(sk), me: pk(sk) })
const plain = ev => JSON.parse(JSON.stringify(ev))

// Haven /chat as dms.js uses it: #p + kinds, keeps what it is given, refuses kind 4 like the real route.
function fakeChat(seed = []) {
  const stored = [...seed]
  return {
    stored,
    query: async f => stored.filter(e => (!f.kinds || f.kinds.includes(e.kind)) && (!f["#p"] || e.tags.some(t => t[0] === "p" && f["#p"].includes(t[1])))),
    event: async ev => { if (ev.kind === 4) return { ok: false, message: "blocked: only chat related events are allowed" }; if (!stored.some(e => e.id === ev.id)) stored.push(plain(ev)); return { ok: true, message: "" } },
  }
}
const ctxOf = (sk, { read = ["wss://read.example"], write = ["wss://write.example"] } = {}) => ({ vault: {}, session: { method: "nip07", pubkey: pk(sk) }, signer: envOf(sk).signer, account: { relays: { read, write } } })

test("a message wrapped for the other person opens for them, and the self-copy opens for the sender", async () => {
  const rumor = rumorFor(pk(A), pk(B), "hello B")
  assert.match(rumor.id, /^[0-9a-f]{64}$/)
  const toB = await wrapFor(rumor, envOf(A), pk(B))
  const toA = await wrapFor(rumor, envOf(A), pk(A))
  assert.equal(toB.kind, 1059); assert.notEqual(toB.pubkey, pk(A), "signed by a throwaway key")
  assert.deepEqual(toB.tags, [["p", pk(B)]])
  assert.ok(toB.created_at <= Math.floor(Date.now() / 1000) && toB.created_at > Math.floor(Date.now() / 1000) - 2 * 86400 - 5)
  assert.ok(!JSON.stringify(toB).includes("hello B") && !JSON.stringify(toA).includes("hello B"), "no plaintext in a wrap")

  const got = await unwrap(toB, cryptoOf(B), pk(B))
  assert.deepEqual(got, { id: toB.id, from: pk(A), peer: pk(A), content: "hello B", at: rumor.created_at, legacy: false })
  const mine = await unwrap(toA, cryptoOf(A), pk(A))
  assert.deepEqual(mine, { id: toA.id, from: pk(A), peer: pk(B), content: "hello B", at: rumor.created_at, legacy: false })
  // C's signer can't decrypt B's wrap: that's the signer failing, which unwrap reports rather than hides.
  await assert.rejects(unwrap(toB, cryptoOf(C), pk(C)), e => e.refused === true)
})

test("a seal signed by someone else, or a rumor claiming another sender, is refused", async () => {
  const rumor = rumorFor(pk(A), pk(B), "forged")
  // C seals a rumor that claims to be from A.
  const forged = await wrapFor(rumor, envOf(C), pk(B))
  assert.equal(await unwrap(forged, cryptoOf(B), pk(B)), null)
  // A seal whose signature doesn't check.
  const env = envOf(A)
  const bad = { ...env, signer: { signEvent: async t => ({ ...finalizeEvent(t, A), sig: "00".repeat(64) }) } }
  await assert.rejects(wrapFor(rumor, bad, pk(B)), /sign/i)
  assert.equal(await unwrap({ kind: 1, pubkey: pk(A), content: "" }, cryptoOf(B), pk(B)), null)
})

test("a legacy kind 4 opens with NIP-04, either way round", async () => {
  const fromA = finalizeEvent({ kind: 4, created_at: 100, tags: [["p", pk(B)]], content: nip04.encrypt(A, pk(B), "old style") }, A)
  assert.deepEqual(await openLegacy(fromA, cryptoOf(B), pk(B)), { id: fromA.id, from: pk(A), peer: pk(A), content: "old style", at: 100, legacy: true })
  assert.deepEqual(await openLegacy(fromA, cryptoOf(A), pk(A)), { id: fromA.id, from: pk(A), peer: pk(B), content: "old style", at: 100, legacy: true })
  assert.equal(await openLegacy(fromA, cryptoOf(C), pk(C)), null)
})

test("with no signer to ask, a sign-in can't decrypt and says so", () => {
  assert.match(cryptoFor({ method: "nip46", pubkey: pk(A) }).reason, /bunker isn't connected/)
  assert.match(cryptoFor({ method: "nip46", pubkey: pk(A) }, { signer: { signEvent() {} } }).reason, /bunker isn't connected/)
  assert.match(cryptoFor({ method: "other" }).reason, /can't decrypt/)
  assert.equal(cryptoFor({ method: "nip07" }, { ext: "x" }), "x")
})

test("DM relays: kind 10050 first, then the 10002 read list, then the fallback; loopback dropped", async () => {
  const inbox = finalizeEvent({ kind: 10050, created_at: 2, tags: [["relay", "wss://inbox.example/"], ["relay", "ws://127.0.0.1:3355"], ["relay", "nope"]], content: "" }, B)
  const general = finalizeEvent({ kind: 10002, created_at: 1, tags: [["r", "wss://r1.example"], ["r", "wss://w.example", "write"]], content: "" }, B)
  const q = evs => async () => evs
  assert.deepEqual(await dmRelaysFor(pk(B), ["wss://x"], { query: q([inbox, general]) }), ["wss://inbox.example"])
  assert.deepEqual(await dmRelaysFor(pk(B), ["wss://x"], { query: q([general]) }), ["wss://r1.example"])
  const onlyLoop = finalizeEvent({ kind: 10050, created_at: 3, tags: [["relay", "ws://localhost:3355"]], content: "" }, B)
  assert.deepEqual(await dmRelaysFor(pk(B), ["wss://x"], { query: q([onlyLoop, general]) }), ["wss://r1.example"], "a loopback-only inbox falls through")
  assert.deepEqual(await dmRelaysFor(pk(B), ["wss://x"], { query: q([]), fallback: ["wss://f.example"] }), ["wss://f.example"])
  const notTheirs = finalizeEvent({ kind: 10050, created_at: 9, tags: [["relay", "wss://evil.example"]], content: "" }, C)
  assert.deepEqual(await dmRelaysFor(pk(B), ["wss://x"], { query: q([notTheirs]), fallback: ["wss://f.example"] }), ["wss://f.example"], "someone else's list is ignored")
})

test("extra relays come from localStorage, ws(s) only", () => {
  const storage = { getItem: () => " ws://127.0.0.1:7777 , wss://a.example, http://no " }
  assert.deepEqual(extraRelays(storage), ["ws://127.0.0.1:7777", "wss://a.example"])
  assert.deepEqual(extraRelays({ getItem: () => null }), [])
})

test("loadMessages: Haven /chat first, then the relays, new wraps kept in /chat, kind 4 read but not kept", async () => {
  const r1 = rumorFor(pk(B), pk(A), "from haven", 100)
  const inHaven = await wrapFor(r1, envOf(B), pk(A))
  const r2 = rumorFor(pk(B), pk(A), "from relay", 200)
  const onRelay = await wrapFor(r2, envOf(B), pk(A))
  const legacy = finalizeEvent({ kind: 4, created_at: 150, tags: [["p", pk(A)]], content: nip04.encrypt(C, pk(A), "legacy hi") }, C)
  const chat = fakeChat([inHaven])
  const asked = []
  // The stub answers like a relay: one filter object per REQ (a list would be an invalid REQ on a real relay).
  const query = async (relays, f) => { asked.push(f); assert.ok(!Array.isArray(f) && typeof f.kinds?.[0] === "number", "one filter per query"); return f.kinds[0] === 4 ? (f.authors ? [] : [legacy]) : [onRelay, inHaven] }
  resetMessages(pk(A))
  let changes = 0
  const off = onMessages(() => changes++)
  const { stored } = await loadMessages(ctxOf(A), ["wss://r.example"], { crypto: cryptoOf(A), query, chat })
  off()
  assert.equal(stored, 1, "only the wrap Haven didn't have")
  assert.equal(chat.stored.length, 2)
  const m = getMessages()
  assert.equal(m.loaded, true); assert.equal(m.note, "")
  assert.deepEqual([...m.messages.values()].map(x => x.content).sort(), ["from haven", "from relay", "legacy hi"])
  assert.ok(changes >= 2)
  assert.ok(!JSON.stringify(chat.stored).includes("from"), "nothing decrypted in Haven")

  // A second load asks the relays again but opens nothing twice.
  await loadMessages(ctxOf(A), ["wss://r.example"], { crypto: cryptoOf(A), query, chat })
  assert.equal(getMessages().messages.size, 3)
})

test("loadMessages with a signer that can't decrypt opens nothing and leaves the note", async () => {
  const chat = fakeChat([await wrapFor(rumorFor(pk(B), pk(A), "secret"), envOf(B), pk(A))])
  resetMessages(pk(A))
  const query = async () => { throw new Error("network used") }
  await loadMessages({ vault: {}, session: { method: "nip46", pubkey: pk(A) } }, ["wss://r"], { query, chat })
  const m = getMessages()
  assert.equal(m.messages.size, 0); assert.equal(m.loaded, true); assert.match(m.note, /bunker/)
})

test("watchMessages looks two days back (a wrap's created_at is randomised that far) and opens what arrives", async () => {
  const rumor = rumorFor(pk(B), pk(A), "live", 500)
  const wrap = await wrapFor(rumor, envOf(B), pk(A))
  let filter, onevent, closed = 0
  const subscribe = (relays, f, o) => { filter = f; onevent = o.onevent; return { close: () => closed++ } }
  const chat = fakeChat()
  resetMessages(pk(A))
  const stop = watchMessages(ctxOf(A), ["wss://r.example"], { crypto: cryptoOf(A), chat, subscribe })
  assert.deepEqual(filter.kinds, [1059, 4]); assert.deepEqual(filter["#p"], [pk(A)])
  assert.ok(filter.since <= Math.floor(Date.now() / 1000) - 2 * 86400, "since reaches two days back")
  assert.equal(WATCH_SINCE, 2 * 86400 + 3600)
  await onevent(wrap)
  assert.deepEqual([...getMessages().messages.values()].map(m => m.content), ["live"])
  assert.deepEqual(chat.stored.map(e => e.id), [wrap.id], "the wrap is kept in /chat")
  stop(); assert.equal(closed, 1)
})

test("conversations are per person, newest first, blocked people left out; a thread is oldest first", () => {
  const msgs = new Map([
    ["1", { id: "1", from: pk(B), peer: pk(B), content: "b1", at: 10 }],
    ["2", { id: "2", from: pk(A), peer: pk(B), content: "a->b", at: 30 }],
    ["3", { id: "3", from: pk(C), peer: pk(C), content: "c1", at: 20 }],
  ])
  const list = conversations(msgs)
  assert.deepEqual(list.map(c => [c.peer, c.last.content, c.count]), [[pk(B), "a->b", 2], [pk(C), "c1", 1]])
  assert.deepEqual(conversations(msgs, new Set([pk(B)])).map(c => c.peer), [pk(C)])
  assert.deepEqual(thread(msgs, pk(B)).map(m => m.id), ["1", "2"])
})

test("sendMessage: their wrap to their DM relays, the self-copy to mine and into /chat, shown at once", async () => {
  const theirInbox = finalizeEvent({ kind: 10050, created_at: 2, tags: [["relay", "wss://b-inbox.example"]], content: "" }, B)
  const query = async (relays, f) => (f.authors[0] === pk(B) ? [theirInbox] : [])
  const sent = []
  const publish = (urls, ev) => { sent.push([urls[0], ev]); return [Promise.resolve("ok")] }
  const chat = fakeChat()
  resetMessages(pk(A))
  const ctx = ctxOf(A, { write: ["wss://a-write.example"] })
  const { relays } = await sendMessage(ctx, pk(B), "hi there", { crypto: cryptoOf(A), query, chat, publish })
  assert.deepEqual(relays.map(r => [r.url, r.ok]), [["wss://b-inbox.example", true], ["wss://a-write.example", true]])
  const [[, toB], [, toA]] = sent
  assert.deepEqual(toB.tags, [["p", pk(B)]]); assert.deepEqual(toA.tags, [["p", pk(A)]])
  assert.equal((await unwrap(toB, cryptoOf(B), pk(B))).content, "hi there")
  assert.equal((await unwrap(toA, cryptoOf(A), pk(A))).content, "hi there")
  assert.deepEqual(chat.stored.map(e => e.id), [toA.id], "only the self-copy is kept")
  assert.ok(!JSON.stringify(chat.stored).includes("hi there"))
  const [m] = getMessages().messages.values()
  assert.deepEqual([m.from, m.peer, m.content], [pk(A), pk(B), "hi there"])
  assert.equal(thread(getMessages().messages, pk(B)).length, 1)
})

test("sendMessage throws when no relay took it, and with no signer that can encrypt", async () => {
  const publish = () => [Promise.reject(new Error("closed"))]
  resetMessages(pk(A))
  await assert.rejects(sendMessage(ctxOf(A), pk(B), "x", { crypto: cryptoOf(A), query: async () => [], chat: fakeChat(), publish }), /Error: Not delivered: none of their 1 relay took it\.$/)
  const [failed] = getMessages().messages.values()
  assert.deepEqual([getMessages().messages.size, failed.pending, failed.failed, failed.content], [1, false, "Not delivered: none of their 1 relay took it.", "x"], "shown as not sent, never as sent")
  await assert.rejects(sendMessage({ ...ctxOf(A), session: { method: "nip46", pubkey: pk(A) } }, pk(B), "x", { chat: fakeChat() }), /bunker/)
})

test("sendMessage: a DM is not delivered when only the self-copy landed", async () => {
  const theirInbox = finalizeEvent({ kind: 10050, created_at: 2, tags: [["relay", "wss://their-haven.example"]], content: "" }, B)
  const query = async (relays, f) => (f.authors[0] === pk(B) ? [theirInbox] : [])
  const sent = []
  const publish = (urls) => { sent.push(urls[0]); return [urls[0].includes("their") ? Promise.reject(new Error("blocked: not in WoT")) : Promise.resolve("ok")] }
  const chat = fakeChat()
  resetMessages(pk(A))
  await assert.rejects(sendMessage(ctxOf(A), pk(B), "hi", { crypto: cryptoOf(A), query, chat, publish }), /Error: Not delivered: none of their 1 relay took it\.$/)
  assert.deepEqual([...getMessages().messages.values()].map(m => [m.failed, m.pending]), [["Not delivered: none of their 1 relay took it.", false]], "shown as not sent, never as sent")
  assert.equal(chat.stored.length, 0, "no self-copy kept")
  assert.deepEqual(sent, ["wss://their-haven.example"], "the self-copy was never published, so my relay can't echo it back")
})

test("sendMessage: this browser's extra relays get the self-copy only; a note to self is one wrap to my relays", async () => {
  globalThis.localStorage = { getItem: k => (k === "nv-dm-relays" ? "ws://127.0.0.1:1" : null) }
  try {
    const sent = []
    const publish = (urls, ev) => { sent.push([urls[0], ev]); return [Promise.resolve("ok")] }
    resetMessages(pk(A))
    const { relays } = await sendMessage(ctxOf(A), pk(B), "x", { crypto: cryptoOf(A), query: async () => [], chat: fakeChat(), publish })
    assert.deepEqual(relays.map(r => [r.url, r.to]), [["wss://write.example", "them"], ["wss://write.example", "me"], ["ws://127.0.0.1:1", "me"]])
    assert.deepEqual(sent.find(([u]) => u.startsWith("ws://127"))[1].tags, [["p", pk(A)]], "the extra relay got the self-copy")

    sent.length = 0
    const chat = fakeChat()
    const r = await sendMessage(ctxOf(A), pk(A), "note to self", { crypto: cryptoOf(A), query: async () => [], chat, publish })
    assert.deepEqual(r.relays.map(x => [x.url, x.to]), [["wss://write.example", "them"], ["ws://127.0.0.1:1", "them"]])
    assert.equal(new Set(sent.map(([, ev]) => ev.id)).size, 1, "one wrap")
    const m = await unwrap(chat.stored[0], cryptoOf(A), pk(A))
    assert.deepEqual([m.from, m.peer, m.content], [pk(A), pk(A), "note to self"], "a note to self survives reload")
  } finally { delete globalThis.localStorage }
})

test("unwrap refuses a rumor that doesn't name me", async () => {
  const rumor = rumorFor(pk(A), pk(C), "for C")
  const wrap = await wrapFor(rumor, envOf(A), pk(B)) // sealed and wrapped to B, but the rumor is to C
  assert.equal(await unwrap(wrap, cryptoOf(B), pk(B)), null)
})

test("loadMessages opens newest first in batches, telling the screen after each", async () => {
  const wraps = []
  for (let i = 0; i < 2 * OPEN_BATCH + 3; i++) wraps.push(await wrapFor(rumorFor(pk(B), pk(A), `m${i}`, 1000 + i), envOf(B), pk(A)))
  const query = async (relays, f) => (f.kinds[0] === 1059 ? wraps : [])
  resetMessages(pk(A))
  const seen = []
  const off = onMessages(() => seen.push(getMessages().messages.size))
  await loadMessages(ctxOf(A), ["wss://r.example"], { crypto: cryptoOf(A), query, chat: fakeChat() })
  off()
  assert.ok(seen.length >= 3, `screen told per batch, got ${seen.length}`)
  const counts = seen.filter((n, i) => n !== seen[i - 1])
  assert.deepEqual(counts.slice(0, 3), [OPEN_BATCH, 2 * OPEN_BATCH, 2 * OPEN_BATCH + 3])
  assert.equal(getMessages().messages.size, wraps.length)
})

test("#/dm/<hex> names the peer", () => {
  assert.equal(peerOf(`#/dm/${pk(B)}`), pk(B))
  assert.equal(peerOf("#/dm/short"), null)
  assert.equal(peerOf("#/messages"), null)
})

test("coming back looks again only after five minutes, and once for two screens", async () => {
  const { claimResync, RESYNC_AFTER } = await import("../src/net/dms.js")
  let t = 10_000_000
  const clock = () => t
  await loadMessages({ vault: {}, session: { method: "nip07", pubkey: pk(A) }, signer: envOf(A).signer, account: { relays: { read: [], write: [] } } }, [], { crypto: cryptoOf(A), chat: fakeChat(), clock })
  t += RESYNC_AFTER - 1
  assert.equal(claimResync({ clock }), false, "a load just ran")
  t += 1
  assert.equal(claimResync({ clock }), true)
  assert.equal(claimResync({ clock }), false, "the second screen coming back at the same moment doesn't look again")
  t += 10_000
  assert.equal(claimResync({ clock, after: 10_000 }), true, "back online looks after a shorter wait")
})

test("a relay that wants AUTH gets one signed by the sender, for that relay only, and then takes the wrap", async () => {
  const theirInbox = finalizeEvent({ kind: 10050, created_at: 2, tags: [["relay", "wss://b-haven.example"]], content: "" }, B)
  const query = async (relays, f) => (f.authors[0] === pk(B) ? [theirInbox] : [])
  const authed = []
  // What nostr-tools does on "auth-required: …": sign makeAuthEvent(relay.url, challenge), wait for its OK, resend.
  const publish = (urls, ev, opts) => [(async () => {
    if (!urls[0].includes("b-haven")) return "ok"
    const auth = await opts.onauth(makeAuthEvent(urls[0], "challenge-123"))
    authed.push(auth)
    return "ok"
  })()]
  resetMessages(pk(A))
  const { relays } = await sendMessage(ctxOf(A, { write: ["wss://a-write.example"] }), pk(B), "hi", { crypto: cryptoOf(A), query, chat: fakeChat(), publish })
  assert.deepEqual(relays.map(r => [r.url, r.ok]), [["wss://b-haven.example", true], ["wss://a-write.example", true]])
  const [auth] = authed
  assert.equal(auth.kind, 22242); assert.equal(auth.pubkey, pk(A)); assert.ok(verifyEvent(auth))
  assert.deepEqual(auth.tags, [["relay", "wss://b-haven.example"], ["challenge", "challenge-123"]])
})

test("authFor signs nothing but a bare AUTH for its own relay", async () => {
  let asked = 0
  const ctx = { session: { method: "nip07", pubkey: pk(A) }, signer: { signEvent: async t => { asked++; return finalizeEvent(t, A) } } }
  const auth = authFor(ctx, "wss://relay.example")
  assert.equal((await auth(makeAuthEvent("wss://Relay.Example/", "c"))).kind, 22242, "the same relay, written differently")
  await assert.rejects(auth(makeAuthEvent("wss://other.example", "c")), /not an AUTH for this relay/)
  await assert.rejects(auth({ ...makeAuthEvent("wss://relay.example", "c"), kind: 1, content: "gm" }), /not an AUTH/)
  await assert.rejects(auth({ ...makeAuthEvent("wss://relay.example", "c"), content: "x" }), /not an AUTH/)
  const t = makeAuthEvent("wss://relay.example", "c")
  await assert.rejects(auth({ ...t, tags: [...t.tags, ["p", pk(B)]] }), /not an AUTH/)
  assert.equal(asked, 1, "the signer only saw the one real AUTH")
  const wrongAccount = authFor({ session: { pubkey: pk(A) }, signer: { signEvent: async t => finalizeEvent(t, B) } }, "wss://relay.example")
  await assert.rejects(wrongAccount(makeAuthEvent("wss://relay.example", "c")), /different account/)
})

test("through the real nostr-tools pool: auth-required, AUTH, then the wrap is taken", async () => {
  const { SimplePool } = await import("nostr-tools/pool")
  const log = []
  // A relay that, like a Haven inbox, refuses events until the connection has AUTHed. In memory, no network.
  class FakeRelaySocket {
    static OPEN = 1; static CLOSING = 2; static CLOSED = 3
    constructor(url) { this.url = url; this.readyState = 0; this.authed = null; setTimeout(() => { this.readyState = 1; this.onopen?.(); this.reply(["AUTH", "chal-xyz"]) }) }
    reply(m) { setTimeout(() => this.onmessage?.({ data: JSON.stringify(m) })) }
    send(raw) {
      const [type, ev] = JSON.parse(raw)
      if (type === "AUTH") {
        const ok = ev.kind === 22242 && verifyEvent(ev) && ev.tags.some(t => t[0] === "challenge" && t[1] === "chal-xyz")
        if (ok) this.authed = ev.pubkey
        log.push(["AUTH", ok]); return this.reply(["OK", ev.id, ok, ok ? "" : "invalid: bad auth"])
      }
      if (type === "EVENT") { log.push(["EVENT", !!this.authed]); return this.reply(["OK", ev.id, !!this.authed, this.authed ? "" : "auth-required: we only accept DMs from authenticated users"]) }
    }
    close() { this.readyState = 3; this.onclose?.({}) }
  }
  const testPool = new SimplePool({ websocketImplementation: FakeRelaySocket })
  const theirInbox = finalizeEvent({ kind: 10050, created_at: 2, tags: [["relay", "wss://b-haven.example"]], content: "" }, B)
  const query = async (relays, f) => (f.authors[0] === pk(B) ? [theirInbox] : [])
  resetMessages(pk(A))
  try {
    const { relays } = await sendMessage(ctxOf(A, { write: ["wss://a-haven.example"] }), pk(B), "hi", {
      crypto: cryptoOf(A), query, chat: fakeChat(), publish: (urls, ev, opts) => testPool.publish(urls, ev, opts),
    })
    assert.deepEqual(relays.map(r => [r.url, r.ok]), [["wss://b-haven.example", true], ["wss://a-haven.example", true]])
    assert.deepEqual(log.slice(0, 3), [["EVENT", false], ["AUTH", true], ["EVENT", true]], "refused, AUTHed, then taken")
  } finally { testPool.destroy() }
})

test("a declined AUTH doesn't jam the relay: it's dropped, and the next send AUTHs afresh and is taken", async () => {
  const { SimplePool } = await import("nostr-tools/pool")
  const log = []
  class FakeRelaySocket {
    static OPEN = 1; static CLOSING = 2; static CLOSED = 3
    constructor(url) { this.url = url; this.readyState = 0; this.authed = null; log.push(["OPEN"]); setTimeout(() => { this.readyState = 1; this.onopen?.(); this.reply(["AUTH", "chal-" + log.length]) }) }
    reply(m) { setTimeout(() => this.onmessage?.({ data: JSON.stringify(m) })) }
    send(raw) {
      const [type, ev] = JSON.parse(raw)
      if (type === "AUTH") { this.authed = ev.pubkey; log.push(["AUTH"]); return this.reply(["OK", ev.id, true, ""]) }
      if (type === "EVENT") { log.push(["EVENT", !!this.authed]); return this.reply(["OK", ev.id, !!this.authed, this.authed ? "" : "auth-required: who are you"]) }
    }
    close() { this.readyState = 3; this.onclose?.({}) }
  }
  const testPool = new SimplePool({ websocketImplementation: FakeRelaySocket })
  const theirInbox = finalizeEvent({ kind: 10050, created_at: 2, tags: [["relay", "wss://b-haven.example"]], content: "" }, B)
  const query = async (relays, f) => (f.authors[0] === pk(B) ? [theirInbox] : [])
  let decline = true
  const ctx = ctxOf(A, { write: ["wss://b-haven.example"] })
  ctx.signer = { signEvent: async t => { if (t.kind === 22242 && decline) throw new Error("user declined"); return finalizeEvent(t, A) } }
  const dropped = []
  const opts = { crypto: cryptoOf(A), query, chat: fakeChat(), wait: 300, publish: (urls, ev, o) => testPool.publish(urls, ev, o), drop: urls => { dropped.push(...urls); testPool.close(urls) } }
  resetMessages(pk(A))
  try {
    await assert.rejects(sendMessage(ctx, pk(B), "first", opts), /Not delivered/)
    assert.deepEqual(dropped, ["wss://b-haven.example"])
    decline = false
    const { relays } = await sendMessage(ctx, pk(B), "second", opts)
    assert.ok(relays.find(r => r.to === "them").ok, "the second send got through")
    assert.equal(log.filter(e => e[0] === "OPEN").length, 2, "a fresh socket")
    assert.equal(log.filter(e => e[0] === "AUTH").length, 1, "the relay saw the second AUTH")
  } finally { testPool.destroy() }
})

test("dropping a relay after a failed AUTH tells the screens to look again, once per drop", async () => {
  const { onResyncNeeded } = await import("../src/net/dms.js")
  const theirInbox = finalizeEvent({ kind: 10050, created_at: 2, tags: [["relay", "wss://b-haven.example"]], content: "" }, B)
  const query = async (relays, f) => (f.authors[0] === pk(B) ? [theirInbox] : [])
  const ctx = ctxOf(A, { write: ["wss://b-haven.example"] })
  ctx.signer = { signEvent: async t => { if (t.kind === 22242) throw new Error("user declined"); return finalizeEvent(t, A) } }
  const heard = []
  const off = onResyncNeeded(urls => heard.push(urls))
  const publish = (urls, ev, o) => [o.onauth(makeAuthEvent(urls[0], "c")).then(() => "ok")]
  resetMessages(pk(A))
  try {
    await assert.rejects(sendMessage(ctx, pk(B), "x", { crypto: cryptoOf(A), query, chat: fakeChat(), wait: 200, publish, drop: () => {} }), /Not delivered/)
    assert.deepEqual(heard, [["wss://b-haven.example"]])
    heard.length = 0
    const ok = (urls, ev) => [Promise.resolve("ok")]
    await sendMessage(ctxOf(A, { write: ["wss://b-haven.example"] }), pk(B), "y", { crypto: cryptoOf(A), query, chat: fakeChat(), publish: ok, drop: () => {} })
    assert.deepEqual(heard, [], "no drop, no extra look")
  } finally { off() }
})

test("sendMessage: the bubble shows at once as Sending, turns real at the first relay's OK, before the slowest answers", async () => {
  const theirInbox = finalizeEvent({ kind: 10050, created_at: 2, tags: [["relay", "wss://fast.example"], ["relay", "wss://slow.example"]], content: "" }, B)
  const query = async (relays, f) => (f.authors[0] === pk(B) ? [theirInbox] : [])
  let releaseSlow
  const slow = new Promise(r => { releaseSlow = r })
  const publish = urls => [urls[0].includes("slow") ? slow : Promise.resolve("ok")]
  resetMessages(pk(A))
  const sending = sendMessage(ctxOf(A), pk(B), "quick", { crypto: cryptoOf(A), query, chat: fakeChat(), publish })
  const [pending] = getMessages().messages.values()
  assert.deepEqual([pending.pending, pending.content, pending.from], [true, "quick", pk(A)], "shown before any signing or lookup")
  for (let i = 0; i < 50 && [...getMessages().messages.values()].some(m => m.pending); i++) await new Promise(r => setTimeout(r, 5))
  const [real] = getMessages().messages.values()
  assert.equal(getMessages().messages.size, 1)
  assert.ok(!real.pending && !real.failed && !real.id.startsWith("pending:"), "real while the slow relay still hasn't answered")
  releaseSlow("ok")
  const { relays } = await sending
  assert.equal(relays.filter(r => r.to === "them" && r.ok).length, 2)
})

test("sendMessage: a failed bubble's resend sends it again and replaces it", async () => {
  const theirInbox = finalizeEvent({ kind: 10050, created_at: 2, tags: [["relay", "wss://b.example"]], content: "" }, B)
  const query = async (relays, f) => (f.authors[0] === pk(B) ? [theirInbox] : [])
  let up = false
  const publish = () => [up ? Promise.resolve("ok") : Promise.reject(new Error("closed"))]
  resetMessages(pk(A))
  await assert.rejects(sendMessage(ctxOf(A), pk(B), "again", { crypto: cryptoOf(A), query, chat: fakeChat(), publish }), /Not delivered/)
  const [failed] = getMessages().messages.values()
  up = true
  await failed.resend()
  const all = [...getMessages().messages.values()]
  assert.deepEqual(all.map(m => [m.content, !!m.failed, !!m.pending]), [["again", false, false]])
})

test("sendMessage: a photo that doesn't upload leaves a failed bubble with the text, and signs nothing", async () => {
  let signed = 0
  const ctx = ctxOf(A); const sign = ctx.signer.signEvent; ctx.signer = { signEvent: t => { signed++; return sign(t) } }
  resetMessages(pk(A))
  let uploads = 0
  const prepare = async () => { uploads++; throw new Error("blossom 500 at https://evil") }
  await assert.rejects(sendMessage(ctx, pk(B), "look", { crypto: cryptoOf(A), query: async () => [], chat: fakeChat(), prepare }), /^Error: The photo didn't upload, so nothing was sent\.$/)
  const [m] = getMessages().messages.values()
  assert.deepEqual([m.content, m.failed], ["look", "The photo didn't upload, so nothing was sent."])
  assert.equal(signed, 0)
  await assert.rejects(m.resend(), /photo didn't upload/)
  assert.equal(uploads, 2, "Try again uploads the photo again, not the text alone")
})

test("DM relay lookups are kept per person, and a failed lookup isn't", async () => {
  const { cachedDmRelays, forgetDmRelays } = await import("../src/net/dms.js")
  forgetDmRelays()
  let asked = 0
  const query = async () => { asked++; return [] }
  let t = 0; const clock = () => t
  assert.deepEqual(await cachedDmRelays(pk(B), ["wss://x.example"], { query, fallback: ["wss://f.example"] }, clock), ["wss://f.example"])
  await cachedDmRelays(pk(B), ["wss://x.example"], { query, fallback: ["wss://f.example"] }, clock)
  assert.equal(asked, 1)
  t = 11 * 60_000
  await cachedDmRelays(pk(B), ["wss://x.example"], { query, fallback: ["wss://f.example"] }, clock)
  assert.equal(asked, 2, "looked up again once it went stale")
  const bad = async () => { throw new Error("down") }
  await assert.rejects(cachedDmRelays(pk(C), ["wss://x.example"], { query: bad }, clock))
  await new Promise(r => setTimeout(r, 0))
  assert.deepEqual(await cachedDmRelays(pk(C), ["wss://x.example"], { query, fallback: [] }, clock), [], "asked again after a failure")
  forgetDmRelays()
})

test("loadMessages: Haven's messages are on screen before the inbox relay lookup comes back", async () => {
  const inHaven = await wrapFor(rumorFor(pk(B), pk(A), "kept here", 100), envOf(B), pk(A))
  let release
  const relays = new Promise(r => { release = r })
  resetMessages(pk(A))
  const loading = loadMessages(ctxOf(A), relays, { crypto: cryptoOf(A), query: async () => [], chat: fakeChat([inHaven]) })
  for (let i = 0; i < 50 && !getMessages().loaded; i++) await new Promise(r => setTimeout(r, 5))
  assert.equal(getMessages().loaded, true, "no skeleton while the relays are looked up")
  assert.deepEqual([...getMessages().messages.values()].map(m => m.content), ["kept here"])
  release(["wss://r.example"])
  await loading
})
