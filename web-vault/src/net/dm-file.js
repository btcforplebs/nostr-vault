// A photo in a DM as a NIP-17 kind 15 file message (DM privacy, Tron 2026-11-14). A plain photo link in a DM is
// public: anyone with the link (the media server, whoever it's shared with) sees the photo. So the file is encrypted
// with a fresh AES-GCM key before it goes up; the server holds only ciphertext, named by its hash (the x tag), and the
// key and nonce travel inside the sealed message, where only the two people can read them.
//
// On this device a file message is kept as its link with what opens it in the fragment ("<url>#nv-dm=<base64url>"):
// the thread, the inbox, the sealed cache and the Messages napplet all carry a message as text, and a fragment never
// leaves in a fetch, so an <img> that ever drew the link as it is would only get ciphertext. openFileLink fetches the
// ciphertext, checks its hash, and decrypts.

import { readCapped } from "./blossom-uri.js"

const HEX64 = /^[0-9a-f]{64}$/
const NONCE = /^(?:[0-9a-f]{24}|[0-9a-f]{32})$/ // 12 bytes (ours, and GCM's usual) or 16 (some other NIP-17 apps)
const MARK = "#nv-dm="
const hex = b => [...b].map(x => x.toString(16).padStart(2, "0")).join("")
const unhex = s => Uint8Array.from(s.match(/../g) ?? [], h => parseInt(h, 16))
const sha256Hex = async b => hex(new Uint8Array(await crypto.subtle.digest("SHA-256", b)))
const b64url = s => btoa(String.fromCharCode(...new TextEncoder().encode(s))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const unb64url = s => new TextDecoder().decode(Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0)))
const MIME = /^[a-z]+\/[a-z0-9.+-]+$/i

/** Encrypt `bytes` with a fresh 256-bit AES-GCM key and 96-bit nonce.
 *  -> { cipher, key, nonce, x: sha256 of cipher, ox: sha256 of the original }, hex strings. */
export async function encryptFile(bytes) {
  const plain = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
  const raw = crypto.getRandomValues(new Uint8Array(32)), iv = crypto.getRandomValues(new Uint8Array(12))
  const k = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt"])
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, k, plain))
  return { cipher, key: hex(raw), nonce: hex(iv), x: await sha256Hex(cipher), ox: await sha256Hex(plain) }
}

/** The original bytes; throws when `cipher` isn't the file named by `x` (when given), doesn't open with the key, or
 *  opens to something other than the original named by `ox` (when given). */
export async function decryptFile(cipher, { key, nonce, x, ox }) {
  const c = cipher instanceof Uint8Array ? cipher : new Uint8Array(cipher)
  if (x && (await sha256Hex(c)) !== x) throw new Error("the file was changed on the server")
  const k = await crypto.subtle.importKey("raw", unhex(key), "AES-GCM", false, ["decrypt"])
  const plain = new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: unhex(nonce) }, k, c))
  if (ox && (await sha256Hex(plain)) !== ox) throw new Error("the file isn't the one that was sent")
  return plain
}

/** "<url>#nv-dm=…": the message as this device keeps and shows it. `size` (s, the encrypted bytes) when known, so a
 *  video shows its size before it loads. */
export function fileLink(url, { key, nonce, x, ox, mime, size }) {
  return `${url}${MARK}${b64url(JSON.stringify({ k: key, n: nonce, x, o: ox, m: mime, s: size }))}`
}

/** The same link marked as opened without a tap ("a": 1): whoever fetches it (the shell, for the Messages napplet)
 *  holds it to AUTO_SHOW_MAX. */
export function autoLink(link) {
  if (!isFileLink(link)) return link
  const i = link.indexOf(MARK)
  try { return `${link.slice(0, i)}${MARK}${b64url(JSON.stringify({ ...JSON.parse(unb64url(link.slice(i + MARK.length))), a: 1 }))}` } catch { return link }
}

