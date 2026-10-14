// Accounts (session.js, signer/accounts.js) and how a bunker session's client key is stored (signer/keyring.js).
// Only throwaway keys.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { bytesToHex } from "nostr-tools/utils"
import { saveSession, loadSession, clearSession, loadAccounts, rememberAccount, forgetAccount } from "../src/session.js"
import { seal, unseal, LOST_KEY } from "../src/signer/keyring.js"
import { setKeyStore, resealSession, bunkerSigner } from "../src/signer/nip46.js"
import { removeAccount, switchAccount, checkExtensionAccount } from "../src/signer/accounts.js"

function memStorage() {
  const m = new Map()
  return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }
}
function memKeyStore() {
  const m = new Map()
  return { m, get: async k => m.get(k), add: async (k, v) => { if (m.has(k)) throw new Error("exists"); m.set(k, v) } }
}
const pk = c => c.repeat(64)
const ext = p => ({ method: "nip07", pubkey: p })

test("signing in remembers the account; a second sign-in adds to the list and becomes active", () => {
  const s = memStorage()
  saveSession(ext(pk("a")), s)
  saveSession(ext(pk("b")), s)
  assert.equal(loadSession(s).pubkey, pk("b"))
  assert.deepEqual(loadAccounts(s).map(a => a.pubkey), [pk("a"), pk("b")])
  saveSession({ ...ext(pk("a")) }, s) // switching back doesn't duplicate it
  assert.deepEqual(loadAccounts(s).map(a => a.pubkey), [pk("a"), pk("b")])
})

test("a session from before the account list counts as an account", () => {
  const s = memStorage()
  s.setItem("nv-session", JSON.stringify(ext(pk("c"))))
  assert.deepEqual(loadAccounts(s).map(a => a.pubkey), [pk("c")])
})

test("the list ignores junk and refuses to remember a malformed account", () => {
  const s = memStorage()
  s.setItem("nv-accounts", JSON.stringify([ext(pk("a")), { method: "nip07", pubkey: "A".repeat(64) }, { method: "nsec", pubkey: pk("d") }, null, 7]))
  assert.deepEqual(loadAccounts(s).map(a => a.pubkey), [pk("a")])
  s.setItem("nv-accounts", "{not json")
  assert.deepEqual(loadAccounts(s), [])
  assert.throws(() => rememberAccount({ method: "nip07", pubkey: "nope" }, s), /not an account/)
})

test("adding an account doesn't switch to it; re-adding replaces its saved sign-in", () => {
  const s = memStorage()
  saveSession(ext(pk("a")), s)
  rememberAccount({ method: "nip46", pubkey: pk("b"), bunker: { pubkey: pk("e"), relays: ["wss://x"] }, clientSkSealed: { iv: "1", ct: "1" } }, s)
  rememberAccount({ method: "nip46", pubkey: pk("b"), bunker: { pubkey: pk("e"), relays: ["wss://y"] }, clientSkSealed: { iv: "2", ct: "2" } }, s)
  assert.equal(loadSession(s).pubkey, pk("a"))
  const b = loadAccounts(s).find(a => a.pubkey === pk("b"))
  assert.deepEqual(b.bunker.relays, ["wss://y"])
  assert.equal(loadAccounts(s).length, 2)
})

test("signing out forgets only the active account; the last one leaves nothing behind", () => {
  const s = memStorage()
  saveSession(ext(pk("a")), s)
  saveSession(ext(pk("b")), s)
  clearSession(s)
  assert.equal(loadSession(s), null)
  assert.deepEqual(loadAccounts(s).map(a => a.pubkey), [pk("a")])
  saveSession(ext(pk("a")), s)
  clearSession(s)
  assert.deepEqual([...s.m.keys()], [])
  assert.deepEqual(forgetAccount(pk("z"), s), [])
})

test("seal/unseal: the stored form isn't the key, and a lost wrapping key says so", async () => {
  const ks = memKeyStore()
  const hex = bytesToHex(generateSecretKey())
  const sealed = await seal(hex, ks)
  assert.ok(!JSON.stringify(sealed).includes(hex))
  assert.equal(await unseal(sealed, ks), hex)
  assert.equal(ks.m.get("wrap").extractable, false, "the wrapping key can't be read out")
  const again = await seal(hex, ks)
  assert.notEqual(again.iv, sealed.iv, "a fresh IV each time")
  await assert.rejects(unseal(sealed, memKeyStore()), e => e.message === LOST_KEY)
  await assert.rejects(unseal({ ...sealed, ct: again.ct }, ks), e => e.message === LOST_KEY)
})

test("two tabs making the wrapping key at once both seal with the one that was stored", async () => {
  const ks = memKeyStore()
  const [a, b] = await Promise.all([seal("aa", ks), seal("bb", ks)])
  assert.equal(await unseal(a, ks), "aa")
  assert.equal(await unseal(b, ks), "bb")
})

