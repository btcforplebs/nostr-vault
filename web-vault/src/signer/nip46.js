// NIP-46: a remote signer (bunker) holds the key. This browser keeps only the session's client key, which the
// bunker can revoke; the user's secret key never comes here.
import { BunkerSigner, parseBunkerInput } from "nostr-tools/nip46"
import { generateSecretKey } from "nostr-tools/pure"
import { bytesToHex, hexToBytes } from "nostr-tools/utils"
import { checkedPubkey, loadSession, saveSession, rememberAccount } from "../session.js"
import { seal, unseal, assertCanSeal } from "./keyring.js"

// The bunker sends this URL, and a hostile bunker link is how a phishing attempt would start, so only web pages
// are shown. The scheme check is what keeps a javascript: URL out; noopener only cuts the new page off from this one.
export function safeAuthUrl(url) {
  try {
    const u = new URL(url)
    return u.protocol === "https:" || u.protocol === "http:" ? u.href : null
  } catch {
    return null
  }
}
// Shown as a link the user taps (AuthPrompt), not opened here: this runs in a relay callback with no user gesture,
// so a popup blocker would eat it and the sign-in would hang until the timeout.
// The last one is kept so a prompt mounted later (after the boot splash or sign-out screen) still shows it.
export const authUrls = new EventTarget()
export let lastAuthUrl = ""
export const clearAuthUrl = () => { lastAuthUrl = "" } // once tapped, a later prompt shouldn't show it again
const openAuthUrl = url => { const safe = safeAuthUrl(url); if (safe) { lastAuthUrl = safe; authUrls.dispatchEvent(new CustomEvent("url", { detail: safe })) } }

// nostr-tools' NIP05_REGEX: what parseBunkerInput looks up as an address.
const NIP05 = /^(?:([\w.+-]+)@)?([\w_-]+(\.[\w_-]+)+)$/
/** Why `parseBunkerInput`'s answer for `input` can't be signed in with, or "". A NIP-05 that doesn't resolve, or
 *  resolves with no bunker, is named, so the user knows it was the address, not the format. */
export function bunkerInputError(input, bp) {
  const nip05 = NIP05.test(input) ? input.replace(/^_@/, "") : ""
  if (!bp || (nip05 && !bp.pubkey)) return nip05 ? `Couldn't find a bunker at ${nip05}. Check the address, or paste the bunker:// link from your signer app.` : "That isn't a bunker:// link or a name@domain address"
  if (!bp.relays.length) return nip05 ? `${nip05} has no bunker relay set up. Paste the bunker:// link from your signer app instead.` : "The bunker link has no relay"
  return ""
}

export async function bunkerSignIn(input, pool) {
  assertCanSeal()
  const text = String(input).trim()
  const bp = await parseBunkerInput(text)
  const refused = bunkerInputError(text, bp)
  if (refused) throw new Error(refused)
  const clientSk = generateSecretKey()
  pool.keepForSigner?.(bp.relays)
  const signer = BunkerSigner.fromBunker(clientSk, bp, { pool, onauth: openAuthUrl })
  // On any failure close the signer, so a timed-out sign-in doesn't leave its subscription and grant open.
  let pubkey
  try {
    await answered(signer.connect())
    pubkey = checkedPubkey(await answered(signer.getPublicKey()))
  } catch (e) { signer.close(); throw e }
  // The connect secret is single-use; don't keep it. The client key is stored sealed (keyring.js), never as hex.
  let clientSkSealed
  try { clientSkSealed = await seal(bytesToHex(clientSk), keyStore) } catch (e) { signer.close(); throw e }
  const session = { method: "nip46", pubkey, bunker: { pubkey: bp.pubkey, relays: bp.relays, secret: null }, clientSkSealed }
  return { signer: wrap(Promise.resolve(signer)), session }
}

// Tests set this to a Map-backed key store; the page uses IndexedDB (keyring.js).
let keyStore
export const setKeyStore = ks => { keyStore = ks }

/**
 * A signer for a saved session. It doesn't contact the bunker until something needs signing. A session saved before
 * sealing (plain clientSk) is sealed and saved back over the plain one, in the session and in the account list.
 */
