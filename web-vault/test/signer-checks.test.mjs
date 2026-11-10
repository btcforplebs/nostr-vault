// Signer audit 2026-11-05 #2 (an extension on another account) and #4 (box-mode logins). Throwaway keys only.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent, verifyEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import { HavenClient } from "../../web-relay/src/haven/client.js"
import { extensionCrypto, extensionSigner, forgetAccountCheck, WRONG_ACCOUNT } from "../src/signer/nip07.js"
import { dmCache, cacheKey } from "../src/net/dm-cache.js"
import { rumorFor, wrapFor, loadMessages, resetMessages, getMessages, sendMessage, sendFailure } from "../src/net/dms.js"
import { boxHaven, LOGIN_DECLINED } from "../src/box/box-vault.js"

const ME = generateSecretKey(), OTHER = generateSecretKey(), PEER = generateSecretKey()
const pk = sk => getPublicKey(sk)

/** window.nostr for an extension currently on `sk`, counting what it's asked. */
function fakeExtension(sk) {
  const asked = { pubkey: 0, decrypt: 0, encrypt: 0, sign: 0 }
  globalThis.nostr = {
    getPublicKey: async () => { asked.pubkey++; return pk(sk) },
    signEvent: async t => { asked.sign++; return finalizeEvent(t, sk) },
    nip44: {
      encrypt: async (peer, t) => { asked.encrypt++; return nip44.encrypt(t, nip44.getConversationKey(sk, peer)) },
      decrypt: async (peer, c) => { asked.decrypt++; return nip44.decrypt(c, nip44.getConversationKey(sk, peer)) },
    },
  }
  return asked
}
const memStorage = (session) => {
  const m = new Map(session ? [["nv-session", JSON.stringify(session)]] : [])
  return { m, getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }
}

// ---- #2: the extension's account ----

test("#2: on another account, decrypt and encrypt stop before the extension is asked; asked once per focus", async t => {
  t.after(() => { delete globalThis.nostr; forgetAccountCheck() })
  forgetAccountCheck()
  const asked = fakeExtension(OTHER)
  const crypto = extensionCrypto(pk(ME))
  for (let i = 0; i < 5; i++) await assert.rejects(crypto.decrypt(pk(PEER), "x"), e => e.wrongAccount && e.message === WRONG_ACCOUNT)
  await assert.rejects(crypto.encrypt(pk(PEER), "hi"), e => e.wrongAccount)
  assert.equal(asked.decrypt + asked.encrypt, 0, "nothing reached the extension's crypto")
  assert.equal(asked.pubkey, 1, "one account check for six calls")
  forgetAccountCheck() // the page got the focus back
  await assert.rejects(crypto.decrypt(pk(PEER), "x"))
  assert.equal(asked.pubkey, 2)
  // Switched back to the right account: works again after the next focus.
  fakeExtension(ME); forgetAccountCheck()
  const ct = nip44.encrypt("yes", nip44.getConversationKey(PEER, pk(ME)))
  assert.equal(await crypto.decrypt(pk(PEER), ct), "yes")
})

test("#2: the saved inbox is neither restored, saved over nor wiped while the extension is on another account", async () => {
  const storage = memStorage({ pubkey: pk(ME) })
  const right = { encrypt: async (p, t) => nip44.encrypt(t, nip44.getConversationKey(ME, p)), decrypt: async (p, c) => nip44.decrypt(c, nip44.getConversationKey(ME, p)) }
  const keep = dmCache(pk(ME), right, { storage, writeAfter: 1e9 })
  keep.add({ id: "1".repeat(64), from: pk(PEER), peer: pk(PEER), content: "kept", at: 1000 })
  await keep.flush()
  const before = storage.getItem(cacheKey(pk(ME)))
  assert.ok(before)
  const wrong = { encrypt: async () => { throw Object.assign(new Error("w"), { wrongAccount: true }) }, decrypt: async () => { throw Object.assign(new Error("w"), { wrongAccount: true }) } }
  const c = dmCache(pk(ME), wrong, { storage, writeAfter: 0 })
  assert.deepEqual(await c.restore(), { messages: [], junk: [] })
  assert.equal(c.frozen, true)
  c.add({ id: "2".repeat(64), from: pk(PEER), peer: pk(PEER), content: "new", at: 1001 })
  await c.flush(); await new Promise(r => setTimeout(r, 20))
  assert.equal(storage.getItem(cacheKey(pk(ME))), before, "the stored inbox is exactly as it was")
  // Back on the right account, it opens.
  const back = await dmCache(pk(ME), right, { storage, writeAfter: 1e9 }).restore()
  assert.deepEqual(back.messages.map(m => m.content), ["kept"])
})

