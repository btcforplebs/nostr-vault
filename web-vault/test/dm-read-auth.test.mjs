// DM reads from a relay that refuses REQ until AUTH (a Haven inbox only lets its owner read): the load and the live
// subscription answer the AUTH, signed by the user for that relay only, and the wraps come through. A declined AUTH
// ends the load on time and drops the relay, so its stuck socket isn't reused. All in memory: no network.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import * as nip04 from "nostr-tools/nip04"
import { makeAuthEvent } from "nostr-tools/nip42"
import { SimplePool } from "nostr-tools/pool"
import { rumorFor, wrapFor, loadMessages, getMessages, resetMessages, watchMessages } from "../src/net/dms.js"
import { forgetDeclinedAuth } from "../src/net/dm-read-auth.js"

const A = generateSecretKey(), B = generateSecretKey()
const pk = sk => getPublicKey(sk)
const cryptoOf = sk => ({
  encrypt: async (peer, t) => nip44.encrypt(t, nip44.getConversationKey(sk, peer)),
  decrypt: async (peer, c) => nip44.decrypt(c, nip44.getConversationKey(sk, peer)),
  decrypt04: async (peer, c) => nip04.decrypt(sk, peer, c),
})
const plain = ev => JSON.parse(JSON.stringify(ev))
const fakeChat = () => { const stored = []; return { stored, query: async () => [], event: async ev => { stored.push(plain(ev)); return { ok: true, message: "" } } } }
const RELAY = "wss://a-haven.example"

// A Haven-like inbox: sends an AUTH challenge on connect, closes every REQ with auth-required until a valid AUTH from
// the owner lands, then serves its wraps. `log` records what it saw.
function havenInbox(owner, wraps, log, { refuseAuth = false, sockets = [] } = {}) {
  let n = 0
  return class FakeRelaySocket {
    static OPEN = 1; static CLOSING = 2; static CLOSED = 3
    constructor(url) {
      this.url = url; this.readyState = 0; this.authed = false; this.challenge = `chal-${++n}`; sockets.push(this); log.push(["OPEN"])
      setTimeout(() => { this.readyState = 1; this.onopen?.(); this.reply(["AUTH", this.challenge]) })
    }
    reply(m) { setTimeout(() => this.readyState === 1 && this.onmessage?.({ data: JSON.stringify(m) })) }
    send(raw) {
      const [type, a] = JSON.parse(raw)
      if (type === "AUTH") {
        const ok = !refuseAuth && a.kind === 22242 && verifyEvent(a) && a.pubkey === owner && a.tags.some(t => t[0] === "challenge" && t[1] === this.challenge)
        this.authed ||= ok; log.push(["AUTH", ok]); return this.reply(["OK", a.id, ok, ok ? "" : "auth-required: bad auth"])
      }
      if (type === "REQ") {
        log.push(["REQ", this.authed, a])
        if (!this.authed) return this.reply(["CLOSED", a, "auth-required: only the owner may read"])
        for (const w of wraps) this.reply(["EVENT", a, w])
        return this.reply(["EOSE", a])
      }
      if (type === "CLOSE") log.push(["CLOSE", a])
    }
    close() { this.readyState = 3; this.onclose?.({}) }
    /** The network drops: the relay is gone, the page didn't ask. */
    lose() { this.readyState = 3; this.onclose?.({ code: 1006 }) }
  }
}

const session = { method: "nip07", pubkey: pk(A) }
const signerOf = (sk, { decline = false, count } = {}) => ({ signEvent: async t => { if (t.kind === 22242) { if (count) count.n++; if (decline) throw new Error("user declined") } return finalizeEvent(t, sk) } })
const until = async f => { for (let i = 0; i < 100 && !f(); i++) await new Promise(r => setTimeout(r, 20)) }

