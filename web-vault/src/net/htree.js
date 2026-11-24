// hashtree (Iris) photo links in a note: htree://nhash1…/<name>. The nhash carries the sha256 of an encrypted blob and
// the key to open it (hashtree docs/HTS-01.md, ts/packages/hashtree/src/{nhash,encryption,crypto}.ts). Phase 1 reads
// only what a photo up to 2 MiB is: one blob, CHK-encrypted, where the key IS the sha256 of the plain file, so the
// link already names the file the way Blossom does and the vault can keep it under that hash.
//
// Steps: decode the nhash (bech32 "nhash", TLV 0 = blob hash, 5 = key; a 33-byte key starts with its suite byte,
// 1 = chk-v1, a 32-byte one is legacy CHK), GET <server>/<blob hash> from upload.iris.to, the author's media servers
// and the reader's, check sha256(blob) == blob hash, decrypt (AES-256-GCM, key HKDF-SHA256(plain hash, salt
// "hashtree-chk", info "encryption-key"), all-zero nonce), check sha256(plain) == key, and draw it only when the bytes
// are a picture. rnd-v1 keys (random, no plain hash in the link) and links without a key stay plain text, and so does
// anything bigger than one blob (a chunked file or a folder: phase 2).
import { bech32 } from "@scure/base"
import { uniq } from "./pool.js"
import { authorServers, readCapped, serverOrigin, sha256Hex } from "./blossom-uri.js"

/** Iris's own upload server: every htree photo seen so far is only there (RESEARCH/NV_HTREE_MEDIA_SCOPE.md §0). */
export const IRIS_SERVERS = ["https://upload.iris.to"]
/** Phase 1 reads one blob: a photo up to 2 MiB, plus the 16-byte GCM tag. */
export const MAX_PLAIN_BYTES = 2 * 1024 * 1024
export const MAX_BLOB_BYTES = MAX_PLAIN_BYTES + 16
export const MAX_SERVERS = 8
const TIMEOUT_MS = 20_000
const LIST_WAIT_MS = 6_000

const hex = bytes => [...bytes].map(x => x.toString(16).padStart(2, "0")).join("")

/** The nhash's parts -> { hash: hex, key: Uint8Array | null }, or null when it isn't one. */
export function decodeNhash(code) {
  let words, prefix
  try { ({ prefix, words } = bech32.decode(String(code).toLowerCase(), 5000)) } catch { return null }
  if (prefix !== "nhash") return null
  const data = Uint8Array.from(bech32.fromWords(words))
  if (data.length === 32) return { hash: hex(data), key: null }
  let hash = null, key = null
  for (let at = 0; at < data.length;) {
    if (at + 2 > data.length) return null
    const t = data[at], l = data[at + 1]
    at += 2
    if (at + l > data.length) return null
    const v = data.slice(at, at + l)
    at += l
    if (t === 0 && l === 32 && !hash) hash = hex(v)
    if (t === 5 && !key) key = v
  }
  return hash ? { hash, key } : null
}

/** "legacy-chk" | "chk-v1" | "rnd-v1" | null for a key, as hashtree's encryptionMode. */
export function keyMode(key) {
  if (key?.length === 32) return "legacy-chk"
  if (key?.length !== 33) return null
  return key[0] === 1 ? "chk-v1" : key[0] === 2 ? "rnd-v1" : null
}

/**
 * An htree:// link read, or null when phase 1 can't show it.
 * -> { hash: blob sha256 hex, chk: Uint8Array(32), sha256: plain sha256 hex (the Blossom name), name, ext, raw }
 */
