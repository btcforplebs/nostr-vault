// Vault › Media (iPhone MediaGalleryView, MediaGridItem, BlossomService+Delete / +Mirroring): the files the account
// keeps on its Blossom servers. Each server is asked for its list (BUD-02 GET /list/<pubkey>); the lists are merged by
// hash, so a file shows once with the servers that hold it. A file can be copied to the servers missing it (BUD-04
// PUT /mirror) or deleted from all of them (BUD-02 DELETE /<sha256>), each with a kind 24242 authorisation.
import { checkSigned } from "./sync.js"
import { authHeader, serverUrl } from "./upload.js"

const HEX64 = /^[0-9a-f]{64}$/
const hostOf = url => { try { return new URL(url).host } catch { return url } }
const now = () => Math.floor(Date.now() / 1000)

/** Kind 24242 for one action ("list", "delete", "upload" for a mirror), good for ten minutes; `x` scopes it to a file.
 *  A delete names the one server it is sent to (BUD-11 `server`) and lasts five minutes: the same token used to go to
 *  every server, so any of them could replay it against the others, the home vault included. */
export const blossomAuthTemplate = (action, sha256, at = now(), server = null) => ({
  kind: 24242, created_at: at,
  content: sha256 ? `${action[0].toUpperCase()}${action.slice(1)} blob ${sha256.slice(0, 8)}...` : `${action[0].toUpperCase()}${action.slice(1)} blobs`,
  tags: [["t", action], ...(sha256 ? [["x", sha256]] : []), ...(server ? [["server", server]] : []),
    ["expiration", String(at + (action === "delete" ? 300 : 600))]],
})

const hostnameOf = url => { try { return new URL(url).hostname.toLowerCase() } catch { return null } }

async function signAuth(ctx, action, sha256, server = null) {
  const t = blossomAuthTemplate(action, sha256, now(), server)
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

// Servers that want a signed "list" (both defaults do): remembered in this browser, so the next visit asks them
// signed at once instead of waiting out a refusal first (Primal's is a failed fetch, ~0.35 s).
const AUTH_KEY = "nv-blossom-list-auth"
const readNeedsAuth = () => { try { return new Set(JSON.parse(globalThis.localStorage?.getItem(AUTH_KEY) ?? "[]")) } catch { return new Set() } }
let needsAuth = null
const noteNeedsAuth = server => {
  needsAuth ??= readNeedsAuth()
  if (needsAuth.has(server)) return
  needsAuth.add(server)
  try { globalThis.localStorage?.setItem(AUTH_KEY, JSON.stringify([...needsAuth])) } catch {}
}
/** For tests: forget what was learned. */
export const resetListAuth = () => { needsAuth = new Set(); listAuths.clear() }

/** Lists merged by hash, newest first: [{ server, ...descriptor }] -> [{ sha256, url, type, size, uploaded, kind, servers }]. */
function merge(lists) {
  const by = new Map()
  for (const b of lists.flat()) {
    const have = by.get(b.sha256)
    if (have) { if (!have.servers.includes(b.server)) have.servers.push(b.server); continue }
    by.set(b.sha256, { sha256: b.sha256, url: b.url, type: b.type ?? "", size: Number(b.size) || 0, uploaded: Number(b.uploaded) || 0, servers: [b.server] })
  }
  return [...by.values()].map(b => ({ ...b, kind: mediaType(b) })).sort((a, b) => b.uploaded - a.uploaded)
}

/**
 * Every server's list, merged by hash, newest first. A server that wants authorisation is asked again with a signed
 * "list" auth: it may say so (400, 401, 403: Primal answers 400 "missing auth event"), or its refusal may carry no
 * CORS header, which the page only sees as a failed fetch. One that wanted it before is asked signed straight away.
 * `on(partial)` gets the merged result each time a server answers, so the grid needn't wait for the slowest; servers
 * still being asked have no status yet. -> { blobs: [{ sha256, url, type, size, uploaded, kind, servers: [server] }],
 * status: { server: "ok" | reason } }
 */
export async function listBlobs(servers, pubkey, { ctx, fetch = globalThis.fetch, timeoutMs = 10_000, on } = {}) {
  const get = (server, headers) => fetch(`${server}/list/${pubkey}`, { headers, signal: AbortSignal.timeout?.(timeoutMs) })
  const canSign = ctx?.signer && !ctx.signer.readOnly
  needsAuth ??= readNeedsAuth()
  const status = {}
  const lists = servers.map(() => [])
  const answered = (i, list) => { lists[i] = list; on?.({ blobs: merge(lists), status: { ...status } }) }
  await Promise.all(servers.map(async (server, i) => {
    try {
      let res
      if (!(canSign && needsAuth.has(server))) {
        try { res = await get(server, {}) } catch (e) { if (!canSign || e?.name === "TimeoutError") throw e }
      }
      if (canSign && (!res || [400, 401, 403].includes(res.status))) {
        res = await get(server, { Authorization: await listAuth(ctx) })
        if (res.ok) noteNeedsAuth(server)
      }
      if (!res.ok) { status[server] = res.headers?.get?.("X-Reason") || `HTTP ${res.status}`; return answered(i, []) }
      const d = await res.json()
      if (!Array.isArray(d)) { status[server] = "answered with something other than a list"; return answered(i, []) }
      status[server] = "ok"
      answered(i, d.filter(b => HEX64.test(b?.sha256 ?? "") && typeof b.url === "string").map(b => ({ ...b, server })))
    } catch (e) { status[server] = e?.name === "TimeoutError" ? "didn't answer" : String(e?.message ?? e); answered(i, []) }
  }))
  return { blobs: merge(lists), status }
}

/**
 * A host only the owner's own devices can be on (HavenConfig.isPrivateNetworkHost, iOS/Mac #1404, Android #1403):
 * loopback, a LAN or CGNAT/Tailscale address, a unique-local or link-local IPv6, or a home-network name (.local,
 * .lan, .home.arpa, .internal, .localhost, .ts.net). Such a server is one of the owner's vaults, never a mirror.
 */
export function isHomeNetworkHost(hostname) {
  let h = String(hostname ?? "").toLowerCase().replace(/^\[|\]$/g, "").replace(/\.+$/, "")
  if (h.startsWith("::ffff:") && h.includes(".")) h = h.slice(7)
  if (!h || h === "localhost") return true
  if ([".localhost", ".local", ".lan", ".home.arpa", ".internal", ".ts.net"].some(x => h.endsWith(x))) return true
  if (h.includes(":")) return h === "::1" || h === "::" || /^(fc|fd|fe[89ab])/.test(h)
  const o = h.split(".")
  if (o.length !== 4 || !o.every(x => /^\d{1,3}$/.test(x))) return false
  const [a, b] = o.map(Number)
  return a === 10 || a === 127 || a === 0 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) ||
    (a === 169 && b === 254) || (a === 100 && b >= 64 && b <= 127)
}