export function bunkerSigner(session, pool, storage = globalThis.localStorage) {
  const ready = (async () => {
    let hex = session.clientSk
    if (hex) await resealSession(session, storage).catch(() => {}) // next boot tries again; signing still works
    else hex = await unseal(session.clientSkSealed, keyStore)
    pool.keepForSigner?.(session.bunker.relays)
    return BunkerSigner.fromBunker(hexToBytes(hex), session.bunker, { pool, onauth: openAuthUrl })
  })()
  ready.catch(() => {}) // reported by whatever signs next, not as an unhandled rejection at boot
  return wrap(ready)
}

export async function resealSession(session, storage) {
  const { clientSk, ...rest } = session
  const sealed = { ...rest, clientSkSealed: await seal(clientSk, keyStore) }
  if (loadSession(storage)?.pubkey === session.pubkey) saveSession(sealed, storage)
  else rememberAccount(sealed, storage)
  return sealed
}

// A bunker that's gone (app closed, relay down) never answers, and BunkerSigner waits forever. Give the user time to
// approve on their signer, then say so instead of leaving the button spinning.
const ANSWER_TIMEOUT_MS = 60_000

// A signer that didn't answer, or whose relay couldn't be reached, is marked `unreachable`: the request never got a
// yes or no, so whoever is asking many times in a row (Messages opening a page of wraps) can stop instead of waiting
// out each one. A bunker's own refusal ("no permission", a ciphertext it can't open) is an ordinary error.
const unreachable = message => Object.assign(new Error(message), { unreachable: true })

function answered(promise, ms = ANSWER_TIMEOUT_MS) {
  let timer
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(unreachable(`Your signer didn't answer within ${ms >= 60_000 ? "a minute" : `${Math.round(ms / 1000)} seconds`}. Check that your bunker app is open and online, then try again.`)), ms) })
  // The pool rejects with an AggregateError when no bunker relay took the request.
  const reached = promise.catch(e => { throw e instanceof AggregateError ? unreachable("Couldn't reach your signer's relay. Check your connection, then try again.") : e })
  return Promise.race([reached, timeout]).finally(() => clearTimeout(timer))
}

// NIP-46 "logout" asks the bunker to drop this client's grant. Not every bunker supports it, so don't wait long;
// the sign-out screen also tells the user to revoke the connection in their bunker app.
const LOGOUT_TIMEOUT_MS = 3000

/**
 * The bunker's NIP-44 and NIP-04 (NIP-46 nip44_encrypt / nip44_decrypt / nip04_encrypt / nip04_decrypt), in the shape
 * Messages and the block list use for an extension's (nip07.js extensionCrypto). The user's key stays in the bunker:
 * each call is one request to it, and it may ask the user to approve. `peer` is the other key of the conversation;
 * for the user's own lists and DM self-copies it is the user's pubkey.
 */
export function bunkerCrypto(ready, ms = ANSWER_TIMEOUT_MS) {
  const ask = (method, peer, text) => ready.then(b => answered(b[method](peer, text), ms))
  return {
    encrypt: (peer, text) => ask("nip44Encrypt", peer, text),
    decrypt: (peer, ciphertext) => ask("nip44Decrypt", peer, ciphertext),
    encrypt04: (peer, text) => ask("nip04Encrypt", peer, text),
    decrypt04: (peer, ciphertext) => ask("nip04Decrypt", peer, ciphertext),
  }
}

// `ready`: the BunkerSigner, once its client key is unsealed. Exported for tests, which pass a fake bunker.
export function wrap(ready, { ms = ANSWER_TIMEOUT_MS } = {}) {
  return {
    method: "nip46",
    crypto: bunkerCrypto(ready, ms),
    signEvent: t => ready.then(b => answered(b.signEvent(t), ms)),
    close: () => { ready.then(b => b.close(), () => {}) },
    /** -> true if the bunker confirmed it dropped the grant. Always closes the signer. */
    revoke: () => ready.then(b => answered(b.logout(), LOGOUT_TIMEOUT_MS).then(() => true, () => false).finally(() => b.close()), () => false),
  }
}