test("a load reads wraps from an inbox that refuses REQ until AUTH", async () => {
  const wrap = await wrapFor(rumorFor(pk(B), pk(A), "hello from B"), { signer: signerOf(B), crypto: cryptoOf(B), me: pk(B) }, pk(A))
  const log = []
  const net = new SimplePool({ websocketImplementation: havenInbox(pk(A), [wrap], log) })
  resetMessages(pk(A))
  try {
    await loadMessages({ vault: {}, session, signer: signerOf(A) }, [RELAY], { crypto: cryptoOf(A), chat: fakeChat(), net, wait: 500 })
    assert.deepEqual([...getMessages().messages.values()].map(m => m.content), ["hello from B"])
    assert.ok(log.some(e => e[0] === "AUTH" && e[1]), "the owner AUTHed")
    assert.ok(log.some(e => e[0] === "REQ" && e[1]), "and asked again once in")
  } finally { net.destroy() }
})

test("the live subscription answers AUTH too, and new wraps arrive", async () => {
  const wrap = await wrapFor(rumorFor(pk(B), pk(A), "live one"), { signer: signerOf(B), crypto: cryptoOf(B), me: pk(B) }, pk(A))
  const log = []
  const net = new SimplePool({ websocketImplementation: havenInbox(pk(A), [wrap], log) })
  resetMessages(pk(A))
  const close = watchMessages({ vault: {}, session, signer: signerOf(A) }, [RELAY], { crypto: cryptoOf(A), chat: fakeChat(), net })
  try {
    for (let i = 0; i < 50 && !getMessages().messages.size; i++) await new Promise(r => setTimeout(r, 20))
    assert.deepEqual([...getMessages().messages.values()].map(m => m.content), ["live one"])
  } finally { close(); net.destroy() }
})

test("one AUTH per connection: three load queries and the live subscription ask the signer once", async () => {
  const log = [], count = { n: 0 }
  const net = new SimplePool({ websocketImplementation: havenInbox(pk(A), [], log) })
  const ctx = { vault: {}, session, signer: signerOf(A, { count }) }
  resetMessages(pk(A))
  try {
    await loadMessages(ctx, [RELAY], { crypto: cryptoOf(A), chat: fakeChat(), net, wait: 300 })
    const close = watchMessages(ctx, [RELAY], { crypto: cryptoOf(A), chat: fakeChat(), net })
    await until(() => log.filter(e => e[0] === "REQ" && e[1]).length >= 4)
    close()
    assert.equal(count.n, 1)
    assert.equal(log.filter(e => e[0] === "AUTH").length, 1)
  } finally { net.destroy() }
})

test("closing the live subscription closes the REQ re-sent after AUTH", async () => {
  const log = []
  const net = new SimplePool({ websocketImplementation: havenInbox(pk(A), [], log) })
  resetMessages(pk(A))
  const close = watchMessages({ vault: {}, session, signer: signerOf(A) }, [RELAY], { crypto: cryptoOf(A), chat: fakeChat(), net })
  try {
    await until(() => log.some(e => e[0] === "REQ" && e[1]))
    const resent = log.find(e => e[0] === "REQ" && e[1])[2]
    close()
    await until(() => log.some(e => e[0] === "CLOSE" && e[1] === resent))
    assert.ok(log.some(e => e[0] === "CLOSE" && e[1] === resent), "the relay was told to stop it")
  } finally { net.destroy() }
})

test("a declined AUTH ends the load at once, keeps the socket, and isn't asked again until Refresh", async () => {
  const wrap = await wrapFor(rumorFor(pk(B), pk(A), "after refresh"), { signer: signerOf(B), crypto: cryptoOf(B), me: pk(B) }, pk(A))
  const log = [], count = { n: 0 }
  const net = new SimplePool({ websocketImplementation: havenInbox(pk(A), [wrap], log) })
  const closed = []
  const close = net.close.bind(net)
  net.close = urls => { closed.push(...urls); close(urls) }
  resetMessages(pk(A))
  forgetDeclinedAuth()
  try {
    const t0 = Date.now()
    await loadMessages({ vault: {}, session, signer: signerOf(A, { decline: true, count }) }, [RELAY], { crypto: cryptoOf(A), chat: fakeChat(), net, wait: 5000 })
    assert.ok(Date.now() - t0 < 3000, "ended without waiting out the timers")
    assert.equal(count.n, 1, "one prompt")
    assert.deepEqual(closed, [], "nothing stuck, so nothing dropped")
    await loadMessages({ vault: {}, session, signer: signerOf(A, { decline: true, count }) }, [RELAY], { crypto: cryptoOf(A), chat: fakeChat(), net, wait: 300 })
    assert.equal(count.n, 1, "coming back doesn't prompt again")
    forgetDeclinedAuth() // Refresh / Try again
    await loadMessages({ vault: {}, session, signer: signerOf(A, { count }) }, [RELAY], { crypto: cryptoOf(A), chat: fakeChat(), net, wait: 500 })
    assert.equal(count.n, 2, "asked once more")
    assert.equal(log.filter(e => e[0] === "OPEN").length, 1, "on the same socket")
    assert.deepEqual([...getMessages().messages.values()].map(m => m.content), ["after refresh"])
  } finally { net.destroy() }
})