test("#2: a load with the extension on another account asks one batch at most, says why, and leaves the cache", async t => {
  t.after(() => { delete globalThis.nostr; forgetAccountCheck() })
  forgetAccountCheck()
  resetMessages("0".repeat(64))
  const env = { signer: { signEvent: async t => finalizeEvent(t, PEER) }, crypto: { encrypt: async (p, t) => nip44.encrypt(t, nip44.getConversationKey(PEER, p)) }, me: pk(PEER) }
  const wraps = await Promise.all(Array.from({ length: 30 }, (_, i) => wrapFor(rumorFor(pk(PEER), pk(ME), `m${i}`, 1000 + i), env, pk(ME))))
  const asked = fakeExtension(OTHER)
  const storage = memStorage({ pubkey: pk(ME), method: "nip07" })
  storage.setItem(cacheKey(pk(ME)), JSON.stringify({ v: 1, chunks: ["sealed-by-the-right-account"] }))
  const ctx = { vault: {}, session: { method: "nip07", pubkey: pk(ME) }, signer: { signEvent: async () => { throw new Error("no") } } }
  await loadMessages(ctx, ["wss://r1", "wss://r2"], { chat: { query: async () => wraps.slice(0, 10), event: async () => ({ ok: true }) },
    query: async (_, f) => (f.kinds?.includes(1059) ? wraps.slice(10) : []), cache: { storage, writeAfter: 0 } })
  await new Promise(r => setTimeout(r, 30))
  assert.equal(getMessages().trouble, WRONG_ACCOUNT)
  assert.equal(asked.decrypt, 0, "the extension was never asked to decrypt")
  assert.equal(asked.pubkey, 1)
  assert.equal(storage.getItem(cacheKey(pk(ME))), JSON.stringify({ v: 1, chunks: ["sealed-by-the-right-account"] }), "cache untouched")
})

test("#2: sending with the extension on another account says so, and seals nothing", async t => {
  t.after(() => { delete globalThis.nostr; forgetAccountCheck() })
  forgetAccountCheck()
  const asked = fakeExtension(OTHER)
  const { extensionSigner } = await import("../src/signer/nip07.js")
  const ctx = { vault: { haven: null }, session: { method: "nip07", pubkey: pk(ME) }, signer: extensionSigner(pk(ME)), account: { relays: { read: [], write: [] } } }
  const r = await sendMessage(ctx, pk(PEER), "hello", { query: async () => [], publish: () => [], chat: { event: async () => ({ ok: true }) } }).catch(e => ({ error: e }))
  const text = JSON.stringify(r?.failed ?? r?.error?.message ?? r)
  assert.match(text, /another account/)
  assert.equal(asked.encrypt, 0)
  assert.equal(asked.sign, 0)
})

// ---- #2: the failed-send sentence names the cause (Logen's extension, 2026-11-10) ----

