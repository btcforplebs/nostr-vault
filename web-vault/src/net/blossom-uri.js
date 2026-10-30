// BUD-10 blossom: links in a note: blossom:<sha256>.<ext>?xs=<server>&as=<pubkey>&sz=<bytes>. The file is asked of
// each `xs` server, then the servers on the `as` author's media server list (kind 10063, BUD-03), then the usual
// servers, as GET <server>/<sha256>.<ext> (BUD-01). Its bytes must hash to the sha256 the link names before anything is
// shown: a server can send anything, and this is the only check that what shows is what the author linked. Servers
// on this machine or a private network are never asked (a note could otherwise make every reader probe their LAN).
import { pool, uniq } from "./pool.js"
import { DEFAULT_MEDIA_SERVERS } from "./upload.js"
import { mediaType } from "./media.js"

const HEX64 = /^[0-9a-f]{64}$/
/** Where a note's text has one: the whole link, query included, up to the next space. */
export const BLOSSOM_TOKEN = /blossom:[0-9a-fA-F]{64}\.[A-Za-z0-9]{1,10}(?:\?[^\s<>"]*)?/
/** Servers asked for one file, at most: a note can list any number. */
export const MAX_SERVERS = 8
/** Largest file fetched to be checked: a video past this stays a "media unavailable" line. */
export const MAX_BYTES = 100 * 1024 * 1024
const TIMEOUT_MS = 20_000
const LIST_WAIT_MS = 6_000

/** A server as an https origin, or null: bare hosts become https://host; http, loopback, private and .local/.onion
 *  hosts are refused. */
export function serverOrigin(raw) {
  let s = String(raw ?? "").trim()
  if (!s) return null
  if (!/^[a-z]+:\/\//i.test(s)) s = `https://${s}`
  let u
  try { u = new URL(s) } catch { return null }
  if (u.protocol !== "https:" || u.username || u.password) return null
  const h = u.hostname.toLowerCase().replace(/^\[|\]$/g, "")
  if (h === "localhost" || h.endsWith(".localhost") || h.endsWith(".local") || h.endsWith(".onion") || h.endsWith(".internal") || !h.includes(".") && !h.includes(":")) return null
  if (/^(127\.|10\.|0\.|169\.254\.|192\.168\.)/.test(h) || /^172\.(1[6-9]|2\d|3[01])\./.test(h) || /^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(h)) return null
  if (h === "::1" || h === "::" || /^f[cd][0-9a-f]{2}:/.test(h) || /^fe80:/.test(h)) return null
  const path = u.pathname.replace(/\/+$/, "")
  return `${u.origin}${path}`
}

/** A blossom: link read, or null when it isn't one. -> { sha256, ext, servers: [origin], author: hex | null, size: n | null, raw } */
export function parseBlossomUri(raw) {
  const m = /^blossom:([0-9a-fA-F]{64})\.([A-Za-z0-9]{1,10})(?:\?(.*))?$/.exec(String(raw ?? "").trim())
  if (!m) return null
  const q = new URLSearchParams(m[3] ?? "")
  const author = (q.get("as") ?? "").toLowerCase()
  const size = Number(q.get("sz"))
  return {
    sha256: m[1].toLowerCase(), ext: m[2].toLowerCase(),
    servers: uniq(q.getAll("xs").map(serverOrigin).filter(Boolean)),
    author: HEX64.test(author) ? author : null,
    size: Number.isSafeInteger(size) && size > 0 ? size : null,
    raw,
  }
}

/** "image" | "video" | "" from the link's extension (net/media.js rules). */
export const blossomKind = b => mediaType(`x.${b.ext}`)

/** The servers to ask, in order: the link's own, the author's list, the usual ones; MAX_SERVERS at most. */
export const candidateServers = (b, authorServers = [], usual = DEFAULT_MEDIA_SERVERS) =>
  uniq([...b.servers, ...authorServers.map(serverOrigin), ...usual.map(serverOrigin)].filter(Boolean)).slice(0, MAX_SERVERS)

export async function sha256Hex(bytes) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))
  return [...d].map(x => x.toString(16).padStart(2, "0")).join("")
}

