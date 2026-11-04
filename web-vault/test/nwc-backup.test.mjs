// The wallet connection saved on the user's Nostr account (net/nwc-backup.js), as the iPhone (NWCBackup.swift,
// NWCBackupService.swift) and Android (NwcBackup.kt) save it, in Wisp's format. Throwaway keys made per run; no relay
// is opened and nothing is published (fake relays and a fake publish).
import test from "node:test"
import assert from "node:assert/strict"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import {
  BACKUP_KIND, BACKUP_D, SAVED_TAGS, CLEARED_TAGS, BACKUP_ERRORS, isBackup, isCleared, walletString, isCiphertext,
  backupStatus, offersRemove, describeStatus, newestSlot, lockAccount, readBackup, saveBackup, clearBackup,
} from "../src/net/nwc-backup.js"

const hex = n => n.toString(16).padStart(64, "0")
const URI = `nostr+walletconnect://${hex(0xabc)}?relay=wss://relay.example&secret=${hex(0x5ec)}`
const now = () => Math.floor(Date.now() / 1000)

/** A throwaway account with a signer shaped like signer/local.js (NIP-44 v2 to a peer). */
function account(method = "local") {
  const sk = generateSecretKey(), pubkey = getPublicKey(sk)
  const key = peer => nip44.v2.utils.getConversationKey(sk, peer)
  const signer = {
    method, readOnly: method === "readonly",
    signEvent: async t => finalizeEvent({ ...t }, sk),
    crypto: method === "readonly" ? undefined : {
      encrypt: async (peer, text) => nip44.v2.encrypt(text, key(peer)),
      decrypt: async (peer, c) => nip44.v2.decrypt(c, key(peer)),
    },
  }
  const ctx = { session: { method, pubkey }, signer, account: { relays: { read: ["wss://r1"], write: ["wss://w1"] } }, vault: {} }
  return { sk, pubkey, ctx, slot: (content, tags = SAVED_TAGS, at = now() - 60) => finalizeEvent({ kind: BACKUP_KIND, created_at: at, tags, content }, sk) }
}
/** Relays: each answers with `events` (EOSE) unless listed in `silent`. */
const relays = (events, { silent = [] } = {}) => async (url, filter) => {
  assert.deepEqual(filter, { kinds: [30078], authors: [filter.authors[0]], "#d": ["nwc-wallet-backup"] })
  return silent === true || silent.includes(url) ? { events: [], answered: false } : { events, answered: true }
}
const publisher = () => {
  const out = []
  return { out, publish: async (ctx, t) => { const ev = await ctx.signer.signEvent(t); out.push(ev); return { event: ev } } }
}

test("the slot is Wisp's: kind 30078, d nwc-wallet-backup, client + encryption nip44; removal is empty + deleted=true", () => {
  assert.equal(BACKUP_KIND, 30078)
  assert.equal(BACKUP_D, "nwc-wallet-backup")
  assert.deepEqual(SAVED_TAGS, [["d", "nwc-wallet-backup"], ["client", "Nostr Vault"], ["encryption", "nip44"]])
  assert.deepEqual(CLEARED_TAGS, [["d", "nwc-wallet-backup"], ["deleted", "true"]])
  assert.ok(isBackup({ kind: 30078, tags: [["d", "nwc-wallet-backup"]] }))
  assert.ok(!isBackup({ kind: 30078, tags: [["d", "something-else"]] }))
  assert.ok(isCleared("", [])); assert.ok(isCleared("  \n", [])); assert.ok(isCleared("abc", CLEARED_TAGS)); assert.ok(!isCleared("abc", SAVED_TAGS))
})

test("a wallet string is trimmed and starts with nostr+walletconnect:// in any case; only ciphertext may be published", () => {
  assert.equal(walletString(`  ${URI}\n`), URI)
  assert.equal(walletString(URI.replace("nostr+walletconnect", "NOSTR+WalletConnect")), URI.replace("nostr+walletconnect", "NOSTR+WalletConnect"))
  assert.equal(walletString("lightning:abc"), null)
  assert.equal(walletString(""), null)
  assert.ok(!isCiphertext(URI)); assert.ok(!isCiphertext("x WALLETCONNECT y")); assert.ok(!isCiphertext("  ")); assert.ok(isCiphertext("AkFz09sd=="))
})

