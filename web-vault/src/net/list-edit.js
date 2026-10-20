// Editing the account's own lists, as the iPhone's Relays and Media Servers pages do: kind 10002 (NIP-65 relays,
// RelayMatrixView) and kind 10063 (BUD-03 media servers, BlossomSettingsView). An edit starts from the newest copy
// anywhere, Haven's outbox or the relays, so a stale or missing local copy never gets published over the real one.
import { pool, publishRelays, uniq, DEFAULT_RELAYS, PROFILE_RELAYS } from "./pool.js"
import { checkSigned } from "./sync.js"
import { serverUrl } from "./upload.js"

const newest = evs => evs.reduce((a, e) => (!a || e.created_at > a.created_at ? e : a), undefined)
const now = () => Math.floor(Date.now() / 1000)

/** Where a list is looked for and sent: the account's relays, the defaults and the profile index (purplepag.es). */
const listRelays = ctx => uniq([...ctx.account.relays.read, ...ctx.account.relays.write, ...DEFAULT_RELAYS, ...PROFILE_RELAYS])

/**
 * The newest `kind` list the account signed. -> { event, checked }; `checked` is false when the relays weren't
 * asked (offline), so the page can say its copy may be old. A newer copy from the relays is kept in Haven.
 */
export async function latestList(ctx, kind, { query = (r, f, o) => pool.querySync(r, f, o), online = globalThis.navigator?.onLine !== false } = {}) {
  const me = ctx.session.pubkey
  const filter = { kinds: [kind], authors: [me] }
  const mine = evs => evs.filter(e => e?.kind === kind && e.pubkey === me)
  const local = newest(mine(await ctx.vault.outbox.query(filter).catch(() => [])))
  if (!online) return { event: local, checked: false }
  const remote = newest(mine(await query(listRelays(ctx), filter, { maxWait: 5000 }).catch(() => [])))
  if (remote && (!local || remote.created_at > local.created_at)) {
    await ctx.vault.outbox.event(remote).catch(() => {})
    return { event: remote, checked: true }
  }
  return { event: local, checked: true }
}

/**
 * Sign the list with `tags` (the old copy's other tags kept) and send it out. Its time is after the old copy's, so
 * relays take it as the newer one even with a slow clock. Kept in Haven once a relay took it.
 * -> { event, relays: [{ url, ok, message }] }; throws when signing fails or no relay took it.
 */
export async function publishList(ctx, kind, tags, { previous, also = [] } = {}) {
  const template = { kind, content: previous?.content ?? "", tags, created_at: Math.max(now(), (previous?.created_at ?? 0) + 1) }
  const event = checkSigned(await ctx.signer.signEvent(template), template, ctx.session.pubkey)
  const urls = uniq([...publishRelays([...ctx.account.relays.write, ...also]).network, ...PROFILE_RELAYS])
  const results = await Promise.allSettled(pool.publish(urls, event))
  const relays = results.map((r, i) => ({ url: urls[i], ok: r.status === "fulfilled", message: r.status === "fulfilled" ? r.value : String(r.reason?.message ?? r.reason) }))
  if (!relays.some(r => r.ok)) throw new Error(`No relay took it (0 of ${urls.length})`)
  await ctx.vault.outbox.event(event).catch(() => {})
  return { event, relays }
}

// ---- Relays (kind 10002) ----

const loopback = h => { h = h.replace(/^\[|\]$/g, ""); return h === "localhost" || h === "::1" || /^127\./.test(h) }

/**
 * A typed relay address, as RelayMatrix.relayURL reads it: "relay.example.com" gets wss://, other schemes are
 * refused, the trailing slash goes. A loopback address names the browser's own machine, which nobody else can reach,
 * so it is refused for the public list (NostrService.isLoopbackRelay). -> url or null
 */
