// Photos and videos for a post, uploaded as the iPhone app uploads them (BlossomService+PostUpload / +UploadAuth): BUD-02
// `PUT /upload` with a kind 24242 authorisation signed by the user's signer, to the account's media servers
// (kind 10063) or, with none listed, the iPhone's new-account servers. The first server that takes the photo gives the
// URL that goes in the note, with a NIP-92 imeta tag (NoteTagging.imetaTag).
import { pool, uniq } from "./pool.js"
import { checkSigned } from "./sync.js"
import { withoutLocation } from "./media-privacy.js"
import { abortError, xhrPut } from "./upload-progress.js"

/** HavenConfig.newAccountBlossomMirrors: nostr.build first (Logen's call), Primal second. */
export const DEFAULT_MEDIA_SERVERS = ["https://blossom.nostr.build", "https://blossom.primal.net"]
// HavenConfig.defunctMirrorHosts: gone, and every upload to them waits out a timeout.
const DEFUNCT = ["blossom.kylezien.com", "cdn.satellite.earth"]
export const MAX_PHOTOS = 4
// A DM's locked (encrypted) photo is ciphertext with no picture type, and the default servers refuse it (Primal 415,
// nostr.build); nostr.download takes it (Logen 2026-11-14). It deletes files nobody downloads within a day, so it is
// only ever the last try, after the account's own servers.
export const LOCKED_FILE_FALLBACK = "https://nostr.download"
/** Where a locked DM file goes: the account's servers in order, then the fallback when it isn't already one of them. */
export const lockedFileServers = servers => uniq([...(servers ?? []), LOCKED_FILE_FALLBACK])

const loopback = h => h === "localhost" || h === "[::1]" || /^127\./.test(h)
/** A server URL worth trying: https (http only on this machine), no path slash at the end, not a dead host. */
export function serverUrl(raw) {
  let u
  try { u = new URL(String(raw ?? "").trim()) } catch { return null }
  if (!(u.protocol === "https:" || (u.protocol === "http:" && loopback(u.hostname)))) return null
  if (DEFUNCT.includes(u.hostname)) return null
  return (u.origin + u.pathname).replace(/\/+$/, "")
}

/** Media servers from a kind 10063 (BUD-03), in the account's order; the defaults when it lists none. */
export function serverList(ev) {
  const listed = uniq((ev?.tags ?? []).filter(t => t[0] === "server").map(t => serverUrl(t[1])).filter(Boolean))
  return listed.length ? listed : DEFAULT_MEDIA_SERVERS
}

/** The account's media servers: its kind 10063 from Haven's outbox, else from its relays (kept in Haven after). */
export async function mediaServers(ctx, { query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const filter = { kinds: [10063], authors: [ctx.session.pubkey] }
  const newest = evs => evs.filter(e => e?.kind === 10063 && e.pubkey === ctx.session.pubkey).sort((a, b) => b.created_at - a.created_at)[0]
  let ev = newest(await ctx.vault.outbox.query(filter).catch(() => []))
  if (!ev && globalThis.navigator?.onLine !== false) {
    ev = newest(await query(uniq([...ctx.account.relays.read, ...ctx.account.relays.write]), filter, { maxWait: 4000 }).catch(() => []))
    if (ev) await ctx.vault.outbox.event(ev).catch(() => {})
  }
  return serverList(ev)
}

export async function sha256Hex(bytes) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))
  return [...d].map(b => b.toString(16).padStart(2, "0")).join("")
}

/** BUD-02 upload authorisation for one blob: scoped to the hash, good for an hour, reused for every server. */
/** `also`: more hashes the same authorisation covers (BUD-02 lets one name several x), a photo's thumb, so it costs no
 *  second signer prompt. The file's own hash stays first, for a server that only reads the first x. */
export const uploadAuthTemplate = (sha256, now = Math.floor(Date.now() / 1000), also = []) => ({
  kind: 24242, created_at: now, content: `Upload blob ${sha256.slice(0, 8)}...`,
  tags: [["t", "upload"], ["x", sha256], ...also.filter(x => x && x !== sha256).map(x => ["x", x]), ["expiration", String(now + 3600)]],
})

