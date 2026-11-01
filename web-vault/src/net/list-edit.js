// Editing the account's own lists, as the iPhone's Relays and Media Servers pages do: kind 10002 (NIP-65 relays,
// RelayMatrixView) and kind 10063 (BUD-03 media servers, BlossomSettingsView). An edit starts from the newest copy
// anywhere, Haven's outbox or the relays, so a stale or missing local copy never gets published over the real one.
import { pool, publishRelays, uniq, DEFAULT_RELAYS, PROFILE_RELAYS } from "./pool.js"
import { checkSigned } from "./sync.js"
import { serverUrl } from "./upload.js"
import { askRelay, MAX_SKEW } from "./follows.js"
import { verifyEvent } from "nostr-tools/pure"

const newest = evs => evs.reduce((a, e) => (!a || e.created_at > a.created_at ? e : a), undefined)
const now = () => Math.floor(Date.now() / 1000)
/** verifyEvent on a fresh copy: it trusts a "verified" flag an event object carries (follows.js does the same). */
const verifiedCopy = ({ id, pubkey, created_at, kind, tags, content, sig }) => {
  try { return verifyEvent({ id, pubkey, created_at, kind, tags, content, sig }) } catch { return false }
}

/** Where a list is looked for and sent: the account's relays, the defaults and the profile index (purplepag.es). */
const listRelays = ctx => uniq([...ctx.account.relays.read, ...ctx.account.relays.write, ...DEFAULT_RELAYS, ...PROFILE_RELAYS])

/**
 * Whether the newest list is known, by follows.js's rule for kind 3 (wipeGuard, Logen 2026-10-14), counting only the
 * account's own relays (`asked` of them, `answered` sent their EOSE; the defaults and purplepag.es are asked too but
 * don't count): a copy came from one of them (`netFound`), or most of them answered; and to say there is no list at
 * all, every one of them answered. A copy from this browser or a default relay alone, with the user's relays down,
 * says nothing about what those relays hold.
 */
export function listKnown({ asked, answered, netFound, found }) {
  if (!asked) return false
  if (!found) return answered === asked
  return netFound || answered * 2 > asked
}

/**
 * The newest `kind` list the account signed. -> { event, checked, asked, answered }; `checked` is listKnown. Offline,
 * or with the user's relays not answering, it is false, and a page must not save: its copy may be old, or "no list"
 * may be a list nobody could reach. Each relay is asked with follows.js's askRelay, which counts only a real EOSE (a
 * relay that never connected, closed the subscription or timed out is not an answer). Copies dated MAX_SKEW or more
 * ahead are skipped, as follows.js does, so one bad clock can't pin the list in the future. A newer copy from the
 * relays is kept in Haven.
 * Each relay is asked on its own: `on({ event })` gets Haven's copy at once and each newer one as a relay sends it, so
 * a page can draw before the slowest relay answers. The promise still waits for every relay (or its timeout), because
 * an edit must start from the newest copy anywhere. `ask` and `at` are for tests.
 */
export async function latestList(ctx, kind, { ask = askRelay, online = globalThis.navigator?.onLine !== false, on, at = now() } = {}) {
  const me = ctx.session.pubkey
  const filter = { kinds: [kind], authors: [me] }
  const ok = e => e?.kind === kind && e.pubkey === me && e.created_at < at + MAX_SKEW && verifiedCopy(e)
  // The user's own relays: those their 10002 names (pool.js relayLists `listed`). With no 10002 there are none, and a
  // list is unknown (`noRelayList`) rather than decided by the defaults. The 10002 itself is looked for where it lives
  // when the account has none yet: the account's relays as they stand (the defaults) and the index relays.
  const own = kind === 10002 ? uniq([...ctx.account.relays.read, ...ctx.account.relays.write]) : uniq(ctx.account.relays.listed ?? [])
  const noRelayList = !own.length
  const local = newest((await ctx.vault.outbox.query(filter).catch(() => [])).filter(ok))
  if (!online) return { event: local, checked: false, asked: own.length, answered: 0, noRelayList }
  if (local) on?.({ event: local })
  let best = local, answered = 0, netFound = false
  await Promise.all(listRelays(ctx).map(relay => ask(relay, filter).catch(() => ({ events: [], answered: false })).then(r => {
    const evs = (r?.events ?? []).filter(ok)
    if (own.includes(relay)) { if (r?.answered) answered++; if (evs.length) netFound = true }
    const ev = newest(evs)
    if (ev && (!best || ev.created_at > best.created_at)) { best = ev; on?.({ event: ev }) }
  })))
  if (best && best !== local) await ctx.vault.outbox.event(best).catch(() => {})
  return { event: best, checked: listKnown({ asked: own.length, answered, netFound, found: !!best }), asked: own.length, answered, noRelayList }
}

/** What a list page says when the account has no relay list (kind 10002) yet, so its own relays aren't known. */
export const NO_RELAY_LIST = "You have no relay list yet, so your own relays aren't known and your newest copy of this list can't be checked. Add your relays in Settings › Relays and save them first."

/** Thrown by publishList instead of signing: the list couldn't be read just now, or it changed since the page read it.
 *  `latest` is the newest copy found (to start the edit again from), `checked` whether it can be trusted. */
export class ListNotSaved extends Error {
  constructor(message, latest, checked) { super(message); this.name = "ListNotSaved"; this.latest = latest; this.checked = checked }
}

/**
 * Sign the list with `tags` (the old copy's other tags kept) and send it out. Only on a Save tap, never by itself.
 * Right before signing it reads the list again: if the relays don't answer it refuses, and if a newer copy than
 * `previous` turned up (another app saved meanwhile) it refuses with that copy, so the edit is made again on top of
 * it rather than signed over it. Its time is after the old copy's, so relays take it as the newer one even with a slow
 * clock. Kept in Haven once a relay took it.
 * -> { event, relays: [{ url, ok, message }] }; throws ListNotSaved, or when signing fails or no relay took it.
 */
export async function publishList(ctx, kind, tags, { previous, also = [], latest } = {}) {
  const fresh = latest ? await latest(ctx, kind) : await latestList(ctx, kind)
  if (!fresh.checked && fresh.noRelayList) throw new ListNotSaved(`Not saved. ${NO_RELAY_LIST} Nothing was changed.`, fresh.event, false)
  if (!fresh.checked) throw new ListNotSaved("Not saved: your relays didn't answer, so your newest list couldn't be read. Nothing was changed. Try again when you're online.", fresh.event, false)
  if ((fresh.event?.id ?? null) !== (previous?.id ?? null))
    throw new ListNotSaved("Not saved: this list changed in another app since the page opened. It's reloaded below; make your change again.", fresh.event, true)
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