test("a bunker session saved with a plain client key is sealed in place, in the session and the list", async () => {
  const ks = memKeyStore()
  setKeyStore(ks)
  const s = memStorage()
  const clientSk = bytesToHex(generateSecretKey())
  const legacy = { method: "nip46", pubkey: getPublicKey(generateSecretKey()), bunker: { pubkey: pk("e"), relays: ["wss://bunker.invalid"], secret: null }, clientSk }
  s.setItem("nv-session", JSON.stringify(legacy))
  const signer = bunkerSigner(legacy, { subscribe: () => ({ close() {} }), publish: () => [] }, s)
  await new Promise(r => setTimeout(r, 50))
  for (const [k, v] of s.m) assert.ok(!v.includes(clientSk), `${k} still holds the plain client key`)
  const now = loadSession(s)
  assert.equal(now.clientSk, undefined)
  assert.equal(await unseal(now.clientSkSealed, ks), clientSk)
  assert.ok(loadAccounts(s)[0].clientSkSealed)
  signer.close()
  // Sealing a non-active account updates the list and leaves the active session alone.
  const other = { ...legacy, pubkey: pk("f") }
  saveSession(ext(pk("a")), s)
  await resealSession(other, s)
  assert.equal(loadSession(s).pubkey, pk("a"))
  assert.ok(loadAccounts(s).find(a => a.pubkey === pk("f")).clientSkSealed)
})

test("a bunker signer whose client key can't be unsealed fails when it's used, with a message", async () => {
  setKeyStore(memKeyStore())
  const signer = bunkerSigner({ method: "nip46", pubkey: pk("a"), bunker: { pubkey: pk("e"), relays: ["wss://bunker.invalid"] }, clientSkSealed: { iv: "AAAAAAAAAAAAAAAA", ct: "AAAA" } }, {}, memStorage())
  await assert.rejects(signer.signEvent({ kind: 1, content: "", tags: [], created_at: 0 }), e => e.message === LOST_KEY)
  assert.equal(await signer.revoke(), false)
})

function fakeIdb(stuck = []) {
  const deleted = []
  return { deleted, databases: async () => [], deleteDatabase(name) { const req = {}; if (!stuck.includes(name)) setTimeout(() => { deleted.push(name); req.onsuccess?.() }); return req } }
}

test("removing an account revokes its bunker, deletes only its own stores and forgets it", async () => {
  const s = memStorage()
  const bunkerAcct = { method: "nip46", pubkey: pk("b"), bunker: { pubkey: pk("e"), relays: ["wss://x"] }, clientSkSealed: {} }
  saveSession(ext(pk("a")), s)
  rememberAccount(bunkerAcct, s)
  const idb = fakeIdb()
  let revokedFor
  const r = await removeAccount({ account: bunkerAcct, pool: {}, storage: s, idb, signerFor: acct => ({ revoke: async () => { revokedFor = acct.pubkey; return true } }) })
  assert.equal(revokedFor, pk("b"))
  assert.deepEqual(r, { failed: [], revoked: true })
  assert.deepEqual(loadAccounts(s).map(a => a.pubkey), [pk("a")])
  assert.ok(idb.deleted.includes(`haven:${pk("b")}:outbox`) && idb.deleted.includes(`haven:${pk("b")}:drafts`))
  assert.ok(idb.deleted.every(n => n.startsWith(`haven:${pk("b")}:`)), "never the legacy stores or another account's")
})

test("removing an extension account asks no bunker; a stuck store is reported; the active account can't be removed", async () => {
  const s = memStorage()
  saveSession(ext(pk("a")), s)
  rememberAccount(ext(pk("c")), s)
  const r = await removeAccount({ account: ext(pk("c")), pool: {}, storage: s, idb: fakeIdb([`haven:${pk("c")}:feed`]), waitMs: 20, signerFor: () => assert.fail("no bunker") })
  assert.deepEqual(r, { failed: [`haven:${pk("c")}:feed`], revoked: null })
  await assert.rejects(removeAccount({ account: ext(pk("a")), pool: {}, storage: s, idb: fakeIdb() }), /Sign out instead/)
  assert.equal(loadSession(s).pubkey, pk("a"))
})

test("switching stops this account's Haven and signer before the session changes, then reloads", async () => {
  const s = memStorage()
  saveSession(ext(pk("a")), s)
  const steps = []
  const vault = { haven: { stop: async () => steps.push(`stop, active ${loadSession(s).pubkey[0]}`) } }
  const signer = { close: () => steps.push("close") }
  await switchAccount({ account: { method: "nip46", pubkey: pk("b"), bunker: {}, clientSkSealed: {} }, vault, signer, storage: s, reload: () => steps.push(`reload, active ${loadSession(s).pubkey[0]}`) })
  assert.deepEqual(steps, ["stop, active a", "close", "reload, active b"])
})

test("an extension account switches only when the extension is signed in as it", async () => {
  await checkExtensionAccount(ext(pk("a")), async () => ({ getPublicKey: async () => pk("a") }))
  await assert.rejects(checkExtensionAccount(ext(pk("a")), async () => ({ getPublicKey: async () => pk("b") })), /different account/)
  await assert.rejects(checkExtensionAccount(ext(pk("a")), async () => undefined), /No Nostr extension/)
})