export const isFileLink = s => typeof s === "string" && /^https:\/\/[^\s#]+#nv-dm=[A-Za-z0-9_-]+$/.test(s)

/** -> { url, key, nonce, x, ox, mime, size } or null. "o" (ox) is the same field the Apple app keeps. */
export function parseFileLink(s) {
  if (!isFileLink(s)) return null
  const i = s.indexOf(MARK)
  try {
    const d = JSON.parse(unb64url(s.slice(i + MARK.length)))
    if (!HEX64.test(d?.k ?? "") || !NONCE.test(d?.n ?? "") || (d.x != null && !HEX64.test(d.x)) || (d.o != null && !HEX64.test(d.o))) return null
    const size = Number.isSafeInteger(d.s) && d.s > 0 && d.s <= MAX_FILE ? d.s : undefined
    return { url: s.slice(0, i), key: d.k, nonce: d.n, x: d.x ?? undefined, ox: d.o ?? undefined, mime: MIME.test(d.m ?? "") ? d.m : "application/octet-stream", ...(size ? { size } : {}), ...(d.a === 1 ? { auto: true } : {}) }
  } catch { return null }
}

/** The kind 15 rumor's content and tags for an uploaded ciphertext, and `shown`, its link for this device. */
export function fileMessage(url, enc, { mime, dim } = {}) {
  const tags = [
    ["file-type", mime || "application/octet-stream"],
    ["encryption-algorithm", "aes-gcm"],
    ["decryption-key", enc.key],
    ["decryption-nonce", enc.nonce],
    ["x", enc.x],
    ["ox", enc.ox],
    ["size", String(enc.cipher?.length ?? enc.size)],
  ]
  if (dim) tags.push(["dim", dim])
  return { kind: 15, content: url, tags, shown: fileLink(url, { ...enc, mime, size: enc.cipher?.length ?? enc.size }) }
}

/** A received kind 15 rumor as this device keeps it: its link with what opens it, the bare link when it isn't
 *  encrypted the way this reads (it then shows as an old photo link would), null when its content isn't an https URL. */
export function fileContentOf(rumor) {
  const url = typeof rumor?.content === "string" ? rumor.content.trim() : ""
  if (!/^https:\/\/[^\s#]+$/.test(url)) return null
  const tag = k => (rumor.tags ?? []).find(t => Array.isArray(t) && t[0] === k)?.[1]
  const alg = String(tag("encryption-algorithm") ?? "").toLowerCase()
  const key = String(tag("decryption-key") ?? "").toLowerCase(), nonce = String(tag("decryption-nonce") ?? "").toLowerCase()
  const x = String(tag("x") ?? "").toLowerCase(), ox = String(tag("ox") ?? "").toLowerCase()
  if (alg !== "aes-gcm" || !HEX64.test(key) || !NONCE.test(nonce)) return url
  const size = Number(tag("size"))
  return fileLink(url, { key, nonce, x: HEX64.test(x) ? x : undefined, ox: HEX64.test(ox) ? ox : undefined, mime: MIME.test(tag("file-type") ?? "") ? tag("file-type") : undefined, size: Number.isSafeInteger(size) && size > 0 && size <= MAX_FILE ? size : undefined })
}

/** The most one encrypted file may be: a 100 MB video (Logen 2026-11-15) plus its 16-byte GCM tag, so a video the
 *  apps send at their full 100 MB (DMFile.maxVideoBytes + 16) still opens here. */
export const MAX_FILE = 100 * 1024 * 1024 + 16

/** The most a thread opens by itself, without a tap (the phones' DMFileLoader.AUTO_SHOW_MAX). The size tag is the
 *  sender's word, so an auto open is held to this while it reads, and a file past it waits for a tap. */
export const AUTO_SHOW_MAX = 16 * 1024 * 1024

/** A file is bigger than an open without a tap may read (not refused: a tap opens it). */
export const tooBig = () => Object.assign(new Error("too big to show by itself"), { tooBig: true })

/** A kept file link whose file is a video (its file-type starts with "video/"). */
export const isVideoLink = s => /^video\//i.test(parseFileLink(typeof s === "string" ? s.trim() : s)?.mime ?? "")

async function fetchCapped(url, onProgress, { max = MAX_FILE, signal } = {}) {
  // A 100 MB video on a slow line takes minutes: ten of them, where a photo needed one. `signal` (the thread closed,
  // the shell's slot taken) stops it at once.
  const timeout = AbortSignal.timeout?.(600_000)
  const stop = signal && timeout ? (AbortSignal.any?.([signal, timeout]) ?? signal) : (signal ?? timeout)
  const res = await fetch(url, { credentials: "omit", referrerPolicy: "no-referrer", redirect: "error", signal: stop })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  const over = () => max < MAX_FILE ? tooBig() : new Error("too large")
  const length = Number(res.headers.get("content-length"))
  if (length > max) { res.body?.cancel?.().catch(() => {}); throw over() }
  // Read in chunks and stopped at the cap: a body with no length (or a wrong one) can't read past it.
  const b = await readCapped(res, max, onProgress && (got => onProgress(got, length > 0 ? length : -1)))
  if (!b) throw over()
  onProgress?.(b.length, b.length)
  return b
}

/** The photo or video behind a file link, as a Blob of its own type. `onProgress(got, total or -1)` hears the
 *  ciphertext arrive. `max` caps the ciphertext read (AUTO_SHOW_MAX for an open without a tap; a link marked auto,
 *  autoLink, is held to it too); past a cap under MAX_FILE it throws an error with `tooBig`. `signal` aborts the read.
 *  `fetchBytes(url, onProgress, { max, signal })` -> bytes is for tests and the shell. */
export async function openFileLink(link, { fetchBytes = fetchCapped, onProgress, max = MAX_FILE, signal } = {}) {
  const f = parseFileLink(link)
  if (!f) throw new Error("not a DM file")
  const cap = Math.min(max, f.auto ? AUTO_SHOW_MAX : MAX_FILE)
  const bytes = await fetchBytes(f.url, onProgress, { max: cap, signal })
  if (bytes.length > cap) throw cap < MAX_FILE ? tooBig() : new Error("too large")
  const plain = await decryptFile(bytes, f)
  return new Blob([plain], { type: f.mime })
}

/** Encrypt a prepared photo (dm-photo.js preparePhoto) and upload the ciphertext. `upload(file)` -> { url, sha256 }
 *  must upload the bytes as they are (upload.js uploadPhoto with raw). -> the kind 15 message for sendMessage. */
export async function encryptedPhoto(file, { upload }) {
  const enc = await encryptFile(new Uint8Array(await file.arrayBuffer()))
  const up = await upload(new File([enc.cipher], "dm-file", { type: "application/octet-stream" }))
  if (!up?.url || up.sha256 !== enc.x) throw new Error(`The ${/^video\//.test(file.type) ? "video" : "photo"} didn't upload, so nothing was sent.`)
  return fileMessage(up.url, enc, { mime: file.type || "application/octet-stream" })
}