test("a signer that never answers counts as declined: the load still ends", async () => {
  const net = new SimplePool({ websocketImplementation: havenInbox(pk(A), [], []) })
  resetMessages(pk(A))
  forgetDeclinedAuth()
  const ctx = { vault: {}, session, signer: { signEvent: t => (t.kind === 22242 ? new Promise(() => {}) : finalizeEvent(t, A)) } }
  try {
    const t0 = Date.now()
    await loadMessages(ctx, [RELAY], { crypto: cryptoOf(A), chat: fakeChat(), net, wait: 300 })
    assert.ok(Date.now() - t0 < 8000 + 3000, "ended by the AUTH wait, not never")
    assert.equal(getMessages().loaded, true)
  } finally { net.destroy(); forgetDeclinedAuth() }
})

test("after the connection drops and comes back with a new challenge, the inbox is AUTHed again: live and on the next load", async () => {
  const wraps = []
  const log = [], sockets = [], count = { n: 0 }
  const net = new SimplePool({ websocketImplementation: havenInbox(pk(A), wraps, log, { sockets }), enableReconnect: true })
  const ctx = { vault: {}, session, signer: signerOf(A, { count }) }
  resetMessages(pk(A))
  forgetDeclinedAuth()
  const close = watchMessages(ctx, [RELAY], { crypto: cryptoOf(A), chat: fakeChat(), net })
  try {
    await until(() => log.some(e => e[0] === "REQ" && e[1]))
    const relay = await net.ensureRelay(RELAY)
    relay.resubscribeBackoff = [20]
    wraps.push(await wrapFor(rumorFor(pk(B), pk(A), "after the blip"), { signer: signerOf(B), crypto: cryptoOf(B), me: pk(B) }, pk(A)))
    sockets[0].lose()
    await until(() => getMessages().messages.size > 0)
    assert.deepEqual([...getMessages().messages.values()].map(m => m.content), ["after the blip"], "the live subscription came back")
    assert.equal(count.n, 2, "a second AUTH, for the new challenge")
    wraps.push(await wrapFor(rumorFor(pk(B), pk(A), "on refresh"), { signer: signerOf(B), crypto: cryptoOf(B), me: pk(B) }, pk(A)))
    await loadMessages(ctx, [RELAY], { crypto: cryptoOf(A), chat: fakeChat(), net, wait: 500 })
    assert.ok([...getMessages().messages.values()].some(m => m.content === "on refresh"), "and a load on the new socket reads too")
    assert.equal(count.n, 2, "without asking again")
  } finally { close(); net.destroy() }
})

test("an inbox that refuses the AUTH is dropped, so the next look starts a fresh socket", async () => {
  const log = []
  const net = new SimplePool({ websocketImplementation: havenInbox(pk(A), [], log, { refuseAuth: true }) })
  const closed = []
  const close = net.close.bind(net)
  net.close = urls => { closed.push(...urls); close(urls) }
  resetMessages(pk(A))
  forgetDeclinedAuth()
  try {
    await loadMessages({ vault: {}, session, signer: signerOf(A) }, [RELAY], { crypto: cryptoOf(A), chat: fakeChat(), net, wait: 300 })
    assert.ok(closed.map(u => u.replace(/\/$/, "")).includes(RELAY))
    assert.equal(getMessages().loaded, true)
  } finally { net.destroy() }
})
