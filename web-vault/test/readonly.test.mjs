// Read-only sign-in: what it accepts, what it refuses, and that it can never sign.
import test from "node:test"
import assert from "node:assert/strict"
import { npubEncode, nprofileEncode, nsecEncode } from "nostr-tools/nip19"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { resolvePubkey, readonlySignIn, namesAKey, READ_ONLY } from "../src/signer/readonly.js"
import { signerFor } from "../src/signer/index.js"
import { saveSession, loadSession, loadAccounts, rememberAccount, signedInWith } from "../src/session.js"

const pk = getPublicKey(generateSecretKey())
const noLookup = async () => { throw new Error("should not look up") }

function memStorage() {
  const m = new Map()
  return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) }
}

test("an npub, nostr:npub, nprofile or hex resolves to the pubkey without a lookup", async () => {
  for (const input of [npubEncode(pk), ` nostr:${npubEncode(pk)} `, nprofileEncode({ pubkey: pk, relays: ["wss://r.example"] }), pk, pk.toUpperCase()])
    assert.equal(await resolvePubkey(input, noLookup), pk, input)
})

test("a NIP-05 name is looked up, and a miss says so", async () => {
  const seen = []
  const lookup = async s => { seen.push(s); return s === "logen@example.com" || s === "example.com" ? { pubkey: pk } : null }
  assert.equal(await resolvePubkey("logen@example.com", lookup), pk)
  assert.equal(await resolvePubkey("example.com", lookup), pk)
  await assert.rejects(resolvePubkey("nobody@example.com", lookup), /Couldn't find nobody@example.com/)
  await assert.rejects(resolvePubkey("x@example.com", async () => { throw new Error("CORS") }), /Couldn't find/)
  await assert.rejects(resolvePubkey("bad@example.com", async () => ({ pubkey: "not-hex" })), /isn't a public key/)
  assert.deepEqual(seen, ["logen@example.com", "example.com", "nobody@example.com"])
})

test("an nsec is refused and never looked up", async () => {
  await assert.rejects(resolvePubkey(nsecEncode(generateSecretKey()), noLookup), /secret key/)
})

test("junk and empty input are refused", async () => {
  for (const bad of ["", "   ", "hello", "npub1notreal", "a".repeat(63)])
    await assert.rejects(resolvePubkey(bad, noLookup), Error, bad)
})

test("a read-only session is saved and remembered like any other, and its signer never signs", async () => {
  const { signer, session } = await readonlySignIn(npubEncode(pk), noLookup, [])
  assert.deepEqual(session, { method: "readonly", pubkey: pk })
  const storage = memStorage()
  saveSession(session, storage)
  assert.deepEqual(loadSession(storage), session)
  assert.deepEqual(loadAccounts(storage), [session])
  storage.setItem("nv-accounts", JSON.stringify([session, { method: "nsec", pubkey: pk }]))
  assert.deepEqual(loadAccounts(storage), [session], "an unknown method is still dropped")
  for (const s of [signer, signerFor(session)]) {
    assert.equal(s.readOnly, true)
    assert.equal(s.crypto, undefined)
    await assert.rejects(s.signEvent({ kind: 1, created_at: 0, tags: [], content: "hi" }), { message: READ_ONLY })
  }
  assert.equal(signedInWith("readonly"), "read-only (no signer)")
})

test("a name is searched; a key or NIP-05 goes straight in", () => {
  for (const key of [npubEncode(pk), "nostr:" + npubEncode(pk), nprofileEncode({ pubkey: pk }), pk, nsecEncode(generateSecretKey()), "logen@example.com", "example.com", "_@loge.media"])
    assert.equal(namesAKey(key), true, key)
  for (const name of ["Logen", "logan detty", "jack", "", "fiatjaf "])
    assert.equal(namesAKey(name), false, name)
})

test("a NIP-05 host that never answers gives up with a plain error instead of holding sign-in", async () => {
  const t0 = Date.now()
  await assert.rejects(resolvePubkey("slow@example.com", () => new Promise(r => setTimeout(() => r({ pubkey: pk }), 1500)), 50), /slow@example.com didn't answer in 0.05 seconds/)
  assert.ok(Date.now() - t0 < 1000)
})

test("a NIP-05 name is looked up in lowercase", async () => {
  const seen = []
  assert.equal(await resolvePubkey("Logen@Example.COM", async s => { seen.push(s); return { pubkey: pk } }), pk)
  assert.deepEqual(seen, ["logen@example.com"])
})

test("read-only never replaces a saved signer account for the same npub", async () => {
  const bunker = { method: "nip46", pubkey: pk, bunker: { pubkey: "c".repeat(64), relays: ["wss://r.example"], secret: null }, clientSkSealed: "sealed" }
  const ext = { method: "nip07", pubkey: pk }
  for (const saved of [bunker, ext]) {
    await assert.rejects(readonlySignIn(npubEncode(pk), noLookup, [saved]), /already on this browser/)
    const storage = memStorage()
    rememberAccount(saved, storage)
    rememberAccount({ method: "readonly", pubkey: pk }, storage) // the store guards too
    assert.deepEqual(loadAccounts(storage), [saved])
  }
  // A different npub, or a saved read-only one, is fine; and a signer may replace read-only.
  const other = getPublicKey(generateSecretKey())
  assert.equal((await readonlySignIn(npubEncode(pk), noLookup, [{ method: "nip46", pubkey: other }])).session.method, "readonly")
  assert.equal((await readonlySignIn(npubEncode(pk), noLookup, [{ method: "readonly", pubkey: pk }])).session.method, "readonly")
  const storage = memStorage()
  rememberAccount({ method: "readonly", pubkey: pk }, storage)
  rememberAccount(ext, storage)
  assert.deepEqual(loadAccounts(storage), [ext])
})
