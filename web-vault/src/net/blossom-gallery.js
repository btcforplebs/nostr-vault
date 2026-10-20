// Vault › Media (iPhone MediaGalleryView, MediaGridItem, BlossomService+Delete / +Mirroring): the files the account
// keeps on its Blossom servers. Each server is asked for its list (BUD-02 GET /list/<pubkey>); the lists are merged by
// hash, so a file shows once with the servers that hold it. A file can be copied to the servers missing it (BUD-04
// PUT /mirror) or deleted from all of them (BUD-02 DELETE /<sha256>), each with a kind 24242 authorisation.
import { checkSigned } from "./sync.js"
import { authHeader } from "./upload.js"

const HEX64 = /^[0-9a-f]{64}$/
const hostOf = url => { try { return new URL(url).host } catch { return url } }
const now = () => Math.floor(Date.now() / 1000)

/** Kind 24242 for one action ("list", "delete", "upload" for a mirror), good for ten minutes; `x` scopes it to a file. */
export const blossomAuthTemplate = (action, sha256, at = now()) => ({
  kind: 24242, created_at: at,
  content: sha256 ? `${action[0].toUpperCase()}${action.slice(1)} blob ${sha256.slice(0, 8)}...` : `${action[0].toUpperCase()}${action.slice(1)} blobs`,
  tags: [["t", action], ...(sha256 ? [["x", sha256]] : []), ["expiration", String(at + 600)]],
})

async function signAuth(ctx, action, sha256) {
  const t = blossomAuthTemplate(action, sha256)
  return authHeader(checkSigned(await ctx.signer.signEvent(t), t, ctx.session.pubkey))
}