/**
 * Where "Delete from mirrors" goes (Tim's facts, nv-fips 68c16689: one list on every app): the account's media servers
 * (its 10063, the web's mirrors) whether or not their list showed the file, any other server whose list had it, and
 * the server in the file's own link, once each. A server's list can miss a file it still serves, and a server dropped
 * from the 10063 can still hold it. No home-network or mesh server is a target (http other than loopback and `.fips`
 * never pass serverUrl; loopback and the rest are dropped here): any of them may be one of the owner's vaults. A vault
 * with a public https name (a Mac's tunnel in the 10063) looks like a mirror here; deleteBlob asks it first.
 */
export function deleteTargets(blob, servers = []) {
  let own = null
  try { own = serverUrl(new URL(blob.url).origin) } catch {}
  return [...new Set([...servers, ...(blob.servers ?? []), own].map(s => s && serverUrl(s)).filter(Boolean))]
    .filter(s => !isHomeNetworkHost(hostnameOf(s)))
}

/**
 * Is this server one of the owner's vaults? (HavenConfig.vaultCheckVerdict) `info` is what it answered to
 * `Accept: application/nostr+json` at its address, or null for no answer. Every vault's relay names its owner as
 * `pubkey` whatever address it is reached by; a public media server answers with a page, an error or another key.
 * -> "mirror" | "ownVault" | "unknown"
 */
export function vaultCheckVerdict(info, ownerHex) {
  if (info == null) return "unknown"
  let pubkey
  try { pubkey = JSON.parse(info)?.pubkey } catch { return "mirror" }
  if (typeof pubkey !== "string") return "mirror"
  const owner = String(ownerHex ?? "").trim().toLowerCase()
  if (!owner) return "unknown"
  return pubkey.trim().toLowerCase() === owner ? "ownVault" : "mirror"
}

/** Asks a server for its relay info (NIP-11). No answer, or a server error (a tunnel whose vault is down), is null. */
async function vaultCheck(server, ownerHex, { fetch, timeoutMs }) {
  let info = null
  try {
    const res = await fetch(server, { headers: { Accept: "application/nostr+json" }, signal: AbortSignal.timeout?.(timeoutMs) })
    if (res.status < 500) info = await res.text()
  } catch {}
  return vaultCheckVerdict(info, ownerHex)
}

/** Delete a file from every server in deleteTargets that isn't one of the owner's vaults. Each is asked first
 *  (vaultCheck): a vault keeps its copy (that copy may be the last one), and one that can't be asked gets nothing and
 *  is reported as still holding the file. A server that says 404 doesn't have it: that counts as done.
 *  -> [{ server, ok, message, kept? }] */
