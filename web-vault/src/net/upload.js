// Photos for a post, uploaded as the iPhone app uploads them (BlossomService+PostUpload / +UploadAuth): BUD-02
// `PUT /upload` with a kind 24242 authorisation signed by the user's signer, to the account's media servers
// (kind 10063) or, with none listed, the iPhone's new-account servers. The first server that takes the photo gives the
// URL that goes in the note, with a NIP-92 imeta tag (NoteTagging.imetaTag).
import { pool, uniq } from "./pool.js"
import { checkSigned } from "./sync.js"

/** HavenConfig.newAccountBlossomMirrors: nostr.build first (Logen's call), Primal second. */
export const DEFAULT_MEDIA_SERVERS = ["https://blossom.nostr.build", "https://blossom.primal.net"]
// HavenConfig.defunctMirrorHosts: gone, and every upload to them waits out a timeout.
const DEFUNCT = ["blossom.kylezien.com", "cdn.satellite.earth"]
export const MAX_PHOTOS = 4

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
export const uploadAuthTemplate = (sha256, now = Math.floor(Date.now() / 1000)) => ({
  kind: 24242, created_at: now, content: `Upload blob ${sha256.slice(0, 8)}...`,
  tags: [["t", "upload"], ["x", sha256], ["expiration", String(now + 3600)]],
})

const base64 = s => btoa(String.fromCharCode(...new TextEncoder().encode(s)))
export const authHeader = event => `Nostr ${base64(JSON.stringify(event))}`

const hostOf = url => { try { return new URL(url).host } catch { return url } }

/**
 * Hash, sign and upload one photo to the first server that takes it. -> { url, sha256, mime, size, server };
 * throws with every server's reason when none did. A server whose answer names another hash is not used.
 */
export async function uploadPhoto(file, { ctx, servers, fetch = globalThis.fetch }) {
  const bytes = new Uint8Array(await file.arrayBuffer())
  const sha256 = await sha256Hex(bytes)
  const template = uploadAuthTemplate(sha256)
  const auth = authHeader(checkSigned(await ctx.signer.signEvent(template), template, ctx.session.pubkey))
  const mime = file.type || "application/octet-stream"
  const errors = []
  for (const server of servers) {
    try {
      const res = await fetch(`${server}/upload`, { method: "PUT", headers: { Authorization: auth, "Content-Type": mime }, body: bytes })
      if (!res.ok) { errors.push(`${hostOf(server)}: ${res.headers?.get?.("X-Reason") || `HTTP ${res.status}`}`); continue }
      const d = await res.json()
      if (d?.sha256 && d.sha256 !== sha256) { errors.push(`${hostOf(server)}: sent back a different file`); continue }
      const url = typeof d?.url === "string" && serverUrl(d.url) ? d.url : null
      if (!url) { errors.push(`${hostOf(server)}: no link in its answer`); continue }
      return { url, sha256, mime: d.type || mime, size: bytes.length, server }
    } catch (e) {
      errors.push(`${hostOf(server)}: ${e?.message ?? e}`)
    }
  }
  throw new Error(`No media server took it. ${errors.join(" · ")}`)
}

/** NIP-92 imeta for one uploaded photo, fields left out when unknown (NoteTagging.imetaTag). */
export function imetaTag(m) {
  if (!m?.url) return null
  const f = [`url ${m.url}`]
  if (m.mime) f.push(`m ${m.mime}`)
  if (m.sha256) f.push(`x ${m.sha256}`)
  if (m.width > 0 && m.height > 0) f.push(`dim ${m.width}x${m.height}`)
  if (m.size > 0) f.push(`size ${m.size}`)
  const alt = m.alt?.replace(/\s*\n\s*/g, " ").trim()
  if (alt) f.push(`alt ${alt}`)
  return ["imeta", ...f]
}