/** photo | video | gif | other, from the descriptor's type or else the URL's extension. */
export function mediaType(blob) {
  const m = String(blob?.type ?? "").toLowerCase()
  const ext = (/\.([a-z0-9]+)(?:[?#]|$)/i.exec(blob?.url ?? "")?.[1] ?? "").toLowerCase()
  if (m === "image/gif" || ext === "gif") return "gif"
  if (m.startsWith("image/") || ["jpg", "jpeg", "png", "webp", "avif", "heic"].includes(ext)) return "photo"
  if (m.startsWith("video/") || ["mp4", "mov", "webm", "m4v"].includes(ext)) return "video"
  return "other"
}

export const TYPE_FILTERS = { all: () => true, photos: b => b.kind === "photo", videos: b => b.kind === "video", gifs: b => b.kind === "gif" }

// A signed "list" auth, kept until a minute before it runs out, so opening Media again doesn't ask the signer again.
const listAuths = new Map()
async function listAuth(ctx) {
  const have = listAuths.get(ctx.session.pubkey)
  if (have && have.until > now() + 60) return have.header
  const header = signAuth(ctx, "list")
  listAuths.set(ctx.session.pubkey, { header, until: now() + 600 })
  try { return await header } catch (e) { listAuths.delete(ctx.session.pubkey); throw e }
}

/**
 * Every server's list, merged by hash, newest first. A server that wants authorisation is asked again with a signed
 * "list" auth: it may say so (400, 401, 403: Primal answers 400 "missing auth event"), or its refusal may carry no
 * CORS header, which the page only sees as a failed fetch. -> { blobs: [{ sha256, url, type, size, uploaded, kind,
 * servers: [server] }], status: { server: "ok" | reason } }
 */
export async function listBlobs(servers, pubkey, { ctx, fetch = globalThis.fetch, timeoutMs = 10_000 } = {}) {
  const get = (server, headers) => fetch(`${server}/list/${pubkey}`, { headers, signal: AbortSignal.timeout?.(timeoutMs) })
  const canSign = ctx?.signer && !ctx.signer.readOnly
  const status = {}
  const lists = await Promise.all(servers.map(async server => {
    try {
      let res
      try { res = await get(server, {}) } catch (e) { if (!canSign || e?.name === "TimeoutError") throw e }
      if (canSign && (!res || [400, 401, 403].includes(res.status))) res = await get(server, { Authorization: await listAuth(ctx) })
      if (!res.ok) { status[server] = res.headers?.get?.("X-Reason") || `HTTP ${res.status}`; return [] }
      const d = await res.json()
      if (!Array.isArray(d)) { status[server] = "answered with something other than a list"; return [] }
      status[server] = "ok"
      return d.filter(b => HEX64.test(b?.sha256 ?? "") && typeof b.url === "string").map(b => ({ ...b, server }))
    } catch (e) { status[server] = e?.name === "TimeoutError" ? "didn't answer" : String(e?.message ?? e); return [] }
  }))
  const by = new Map()
  for (const b of lists.flat()) {
    const have = by.get(b.sha256)
    if (have) { if (!have.servers.includes(b.server)) have.servers.push(b.server); continue }
    by.set(b.sha256, { sha256: b.sha256, url: b.url, type: b.type ?? "", size: Number(b.size) || 0, uploaded: Number(b.uploaded) || 0, servers: [b.server] })
  }
  const blobs = [...by.values()].map(b => ({ ...b, kind: mediaType(b) })).sort((a, b) => b.uploaded - a.uploaded)
  return { blobs, status }
}

/** Delete a file from every server that holds it. -> [{ server, ok, message }] */
export async function deleteBlob(blob, { ctx, fetch = globalThis.fetch }) {
  const auth = await signAuth(ctx, "delete", blob.sha256)
  return Promise.all(blob.servers.map(async server => {
    try {
      const res = await fetch(`${server}/${blob.sha256}`, { method: "DELETE", headers: { Authorization: auth } })
      return { server, ok: res.ok || res.status === 404, message: res.ok ? "" : res.headers?.get?.("X-Reason") || `HTTP ${res.status}` }
    } catch (e) { return { server, ok: false, message: String(e?.message ?? e) } }
  }))
}

/** Copy a file to the servers that don't hold it (BUD-04: they fetch it from its URL). -> [{ server, ok, message }] */
export async function mirrorBlob(blob, servers, { ctx, fetch = globalThis.fetch }) {
  const missing = servers.filter(s => !blob.servers.includes(s))
  if (!missing.length) return []
  const auth = await signAuth(ctx, "upload", blob.sha256)
  return Promise.all(missing.map(async server => {
    try {
      const res = await fetch(`${server}/mirror`, { method: "PUT", headers: { Authorization: auth, "Content-Type": "application/json" }, body: JSON.stringify({ url: blob.url }) })
      if (!res.ok) return { server, ok: false, message: res.headers?.get?.("X-Reason") || `HTTP ${res.status}` }
      const d = await res.json().catch(() => null)
      // The copy is only proven when the server names the same hash.
      return d?.sha256 === blob.sha256 ? { server, ok: true, message: "" } : { server, ok: false, message: "didn't confirm the file's hash" }
    } catch (e) { return { server, ok: false, message: String(e?.message ?? e) } }
  }))
}

/** "3 of 4 servers" style summary of a delete or mirror, naming the ones that refused. */
export function outcome(results, verb) {
  const ok = results.filter(r => r.ok).length
  const bad = results.filter(r => !r.ok).map(r => `${hostOf(r.server)}: ${r.message}`)
  return `${verb} on ${ok} of ${results.length} server${results.length === 1 ? "" : "s"}${bad.length ? `. ${bad.join(" · ")}` : "."}`
}

/** Day headings for the grid, as the phone groups by date: [{ day, blobs }], newest first. */
export function byDay(blobs, locale) {
  const groups = []
  for (const b of blobs) {
    const day = b.uploaded ? new Date(b.uploaded * 1000).toLocaleDateString(locale, { year: "numeric", month: "long", day: "numeric" }) : "Undated"
    const last = groups.at(-1)
    if (last?.day === day) last.blobs.push(b)
    else groups.push({ day, blobs: [b] })
  }
  return groups
}
