// Sign-in with a password-locked key (NIP-49 ncryptsec) made by another app (NDK check step 4, Logen 2026-11-04):
// signer/local.js lockedKeySession. Throwaway keys, in-memory key store; nothing is sent.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, verifyEvent } from "nostr-tools/pure"
import { encrypt as ncryptsecOf } from "nostr-tools/nip49"
import { nsecEncode } from "nostr-tools/nip19"
import { bytesToHex } from "nostr-tools/utils"
import { lockedKeySession, localSigner, revealNsec, NOT_LOCKED_KEY, WRONG_PASSWORD } from "../src/signer/local.js"

function memKeys() {
  const m = new Map()
  return { m, get: async n => m.get(n), add: async (n, k) => { if (m.has(n)) throw new Error("exists"); m.set(n, k) } }
}
const PW = "another app's password"

test("a locked key from another app signs in; the session keeps that same locked copy and never the key in the clear", async () => {
  const sk = generateSecretKey(), pubkey = getPublicKey(sk)
  const locked = ncryptsecOf(sk, PW, 4) // another app's cost; any 1-20 opens here
  const ks = memKeys()
  const s = await lockedKeySession(`  ${locked.toUpperCase()}\n`, PW, { keyStore: ks })
  assert.equal(s.method, "local")
  assert.equal(s.pubkey, pubkey)
  assert.equal(s.ncryptsec, locked, "the copy the user can take away again, unchanged")
  const stored = JSON.stringify(s)
  for (const secret of [bytesToHex(sk), nsecEncode(sk), PW]) assert.ok(!stored.includes(secret), "session leaks a secret")
  const signer = localSigner(s, { keyStore: ks })
  const ev = await signer.signEvent({ kind: 1, created_at: 1, tags: [], content: "gm" })
  assert.equal(ev.pubkey, pubkey)
  assert.ok(verifyEvent(ev))
  assert.equal(revealNsec(s, PW), nsecEncode(sk), "Your Secret Key opens it with the same password")
})

test("a wrong password or something that isn't a locked key signs nothing in", async () => {
  const sk = generateSecretKey()
  const locked = ncryptsecOf(sk, PW, 4)
  await assert.rejects(lockedKeySession(locked, "not it", { keyStore: memKeys() }), { message: WRONG_PASSWORD })
  for (const bad of ["", nsecEncode(sk), "npub1xyz", "ncryptsec1notakey", locked.slice(0, -4) + "qqqq"]) {
    await assert.rejects(lockedKeySession(bad, PW, { keyStore: memKeys() }), { message: NOT_LOCKED_KEY }, bad.slice(0, 12))
  }
})
