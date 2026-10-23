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
import { bytesToHex, hexToBytes } from "nostr-tools/utils"
import { seal, unseal, assertCanSeal, LOST_KEY } from "./keyring.js"
import { checkedPubkey } from "../session.js"

/** The shortest password the key is locked with (KeyPasswordStep: minimum 8 characters). */
export const MIN_PASSWORD = 8

export const LOCKED = "This browser can't open your key on its own any more (its site data was partly cleared). Type your password to unlock it."

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
 * The session for a new key: { method: "local", pubkey, ncryptsec, skSealed }. Throws (keyring INSECURE) on a page
 * that can't seal, before anything is stored. `logn`: NIP-49's scrypt cost, 16 as the iPhone uses; tests pass less.
 */
export async function localSession(sk, password, { keyStore, logn = 16 } = {}) {
  assertCanSeal()
  const { ok, problem } = checkPassword(password, password)
  if (!ok) throw new Error(problem)
  const pubkey = checkedPubkey(getPublicKey(sk))
  return { method: "local", pubkey, ncryptsec: ncryptsecOf(sk, password, logn), skSealed: await seal(bytesToHex(sk), keyStore) }
}

/** The password opens the ncryptsec and the key is sealed again for this browser -> the session to save. A wrong
 *  password throws "Wrong password". */
export async function unlockLocal(session, password, { keyStore } = {}) {
  let sk
  try { sk = ncryptsecOpen(session.ncryptsec, password) } catch { throw new Error("Wrong password. Try again.") }
  if (getPublicKey(sk) !== session.pubkey) throw new Error("That key isn't this account's.")
  return { ...session, skSealed: await seal(bytesToHex(sk), keyStore) }
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
