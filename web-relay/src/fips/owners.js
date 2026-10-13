// The owner set: the vault identities allowed to open TCP/FIPS streams to this relay.
// Stored as x-only pubkey hex. FIPS reports peers as 33-byte compressed keys, so compare with xOnly().
import { decode, npubEncode } from "nostr-tools/nip19"

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

const OWNERS_ITEM = "fips-owners"

/**
 * The saved owner set, after applying a pairing link (nostrvault.app/relay/#owner=npub1...; a fragment never
 * reaches the server). Haven is configured with these at start, so call this before starting it.
 * A link only ever adds owners, and only once the person at this browser confirms each new one: anyone can
 * send a link, and an owner can write to this relay and gets dialed by it.
 */
export function loadOwners({ storage = localStorage, log = () => {}, confirm = msg => globalThis.confirm(msg) } = {}) {
  let owners = new Set()
  try {
    owners = parseOwners(storage.getItem(OWNERS_ITEM) ?? "")
  } catch {}
  const frag = new URLSearchParams(location.hash.slice(1)).get("owner")
  if (frag) {
    try {
      const fresh = [...parseOwners(frag)].filter(k => !owners.has(k))
      if (fresh.length) {
        const list = fresh.map(k => "  " + npubEncode(k)).join("\n")
        const msg = `This link wants to add ${fresh.length === 1 ? "an owner" : fresh.length + " owners"} to this relay:\n\n${list}\n\n` +
          "An owner can write to this relay and read everything on it. Only continue if this is your own vault."
        if (confirm(msg)) {
          owners = new Set([...owners, ...fresh])
          saveOwners(owners, storage)
          log("fips-owner-paired", { added: fresh.length, owners: owners.size })
        } else {
          log("fips-owner-declined", { offered: fresh.length })
        }
      }
    } catch (e) {
      log("fips-owner-error", { err: String(e) })
    }
    history.replaceState(null, "", location.pathname)
  }
  return owners
}

export function saveOwners(owners, storage = localStorage) {
  storage.setItem(OWNERS_ITEM, [...owners].join(" "))
}
