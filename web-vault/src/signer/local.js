// A key made in this browser, for someone new to Nostr (screens/CreateAccount.jsx). The secret key is stored twice,
// never as plain hex: as an ncryptsec (NIP-49) under the password the user chose, which is the copy that can be taken
// to another app, and sealed with this browser's non-extractable AES key (keyring.js), which is how the page signs
// without asking for the password every time. The iPhone does the same with its ncryptsec and the password in the
// Keychain (SetupWizardView.saveIntermediateConfig). If the sealing key is lost (site data partly cleared), the
// password opens the ncryptsec again (unlockLocal). Nothing here logs or sends the key.
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { encrypt as ncryptsecOf, decrypt as ncryptsecOpen } from "nostr-tools/nip49"
import * as nip44 from "nostr-tools/nip44"
import * as nip04 from "nostr-tools/nip04"
import { nsecEncode, npubEncode } from "nostr-tools/nip19"
import { bech32 } from "@scure/base"
import { bytesToHex, hexToBytes } from "nostr-tools/utils"
import { seal, unseal, assertCanSeal, LOST_KEY } from "./keyring.js"
import { checkedPubkey } from "../session.js"

/** What the user is doing when a plain-http page can't keep the key (keyring.js insecure). */
export const CREATING = "Creating an account"

/** The shortest password the key is locked with (KeyPasswordStep: minimum 8 characters). */
export const MIN_PASSWORD = 8

export const LOCKED = "This browser can't open your key on its own any more (its site data was partly cleared). Type your password to unlock it."
/** The stored ncryptsec is missing or isn't one NIP-49 can open: no password will work, so the screens don't ask again. */
// The web app has no nsec sign-in (signer/readonly.js turns one away), so every line about the saved key says where it works.
export const SAVED_KEY_USE = 'To use this account again, add the secret key you saved to a Nostr browser extension and choose "I already use Nostr", or import it in the Nostr Vault app.'
export const DAMAGED = `The key kept in this browser is missing or damaged, so no password can open it. Sign out first. ${SAVED_KEY_USE}`
export const WRONG_PASSWORD = "Wrong password. Try again."

/** A new keypair -> { sk, pubkey, npub, nsec }. `sk` stays in memory until finish; the nsec is shown once, to be saved. */
export function newKey(make = generateSecretKey) {
  const sk = make()
  const pubkey = checkedPubkey(getPublicKey(sk))
  return { sk, pubkey, npub: npubEncode(pubkey), nsec: nsecEncode(sk) }
}

/** Whether a password may lock the key: { ok, problem } in KeyPasswordStep's words. */
export function checkPassword(password, confirm) {
  if ((password ?? "").length < MIN_PASSWORD) return { ok: false, problem: password ? `Password must be at least ${MIN_PASSWORD} characters` : "" }
  if (confirm !== password) return { ok: false, problem: confirm ? "Passwords do not match" : "" }
  return { ok: true, problem: "" }
}

/**
 * The session for a new key: { method: "local", pubkey, ncryptsec, skSealed }. Throws (keyring insecure) on a page
 * that can't seal, before anything is stored. `logn`: NIP-49's scrypt cost, 16 as the iPhone uses; tests pass less.
 */
export async function localSession(sk, password, { keyStore, logn = 16 } = {}) {
  assertCanSeal(CREATING)
  const { ok, problem } = checkPassword(password, password)
  if (!ok) throw new Error(problem)
  const pubkey = checkedPubkey(getPublicKey(sk))
  return { method: "local", pubkey, ncryptsec: ncryptsecOf(sk, password, logn), skSealed: await seal(bytesToHex(sk), keyStore) }
}

/** The password opens the ncryptsec and the key is sealed again for this browser -> the session to save. Throws
 *  WRONG_PASSWORD for a wrong password and DAMAGED when the stored key can't be opened at all. */
export async function unlockLocal(session, password, { keyStore } = {}) {
  const sk = openKey(session, password)
  try { return { ...session, skSealed: await seal(bytesToHex(sk), keyStore) } } finally { sk.fill(0) }
}

/** The account's secret key as an nsec, for Settings > Your Secret Key: the password opens the ncryptsec. */
export function revealNsec(session, password) {
  const sk = openKey(session, password)
  try { return nsecEncode(sk) } finally { sk.fill(0) }
}

/** Whether `ncryptsec` is a NIP-49 key this page can open: bech32 "ncryptsec", version 2, a scrypt cost a browser can
 *  run (logn 1 to 20; this page writes 16; above 20 scrypt wants more memory than a tab gets, so it is taken as damage) and a 48-byte sealed key. No password is
 *  tried. */
export function wellFormed(ncryptsec) {
  if (typeof ncryptsec !== "string") return false
  try {
    const { prefix, words } = bech32.decode(ncryptsec, 5000)
    const b = bech32.fromWords(words)
    return prefix === "ncryptsec" && b.length === 91 && b[0] === 2 && b[1] >= 1 && b[1] <= 20
  } catch { return false }
}

/** The ncryptsec opened with `password` -> sk. Throws DAMAGED when no password could open it, WRONG_PASSWORD when
 *  this one doesn't, and never hands back a key that isn't the account's. */
function openKey(session, password) {
  if (!wellFormed(session?.ncryptsec)) throw new Error(DAMAGED)
  let sk
  try { sk = ncryptsecOpen(session.ncryptsec, password) } catch { throw new Error(WRONG_PASSWORD) }
  if (getPublicKey(sk) !== session.pubkey) { sk.fill(0); throw new Error(DAMAGED) }
  return sk
}

/** Signs with the sealed key, unsealed once and kept in memory for this page. `ready()` throws LOCKED when the
 *  sealing key is gone, so the app can ask for the password before anything needs a signature. */
export function localSigner(session, { keyStore } = {}) {
  let sk = null
  const key = async () => {
    if (sk) return sk
    try { sk = hexToBytes(await unseal(session.skSealed, keyStore)) } catch (e) { throw new Error(e?.message === LOST_KEY ? LOCKED : String(e?.message ?? e)) }
    if (getPublicKey(sk) !== session.pubkey) { sk = null; throw new Error(LOCKED) }
    return sk
  }
  return {
    method: "local",
    ready: async () => { await key() },
    signEvent: async template => finalizeEvent({ ...template }, await key()),
    crypto: {
      encrypt: async (peer, text) => nip44.v2.encrypt(text, nip44.v2.utils.getConversationKey(await key(), peer)),
      decrypt: async (peer, ciphertext) => nip44.v2.decrypt(ciphertext, nip44.v2.utils.getConversationKey(await key(), peer)),
      encrypt04: async (peer, text) => nip04.encrypt(await key(), peer, text),
      decrypt04: async (peer, ciphertext) => nip04.decrypt(await key(), peer, ciphertext),
    },
    close() { if (sk) sk.fill(0); sk = null },
  }
}
