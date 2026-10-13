// NIP-46: a remote signer (bunker) holds the key. This browser keeps only the session's client key, which the
// bunker can revoke; the user's secret key never comes here.
import { BunkerSigner, parseBunkerInput } from "nostr-tools/nip46"
import { generateSecretKey } from "nostr-tools/pure"
import { bytesToHex, hexToBytes } from "nostr-tools/utils"
import { checkedPubkey } from "../session.js"

// The bunker sends this URL, and a hostile bunker link is how a phishing attempt would start, so only open web
// pages. noopener also matters: without it a javascript: URL would run in this page.
export function safeAuthUrl(url) {
  try {
    const u = new URL(url)
    return u.protocol === "https:" || u.protocol === "http:" ? u.href : null
  } catch {
    return null
  }
}
const openAuthUrl = url => { const safe = safeAuthUrl(url); if (safe) window.open(safe, "_blank", "noopener") }

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

function answered(promise) {
  let timer
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Your signer didn't answer within a minute. Check that your bunker app is open and online, then try again.")), ANSWER_TIMEOUT_MS) })
  // The pool rejects with an AggregateError when no bunker relay took the request.
  const reached = promise.catch(e => { throw e instanceof AggregateError ? new Error("Couldn't reach your signer's relay. Check your connection, then try again.") : e })
  return Promise.race([reached, timeout]).finally(() => clearTimeout(timer))
}

function wrap(b) {
  return { method: "nip46", signEvent: t => answered(b.signEvent(t)), close: () => b.close() }
}