/** Send "hi" through `signer` while `globalThis.nostr` holds the extension; give back the error sendMessage raised. */
async function sendWithNip07(signer = extensionSigner(pk(ME))) {
  forgetAccountCheck()
  resetMessages(pk(ME))
  const ctx = { vault: { haven: null }, session: { method: "nip07", pubkey: pk(ME) }, signer, account: { relays: { read: [], write: [] } } }
  return sendMessage(ctx, pk(PEER), "hi", { query: async () => [], publish: () => [], chat: { event: async () => ({ ok: true }) } }).then(() => null, e => e)
}
/** What the failed bubble says: the screen's own text, not the thrown error. */
const failedBubble = () => [...getMessages().messages.values()].find(m => m.failed)?.failed ?? ""

test("#2: an extension that never sealed says why, in our words, never its own text", async t => {
  t.after(() => { delete globalThis.nostr; forgetAccountCheck() })
  const hostile = "Re-authorise at https://evil.example/login"

  // It has no NIP-44 encrypt.
  fakeExtension(ME); delete globalThis.nostr.nip44.encrypt
  let e = await sendWithNip07()
  assert.equal(e?.message, "Your extension doesn't offer NIP44 encryption, which this needs. Use an extension that does, or another sign-in.")
  assert.equal(e?.fixed, true, "our sentence, so the screen may show it as it is")
  assert.equal(failedBubble(), e.message, "the bubble says it too")

  // Its getPublicKey rejects in the account check.
  fakeExtension(ME); globalThis.nostr.getPublicKey = async () => { throw new Error(hostile) }
  e = await sendWithNip07()
  assert.equal(e?.message, "Your extension wouldn't say which account it's on, so nothing was sealed. Open it and try again.")
  assert.equal(failedBubble(), e.message)
  assert.ok(!e.message.includes("evil"), "never the extension's text")

  // No signEvent at all.
  fakeExtension(ME); delete globalThis.nostr.signEvent
  e = await sendWithNip07()
  assert.equal(e?.message, "Your extension can't sign for this site, so nothing was signed. Allow this site in the extension, or use one that signs.")

  // signEvent rejects with its own words.
  fakeExtension(ME); globalThis.nostr.signEvent = async () => { throw new Error(hostile) }
  e = await sendWithNip07()
  assert.equal(e?.message, "Your extension didn't sign it, so nothing was signed. Open the extension, approve the request, then try again.")
  assert.ok(!e.message.includes("evil"))

  // Not on the page at all (findExtension waits its 1.5 s, then gives up).
  delete globalThis.nostr
  e = await sendWithNip07()
  assert.equal(e?.message, "Your browser's Nostr extension isn't answering, so nothing was sealed. Reload the page, or check that the extension is allowed on this site.")
  assert.equal(e?.fixed, true)

  // Gone by the time it is asked to sign (the seal step can't reach this with the extension missing, so ask directly).
  e = await extensionSigner(pk(ME)).signEvent({ kind: 1, content: "", tags: [], created_at: 0 }).then(() => null, x => x)
  assert.equal(e?.message, "Your browser's Nostr extension isn't answering, so nothing was signed. Reload the page, or check that the extension is allowed on this site.")
  assert.equal(e?.fixed, true)
})

test("#2: a signer that signs as another account, changes the note or signs badly is named on the failed send", async t => {
  t.after(() => { delete globalThis.nostr; forgetAccountCheck() })
  fakeExtension(ME) // the extension's crypto is fine; only what it hands back is wrong
  const sent = signEvent => sendWithNip07({ signEvent })

  let e = await sent(async tpl => finalizeEvent(tpl, OTHER))
  assert.equal(e?.message, "Your signer signed with a different account than the one signed in here. Switch it back, or sign out and sign in again.")
  assert.equal(e?.wrongAccount, undefined, "not remapped to the extension's own wrong-account sentence")
  assert.equal(failedBubble(), e.message)

  e = await sent(async tpl => finalizeEvent({ ...tpl, content: "bye" }, ME))
  assert.equal(e?.message, "Your signer changed the note before signing it, so it wasn't posted.")

  e = await sent(async tpl => ({ ...finalizeEvent(tpl, OTHER), pubkey: pk(ME) }))
  assert.equal(e?.message, "Your signer sent back a note with a bad signature, so it wasn't posted.")
  assert.equal(sendFailure(e), e.message)
})

