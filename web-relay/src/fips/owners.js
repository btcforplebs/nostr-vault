// The owner set: the vault identities allowed to open TCP/FIPS streams to this relay.
// Stored as x-only pubkey hex. FIPS reports peers as 33-byte compressed keys, so compare with xOnly().
import { decode } from "nostr-tools/nip19"

const HEX64 = /^[0-9a-f]{64}$/
const HEX66 = /^0[23][0-9a-f]{64}$/

/** x-only hex for a peer key given as x-only hex, compressed hex, or npub. Undefined if it isn't one. */
export function xOnly(key) {
  const k = String(key ?? "").trim().toLowerCase()
  if (HEX64.test(k)) return k
  if (HEX66.test(k)) return k.slice(2)
  if (k.startsWith("npub1")) {
    try {
      const d = decode(k)
      return d.type === "npub" ? d.data : undefined
    } catch {
      return undefined
    }
  }
  return undefined
}

/** Parse a comma/space/newline separated list of npubs or hex keys. Throws on any entry that isn't a key. */
export function parseOwners(text) {
  const out = new Set()
  for (const part of String(text).split(/[\s,]+/).filter(Boolean)) {
    const k = xOnly(part)
    if (!k) throw new Error(`not an npub or pubkey: ${part.slice(0, 20)}`)
    out.add(k)
  }
  return out
}

export function isOwner(owners, peerKey) {
  const k = xOnly(peerKey)
  return k !== undefined && owners.has(k)
}
