// NIP-07: a browser extension (Alby, nos2x, ...) holds the key and signs.
import { checkedPubkey } from "../session.js"
import { shellNostr } from "../shell.js"

/** The extension's window.nostr, waiting briefly because some extensions inject after the page loads. In the site's
 *  frame (src/shell.js), the top page's when the extension didn't reach the frame. */
export async function findExtension(waitMs = 1500) {
  const ext = () => globalThis.nostr ?? shellNostr()
  for (let t = 0; !ext() && t < waitMs; t += 100) await new Promise(r => setTimeout(r, 100))
  return ext()
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
    crypto: extensionCrypto(),
    signEvent: async t => (await findExtension())?.signEvent(t) ?? Promise.reject(new Error("Nostr extension is gone")),
  }
}

/**
 * The extension's NIP-44 and NIP-04 (Messages, the private block list). Each call asks the extension, which may prompt the user.
 * `peer` is the other key of the conversation; for a self-copy it is the user's own pubkey.
 * -> { encrypt(peer, text), decrypt(peer, ciphertext), encrypt04(peer, text), decrypt04(peer, ciphertext) }, each
 *    throwing when the extension is gone or doesn't offer that call.
 */
export function extensionCrypto() {
  const call = async (scheme, fn, peer, text) => {
    const ext = await findExtension()
    if (!ext) throw new Error("Nostr extension is gone")
    if (typeof ext[scheme]?.[fn] !== "function") throw new Error(`your extension doesn't offer ${scheme.toUpperCase()} ${fn === "encrypt" ? "encryption" : "decryption"}`)
    return ext[scheme][fn](peer, text)
  }
  return {
    encrypt: (peer, text) => call("nip44", "encrypt", peer, text),
    decrypt: (peer, ciphertext) => call("nip44", "decrypt", peer, ciphertext),
    encrypt04: (peer, text) => call("nip04", "encrypt", peer, text),
    decrypt04: (peer, ciphertext) => call("nip04", "decrypt", peer, ciphertext),
  }
}
