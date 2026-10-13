// NIP-07: a browser extension (Alby, nos2x, ...) holds the key and signs.

/** The extension's window.nostr, waiting briefly because some extensions inject after the page loads. */
export async function findExtension(waitMs = 1500) {
  for (let t = 0; !globalThis.nostr && t < waitMs; t += 100) await new Promise(r => setTimeout(r, 100))
  return globalThis.nostr
}

export async function extensionSignIn() {
  const ext = await findExtension()
  if (!ext) throw new Error("No Nostr extension found in this browser")
  const pubkey = await ext.getPublicKey()
  return { signer: extensionSigner(), session: { method: "nip07", pubkey } }
}

export function extensionSigner() {
  return {
    method: "nip07",
    signEvent: async t => (await findExtension())?.signEvent(t) ?? Promise.reject(new Error("Nostr extension is gone")),
  }
}
