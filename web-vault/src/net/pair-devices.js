// The devices this browser is linked with by two-scan pairing. On the web a linked device goes into the owner set
// (web-relay/src/fips/owners.js), as the pairing link does: it may open FIPS streams to this browser vault. Every role
// gets the same access here, so the name and role are kept beside it only to show them and for the role check
// (mesh-pairing.js roleCheck, Tron 1). Nothing is stored before both legs have checked (PairDevice.jsx).
import { npubEncode } from "nostr-tools/nip19"
import { parseOwners, saveOwners } from "../../../web-relay/src/fips/owners.js"
import { VAULT_NS, pageStorage } from "../../../web-relay/src/page-storage.js"
import { npubHex } from "./mesh-pairing.js"

const META_ITEM = "fips-owner-meta"
const OWNERS_ITEM = "fips-owners"
const fips = (storage = globalThis.localStorage) => pageStorage(storage, VAULT_NS)

function readMeta(s) {
  try { const m = JSON.parse(s.getItem(META_ITEM) ?? "{}"); return m && typeof m === "object" ? m : {} } catch { return {} }
}

/** `[{ npub, hex, name, role }]`: every owner, with the name and role pairing gave it (role null for one paired by link). */
export function pairedDevices(storage) {
  const s = fips(storage)
  let owners = new Set()
  try { owners = parseOwners(s.getItem(OWNERS_ITEM) ?? "") } catch {}
  const meta = readMeta(s)
  return [...owners].map(hex => ({ hex, npub: npubEncode(hex), name: meta[hex]?.name ?? "", role: meta[hex]?.role ?? null }))
}

/** The `existing` list for roleCheck. A device paired by link has no role on record: on the web every role is the same
 *  access, so it reads as the role being checked (alreadyLinked), never as a move to another role. */
export const roleCheckList = (devices, role) => devices.map(d => ({ npub: d.npub, role: d.role ?? role }))

/** Links `device` ({ npub, name, role }): into the owner set (and `liveOwners`, the running vault's own Set, so the
 *  FIPS layer sees it now), with its name and role. Returns the device list after. */
export function addPaired(device, { storage, liveOwners } = {}) {
  const hex = npubHex(device.npub)
  if (!hex) throw new Error("not a mesh address")
  const s = fips(storage)
  let owners = new Set()
  try { owners = parseOwners(s.getItem(OWNERS_ITEM) ?? "") } catch {}
  owners.add(hex)
  saveOwners(owners, s)
  liveOwners?.add?.(hex)
  const meta = readMeta(s)
  meta[hex] = { name: device.name ?? "", role: device.role }
  s.setItem(META_ITEM, JSON.stringify(meta))
  return pairedDevices(storage)
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
