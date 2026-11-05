// The devices this browser is linked with by two-scan pairing, per account. On the web a linked device goes into the owner set
// (web-relay/src/fips/owners.js), as the pairing link does: it may open FIPS streams to this browser vault. Every role
// gets the same access here, so the name and role are kept beside it only to show them and for the role check
// (mesh-pairing.js roleCheck, Tron 1). Nothing is stored before both legs have checked (PairDevice.jsx).
import { npubEncode } from "nostr-tools/nip19"
import { parseOwners, saveOwners } from "../../../web-relay/src/fips/owners.js"
import { VAULT_NS, pageStorage } from "../../../web-relay/src/page-storage.js"
import { npubHex } from "./mesh-pairing.js"
import { loadAccounts, loadSession } from "../session.js"

// Per account (Tron 20): a device paired while one account is signed in is that account's, never an owner of another
// account's vault in this browser. "<item>:<pubkey>", so signing that account out removes it (vault.js accountKeys).
// The owner set itself (fips-owners) stays the one the FIPS layer reads; ownersForAccount narrows it at start.
const META_ITEM = "fips-paired"
const LEGACY_META = "fips-owner-meta" // one list per browser, before 2026-11-05
const OWNERS_ITEM = "fips-owners"
const fips = (storage = globalThis.localStorage) => pageStorage(storage, VAULT_NS)
const metaKey = pubkey => (pubkey ? `${META_ITEM}:${pubkey}` : LEGACY_META)
/** The signed-in account, when the caller doesn't say: the one in this browser's session. */
const activeOf = (storage = globalThis.localStorage) => { try { return loadSession(storage)?.pubkey ?? null } catch { return null } }

function readMap(s, key) {
  try { const m = JSON.parse(s.getItem(key) ?? "{}"); return m && typeof m === "object" && !Array.isArray(m) ? m : {} } catch { return {} }
}
function readOwners(s) {
  try { return parseOwners(s.getItem(OWNERS_ITEM) ?? "") } catch { return null } // null: unreadable, never overwritten
}

/** This account's pairing record ({ hex: { name, role } }). The one-per-browser list from before is moved to the first
 *  account that reads it (it was made hours before this change, by whoever was signed in). */
function readMeta(s, pubkey) {
  const own = readMap(s, metaKey(pubkey))
  if (!pubkey || s.getItem(LEGACY_META) == null) return own
  const moved = { ...readMap(s, LEGACY_META), ...own }
  s.setItem(metaKey(pubkey), JSON.stringify(moved))
  s.removeItem(LEGACY_META)
  return moved
}

/** Every mesh address another account in this browser paired: not this account's owners. */
function othersPaired(s, pubkey, storage) {
  const out = new Set()
  if (!pubkey) return out
  let accounts = []
  try { accounts = loadAccounts(storage) } catch {}
  for (const a of accounts) if (a.pubkey !== pubkey) for (const hex of Object.keys(readMap(s, metaKey(a.pubkey)))) out.add(hex)
  return out
}

/** The owner set for `pubkey`'s vault: the saved set, less the devices another account here paired. A device paired by
 *  link (no account on record) stays for everyone, as before. vault.js startVault calls this on what loadOwners read. */
export function ownersForAccount(owners, pubkey, { storage = globalThis.localStorage } = {}) {
  const s = fips(storage)
  const mine = readMeta(s, pubkey)
  const others = othersPaired(s, pubkey, storage)
  return new Set([...owners].filter(hex => mine[hex] || !others.has(hex)))
}

/** `[{ npub, hex, name, role }]`: this account's devices, with the name and role pairing gave each (role null for one
 *  paired by link). `pubkey`: the account; the session's when not given. */
export function pairedDevices(storage, pubkey = activeOf(storage)) {
  const s = fips(storage)
  const owners = ownersForAccount(readOwners(s) ?? new Set(), pubkey, { storage })
  const meta = readMeta(s, pubkey)
  return [...owners].map(hex => ({ hex, npub: npubEncode(hex), name: meta[hex]?.name ?? "", role: meta[hex]?.role ?? null }))
}

/** The `existing` list for roleCheck. A device paired by link has no role on record: on the web every role is the same
 *  access, so it reads as the role being checked (alreadyLinked), never as a move to another role. */
export const roleCheckList = (devices, role) => devices.map(d => ({ npub: d.npub, role: d.role ?? role }))

/** Links `device` ({ npub, name, role }) for `pubkey` (the session's account when not given): into the owner set (and
 *  `liveOwners`, the running vault's own Set, so the FIPS layer sees it now), with its name and role kept under that
 *  account. A saved owner set that can't be read is left alone rather than replaced by this one device. -> the list */
export function addPaired(device, { storage, liveOwners, pubkey = activeOf(storage) } = {}) {
  const hex = npubHex(device.npub)
  if (!hex) throw new Error("not a mesh address")
  const s = fips(storage)
  const owners = readOwners(s)
  if (!owners) throw new Error("This browser's list of linked devices can't be read, so nothing was added.")
  owners.add(hex)
  saveOwners(owners, s)
  liveOwners?.add?.(hex)
  const meta = readMeta(s, pubkey)
  meta[hex] = { name: device.name ?? "", role: device.role }
  s.setItem(metaKey(pubkey), JSON.stringify(meta))
  return pairedDevices(storage, pubkey)
}

/** This browser's name in its code, the device model for now (Logen is still to pick the defaults): "Chrome on Mac". */
export function browserDeviceName(ua = globalThis.navigator?.userAgent ?? "") {
  const browser = /Edg\//.test(ua) ? "Edge" : /OPR\/|Opera/.test(ua) ? "Opera" : /Firefox\//.test(ua) ? "Firefox"
    : /Brave/.test(ua) ? "Brave" : /Chrome\/|CriOS\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "Browser"
  const os = /iPhone/.test(ua) ? "iPhone" : /iPad/.test(ua) ? "iPad" : /Android/.test(ua) ? "Android"
    : /Mac OS X|Macintosh/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows" : /CrOS/.test(ua) ? "Chromebook" : /Linux/.test(ua) ? "Linux" : ""
  return os ? `${browser} on ${os}` : browser
}

const ROLE_LABEL = { phone: "Phone", mac: "Mac", homeVault: "Home vault", browser: "Browser vault" }

/** The Your devices rows: my-devices.js deviceList entries (home vaults from the media server list, then the owner
 *  set), named by pairing where it named them, else by role and the end of the address as before. */
export function deviceRows(devices, paired) {
  const byHex = new Map((paired ?? []).map(p => [p.hex, p]))
  return (devices ?? []).map(d => {
    const p = byHex.get(d.hex)
    const kind = ROLE_LABEL[p?.role] ?? d.role
    const tail = `${d.npub.slice(0, 9)}…${d.npub.slice(-4)}`
    return { ...d, title: p?.name ? p.name : `${kind} ${tail}`, kind }
  })
}
