// Two-scan device pairing: the QR codes, the hello and ack, and the checks. Pure: no I/O, no keys (the digests use
// crypto.subtle, so they are async). The contract is docs/MESH_PAIRING_CONTRACT.md; iOS MeshPairing.swift and Android
// fips/MeshPairing.kt agree with it through the fixtures in
// HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/MeshPairing (made by reference.py there).
import { decode, npubEncode } from "nostr-tools/nip19"

export const HELLO_KIND = 21195
/** Seconds A's code may open the camera after it is shown. */
export const CODE_LIFETIME = 180
/** Seconds A has to scan B's code (or Accept) after the hello. */
export const SCAN_WINDOW = 180
/** Seconds B waits for the ack after scanning A. */
export const ACK_WINDOW = 360
/** A hello's own time must be this close to now. */
export const HELLO_SKEW = 180
/** A device name, in Unicode code points. */
export const NAME_MAX = 40
/** The wire roles, as iOS MeshDeviceRole raw values (Android stores homeVault as "home_vault"). */
export const ROLES = ["phone", "mac", "homeVault", "browser"]

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
const UNRESERVED = /^[A-Za-z0-9\-._~]$/

// ---- the QR ----

/** `nvpair:v1?…` for this device. A's code: `s`. B's code: `e` (A's secret, echoed) and `b` (B's own fresh secret
 *  s_B; only a device that read B's code knows it, so the scan ack proves the scan: Tron, PR 1700). */
export function build({ m, n = "", r, o, s, e, b }) {
  const q = [`m=${m}`]
  const name = cleanName(n)
  if (name) q.push(`n=${percentEncode(name)}`)
  q.push(`r=${r}`, `o=${o}`)
  if (s != null) q.push(`s=${s}`)
  else q.push(`e=${e}`, `b=${b}`)
  return "nvpair:v1?" + q.join("&")
}

/** `{ ok: payload }` or `{ refusal }`. `ownMesh` is this device's own mesh npub. A payload is
 *  `{ mesh, meshHex, name, role, owner, ownerHex, secret }` (A's) or `{ …, echo, bSecret }` (B's). */
export function parse(uri, ownMesh = null) {
  const u = typeof uri === "string" ? uri.trim() : ""
  if (u.slice(0, 7).toLowerCase() !== "nvpair:") return { refusal: "notPairing" }
  const rest = u.slice(7)
  const qi = rest.indexOf("?")
  const version = qi >= 0 ? rest.slice(0, qi) : rest
  const query = qi >= 0 ? rest.slice(qi + 1) : ""
  if (version !== "v1") return { refusal: "unsupportedVersion" }
  const fields = new Map()
  if (query) {
    for (const part of query.split("&")) {
      const eq = part.indexOf("=")
      if (eq < 0) return { refusal: "malformed" }
      const key = part.slice(0, eq)
      const value = percentDecode(part.slice(eq + 1))
      if (fields.has(key) || value == null) return { refusal: "malformed" }
      fields.set(key, value)
    }
  }
  const meshHex = npubHex(fields.get("m"))
  if (!meshHex) return { refusal: "badAddress" }
  if (!ROLES.includes(fields.get("r"))) return { refusal: "unknownRole" }
  const ownerHex = npubHex(fields.get("o"))
  if (!ownerHex) return { refusal: "missingOwner" }
  // A's code has s and no b; B's has e and b.
  const s = fields.get("s"), e = fields.get("e"), b = fields.get("b")
  if ((s == null) === (e == null) || (s == null) !== (b != null)) return { refusal: "badCode" }
  if (!secretBytes(s ?? e) || (b != null && !secretBytes(b))) return { refusal: "badCode" }
  const name = (fields.get("n") ?? "").trim()
  if ([...name].length > NAME_MAX) return { refusal: "nameTooLong" }
  if (ownMesh != null && npubHex(ownMesh) === meshHex) return { refusal: "ownAddress" }
  const p = { mesh: npubEncode(meshHex), meshHex, name, role: fields.get("r"), owner: npubEncode(ownerHex), ownerHex }
  if (s != null) p.secret = s
  else Object.assign(p, { echo: e, bSecret: b })
  return { ok: p }
}

// ---- owner and role ----

/** "ok", "switchTo:<npub>" (another account on this device) or "otherOwner". Checks every account, not only the active. */
export function ownerCheck(owner, active, accounts) {
  const hex = npubHex(owner)
  if (!hex) return "otherOwner"
  if (active != null && npubHex(active) === hex) return "ok"
  const match = (accounts ?? []).find(a => npubHex(a) === hex)
  return match ? "switchTo:" + match : "otherOwner"
}

