// The owner set: the vaults allowed to open TCP/FIPS streams to this relay, by each vault's mesh address (the
// npub of its own per-install FIPS key, as the native apps show it). A mesh address is never a Nostr account.
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

export const ACCOUNT_NOT_MESH = "That's your Nostr account, not a vault's mesh address. In Nostr Vault, open Mesh settings and copy the vault's own mesh address."

/**
 * Parse a comma/space/newline separated list of mesh addresses (npub-encoded or hex keys). Throws on any entry that
 * isn't a key, or that is `account` (the signed-in user's pubkey): a FIPS peer is never the person's identity.
 */
export function parseOwners(text, { account } = {}) {
  const out = new Set()
  for (const part of String(text).split(/[\s,]+/).filter(Boolean)) {
    const k = xOnly(part)
    if (!k) throw new Error(`not a mesh address: ${part.slice(0, 20)}`)
    if (account && k === account) throw new Error(ACCOUNT_NOT_MESH)
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
 * `account` (the signed-in user's pubkey, where there is one) is never an owner: it's dropped from what was saved
 * and refused from a link. `storage` is the page's own (src/page-storage.js).
 */
export function loadOwners({
  account,
  storage,
  log = () => {},
  confirm = msg => globalThis.confirm(msg),
  hash = location.hash,
  scrub = () => history.replaceState(null, "", location.pathname),
} = {}) {
  const saved = storage.getItem(OWNERS_ITEM) ?? ""
  let owners = new Set()
  try {
    owners = parseOwners(saved)
  } catch {}
  if (account && owners.delete(account)) {
    saveOwners(owners, storage)
    log("fips-owner-account-dropped")
  }
  const frag = new URLSearchParams(String(hash).slice(1)).get("owner")
  if (frag) {
    try {
      // One prompt per key: Haven's owner is the first saved key, so a batch prompt would let a link put a
      // stranger's key ahead of the reader's own and have both accepted with one OK.
      const fresh = [...parseOwners(frag, { account })].filter(k => !owners.has(k))
      const added = fresh.filter(k => confirm(`This link wants to let a vault reach this relay over FIPS. Its mesh address:\n\n  ${npubEncode(k)}\n\n` +
        "That vault can write to this relay and read everything on it. Only continue if this is your own vault."))
      if (added.length) {
        owners = new Set([...owners, ...added])
        saveOwners(owners, storage)
        log("fips-owner-paired", { offered: fresh.length, added: added.length, owners: owners.size })
      } else if (fresh.length) {
        log("fips-owner-declined", { offered: fresh.length })
      }
    } catch (e) {
      log("fips-owner-error", { err: String(e) })
    }
    scrub()
  }
  return owners
}

export function saveOwners(owners, storage) {
  storage.setItem(OWNERS_ITEM, [...owners].join(" "))
}

// The owner's Nostr account: the key the vault app signs the notes it pushes with (BrowserRelaySender). Haven
// keeps a note only from its owner or a whitelisted author, and the owner set holds mesh addresses, so without
// this the owner's own notes are refused. It is an author only: never an owner, never dialed, never let in as
// a FIPS peer.
const ACCOUNT_ITEM = "fips-owner-account"

/** The saved account as x-only hex, or undefined. */
export function loadOwnerAccount(storage) {
  return xOnly(storage.getItem(ACCOUNT_ITEM) ?? "")
}

/** Save one npub (or hex) as the owner's account; empty clears it. Throws on anything else. */
export function saveOwnerAccount(text, storage) {
  const t = String(text ?? "").trim()
  if (!t) return storage.setItem(ACCOUNT_ITEM, ""), undefined
  const k = xOnly(t)
  if (!k) throw new Error(`not an npub: ${t.slice(0, 20)}`)
  storage.setItem(ACCOUNT_ITEM, k)
  return k
}

/**
 * Haven's start options from the owner set: the first owner is Haven's owner, the other owners, the owner's
 * account and `extra` (the page's test key) are whitelisted authors. No other key can post.
 */
export function havenAuthors({ owners, account, extra = [] }) {
  const [owner, ...rest] = [...owners]
  const whitelist = [...new Set([...rest, ...(account ? [account] : []), ...extra])].filter(k => k !== owner)
  return { ownerNpub: npubEncode(owner), whitelist: whitelist.map(k => npubEncode(k)) }
}