test("status: no answer is unknown, an answer without a slot is empty, a removed slot is empty, an unread slot is its own state", () => {
  const slot = { content: "cipher", tags: SAVED_TAGS, created_at: 100 }
  assert.deepEqual(backupStatus({ slot: null, answeredAny: false }), { state: "unknown" })
  assert.deepEqual(backupStatus({ slot: null, answeredAny: true }), { state: "empty" })
  assert.deepEqual(backupStatus({ slot: { ...slot, content: "", tags: CLEARED_TAGS }, answeredAny: true }), { state: "empty" })
  assert.deepEqual(backupStatus({ slot, answeredAny: true, read: { tried: false } }), { state: "needsSigner", savedAt: 100 })
  assert.deepEqual(backupStatus({ slot, answeredAny: true, read: { failed: true } }), { state: "unreadable", savedAt: 100 })
  assert.deepEqual(backupStatus({ slot, answeredAny: true, read: { plaintext: "not a wallet" } }), { state: "unreadable", savedAt: 100 })
  assert.deepEqual(backupStatus({ slot, answeredAny: true, read: { plaintext: ` ${URI} ` } }), { state: "saved", uri: URI, savedAt: 100 })
  assert.equal(describeStatus({ state: "saved", uri: URI, savedAt: 100 }), "saved(<redacted>, 100)", "never the link")
})

test("Remove is offered whenever a wallet may be on the account, except when the switch already shows it on", () => {
  const same = u => u === URI
  for (const state of ["unknown", "needsSigner", "unreadable"]) assert.ok(offersRemove({ state }, { connected: true, same }))
  assert.ok(!offersRemove({ state: "empty" }, { connected: true, same }))
  assert.ok(!offersRemove({ state: "saved", uri: URI }, { connected: true, same }), "the switch is on: it removes")
  assert.ok(offersRemove({ state: "saved", uri: URI + "x" }, { connected: true, same }), "another wallet saved")
  assert.ok(offersRemove({ state: "saved", uri: URI }, { connected: false, same }), "nothing in use")
})

test("save, then read back: NIP-44 to the account's own key, readable by any NIP-44 client with that key (Wisp)", async () => {
  const a = account(), p = publisher(), lock = lockAccount(a.ctx, () => a.ctx)
  await saveBackup(lock, `  ${URI}  `, { publish: p.publish })
  assert.equal(p.out.length, 1)
  const ev = p.out[0]
  assert.equal(ev.kind, 30078); assert.equal(ev.pubkey, a.pubkey)
  assert.deepEqual(ev.tags, SAVED_TAGS)
  assert.ok(isCiphertext(ev.content) && !ev.content.includes(URI))
  // What Wisp does: nip44 v2 with the conversation key of its own secret and its own pubkey.
  assert.equal(nip44.v2.decrypt(ev.content, nip44.v2.utils.getConversationKey(a.sk, a.pubkey)), URI, "trimmed, as Wisp writes it")
  const s = await readBackup(a.ctx, { current: () => a.ctx, ask: relays([ev]) })
  assert.deepEqual(s, { state: "saved", uri: URI, savedAt: ev.created_at })
})

test("a slot Wisp wrote (no client or encryption tag) reads the same", async () => {
  const a = account()
  const wisp = a.slot(nip44.v2.encrypt(URI, nip44.v2.utils.getConversationKey(a.sk, a.pubkey)), [["d", "nwc-wallet-backup"]])
  assert.equal((await readBackup(a.ctx, { current: () => a.ctx, ask: relays([wisp]) })).state, "saved")
})