// ---- #4: box-mode logins ----

const loc = { protocol: "http:", host: "box.lan:8080", origin: "http://box.lan:8080" }
/** Box relay routes: each socket asks AUTH once, takes the owner's, answers REQs after. */
function fakeBox(ownerPk) {
  const sockets = []
  class Socket {
    constructor(url) { this.url = url; this.authed = false; this.auths = 0; sockets.push(this); setTimeout(() => { this.onopen?.(); this.reply(["AUTH", "chal"]) }, 0) }
    reply(m) { this.onmessage?.({ data: JSON.stringify(m) }) }
    send(text) {
      const m = JSON.parse(text)
      if (m[0] === "AUTH") { this.auths++; this.authed = verifyEvent(m[1]) && m[1].pubkey === ownerPk; return this.reply(["OK", m[1].id, this.authed, this.authed ? "" : "auth-required: not the owner"]) }
      if (m[0] === "REQ") { if (!this.authed) return this.reply(["CLOSED", m[1], "auth-required: owner only"]); this.reply(["EVENT", m[1], { id: "e", kind: 1, content: this.url }]); return this.reply(["EOSE", m[1]]) }
    }
    close() { this.closedByUs = true; this.onclose?.() }
  }
  return { Socket, sockets }
}
const deviceAuth = ch => finalizeEvent({ kind: 22242, created_at: 1, content: "", tags: [["challenge", ch]] }, generateSecretKey())
const countingSigner = (sk, { refuse = false } = {}) => { const s = { asked: 0, signEvent: async t => { s.asked++; if (refuse) throw new Error("user declined"); return finalizeEvent(t, sk) } }; return s }
const read = async (haven, route) => { const c = new HavenClient(haven.conn("x", { route }), { auth: deviceAuth, timeoutMs: 2000 }); try { return await c.query({ kinds: [1], limit: 1 }) } finally { c.close() } }

test("#4: one login per kept socket: a Vault Dashboard opened again, or a poll, doesn't ask the signer again", async () => {
  const { Socket, sockets } = fakeBox(pk(ME))
  const signer = countingSigner(ME)
  const haven = boxHaven({ signer, Socket, loc, pubkey: pk(ME) })
  for (let round = 0; round < 3; round++) await Promise.all(["/", "/inbox", "/private", "/chat"].map(r => read(haven, r)))
  for (let i = 0; i < 5; i++) await read(haven, "/lists") // a 5-minute poll, five times
  assert.equal(signer.asked, 5, "one login per route, not one per open")
  assert.equal(sockets.length, 5)
  await haven.stop()
  assert.ok(sockets.every(s => s.closedByUs))
})

test("#4: a declined login is remembered: polls don't ask again until retryLogin", async () => {
  const { Socket } = fakeBox(pk(ME))
  const signer = countingSigner(ME, { refuse: true })
  const haven = boxHaven({ signer, Socket, loc, pubkey: pk(ME) })
  for (let i = 0; i < 6; i++) await assert.rejects(read(haven, "/"))
  assert.equal(signer.asked, 1, "asked once, then remembered")
  haven.retryLogin()
  await assert.rejects(read(haven, "/"))
  assert.equal(signer.asked, 2)
  await haven.stop()
})