const base64 = s => btoa(String.fromCharCode(...new TextEncoder().encode(s)))
export const authHeader = event => `Nostr ${base64(JSON.stringify(event))}`

/** A server's no, in words: its own X-Reason when it gives one, and a size refusal said as one (with the file's size). */
export function refusal(res, size) {
  const reason = res.headers?.get?.("X-Reason")?.trim()
  if (res.status === 413) return `too large (${megabytes(size)})${reason ? `, ${reason}` : ""}`
  return reason || `HTTP ${res.status}`
}
export const megabytes = n => `${(n / 1e6).toFixed(n < 1e7 ? 1 : 0)} MB`

const hostOf = url => { try { return new URL(url).host } catch { return url } }

/** BUD-06: whether an answer to `HEAD /upload` lets the upload go ahead. Only a real "not this file" (too big, wrong
 *  type, not allowed) stops it; no such route (404/405) or no answer now (5xx, 408, 429) gets the upload anyway, as on
 *  iPhone/Mac and Android (NDK check step 3, Logen 2026-11-04). */
export const precheckAllows = status => typeof status !== "number" || (status >= 200 && status < 300) ||
  status === 404 || status === 405 || status === 408 || status === 429 || status >= 500

/** Asks `server` whether it takes this file before sending it. -> "" to go ahead, else its refusal in words (refusal()).
 *  A pre-check that fails to run (network, CORS) goes ahead: the upload itself will say. */
export async function precheck(server, { sha256, size, mime, auth, fetch, signal }) {
  try {
    const res = await fetch(`${server}/upload`, {
      method: "HEAD", signal,
      headers: { Authorization: auth, "X-SHA-256": sha256, "X-Content-Length": String(size), "X-Content-Type": mime },
    })
    return precheckAllows(res?.status) ? "" : refusal(res, size)
  } catch (e) {
    if (e?.name === "AbortError") throw e
    return ""
  }
}

/**
 * Hash, sign and upload one photo or video to the first server that takes it. -> { url, sha256, mime, size, server };
 * throws with every server's reason when none did. A server whose answer names another hash, or none, is not used.
 * Where it was taken is removed first (media-privacy.js); one whose location can't be removed isn't uploaded.
 * `signal` stops it (an AbortError; before the signer is asked, if it hasn't been yet); `onProgress(0..1)` follows the PUT.
 * `raw`: the bytes go up exactly as they are (a DM's encrypted file, dm-file.js: ciphertext has no location to remove,
 * and a change to it would break its hash and its seal).
 * `linkOk(url)`: whether the server's link is one to keep (default serverUrl: https only). Vault › Media in box mode
 * also takes the box's own link (box/box-media.js), which is plain http on the LAN.
 * `preview(file)`: its small copy (upload-preview.js previewOf -> { field: "thumb" | "image", file } or null). It goes up
 * after the file, to the server that took the file, under the same authorisation, and its link comes back as
 * `thumb` / `image`. Any failure of it is dropped: the file's upload never waits on it or fails because of it.
 */
