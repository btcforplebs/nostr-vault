// NIP-07: a browser extension (Alby, nos2x, ...) holds the key and signs.
import { checkedPubkey } from "../session.js"

/** The extension's window.nostr, waiting briefly because some extensions inject after the page loads. */
export async function findExtension(waitMs = 1500) {
  for (let t = 0; !globalThis.nostr && t < waitMs; t += 100) await new Promise(r => setTimeout(r, 100))
  return globalThis.nostr
}

export async function extensionSignIn() {
  const ext = await findExtension()
  if (!ext) throw new Error("No Nostr extension found in this browser")
  const pubkey = checkedPubkey(await ext.getPublicKey())
  return { signer: extensionSigner(), session: { method: "nip07", pubkey } }
}

export function extensionSigner() {
  return {
    method: "nip07",
    signEvent: async t => (await findExtension())?.signEvent(t) ?? Promise.reject(new Error("Nostr extension is gone")),
  }
}

/**
 * The extension's NIP-44 and NIP-04 (for Messages). Each call asks the extension, which may prompt the user.
 * `peer` is the other key of the conversation; for a self-copy it is the user's own pubkey.
 * -> { encrypt(peer, text), decrypt(peer, ciphertext), decrypt04(peer, ciphertext) }, each throwing when the
 *    extension is gone or doesn't offer that scheme.
 */
export function extensionCrypto() {
  const need = async scheme => {
    const ext = await findExtension()
    if (!ext) throw new Error("Nostr extension is gone")
    if (typeof ext[scheme]?.encrypt !== "function" && typeof ext[scheme]?.decrypt !== "function") throw new Error(`your extension doesn't offer ${scheme.toUpperCase()}`)
    return ext[scheme]
  }
  return {
    encrypt: async (peer, text) => (await need("nip44")).encrypt(peer, text),
    decrypt: async (peer, ciphertext) => (await need("nip44")).decrypt(peer, ciphertext),
    decrypt04: async (peer, ciphertext) => (await need("nip04")).decrypt(peer, ciphertext),
  }
}