/** "add", "alreadyLinked" or "refuseOtherRole:<role>": a known device is never moved to another role (Tron 1).
 *  `existing` is `[{ npub, role }]` with wire roles. */
export function roleCheck(npub, role, existing) {
  const hex = npubHex(npub)
  const known = (existing ?? []).find(d => npubHex(d.npub) === hex)
  if (!known) return "add"
  return known.role === role ? "alreadyLinked" : "refuseOtherRole:" + known.role
}

// ---- words people read ----

export const displayName = name => (name ?? "").trim() || "this device"

/** The role confirm the person taps before anything is stored (Tron 1). `setup`: first-run "bring it over". */
export function roleConfirmText(role, name, setup = false) {
  const n = displayName(name)
  if (setup) return `Add ${n} as another of your devices: your vault copies between them.`
  return {
    mac: `Add ${n} as your Mac: your vault syncs to it and it keeps a full copy.`,
    homeVault: `Add ${n} as your mobile vault: your new posts and media are sent to it.`,
    browser: `Add ${n} as your browser vault: it gets your new notes while it's open.`,
    phone: `Add ${n} as another of your phones.`,
  }[role]
}

const ROLE_WORD = { phone: "phone", mac: "Mac", homeVault: "mobile vault", browser: "browser vault" }
const UNREADABLE = "That code didn't read correctly. Try scanning again."
const TEXTS = {
  notPairing: "That isn't a Nostr Vault pairing code.",
  unsupportedVersion: "That code is from a newer Nostr Vault. Update this app and try again.",
  malformed: UNREADABLE, badAddress: UNREADABLE, missingOwner: UNREADABLE, badCode: UNREADABLE, nameTooLong: UNREADABLE,
  unknownRole: "This version can't link that kind of device. Update this app and try again.",
  ownAddress: "That's this device's own code.",
  otherOwner: "That device belongs to another account. Only your own devices can be linked.",
  alreadyLinked: "Already linked.",
  expired: "This code has expired. Show a new one.",
  abort: "Another device tried to use this code. Start again, and only show your code to your own device.",
}

/** The line for a refusal or outcome code. `accountName` for switchTo, `role` for refuseOtherRole. */
export function refusalText(code, { accountName = "", role = "" } = {}) {
  if (code === "switchTo") {
    const n = accountName.trim() || "that account"
    return `This is ${n}'s device. Switch to ${n} first.`
  }
  if (code === "refuseOtherRole") return `This device is already added as your ${ROLE_WORD[role] ?? "device"}. Remove it in Mesh settings first.`
  return TEXTS[code]
}

/** "npub1abc…wxyz", as the apps. */
export const shortAddress = npub => (npub.length <= 12 ? npub : npub.slice(0, 8) + "…" + npub.slice(-4))

// ---- hello and ack (the decrypted content of a kind-21195 event) ----

export function helloJson({ s, n = "", r, o, t }) {
  const d = { v: 1, s }
  const name = cleanName(n)
  if (name) d.n = name
  Object.assign(d, { r, o, t })
  return JSON.stringify(d)
}

export const ackJson = (d, w = false) => JSON.stringify(w ? { v: 1, ack: true, d, w: true } : { v: 1, ack: true, d })

/** `{ s, n, r, o, t }` or null. */
export function parseHello(text) {
  const d = jsonObject(text)
  if (!d || d.v !== 1 || "ack" in d) return null
  const { s, r, o, t } = d
  const n = "n" in d ? d.n : ""
  if (!secretBytes(s) || !ROLES.includes(r) || !npubHex(o) || !Number.isSafeInteger(t) || typeof n !== "string") return null
  const name = n.trim()
  if ([...name].length > NAME_MAX) return null
  return { s, n: name, r, o: npubEncode(npubHex(o)), t }
}

/** `{ d, w }` or null. `w`: A linked by Accept with the check words, so B needs its own tap. */
export function parseAck(text) {
  const d = jsonObject(text)
  if (!d || d.v !== 1 || d.ack !== true) return null
  if (typeof d.d !== "string" || !/^[0-9a-f]{64}$/.test(d.d)) return null
  if ("w" in d && typeof d.w !== "boolean") return null
  return { d: d.d, w: d.w === true }
}

// ---- digests ----