export async function uploadPhoto(file, { ctx, servers, fetch, signal, onProgress, raw = false, linkOk = serverUrl, preview }) {
  const stopped = () => { if (signal?.aborted) throw abortError() }
  const bytes = raw ? new Uint8Array(await file.arrayBuffer()) : withoutLocation(new Uint8Array(await file.arrayBuffer()))
  const sha256 = await sha256Hex(bytes)
  stopped() // removed before its turn came: no signer prompt for it
  const small = preview ? await smallCopy(preview, file) : null
  stopped()
  const template = uploadAuthTemplate(sha256, undefined, small ? [small.sha256] : [])
  const auth = authHeader(checkSigned(await ctx.signer.signEvent(template), template, ctx.session.pubkey))
  const mime = file.type || "application/octet-stream"
  // With a progress callback (the composer's ring) the PUT goes through XMLHttpRequest, which reports progress;
  // otherwise fetch, as before. A fetch passed in (tests) is always used.
  const put = fetch ?? (onProgress && globalThis.XMLHttpRequest
    ? (url, o) => xhrPut(url, { ...o, signal, onProgress })
    : (url, o) => globalThis.fetch(url, { ...o, signal }))
  const errors = []
  for (const server of servers) {
    stopped()
    try {
      onProgress?.(0)
      const no = await precheck(server, { sha256, size: bytes.length, mime, auth, signal, fetch: fetch ?? ((u, o) => globalThis.fetch(u, o)) })
      if (no) { errors.push(`${hostOf(server)}: ${no}`); continue }
      const res = await put(`${server}/upload`, { method: "PUT", headers: { Authorization: auth, "Content-Type": mime }, body: bytes })
      if (!res.ok) { errors.push(`${hostOf(server)}: ${refusal(res, bytes.length)}`); continue }
      const d = await res.json()
      // A BUD-02 blob descriptor always names the hash; no hash is as unproven as a wrong one.
      if (d?.sha256 !== sha256) { errors.push(`${hostOf(server)}: ${d?.sha256 ? "sent back a different file" : "didn't confirm the file's hash"}`); continue }
      const url = typeof d?.url === "string" && linkOk(d.url) ? d.url : null
      if (!url) { errors.push(`${hostOf(server)}: no link in its answer`); continue }
      const out = { url, sha256, mime: d.type || mime, size: bytes.length, server }
      if (small) {
        const link = await putSmall(server, small, { auth, linkOk, signal, fetch: fetch ?? ((u, o) => globalThis.fetch(u, o)) })
        if (link) out[small.field] = link
      }
      return out
    } catch (e) {
      if (e?.name === "AbortError") throw e
      errors.push(`${hostOf(server)}: ${e?.message ?? e}`)
    }
  }
  throw new Error(`No media server took it. ${errors.join(" · ")}`)
}

/** The preview's bytes and hash, or null: a preview that fails to be made is no preview. */
async function smallCopy(preview, file) {
  try {
    const p = await preview(file)
    if (!p?.file || !(p.field === "thumb" || p.field === "image")) return null
    const bytes = new Uint8Array(await p.file.arrayBuffer())
    if (!bytes.length) return null
    return { field: p.field, bytes, sha256: await sha256Hex(bytes), mime: p.file.type || "image/jpeg" }
  } catch { return null }
}

/** PUTs the preview to `server`. -> its link, or null for any failure (only a stop is passed on). */
async function putSmall(server, small, { auth, linkOk, signal, fetch }) {
  try {
    const res = await fetch(`${server}/upload`, { method: "PUT", signal, headers: { Authorization: auth, "Content-Type": small.mime }, body: small.bytes })
    if (!res?.ok) return null
    const d = await res.json()
    return d?.sha256 === small.sha256 && typeof d?.url === "string" && linkOk(d.url) ? d.url : null
  } catch (e) {
    if (e?.name === "AbortError") throw e
    return null
  }
}

/** NIP-92 imeta for one uploaded photo, fields left out when unknown (NoteTagging.imetaTag). */
export function imetaTag(m) {
  if (!m?.url) return null
  const f = [`url ${m.url}`]
  if (m.mime) f.push(`m ${m.mime}`)
  if (m.sha256) f.push(`x ${m.sha256}`)
  if (m.width > 0 && m.height > 0) f.push(`dim ${m.width}x${m.height}`)
  if (m.size > 0) f.push(`size ${m.size}`)
  // NIP-94's small copies (upload-preview.js): what Media grids draw instead of the file (components/grid-thumb.js).
  if (typeof m.thumb === "string" && m.thumb && m.thumb !== m.url) f.push(`thumb ${m.thumb}`)
  if (typeof m.image === "string" && m.image && m.image !== m.url) f.push(`image ${m.image}`)
  const alt = m.alt?.replace(/\s*\n\s*/g, " ").trim()
  if (alt) f.push(`alt ${alt}`)
  return ["imeta", ...f]
}
