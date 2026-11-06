// The owner's Nostr account on the relay page, proven by a signature. Haven keeps notes from this account (owners.js
// havenAuthors), so a typed npub alone would let a watch-only account in: the account is only taken from an event it
// signed, naming this browser relay, and that proof is checked again on every load (a stale or missing one drops the
// account). The signing key never stays here: an extension or bunker keeps its own; a pasted nsec/ncryptsec signs
// once and is forgotten.
import { verifyEvent, finalizeEvent, getPublicKey, generateSecretKey } from "nostr-tools/pure"
import { decode } from "nostr-tools/nip19"
import { decrypt as decryptNcryptsec } from "nostr-tools/nip49"
import { xOnly } from "./owners.js"

export const ACCOUNT_ITEM = "fips-owner-account"
export const PROOF_ITEM = "fips-owner-account-proof"
export const PROOF_KIND = 22242
const RELAY_TAG = "https://nostrvault.app/relay/"
const CONTENT = "I own this browser relay. Keep my notes on it."

// `bind` is this page's own key (main.js `pk`, kept in the page's storage): a proof made for another browser relay,
// or before this one's storage was reset, names a different key and isn't accepted.
const challenge = bind => `nostr-vault-relay-owner:${bind}`

/** The unsigned event the account signs. */
export function proofTemplate(bind, now = Math.floor(Date.now() / 1000)) {
  if (!xOnly(bind)) throw new Error("no relay key to prove ownership of")
  return { kind: PROOF_KIND, created_at: now, tags: [["relay", RELAY_TAG], ["challenge", challenge(bind)]], content: CONTENT }
}

/** The account a proof proves for this relay, or undefined when it's unsigned, altered, or for another relay. */
export function provenAccount(proof, bind) {
  try {
    if (!proof || proof.kind !== PROOF_KIND || !xOnly(bind)) return undefined
    if (!proof.tags?.some(t => t[0] === "challenge" && t[1] === challenge(bind))) return undefined
    // A plain copy: nostr-tools caches "verified" on the object under a symbol, and a spread or an object handed back
    // by an extension can carry it over onto altered fields.
    const plain = JSON.parse(JSON.stringify(proof))
    return verifyEvent(plain) ? plain.pubkey : undefined
  } catch {
    return undefined
  }
}

const clear = storage => (storage.setItem(ACCOUNT_ITEM, ""), storage.setItem(PROOF_ITEM, ""))

/**
 * The saved account as x-only hex, only while its saved proof holds for `bind`. Anything else (a typed npub saved
 * before proofs, a proof for another relay key, a proof for a different account) is cleared and gives undefined.
 */
export function loadOwnerAccount(storage, { bind, log = () => {} } = {}) {
  const saved = xOnly(storage.getItem(ACCOUNT_ITEM) ?? "")
  if (!saved) return undefined
  let proof
  try { proof = JSON.parse(storage.getItem(PROOF_ITEM) || "null") } catch {}
  if (provenAccount(proof, bind) === saved) return saved
  clear(storage)
  log("fips-owner-account-unproven-dropped")
  return undefined
}

/** Save the account a signed proof proves; `null` clears it. Throws on a proof that doesn't hold, saving nothing. */
export function saveOwnerAccount(proof, storage, { bind } = {}) {
  if (proof == null) return clear(storage), undefined
  const k = provenAccount(proof, bind)
  if (!k) throw new Error("That signature doesn't prove an account for this relay. Nothing was saved.")
  storage.setItem(ACCOUNT_ITEM, k)
  storage.setItem(PROOF_ITEM, JSON.stringify(proof))
  return k
}

/** Sign the proof with a browser extension (NIP-07). */
export async function signWithExtension(bind, nostr = globalThis.window?.nostr) {
  if (!nostr?.signEvent) throw new Error("No Nostr browser extension found.")
  const pubkey = await nostr.getPublicKey()
  const signed = await nostr.signEvent({ ...proofTemplate(bind), pubkey })
  if (signed?.pubkey !== pubkey) throw new Error("The extension signed with a different account than it named.")
  return signed
}

/**
 * Sign the proof with a key typed here: nsec, hex, or ncryptsec + password (NIP-49). The key is used once and not
 * kept. A bunker:// link signs through the remote signer (NIP-46) via `bunker(url, template)`.
 */
export async function signWithKey(text, password, bind, { bunker } = {}) {
  const t = String(text ?? "").trim()
  if (t.startsWith("bunker://")) {
    if (!bunker) throw new Error("This page can't reach a bunker.")
    return bunker(t, proofTemplate(bind))
  }
  let sk
  if (t.startsWith("ncryptsec1")) {
    if (!password) throw new Error("Type the ncryptsec's password.")
    sk = decryptNcryptsec(t, password)
  } else if (t.startsWith("nsec1")) {
    const d = decode(t)
    if (d.type !== "nsec") throw new Error("Not a secret key.")
    sk = d.data
  } else if (/^[0-9a-f]{64}$/i.test(t)) {
    sk = Uint8Array.from(t.match(/../g), h => parseInt(h, 16))
  } else throw new Error("Paste an nsec, an ncryptsec with its password, or a bunker:// link. An npub can't sign.")
  getPublicKey(sk)
  return finalizeEvent(proofTemplate(bind), sk)
}

/** Sign through a NIP-46 bunker (only loaded when used). */
export async function bunkerSign(url, template) {
  const { BunkerSigner, parseBunkerInput } = await import("nostr-tools/nip46")
  const bp = await parseBunkerInput(url)
  if (!bp) throw new Error("That bunker link isn't valid.")
  const signer = BunkerSigner.fromBunker(generateSecretKey(), bp)
  try {
    await signer.connect()
    return await signer.signEvent(template)
  } finally {
    await signer.close?.().catch?.(() => {})
  }
}