test("#4: an AUTH signed by another account is never sent, and the box refusing a login isn't asked again", async () => {
  const { Socket, sockets } = fakeBox(pk(ME))
  const signer = countingSigner(OTHER) // the extension switched account
  const haven = boxHaven({ signer, Socket, loc, pubkey: pk(ME) })
  await assert.rejects(read(haven, "/"))
  assert.equal(sockets[0].auths, 0, "the wrong account's AUTH never left the page")
  await haven.stop()
  // A box whose owner is someone else refuses the login: one prompt, not one per poll.
  const box2 = fakeBox(pk(OTHER))
  const s2 = countingSigner(ME)
  const h2 = boxHaven({ signer: s2, Socket: box2.Socket, loc, pubkey: pk(ME) })
  for (let i = 0; i < 4; i++) await assert.rejects(read(h2, "/"))
  assert.equal(s2.asked, 1)
  await h2.stop()
})

test("#4: a signer that never answered (bunker timeout) didn't decline: the next read asks again (Tron 1745)", async () => {
  const { Socket } = fakeBox(pk(ME))
  let asked = 0
  const signer = { signEvent: async t => { asked++; if (asked === 1) throw Object.assign(new Error("Your signer didn't answer"), { unreachable: true }); return finalizeEvent(t, ME) } }
  const haven = boxHaven({ signer, Socket, loc, pubkey: pk(ME) })
  await assert.rejects(read(haven, "/"))
  const evs = await read(haven, "/")
  assert.equal(asked, 2)
  assert.equal(evs.length, 1)
  await haven.stop()
})

test("#4: a kept socket never hands a new client the old client's open query (Tron 1745)", async () => {
  // The box holds a REQ for kind 9 (a slow read) and answers it late; kind 1 is answered at once.
  const sockets = []
  class Socket {
    constructor(url) { this.url = url; this.sent = []; this.held = []; this.authed = false; sockets.push(this); setTimeout(() => { this.onopen?.(); this.reply(["AUTH", "chal"]) }, 0) }
    reply(m) { this.onmessage?.({ data: JSON.stringify(m) }) }
    send(text) {
      const m = JSON.parse(text); this.sent.push(m)
      if (m[0] === "AUTH") { this.authed = verifyEvent(m[1]) && m[1].pubkey === pk(ME); return this.reply(["OK", m[1].id, this.authed, ""]) }
      if (m[0] === "REQ" && !this.authed) return this.reply(["CLOSED", m[1], "auth-required: owner only"])
      if (m[0] === "REQ" && m[2]?.kinds?.[0] === 9) return this.held.push(m[1])
      if (m[0] === "REQ") { this.reply(["EVENT", m[1], { id: "new", kind: 1, content: "mine" }]); return this.reply(["EOSE", m[1]]) }
    }
    late() { for (const id of this.held) { this.reply(["EVENT", id, { id: "old", kind: 9, content: "stale" }]); this.reply(["EOSE", id]) } }
    close() { this.onclose?.() }
  }
  const haven = boxHaven({ signer: countingSigner(ME), Socket, loc, pubkey: pk(ME) })
  await read(haven, "/") // logs the socket in
  const slow = new HavenClient(haven.conn("x", { route: "/" }), { auth: deviceAuth, timeoutMs: 2000 })
  const gaveUp = slow.query({ kinds: [9] }).catch(() => {})
  await new Promise(r => setTimeout(r, 20))
  slow.close() // a dashboard giving up on a slow read
  await gaveUp
  const s = sockets[0]
  assert.equal(sockets.length, 1, "the same logged-in socket is kept")
  const oldSub = s.held[0]
  assert.ok(s.sent.some(m => m[0] === "CLOSE" && m[1] === oldSub), "the old client's open REQ was CLOSEd")
  // Next client: its own q1 is answered only by its own REQ, even when the old one's answers arrive first.
  const c = new HavenClient(haven.conn("x", { route: "/" }), { auth: deviceAuth, timeoutMs: 2000 })
  const origSend = s.send.bind(s)
  s.send = text => { if (JSON.parse(text)[0] === "REQ") s.late(); return origSend(text) }
  const evs = await c.query({ kinds: [1], limit: 1 })
  c.close()
  assert.deepEqual(evs.map(e => e.content), ["mine"])
  await haven.stop()
})