test("reading: the newest verified slot of this account wins; a removal is empty; another key's or a forged slot is ignored", async () => {
  const a = account(), b = account(), cur = () => a.ctx
  const enc = t => nip44.v2.encrypt(t, nip44.v2.utils.getConversationKey(a.sk, a.pubkey))
  const old = a.slot(enc(URI), SAVED_TAGS, now() - 600), cleared = a.slot("", CLEARED_TAGS, now() - 60)
  assert.deepEqual(await readBackup(a.ctx, { current: cur, ask: relays([old, cleared]) }), { state: "empty" })
  const theirs = b.slot("cipher", SAVED_TAGS, now())
  const forged = { ...a.slot(enc(URI + "&forged=1"), SAVED_TAGS, now()), sig: "00".repeat(64) }
  const s = await readBackup(a.ctx, { current: cur, ask: relays([old, theirs, forged]) })
  assert.equal(s.state, "saved"); assert.equal(s.savedAt, old.created_at)
  assert.deepEqual(await readBackup(a.ctx, { current: cur, ask: relays([], { silent: true }) }), { state: "unknown" })
  assert.deepEqual(await readBackup(a.ctx, { current: cur, ask: relays([]) }), { state: "empty" })
})

test("a bunker or an extension isn't asked to decrypt until the user taps; a read-only sign-in can't read it", async () => {
  for (const method of ["nip46", "nip07"]) {
    const a = account(method), cur = () => a.ctx
    let asked = 0
    const decrypt = a.ctx.signer.crypto.decrypt
    a.ctx.signer.crypto.decrypt = (...x) => { asked++; return decrypt(...x) }
    const ev = a.slot(nip44.v2.encrypt(URI, nip44.v2.utils.getConversationKey(a.sk, a.pubkey)))
    assert.equal((await readBackup(a.ctx, { current: cur, ask: relays([ev]) })).state, "needsSigner")
    assert.equal(asked, 0, `${method}: not asked on open`)
    assert.equal((await readBackup(a.ctx, { askSigner: true, current: cur, ask: relays([ev]) })).state, "saved")
    assert.equal(asked, 1)
  }
  const r = account("readonly")
  assert.equal((await readBackup(r.ctx, { current: () => r.ctx, ask: relays([r.slot("cipher")]) })).state, "unreadable")
  await assert.rejects(saveBackup(lockAccount(r.ctx, () => r.ctx), URI, { publish: publisher().publish }), { code: "readOnly" })
  await assert.rejects(clearBackup(lockAccount(r.ctx, () => r.ctx), { publish: publisher().publish }), { code: "readOnly" })
})

test("a decrypt that fails or isn't a wallet is unreadable, not empty", async () => {
  const a = account()
  assert.equal((await readBackup(a.ctx, { current: () => a.ctx, ask: relays([a.slot("garbage")]) })).state, "unreadable")
  const notWallet = a.slot(nip44.v2.encrypt("hello", nip44.v2.utils.getConversationKey(a.sk, a.pubkey)))
  assert.equal((await readBackup(a.ctx, { current: () => a.ctx, ask: relays([notWallet]) })).state, "unreadable")
})

test("a switch to another account while reading answers unknown, not the old account's slot", async () => {
  const a = account(), b = account()
  let ctx = a.ctx
  const ev = a.slot(nip44.v2.encrypt(URI, nip44.v2.utils.getConversationKey(a.sk, a.pubkey)))
  const ask = async (...x) => { const r = await relays([ev])(...x); ctx = b.ctx; return r }
  assert.deepEqual(await readBackup(a.ctx, { current: () => ctx, ask }), { state: "unknown" })
})

test("nothing is published for a link that isn't one, or when the encrypter hands back the plaintext", async () => {
  const a = account(), p = publisher(), lock = lockAccount(a.ctx, () => a.ctx)
  await assert.rejects(saveBackup(lock, "lightning:alice@example.com", { publish: p.publish }), { code: "notAWallet" })
  a.ctx.signer.crypto.encrypt = async (_, text) => text // a broken or hostile signer
  await assert.rejects(saveBackup(lock, URI, { publish: p.publish }), { code: "encryptFailed" })
  a.ctx.signer.crypto.encrypt = async () => { throw new Error(`failed on ${URI}`) }
  const e = await saveBackup(lock, URI, { publish: p.publish }).catch(x => x)
  assert.equal(e.code, "encryptFailed"); assert.ok(!e.message.includes("walletconnect"), "the error never carries the link")
  assert.equal(p.out.length, 0)
})