export function parseHtree(raw) {
  const m = /^htree:\/\/(nhash1[02-9ac-hj-np-z]+)(?:\/([^\s<>"]*))?$/i.exec(String(raw ?? "").trim())
  if (!m) return null
  const d = decodeNhash(m[1])
  const mode = keyMode(d?.key)
  if (mode !== "legacy-chk" && mode !== "chk-v1") return null
  const chk = mode === "chk-v1" ? d.key.slice(1) : d.key
  let name = ""
  try { name = decodeURIComponent((m[2] ?? "").split(/[?#]/)[0]) } catch { name = m[2] ?? "" }
  const ext = (/\.([A-Za-z0-9]{1,10})$/.exec(name)?.[1] ?? "").toLowerCase()
  return { hash: d.hash, chk, sha256: hex(chk), name, ext, raw }
}

/** CHK decrypt: the plain bytes, or null when the tag doesn't check (wrong key or other bytes). */
export async function decryptChk(cipher, chk, { subtle = globalThis.crypto.subtle } = {}) {
  if (cipher.byteLength < 16) return null
  try {
    const ikm = await subtle.importKey("raw", chk, "HKDF", false, ["deriveKey"])
    const key = await subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt: new TextEncoder().encode("hashtree-chk"), info: new TextEncoder().encode("encryption-key") },
      ikm, { name: "AES-GCM", length: 256 }, false, ["decrypt"])
    return new Uint8Array(await subtle.decrypt({ name: "AES-GCM", iv: new Uint8Array(12) }, key, cipher))
  } catch { return null }
}

/** "image/…" from the file's first bytes, or "": only pictures are drawn, whatever the name says. */
export function sniffImage(b) {
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg"
  if (b.length >= 8 && hex(b.slice(0, 8)) === "89504e470d0a1a0a") return "image/png"
  const ascii = (from, to) => String.fromCharCode(...b.slice(from, to))
  if (b.length >= 6 && /^GIF8[79]a$/.test(ascii(0, 6))) return "image/gif"
  if (b.length >= 12 && ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP") return "image/webp"
  if (b.length >= 12 && ascii(4, 8) === "ftyp" && /^avi[fs]$/.test(ascii(8, 12))) return "image/avif"
  return ""
}

/** The servers to ask, in order: Iris, the author's list, the reader's own; MAX_SERVERS at most. */
export const htreeServers = (authorServers = [], ownServers = []) =>
  uniq([...IRIS_SERVERS, ...authorServers, ...ownServers].map(serverOrigin).filter(Boolean)).slice(0, MAX_SERVERS)

/**
 * The photo's plain bytes from the first server whose blob checks: hash, decrypt, plain hash, picture.
 * -> { bytes, mime, server } | null. No redirects (blossom-uri.js fetchVerified's reason). `fetch` is for tests.
 */
export async function fetchHtree(h, servers, { fetch = globalThis.fetch, maxBytes = MAX_BLOB_BYTES } = {}) {
  for (const server of servers) {
    try {
      const res = await fetch(`${server}/${h.hash}`, { signal: AbortSignal.timeout?.(TIMEOUT_MS), referrerPolicy: "no-referrer", credentials: "omit", redirect: "error" })
      if (!res.ok) continue
      const length = Number(res.headers?.get?.("content-length"))
      if (Number.isFinite(length) && length > maxBytes) continue
      const blob = await readCapped(res, maxBytes)
      if (!blob || (await sha256Hex(blob)) !== h.hash) continue
      const bytes = await decryptChk(blob, h.chk)
      if (!bytes || (await sha256Hex(bytes)) !== h.sha256) continue
      const mime = sniffImage(bytes)
      if (!mime) return null // the right file, but not one blob of picture (a chunked file's node, a folder): phase 2
      return { bytes, mime, server }
    } catch {}
  }
  return null
}

const own = new Map()
/** The reader's own media servers: their newest kind 10063 in their vault's outbox, or []. Keyed by pubkey, so signing in
 *  or switching accounts reads the new one's list. Capped like authorServers. */
export function ownList(vault, me) {
  if (!me || !vault?.outbox?.query) return Promise.resolve([])
  if (!own.has(me)) {
    const capped = Promise.race([vault.outbox.query({ kinds: [10063], authors: [me] }), new Promise(r => setTimeout(() => r([]), LIST_WAIT_MS))])
    own.set(me, capped.then(evs => {
      const ev = (evs ?? []).filter(e => e?.kind === 10063 && e.pubkey === me).sort((a, b) => b.created_at - a.created_at)[0]
      return (ev?.tags ?? []).filter(t => t[0] === "server").map(t => t[1])
    }).catch(() => []))
  }
  return own.get(me)
}

/**
 * An htree photo the way a note draws it: Iris first, with no list read at all (every htree photo seen so far is there);
 * only when Iris hasn't got it, the author's kind 10063 (blossom-uri's authorServers, one read per author for both
 * kinds of link) and the reader's own list. -> { bytes, mime, server } | null. `fetch` and `query` are for tests.
 */
export async function loadHtree(h, { author, relays = [], vault, me, fetch, query } = {}) {
  const first = await fetchHtree(h, IRIS_SERVERS, fetch ? { fetch } : {})
  if (first) return first
  const [theirs, mine] = await Promise.all([authorServers(author, relays, query ? { query } : {}), ownList(vault, me)])
  const iris = new Set(IRIS_SERVERS.map(serverOrigin))
  const rest = htreeServers(theirs, mine).filter(s => !iris.has(s))
  return rest.length ? fetchHtree(h, rest, fetch ? { fetch } : {}) : null
}

/** Tests: forget the server lists read this session. */
export const resetHtreeLists = () => own.clear()
