// NIP-46: a remote signer (bunker) holds the key. This browser keeps only the session's client key, which the
// bunker can revoke; the user's secret key never comes here.
import { BunkerSigner, parseBunkerInput } from "nostr-tools/nip46"
import { generateSecretKey } from "nostr-tools/pure"
import { bytesToHex, hexToBytes } from "nostr-tools/utils"
import { checkedPubkey } from "../session.js"

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

export async function bunkerSignIn(input, pool) {
  const bp = await parseBunkerInput(String(input).trim())
  if (!bp) throw new Error("That isn't a bunker:// link or a NIP-05 with a bunker")
  if (!bp.relays.length) throw new Error("The bunker link has no relay")
  const clientSk = generateSecretKey()
  const signer = BunkerSigner.fromBunker(clientSk, bp, { pool, onauth: openAuthUrl })
  // On any failure close the signer, so a timed-out sign-in doesn't leave its subscription and grant open.
  let pubkey
  try {
    await answered(signer.connect())
    pubkey = checkedPubkey(await answered(signer.getPublicKey()))
  } catch (e) { signer.close(); throw e }
  // The connect secret is single-use; don't keep it.
  const session = { method: "nip46", pubkey, bunker: { pubkey: bp.pubkey, relays: bp.relays, secret: null }, clientSk: bytesToHex(clientSk) }
  return { signer: wrap(signer), session }
}

/** A signer for a saved session. It doesn't contact the bunker until something needs signing. */
export function bunkerSigner(session, pool) {
  return wrap(BunkerSigner.fromBunker(hexToBytes(session.clientSk), session.bunker, { pool, onauth: openAuthUrl }))
}

// A bunker that's gone (app closed, relay down) never answers, and BunkerSigner waits forever. Give the user time to
// approve on their signer, then say so instead of leaving the button spinning.
const ANSWER_TIMEOUT_MS = 60_000

function answered(promise, ms = ANSWER_TIMEOUT_MS) {
  let timer
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Your signer didn't answer within a minute. Check that your bunker app is open and online, then try again.")), ms) })
  // The pool rejects with an AggregateError when no bunker relay took the request.
  const reached = promise.catch(e => { throw e instanceof AggregateError ? new Error("Couldn't reach your signer's relay. Check your connection, then try again.") : e })
  return Promise.race([reached, timeout]).finally(() => clearTimeout(timer))
}

// NIP-46 "logout" asks the bunker to drop this client's grant. Not every bunker supports it, so don't wait long;
// the sign-out screen also tells the user to revoke the connection in their bunker app.
const LOGOUT_TIMEOUT_MS = 3000

function wrap(b) {
  return {
    method: "nip46",
    signEvent: t => answered(b.signEvent(t)),
    close: () => b.close(),
    /** -> true if the bunker confirmed it dropped the grant. Always closes the signer. */
    revoke: () => answered(b.logout(), LOGOUT_TIMEOUT_MS).then(() => true, () => false).finally(() => b.close()),
  }
}
