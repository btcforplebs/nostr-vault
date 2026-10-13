// NIP-46: a remote signer (bunker) holds the key. This browser keeps only the session's client key, which the
// bunker can revoke; the user's secret key never comes here.
import { BunkerSigner, parseBunkerInput } from "nostr-tools/nip46"
import { generateSecretKey } from "nostr-tools/pure"
import { bytesToHex, hexToBytes } from "nostr-tools/utils"

const openAuthUrl = url => window.open(url, "_blank", "noopener")

export async function bunkerSignIn(input, pool) {
  const bp = await parseBunkerInput(String(input).trim())
  if (!bp) throw new Error("That isn't a bunker:// link or a NIP-05 with a bunker")
  if (!bp.relays.length) throw new Error("The bunker link has no relay")
  const clientSk = generateSecretKey()
  const signer = BunkerSigner.fromBunker(clientSk, bp, { pool, onauth: openAuthUrl })
  await signer.connect()
  const pubkey = await signer.getPublicKey()
  // The connect secret is single-use; don't keep it.
  const session = { method: "nip46", pubkey, bunker: { pubkey: bp.pubkey, relays: bp.relays, secret: null }, clientSk: bytesToHex(clientSk) }
  return { signer: wrap(signer), session }
}

/** A signer for a saved session. It doesn't contact the bunker until something needs signing. */
export function bunkerSigner(session, pool) {
  return wrap(BunkerSigner.fromBunker(hexToBytes(session.clientSk), session.bunker, { pool, onauth: openAuthUrl }))
}

function wrap(b) {
  return { method: "nip46", signEvent: t => b.signEvent(t), close: () => b.close() }
}
