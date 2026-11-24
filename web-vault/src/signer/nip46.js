// NIP-46: a remote signer (bunker) holds the key. This browser keeps only the session's client key, which the
// bunker can revoke; the user's secret key never comes here.
import { BunkerSigner, parseBunkerInput } from "nostr-tools/nip46"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { getConversationKey, decrypt as nip44Decrypt } from "nostr-tools/nip44"
import { bytesToHex, hexToBytes } from "nostr-tools/utils"
import { checkedPubkey, loadSession, saveSession, rememberAccount } from "../session.js"
import { seal, unseal, assertCanSeal } from "./keyring.js"
import { assertNoSecretKey } from "../net/secret-key-leak.js"

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

/**
 * What was pasted, as parseBunkerInput can read it. A link copied from a phone app or a chat often comes with spaces,
 * a line break, an invisible character or a "nostr:" in front, or inside a sentence ("my bunker: bunker://…"), and an
 * upper-case key from a QR reader; nostr-tools' BUNKER_REGEX refused every one of those as "not a bunker link".
 */
export function cleanBunkerInput(input) {
  let text = String(input ?? "").replace(/[\s\u200b-\u200d\u2060\ufeff]+/g, " ").trim()
  // From "bunker://" on, with no spaces: a link a chat app wrapped onto two lines is still one link.
  const at = text.search(/bunker:\/\//i)
  if (at >= 0) text = text.slice(at).replace(/\s+/g, "")
  else if (!text.includes(" ")) text = text.replace(/^nostr:/i, "")
  return text.replace(/^bunker:\/\/([0-9a-f]{64})/i, (_, pk) => `bunker://${pk.toLowerCase()}`)
}

export async function bunkerSignIn(input, pool) {
  assertCanSeal()
  const text = cleanBunkerInput(input)
  const bp = await parseBunkerInput(text)
  const refused = bunkerInputError(text, bp)
  if (refused) throw new Error(refused)
  const clientSk = generateSecretKey()
  pool.keepForSigner?.(bp.relays)
  const signer = BunkerSigner.fromBunker(clientSk, bp, { pool, onauth: openAuthUrl })
  // On any failure close the signer, so a timed-out sign-in doesn't leave its subscription and grant open.
  try { await answered(signer.connect()) } catch (e) { signer.close(); throw e }
  return finishSignIn(signer, clientSk, bp)
}

// The signer answered: ask whose key it holds, seal this browser's client key, and make the session.
async function finishSignIn(signer, clientSk, bp) {
  let pubkey
  try { pubkey = checkedPubkey(await answered(signer.getPublicKey())) } catch (e) { signer.close(); throw e }
  // The connect secret is single-use; don't keep it. The client key is stored sealed (keyring.js), never as hex.
  let clientSkSealed
  try { clientSkSealed = await seal(bytesToHex(clientSk), keyStore) } catch (e) { signer.close(); throw e }
  const session = { method: "nip46", pubkey, bunker: { pubkey: bp.pubkey, relays: bp.relays, secret: null }, clientSkSealed }
  return { signer: wrap(Promise.resolve(signer), { pubkey }), session }
}

// ---- Nostr Connect (nostrconnect://): this page shows a QR code, the signer app (Amber, Clave, nsec.app) scans it.
// The way round a desktop with no extension needs: the bunker:// link lives on the phone, and there is no clipboard
// between the two.

// relay.nip46.com is one of Amber's own default relays and carries only NIP-46; damus is what the iPhone and Android
// apps' nostrconnect requests use beside relay.powr.build (NIP46Service nostrConnectRelays), which was down on 11-13.
export const NOSTRCONNECT_RELAYS = ["wss://relay.nip46.com", "wss://relay.damus.io"]
// The same permissions the apps ask for. Amber drops a sign_event with no kind and asks each time instead.
export const NOSTRCONNECT_PERMS = "sign_event,nip04_encrypt,nip04_decrypt,nip44_encrypt,nip44_decrypt"
// How long a QR code is waited on before it is replaced by "Show a new code".
export const NOSTRCONNECT_WAIT_MS = 10 * 60_000

/**
 * A fresh request: a client key for this sign-in only and a single-use secret, and the nostrconnect:// URI with both.
 * Relay values go in as they are (":" and "/" are fine in a query, and the apps do the same). No url or image, unlike
 * the apps' link: this one is read off a screen by a phone camera, and every character makes the code denser. The
 * name is percent-encoded, never "+" for a space, since a decoder may read "+" either way.
 */
export function nostrConnectRequest({ relays = NOSTRCONNECT_RELAYS, sk = generateSecretKey(), secret = bytesToHex(generateSecretKey().slice(0, 16)), now = Date.now() } = {}) {
  const clientPubkey = getPublicKey(sk)
  const q = [...relays.map(r => `relay=${r}`), `secret=${secret}`, `perms=${NOSTRCONNECT_PERMS}`,
    `name=${encodeURIComponent("Nostr Vault")}`]
  return { uri: `nostrconnect://${clientPubkey}?${q.join("&")}`, clientSk: sk, clientPubkey, secret, relays, since: Math.floor(now / 1000) - 5 }
}

/**
 * The signer's pubkey if `ev` is its answer to `req`, else "". Anyone can publish a kind 24133 tagged to our client
 * key, so the echoed secret is the only proof the answer came from the app the user approved in: "ack" is refused.
 * Clave's opt-in multi-account answer carries it as `echoed_secret` (haven-go/nip46_nostrconnect.go, the same rule).
 */
export function nostrConnectAnswer(ev, req) {
  if (ev?.kind !== 24133 || !ev.tags?.some(t => t[0] === "p" && t[1] === req.clientPubkey)) return ""
  try {
    const { result, error } = JSON.parse(nip44Decrypt(ev.content, getConversationKey(req.clientSk, ev.pubkey)))
    if (error || typeof result !== "string") return ""
    let echoed = result
    if (result.startsWith("{")) { try { echoed = JSON.parse(result).echoed_secret } catch {} }
    return echoed === req.secret && /^[0-9a-f]{64}$/.test(ev.pubkey) ? ev.pubkey : ""
  } catch { return "" }
}

/**
 * Wait for the signer to scan `req` and approve. -> { done: Promise<{ signer, session }>, cancel }. `done` rejects
 * with { cancelled: true } after cancel(), and with an `expired` error after `ms` with no answer.
 */
export function nostrConnectSignIn(req, pool, { ms = NOSTRCONNECT_WAIT_MS } = {}) {
  let sub, timer, stop
  const done = new Promise((resolve, reject) => {
    assertCanSeal()
    stop = e => { clearTimeout(timer); sub?.close(); reject(e) }
    timer = setTimeout(() => stop(Object.assign(new Error("The code expired. Show a new one and scan it again."), { expired: true })), ms)
    pool.keepForSigner?.(req.relays)
    sub = pool.subscribe(req.relays, { kinds: [24133], "#p": [req.clientPubkey], since: req.since }, {
      onevent: ev => {
        const signerPubkey = nostrConnectAnswer(ev, req)
        if (!signerPubkey) return
        clearTimeout(timer); sub.close()
        const bp = { pubkey: signerPubkey, relays: req.relays, secret: null }
        const signer = BunkerSigner.fromBunker(req.clientSk, bp, { pool, onauth: openAuthUrl })
        finishSignIn(signer, req.clientSk, bp).then(resolve, reject)
      },
    })
  })
  done.catch(() => {})
  return { done, cancel: () => stop?.(Object.assign(new Error("cancelled"), { cancelled: true })) }
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
  return wrap(ready, { pubkey: session.pubkey })
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
export function wrap(ready, { ms = ANSWER_TIMEOUT_MS, pubkey } = {}) {
  return {
    method: "nip46",
    crypto: bunkerCrypto(ready, ms),
    // A secret key never goes to the bunker, not even encrypted (net/secret-key-leak.js).
    signEvent: async t => { assertNoSecretKey(t, pubkey); return ready.then(b => answered(b.signEvent(t), ms)) },
    close: () => { ready.then(b => b.close(), () => {}) },
    /** -> true if the bunker confirmed it dropped the grant. Always closes the signer. */
    revoke: () => ready.then(b => answered(b.logout(), LOGOUT_TIMEOUT_MS).then(() => true, () => false).finally(() => b.close()), () => false),
  }
}