export async function deleteBlob(blob, { ctx, fetch = globalThis.fetch, servers = [], timeoutMs = 15_000 }) {
  return Promise.all(deleteTargets(blob, servers).map(async server => {
    const verdict = await vaultCheck(server, ctx?.session?.pubkey, { fetch, timeoutMs })
    if (verdict === "ownVault") return { server, ok: false, kept: true, message: "your vault, kept" }
    if (verdict === "unknown") return { server, ok: false, message: "couldn't check it isn't your vault, so nothing was sent" }
    try {
      const auth = await signAuth(ctx, "delete", blob.sha256, hostnameOf(server))
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
  const kept = results.filter(r => r.kept).map(r => hostOf(r.server))
  const asked = results.filter(r => !r.kept)
  const ok = asked.filter(r => r.ok).length
  const bad = asked.filter(r => !r.ok).map(r => `${hostOf(r.server)}: ${r.message}`)
  const keptLine = kept.length ? ` Your vault keeps its copy: ${kept.join(", ")}.` : ""
  return `${verb} on ${ok} of ${asked.length} server${asked.length === 1 ? "" : "s"}${bad.length ? `. ${bad.join(" · ")}` : "."}${keptLine}`
}

/** The first day of the week in `locale` (0 Sunday … 6 Saturday), as the phone's calendar has it; Sunday if unknown. */
export function weekStart(locale) {
  try { const l = new Intl.Locale(locale ?? Intl.DateTimeFormat().resolvedOptions().locale); const d = (l.getWeekInfo?.() ?? l.weekInfo)?.firstDay; return d ? d % 7 : 0 } catch { return 0 }
}

/** The heading a file sits under, as the phone's MediaDateGrouping: Today, This Week (the calendar week, not the last
 *  seven days), This Month, then the month, with the year when it isn't this year. */
export function dayHeading(uploaded, locale, now = new Date()) {
  if (!uploaded) return "Undated"
  const d = new Date(uploaded * 1000)
  const sameMonth = d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth()
  if (sameMonth && d.getDate() === now.getDate()) return "Today"
  const week = new Date(now.getFullYear(), now.getMonth(), now.getDate() - ((now.getDay() - weekStart(locale) + 7) % 7))
  if (d >= week && d <= now) return "This Week"
  if (sameMonth) return "This Month"
  return d.toLocaleDateString(locale, d.getFullYear() === now.getFullYear() ? { month: "long" } : { month: "long", year: "numeric" })
}

/** Headings for the grid, runs in the order given (newest first opens with Today, oldest first ends with it): [{ day, blobs }]. */
export function byDay(blobs, locale, now = new Date()) {
  const groups = []
  for (const b of blobs) {
    const day = dayHeading(b.uploaded, locale, now)
    const last = groups.at(-1)
    if (last?.day === day) last.blobs.push(b)
    else groups.push({ day, blobs: [b] })
  }
  return groups
}

/**
 * Is a media server working for you? (MediaServersPage.test) Holding one of your files is the proof: its list is
 * asked for, and the newest file on it is checked with HEAD. A front page that answers proves only that it answers.
 * -> { state: "working" | "answers" | "lostFile" | "offline", reason? }
 */
export async function testServer(server, pubkey, { ctx, fetch = globalThis.fetch, timeoutMs = 8000 } = {}) {
  const { blobs, status } = await listBlobs([server], pubkey, { ctx, fetch, timeoutMs })
  if (status[server] === "ok" && blobs.length) {
    try {
      const res = await fetch(`${server}/${blobs[0].sha256}`, { method: "HEAD", signal: AbortSignal.timeout?.(timeoutMs) })
      if (res.ok) return { state: "working" }
      if (res.status === 404) return { state: "lostFile" }
      return { state: "answers", reason: `HTTP ${res.status}` }
    } catch (e) { return { state: "offline", reason: String(e?.message ?? e) } }
  }
  if (status[server] === "ok") return { state: "answers" }
  // Its list wasn't readable: does it answer at all? An opaque answer still means something is there.
  try { await fetch(`${server}/`, { mode: "no-cors", signal: AbortSignal.timeout?.(timeoutMs) }); return { state: "answers", reason: status[server] } }
  catch (e) { return { state: "offline", reason: e?.name === "TimeoutError" ? "didn't answer" : String(e?.message ?? e) } }
}

/** The phone's words for each state (MediaServersPage statusLine). */
export const SERVER_STATES = {
  working: "Has your files",
  answers: "Answers, but holds none of your files to check",
  lostFile: "Answers, but a file it had is gone",
  offline: "Not answering",
}