export function relayUrl(typed) {
  let s = String(typed ?? "").trim()
  if (!s || /\s/.test(s)) return null
  if (!/^wss?:\/\//i.test(s)) { if (s.includes("://")) return null; s = "wss://" + s }
  let u
  try { u = new URL(s) } catch { return null }
  if (!u.hostname || loopback(u.hostname) || u.username || u.password) return null
  return `${u.protocol}//${u.host}${u.pathname}`.replace(/\/+$/, "") + u.search
}

/** Why a typed address can't be added, for the page to say. */
export function relayUrlError(typed) {
  let host = ""
  try { host = new URL(/^wss?:\/\//i.test(String(typed).trim()) ? String(typed).trim() : `wss://${String(typed).trim()}`).hostname } catch {}
  return host && loopback(host)
    ? "That's this computer's own address. Nobody else can reach it, so it can't go in your public relay list."
    : "That isn't a relay address. Type one like relay.example.com or wss://relay.example.com."
}

/** The list's relays as rows, in its order, read and write marks merged per address. Nothing is dropped. */
export function relayEntries(ev) {
  const rows = new Map()
  for (const t of ev?.tags ?? []) {
    if (t[0] !== "r" || !/^wss?:\/\//i.test(t[1] ?? "")) continue
    const url = t[1].trim().replace(/\/+$/, "")
    const row = rows.get(url) ?? { url, read: false, write: false }
    if (t[2] !== "write") row.read = true
    if (t[2] !== "read") row.write = true
    rows.set(url, row)
  }
  return [...rows.values()]
}

/** Added with Read and Write, the jobs people mean by "add a relay" (RelayMatrix.adding). Already there: both on. */
export function addRelay(rows, url) {
  return rows.some(r => r.url === url) ? rows.map(r => r.url === url ? { ...r, read: true, write: true } : r) : [...rows, { url, read: true, write: true }]
}

/** Read or write switched; the last job a relay has can't be switched off (Remove takes it out). */
export function setJob(rows, url, job, on) {
  return rows.map(r => {
    if (r.url !== url) return r
    const next = { ...r, [job]: on }
    return next.read || next.write ? next : r
  })
}

export const removeRelay = (rows, url) => rows.filter(r => r.url !== url)

/** NIP-65 tags: no mark for both, "read" or "write" for one. The old copy's other tags stay. */
export function relayTags(rows, previous) {
  const other = (previous?.tags ?? []).filter(t => t[0] !== "r")
  return [...other, ...rows.map(r => r.read && r.write ? ["r", r.url] : ["r", r.url, r.read ? "read" : "write"])]
}

/** Why the list can't be saved yet, or "" when it can: it needs a relay to read from and one to write to. */
export function relayProblem(rows) {
  if (!rows.some(r => r.read)) return "Keep at least one relay to read from."
  if (!rows.some(r => r.write)) return "Keep at least one relay to write to."
  return ""
}

export const sameRows = (a, b) => JSON.stringify(a) === JSON.stringify(b)

// ---- Media servers (kind 10063) ----

/** The list's servers, in its order (the first is where a photo is uploaded first), duplicates dropped. Servers
 *  upload.js won't use (not https, gone hosts) stay listed so an edit doesn't drop them unasked. */
export function serverEntries(ev) {
  const urls = (ev?.tags ?? []).filter(t => t[0] === "server" && typeof t[1] === "string" && t[1].trim()).map(t => serverUrl(t[1]) ?? t[1].trim())
  return uniq(urls)
}

/** BUD-03 tags, the old copy's other tags kept. */
export function serverTags(urls, previous) {
  return [...(previous?.tags ?? []).filter(t => t[0] !== "server"), ...urls.map(u => ["server", u])]
}

export const addServer = (urls, url) => urls.includes(url) ? urls : [...urls, url]
export const removeServer = (urls, url) => urls.filter(u => u !== url)
export const serverProblem = urls => urls.length ? "" : "Keep at least one server, or photos have nowhere to go."

// ---- Plain relay lists: DM inbox (kind 10050, NIP-17) and Never Connect (kind 10006, NIP-51) ----

/** The list's relays from its `relay` tags, in order, trailing slash dropped, each once. */
export function urlEntries(ev, tag = "relay") {
  return uniq((ev?.tags ?? []).filter(t => t[0] === tag && /^wss?:\/\//i.test(t[1] ?? "")).map(t => t[1].trim().replace(/\/+$/, "")))
}

/** `relay` tags, the old copy's other tags kept. */
export function urlTags(urls, previous, tag = "relay") {
  return [...(previous?.tags ?? []).filter(t => t[0] !== tag), ...urls.map(u => [tag, u])]
}

export const addUrl = addServer
export const removeUrl = removeServer