/** The ack's proof. Scan path (`bSecret` given): hex SHA-256(s_A ‖ s_B ‖ m_A ‖ m_B), which only a device that read
 *  B's code can make (Tron, PR 1700). Accept path (`w`): hex SHA-256(s_A ‖ m_A ‖ m_B), and B also needs its own words
 *  tap (Tron 2). */
export async function ackDigest(secret, aHex, bHex, bSecret = null) {
  const parts = bytesOf(secret, aHex, bHex)
  if (!parts) return null
  const sb = bSecret == null ? new Uint8Array(0) : secretBytes(bSecret)
  return sb ? toHex(await sha256(concat(parts.s, sb, parts.a, parts.b))) : null
}

/** The 4 check words on the Accept path: the first 44 bits of SHA-256(m_A ‖ m_B ‖ s_A), 11 bits a word, BIP-39 English. */
export async function checkWords(aHex, bHex, secret) {
  const parts = bytesOf(secret, aHex, bHex)
  if (!parts) return null
  const h = await sha256(concat(parts.a, parts.b, parts.s))
  const { WORDS } = await import("./mesh-pairing-words.js")
  let n = 0n
  for (const byte of h.slice(0, 6)) n = (n << 8n) | BigInt(byte)
  n >>= 4n
  return [0, 1, 2, 3].map(i => WORDS[Number((n >> BigInt(11 * (3 - i))) & 2047n)])
}

// ---- helpers ----

/** A fresh one-time secret: 16 random bytes, base64url. */
export const newSecret = () => base64url(crypto.getRandomValues(new Uint8Array(16)))

/** The 32-byte key of an npub as hex, or null. Upper or lower case, never mixed. */
export function npubHex(s) {
  if (typeof s !== "string" || s.length !== 63) return null
  if (s.toLowerCase() !== s && s.toUpperCase() !== s) return null
  try {
    const d = decode(s.toLowerCase())
    return d.type === "npub" && /^[0-9a-f]{64}$/.test(d.data) ? d.data : null
  } catch {
    return null
  }
}

export function secretBytes(s) {
  if (typeof s !== "string" || s.length !== 22 || [...s].some(c => !B64.includes(c))) return null
  let bits = 0, acc = 0
  const out = []
  for (const c of s) {
    acc = (acc << 6) | B64.indexOf(c)
    bits += 6
    if (bits >= 8) {
      bits -= 8
      out.push((acc >> bits) & 0xff)
    }
  }
  if (out.length !== 16 || (acc & ((1 << bits) - 1)) !== 0) return null // canonical: the spare bits are zero
  return new Uint8Array(out)
}

export function base64url(bytes) {
  let s = ""
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

export const cleanName = name => [...(name ?? "").trim()].slice(0, NAME_MAX).join("")

export function percentEncode(s) {
  let out = ""
  for (const ch of s) {
    if (UNRESERVED.test(ch)) out += ch
    else for (const b of new TextEncoder().encode(ch)) out += "%" + b.toString(16).toUpperCase().padStart(2, "0")
  }
  return out
}

export function percentDecode(s) {
  const bytes = []
  const src = new TextEncoder().encode(s)
  for (let i = 0; i < src.length; i++) {
    if (src[i] === 0x25) {
      const h = String.fromCharCode(src[i + 1] ?? 0, src[i + 2] ?? 0)
      if (!/^[0-9a-fA-F]{2}$/.test(h)) return null
      bytes.push(parseInt(h, 16))
      i += 2
    } else bytes.push(src[i])
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array(bytes))
  } catch {
    return null
  }
}

function bytesOf(secret, aHex, bHex) {
  const s = secretBytes(secret)
  const ok = h => typeof h === "string" && /^[0-9a-fA-F]{64}$/.test(h)
  if (!s || !ok(aHex) || !ok(bHex)) return null
  return { s, a: fromHex(aHex), b: fromHex(bHex) }
}

const fromHex = h => new Uint8Array(h.match(/../g).map(x => parseInt(x, 16)))
const toHex = b => [...b].map(x => x.toString(16).padStart(2, "0")).join("")
const sha256 = async b => new Uint8Array(await crypto.subtle.digest("SHA-256", b))

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let i = 0
  for (const p of parts) {
    out.set(p, i)
    i += p.length
  }
  return out
}

function jsonObject(text) {
  try {
    const d = JSON.parse(text)
    return d && typeof d === "object" && !Array.isArray(d) ? d : null
  } catch {
    return null
  }
}
