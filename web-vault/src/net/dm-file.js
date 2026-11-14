// A photo in a DM as a NIP-17 kind 15 file message (DM privacy, Tron 2026-11-14). A plain photo link in a DM is
// public: anyone with the link (the media server, whoever it's shared with) sees the photo. So the file is encrypted
// with a fresh AES-GCM key before it goes up; the server holds only ciphertext, named by its hash (the x tag), and the
// key and nonce travel inside the sealed message, where only the two people can read them.
//
// On this device a file message is kept as its link with what opens it in the fragment ("<url>#nv-dm=<base64url>"):
// the thread, the inbox, the sealed cache and the Messages napplet all carry a message as text, and a fragment never
// leaves in a fetch, so an <img> that ever drew the link as it is would only get ciphertext. openFileLink fetches the
// ciphertext, checks its hash, and decrypts.

const HEX64 = /^[0-9a-f]{64}$/
const HEX24 = /^[0-9a-f]{24}$/
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

/** The original bytes; throws when `cipher` isn't the file named by `x` (when given) or doesn't open with the key. */
export async function decryptFile(cipher, { key, nonce, x }) {
  const c = cipher instanceof Uint8Array ? cipher : new Uint8Array(cipher)
  if (x && (await sha256Hex(c)) !== x) throw new Error("the file was changed on the server")
  const k = await crypto.subtle.importKey("raw", unhex(key), "AES-GCM", false, ["decrypt"])
  return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: unhex(nonce) }, k, c))
}

/** "<url>#nv-dm=…": the message as this device keeps and shows it. */
export function fileLink(url, { key, nonce, x, mime }) {
  return `${url}${MARK}${b64url(JSON.stringify({ k: key, n: nonce, x, m: mime }))}`
}

export const isFileLink = s => typeof s === "string" && /^https:\/\/[^\s#]+#nv-dm=[A-Za-z0-9_-]+$/.test(s)

/** -> { url, key, nonce, x, mime } or null. */
export function parseFileLink(s) {
  if (!isFileLink(s)) return null
  const i = s.indexOf(MARK)
  try {
    const d = JSON.parse(unb64url(s.slice(i + MARK.length)))
    if (!HEX64.test(d?.k ?? "") || !HEX24.test(d?.n ?? "") || (d.x != null && !HEX64.test(d.x))) return null
    return { url: s.slice(0, i), key: d.k, nonce: d.n, x: d.x ?? undefined, mime: MIME.test(d.m ?? "") ? d.m : "application/octet-stream" }
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
  return { kind: 15, content: url, tags, shown: fileLink(url, { ...enc, mime }) }
}

/** A received kind 15 rumor as this device keeps it: its link with what opens it, the bare link when it isn't
 *  encrypted the way this reads (it then shows as an old photo link would), null when its content isn't an https URL. */
export function fileContentOf(rumor) {
  const url = typeof rumor?.content === "string" ? rumor.content.trim() : ""
  if (!/^https:\/\/[^\s#]+$/.test(url)) return null
  const tag = k => (rumor.tags ?? []).find(t => Array.isArray(t) && t[0] === k)?.[1]
  const alg = String(tag("encryption-algorithm") ?? "").toLowerCase()
  const key = String(tag("decryption-key") ?? "").toLowerCase(), nonce = String(tag("decryption-nonce") ?? "").toLowerCase()
  const x = String(tag("x") ?? "").toLowerCase()
  if (alg !== "aes-gcm" || !HEX64.test(key) || !HEX24.test(nonce)) return url
  return fileLink(url, { key, nonce, x: HEX64.test(x) ? x : undefined, mime: MIME.test(tag("file-type") ?? "") ? tag("file-type") : undefined })
}

export const MAX_FILE = 60 * 1024 * 1024

async function fetchCapped(url) {
  const res = await fetch(url, { credentials: "omit", referrerPolicy: "no-referrer", redirect: "error", signal: AbortSignal.timeout?.(60_000) })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  if (Number(res.headers.get("content-length")) > MAX_FILE) throw new Error("too large")
  const b = new Uint8Array(await res.arrayBuffer())
  if (b.length > MAX_FILE) throw new Error("too large")
  return b
}

/** The photo behind a file link, as a Blob of its own type. `fetchBytes(url)` -> bytes is for tests and the shell. */
export async function openFileLink(link, { fetchBytes = fetchCapped } = {}) {
  const f = parseFileLink(link)
  if (!f) throw new Error("not a DM file")
  const plain = await decryptFile(await fetchBytes(f.url), f)
  return new Blob([plain], { type: f.mime })
}

/** Encrypt a prepared photo (dm-photo.js preparePhoto) and upload the ciphertext. `upload(file)` -> { url, sha256 }
 *  must upload the bytes as they are (upload.js uploadPhoto with raw). -> the kind 15 message for sendMessage. */
export async function encryptedPhoto(file, { upload }) {
  const enc = await encryptFile(new Uint8Array(await file.arrayBuffer()))
  const up = await upload(new File([enc.cipher], "dm-file", { type: "application/octet-stream" }))
  if (!up?.url || up.sha256 !== enc.x) throw new Error("The photo didn't upload, so nothing was sent.")
  return fileMessage(up.url, enc, { mime: file.type || "application/octet-stream" })
}