const MIME = { jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", gif: "image/gif", webp: "image/webp", avif: "image/avif", svg: "image/svg+xml",
  mp4: "video/mp4", m4v: "video/mp4", mov: "video/quicktime", webm: "video/webm", mkv: "video/x-matroska" }

/**
 * The file's bytes from the first server whose answer hashes to the link's sha256. -> { bytes, server, mime } | null.
 * A server that refuses, times out, sends too much or sends other bytes is skipped. `fetch` is for tests.
 */
export async function fetchVerified(b, servers, { fetch = globalThis.fetch, maxBytes = MAX_BYTES } = {}) {
  if (b.size && b.size > maxBytes) return null
  for (const server of servers) {
    try {
      const res = await fetch(`${server}/${b.sha256}.${b.ext}`, { signal: AbortSignal.timeout?.(TIMEOUT_MS), referrerPolicy: "no-referrer", credentials: "omit" })
      if (!res.ok) continue
      const length = Number(res.headers?.get?.("content-length"))
      if (Number.isFinite(length) && length > maxBytes) continue
      const bytes = new Uint8Array(await res.arrayBuffer())
      if (bytes.byteLength > maxBytes) continue
      if ((await sha256Hex(bytes)) !== b.sha256) continue
      return { bytes, server, mime: MIME[b.ext] ?? (res.headers?.get?.("content-type") || "application/octet-stream") }
    } catch {}
  }
  return null
}

// One author's media server list per session, and one fetch per file: the same link in two notes is fetched once.
const lists = new Map()
const files = new Map()

/** The servers on `pubkey`'s newest kind 10063 from `relays`, or []. `query` is for tests. */
export function authorServers(pubkey, relays, { query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  if (!pubkey || !relays?.length) return Promise.resolve([])
  if (!lists.has(pubkey)) {
    // Capped on our side too: a pool waiting for a free socket can hold a query well past its maxWait.
    const capped = Promise.race([query(uniq(relays), { kinds: [10063], authors: [pubkey] }, { maxWait: 5000 }), new Promise(r => setTimeout(() => r([]), LIST_WAIT_MS))])
    lists.set(pubkey, capped.then(evs => {
      const ev = evs.filter(e => e?.kind === 10063 && e.pubkey === pubkey).sort((a, b) => b.created_at - a.created_at)[0]
      return (ev?.tags ?? []).filter(t => t[0] === "server").map(t => t[1])
    }).catch(() => []))
  }
  return lists.get(pubkey)
}

/**
 * A blossom: link as something to show: an object URL of its checked bytes. -> Promise<{ url, kind } | null>.
 * `author`: the note's author, used when the link has no `as`. `relays`: where to read their server list.
 */
export function loadBlossom(b, { author, relays, fetch, query, usual = DEFAULT_MEDIA_SERVERS, makeUrl = (bytes, mime) => URL.createObjectURL(new Blob([bytes], { type: mime })) } = {}) {
  if (!files.has(b.sha256)) {
    files.set(b.sha256, (async () => {
      // The link's own servers first, before the author's list is even read: most links say where the file is.
      const first = candidateServers(b, [], [])
      let got = await fetchVerified(b, first, { fetch })
      if (!got) {
        const listed = await authorServers(b.author ?? author, relays, { query })
        got = await fetchVerified(b, candidateServers(b, listed, usual).filter(s => !first.includes(s)), { fetch })
      }
      if (!got) { files.delete(b.sha256); return null } // another note may link it with servers that have it
      return { url: makeUrl(got.bytes, got.mime), kind: blossomKind(b) || (got.mime.startsWith("video/") ? "video" : "image"), server: got.server }
    })())
  }
  return files.get(b.sha256)
}

/** Tests: forget what this session fetched. */
export const resetBlossom = () => { lists.clear(); files.clear() }
