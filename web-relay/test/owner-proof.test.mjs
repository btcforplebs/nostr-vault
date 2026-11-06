// The relay page's owner account must be proven by a signature: a typed npub (a watch-only account) gets no access.
import { test, beforeEach } from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { npubEncode, nsecEncode } from "nostr-tools/nip19"
import { encrypt } from "nostr-tools/nip49"
import { bytesToHex } from "nostr-tools/utils"
import { havenAuthors } from "../src/fips/owners.js"
import { loadOwnerAccount, saveOwnerAccount, proofTemplate, provenAccount, signWithKey, signWithExtension, ACCOUNT_ITEM, PROOF_ITEM } from "../src/fips/owner-proof.js"
import { mountAccountProof } from "../src/fips/account-panel.js"

let store
const storage = { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) }
const bind = getPublicKey(generateSecretKey()) // the relay page's own key
const mesh = getPublicKey(generateSecretKey())
beforeEach(() => { store = new Map() })

test("a typed npub saved before proofs is dropped on load, and Haven doesn't whitelist it", () => {
  const watched = getPublicKey(generateSecretKey())
  store.set(ACCOUNT_ITEM, watched)
  const logs = []
  const account = loadOwnerAccount(storage, { bind, log: e => logs.push(e) })
  assert.equal(account, undefined)
  assert.equal(store.get(ACCOUNT_ITEM), "", "the stale unproven owner is cleared")
  assert.deepEqual(logs, ["fips-owner-account-unproven-dropped"])
  assert.ok(!havenAuthors({ owners: new Set([mesh]), account }).whitelist.includes(npubEncode(watched)))
})

test("saving a typed npub (no signature) is refused and saves nothing", () => {
  const watched = getPublicKey(generateSecretKey())
  assert.throws(() => saveOwnerAccount(npubEncode(watched), storage, { bind }), /doesn't prove/)
  assert.throws(() => saveOwnerAccount({ ...proofTemplate(bind), pubkey: watched }, storage, { bind }), /doesn't prove/)
  assert.equal(store.get(ACCOUNT_ITEM), undefined)
})

test("an account that signed for this relay is kept across loads; Forget clears it", () => {
  const sk = generateSecretKey(), pk = getPublicKey(sk)
  assert.equal(saveOwnerAccount(finalizeEvent(proofTemplate(bind), sk), storage, { bind }), pk)
  assert.equal(loadOwnerAccount(storage, { bind }), pk)
  assert.equal(loadOwnerAccount(storage, { bind }), pk, "checked again on the next load, still good")
  saveOwnerAccount(null, storage)
  assert.equal(loadOwnerAccount(storage, { bind }), undefined)
})

test("a proof doesn't transfer: other relay key, altered event, or a swapped account are all dropped", () => {
  const sk = generateSecretKey(), pk = getPublicKey(sk)
  const other = getPublicKey(generateSecretKey())
  const forOther = finalizeEvent(proofTemplate(other), sk)
  assert.equal(provenAccount(forOther, bind), undefined, "signed for another browser relay")
  assert.throws(() => saveOwnerAccount(forOther, storage, { bind }))
  const good = finalizeEvent(proofTemplate(bind), sk)
  const watched = getPublicKey(generateSecretKey())
  assert.equal(provenAccount({ ...good, pubkey: watched }, bind), undefined, "someone else's pubkey on a real signature")
  assert.equal(provenAccount({ ...good, kind: 1 }, bind), undefined)
  // Storage edited by hand: the saved account no longer matches its proof.
  saveOwnerAccount(good, storage, { bind })
  store.set(ACCOUNT_ITEM, watched)
  assert.equal(loadOwnerAccount(storage, { bind }), undefined)
  assert.equal(store.get(PROOF_ITEM), "")
  // The page's storage was reset (new relay key): the old proof names the old key.
  saveOwnerAccount(good, storage, { bind })
  assert.equal(loadOwnerAccount(storage, { bind: other }), undefined)
  assert.equal(store.get(ACCOUNT_ITEM), "")
  assert.equal(pk, good.pubkey)
})

test("a key in this browser signs once: nsec, hex and ncryptsec work, an npub can't", async () => {
  const sk = generateSecretKey(), pk = getPublicKey(sk)
  for (const [text, pw] of [[nsecEncode(sk)], [bytesToHex(sk)], [encrypt(sk, "pw-1", 4), "pw-1"]]) {
    const proof = await signWithKey(text, pw, bind)
    assert.equal(provenAccount(proof, bind), pk)
  }
  await assert.rejects(signWithKey(npubEncode(pk), "", bind), /npub can't sign/)
  await assert.rejects(signWithKey(encrypt(sk, "pw-1", 4), "wrong", bind))
})

test("a bunker link signs through the bunker", async () => {
  const sk = generateSecretKey()
  const proof = await signWithKey("bunker://x?relay=wss://r.example", "", bind, { bunker: async (_url, t) => finalizeEvent(t, sk) })
  assert.equal(provenAccount(proof, bind), getPublicKey(sk))
})

test("extension (NIP-07): its signature proves it; a different signer than it named is refused", async () => {
  const sk = generateSecretKey(), pk = getPublicKey(sk)
  const ext = { getPublicKey: async () => pk, signEvent: async t => finalizeEvent(t, sk) }
  assert.equal(provenAccount(await signWithExtension(bind, ext), bind), pk)
  const liar = { getPublicKey: async () => getPublicKey(generateSecretKey()), signEvent: async t => finalizeEvent(t, sk) }
  await assert.rejects(signWithExtension(bind, liar), /different account/)
  await assert.rejects(signWithExtension(bind, undefined), /No Nostr browser extension/)
})

test("the page's box: a typed npub gives an error and no access; a signed key saves, reloads, and is wiped from the box", async () => {
  const els = Object.fromEntries(["fipsAccountNow", "fipsAccount", "fipsAccountPw", "fipsAccountExt", "fipsAccountSign", "fipsAccountClear"].map(id => [id, { value: "", textContent: "" }]))
  globalThis.document = { getElementById: id => els[id] }
  let reloads = 0
  mountAccountProof({ storage, bind, reload: () => reloads++ })
  assert.match(els.fipsAccountNow.textContent, /typed npub can't be used/)
  const sk = generateSecretKey(), pk = getPublicKey(sk)
  els.fipsAccount.value = npubEncode(pk)
  await els.fipsAccountSign.onclick()
  assert.match(els.fipsAccountNow.textContent, /npub can't sign/)
  assert.equal(loadOwnerAccount(storage, { bind }), undefined)
  assert.equal(reloads, 0)
  els.fipsAccount.value = nsecEncode(sk)
  await els.fipsAccountSign.onclick()
  assert.equal(loadOwnerAccount(storage, { bind }), pk)
  assert.equal(reloads, 1)
  assert.equal(els.fipsAccount.value, "", "the key isn't left in the box")
  assert.ok(![...store.values()].some(v => String(v).includes(bytesToHex(sk)) || String(v).includes(nsecEncode(sk))), "the secret key is never stored")
  els.fipsAccountClear.onclick()
  assert.equal(loadOwnerAccount(storage, { bind }), undefined)
  assert.equal(reloads, 2)
  delete globalThis.document
})
