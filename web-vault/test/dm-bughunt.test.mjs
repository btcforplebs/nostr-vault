// DM fixes from the web bug hunt (RESEARCH/NV_BUG_HUNT_WEB_2026_11_05.md #3, #4, #6, #9, open-chat notifications, the
// live rate cap). Throwaway keys only; nothing reaches a relay.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import { rumorFor, wrapFor, unwrap, loadMessages, resetMessages, getMessages, conversations, threadShown, watchMessages, dmTime, TROUBLE_UNREACHABLE } from "../src/net/dms.js"
import { dmCache } from "../src/net/dm-cache.js"
import { dmOnScreen } from "../src/net/dm-notify.js"

const A = generateSecretKey(), B = generateSecretKey()
const pk = sk => getPublicKey(sk)
const ME = pk(A)
const cryptoOf = (sk, asked = { enc: 0, dec: 0 }) => ({
  asked,
  encrypt: async (peer, t) => { asked.enc++; return nip44.encrypt(t, nip44.getConversationKey(sk, peer)) },
  decrypt: async (peer, c) => { asked.dec++; return nip44.decrypt(c, nip44.getConversationKey(sk, peer)) },
})
const envB = { signer: { signEvent: async t => finalizeEvent(t, B) }, crypto: cryptoOf(B), me: pk(B) }
const now = () => Math.floor(Date.now() / 1000)

test("#3: a rumor's absurd time can't break the lists that draw it", async () => {
  const rumor = rumorFor(pk(B), ME, "from the year 318857", 1e13)
  const wrap = await wrapFor(rumor, envB, ME)
  const m = await unwrap(wrap, cryptoOf(A), ME)
  assert.ok(m.at <= now() + 1, "read as now, not 1e13")
  const c = conversations(new Map([[m.id, m]]))
  assert.doesNotThrow(() => new Date(c[0].last.at * 1000).toISOString())
  assert.equal(dmTime(1e13, 1000), 1000)
  assert.equal(dmTime("x"), 0)
  assert.equal(dmTime(-5), 0)
  assert.equal(dmTime(1_700_000_000), 1_700_000_000)
})

test("#3: a cached row with an absurd time reads as now too", async () => {
  const m = new Map([["nv-session", JSON.stringify({ pubkey: ME })]])
  const storage = { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }
  const crypto = cryptoOf(A)
  const c = dmCache(ME, crypto, { storage, writeAfter: 1e9 })
  c.add({ id: "a".repeat(64), from: pk(B), peer: pk(B), content: "x", at: 9e15 })
  await c.flush()
  const back = await dmCache(ME, crypto, { storage, writeAfter: 1e9 }).restore()
  assert.ok(back.messages[0].at <= now() + 1)
})

test("#4: a blocked person's messages aren't drawn; the user's own stay", () => {
  const peer = pk(B)
  const msgs = new Map([
    ["1".repeat(64), { id: "1".repeat(64), from: peer, peer, content: "theirs", at: 1 }],
    ["2".repeat(64), { id: "2".repeat(64), from: ME, peer, content: "mine", at: 2 }],
  ])
  assert.deepEqual(threadShown(msgs, peer, { blocked: new Set([peer]), me: ME }).map(m => m.content), ["mine"])
  assert.deepEqual(threadShown(msgs, peer, { blocked: new Set(), me: ME }).map(m => m.content), ["theirs", "mine"])
})

test("#6: a message kept while the cache is being written is not lost", async () => {
  const m = new Map([["nv-session", JSON.stringify({ pubkey: ME })]])
  const storage = { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }
  const real = cryptoOf(A)
  let release
  const gate = new Promise(r => { release = r })
  let held = true
  const slow = { ...real, encrypt: async (p, t) => { if (held) { held = false; await gate } return real.encrypt(p, t) } }
  const c = dmCache(ME, slow, { storage, writeAfter: 1e9 })
  const msg = n => ({ id: String(n).repeat(64), from: pk(B), peer: pk(B), content: `m${n}`, at: 1000 + n })
  c.add(msg(1))
  const first = c.flush() // encrypting m1, waiting on the bunker
  await new Promise(r => setTimeout(r, 5))
  c.add(msg(2)) // lands mid-write
  release()
  await first
  await c.flush()
  const back = await dmCache(ME, real, { storage, writeAfter: 1e9 }).restore()
  assert.deepEqual(back.messages.map(x => x.content).sort(), ["m1", "m2"])
})

test("#9: a signer that stops answering twice ends the load's opening", async () => {
  resetMessages("0".repeat(64))
  const wraps = await Promise.all(Array.from({ length: 30 }, (_, i) => wrapFor(rumorFor(pk(B), ME, `w${i}`, 1000 + i), envB, ME)))
  let asked = 0
  const offline = { encrypt: async () => { throw Object.assign(new Error("no answer"), { unreachable: true }) },
    decrypt: async () => { asked++; throw Object.assign(new Error("no answer"), { unreachable: true }) } }
  const ctx = { vault: {}, session: { method: "nip46", pubkey: ME }, signer: {} }
  const relayWraps = (n) => wraps.slice(n * 8, n * 8 + 8)
  const query = async ([url], f) => (f.kinds?.includes(1059) ? relayWraps(Number(url.at(-1))) : [])
  await loadMessages(ctx, ["wss://r1", "wss://r2", "wss://r3"], { crypto: offline, chat: { query: async () => wraps.slice(0, 8), event: async () => ({ ok: true }) }, cache: null, query })
  assert.ok(asked <= 16, `two batches asked (two timeouts), then stopped, not five (asked ${asked})`)
  assert.equal(getMessages().trouble, TROUBLE_UNREACHABLE)
})

test("desktop: the open conversation (#/messages?dm=) counts as on screen, so it doesn't notify", () => {
  const doc = { visibilityState: "visible" }
  const hex = "ab".repeat(32)
  assert.equal(dmOnScreen(doc, `#/dm/${hex}`), hex)
  assert.equal(dmOnScreen(doc, `#/messages?dm=${hex}`), hex)
  assert.equal(dmOnScreen(doc, `#/messages/requests?dm=${hex}&note=x`), hex)
  assert.equal(dmOnScreen(doc, "#/messages"), null)
  assert.equal(dmOnScreen({ visibilityState: "hidden" }, `#/messages?dm=${hex}`), null)
})

test("the live rate cap is one per page, however many screens listen", async () => {
  resetMessages(ME)
  const asked = { enc: 0, dec: 0 }
  const crypto = cryptoOf(A, asked)
  const handlers = []
  const subscribe = (r, f, o) => { handlers.push(o.onevent); return { close() {} } }
  const ctx = { vault: {}, session: { method: "nip46", pubkey: ME }, signer: {} }
  const chat = { event: async () => ({ ok: true }), query: async () => [] }
  for (let i = 0; i < 4; i++) watchMessages(ctx, ["wss://r"], { crypto, chat, subscribe, clock: () => 1000 })
  const wraps = await Promise.all(Array.from({ length: 12 }, (_, i) => wrapFor(rumorFor(pk(B), ME, `live${i}`, 1000 + i), envB, ME)))
  for (let i = 0; i < wraps.length; i++) await handlers[i % 4](wraps[i])
  // Each opened wrap is two decrypts (wrap, seal). 6 a minute through a bunker, for the whole page.
  assert.equal(asked.dec, 12)
})