test("an account switch at any step publishes nothing: before encrypting, after encrypting, at signing", async () => {
  const a = account(), b = account()
  for (const at of ["start", "encrypt", "sign"]) {
    let ctx = a.ctx
    const p = publisher(), lock = lockAccount(a.ctx, () => ctx)
    if (at === "start") ctx = b.ctx
    const enc = a.ctx.signer.crypto.encrypt
    if (at === "encrypt") a.ctx.signer.crypto.encrypt = async (...x) => { const c = await enc(...x); ctx = b.ctx; return c }
    const sign = a.ctx.signer.signEvent
    if (at === "sign") a.ctx.signer.signEvent = async t => { ctx = b.ctx; return sign(t) }
    await assert.rejects(saveBackup(lock, URI, { publish: p.publish }), { code: "accountChanged" }, at)
    assert.equal(p.out.length, 0, at)
    a.ctx.signer.crypto.encrypt = enc; a.ctx.signer.signEvent = sign
  }
  // A sign-out and back in brings a new signer for the same pubkey: the old lock no longer holds.
  let ctx = a.ctx
  const lock = lockAccount(a.ctx, () => ctx)
  ctx = { ...a.ctx, signer: { ...a.ctx.signer } }
  await assert.rejects(clearBackup(lock, { publish: publisher().publish }), { code: "accountChanged" })
  // main.jsx's fresh ctx object each render, same signer: still held.
  ctx = { ...a.ctx }
  assert.ok(lock.held())
})

test("a signer that signs as someone else is refused before it reaches the relays", async () => {
  const a = account(), b = account(), p = publisher()
  a.ctx.signer.signEvent = b.ctx.signer.signEvent
  await assert.rejects(saveBackup(lockAccount(a.ctx, () => a.ctx), URI, { publish: p.publish }), { code: "accountChanged" })
  assert.equal(p.out.length, 0)
})

test("remove: the same slot, empty content and deleted=true, with no decryption", async () => {
  const a = account(), p = publisher()
  a.ctx.signer.crypto.decrypt = async () => { throw new Error("not asked") }
  await clearBackup(lockAccount(a.ctx, () => a.ctx), { publish: p.publish })
  assert.equal(p.out.length, 1)
  assert.equal(p.out[0].kind, 30078); assert.equal(p.out[0].content, ""); assert.deepEqual(p.out[0].tags, CLEARED_TAGS)
})

test("nothing here logs: not the link, not anything", async () => {
  const seen = []
  const saved = {}
  for (const k of ["log", "info", "warn", "error", "debug"]) { saved[k] = console[k]; console[k] = (...x) => seen.push(x) }
  try {
    const a = account(), p = publisher()
    await saveBackup(lockAccount(a.ctx, () => a.ctx), URI, { publish: p.publish })
    await readBackup(a.ctx, { askSigner: true, current: () => a.ctx, ask: relays(p.out) })
    await clearBackup(lockAccount(a.ctx, () => a.ctx), { publish: p.publish })
    await saveBackup(lockAccount(a.ctx, () => null), URI, { publish: p.publish }).catch(() => {})
  } finally { Object.assign(console, saved) }
  assert.deepEqual(seen, [])
})

test("every error message is free of the link", () => {
  for (const m of Object.values(BACKUP_ERRORS)) assert.ok(!/walletconnect:\/\/[0-9a-f]|secret=[0-9a-f]/i.test(m), m)
})

test("newestSlot: ties go to the lower id", () => {
  const a = account(), at = now() - 5
  const x = a.slot("c1", SAVED_TAGS, at), y = a.slot("c2", SAVED_TAGS, at)
  const lower = x.id < y.id ? x : y
  assert.equal(newestSlot([x, y], a.pubkey).id, lower.id)
  assert.equal(newestSlot([y, x], a.pubkey).id, lower.id)
})
