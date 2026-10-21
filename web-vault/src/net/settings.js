// Settings (iPhone SettingsView): the groups and rows the phone shows, trimmed to what the web can do, and the
// work behind its pages: a backup of everything your relay holds for you as JSON lines, restoring one into Haven,
// the relay and media-server lists as your account publishes them, and this page's own log. Nothing here signs.
import { verifyEvent } from "nostr-tools/pure"
import pkg from "../../package.json" with { type: "json" }
import { relayLists } from "./pool.js"
import { serverList } from "./upload.js"

export const APP_VERSION = pkg.version
/** The developer's npub for support and abuse reports, as the phone's About section shows it. */
export const SUPPORT_NPUB = "npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx"
export const PRIVACY_URL = "https://nostrvault.app/privacy.html"

/**
 * The phone's groups (SettingsView.groups), with the rows the web has. A row's `href` is where it goes: a page of
 * this screen ("#/settings/<page>"), another screen ("#/accounts" is the Accounts & Keys screen, "#/relay" the
 * Relay screen with its FIPS panel, which is the web's "Who Can Reach You"). Rows the phone has and the web
 * doesn't are left out rather than shown dead: Feed, Appearance,
 * Media & Cache, Notifications, Sync with Vault on Mac, Tutorials, Proof of Work, Start Relay Automatically.
 */
export const SETTINGS_GROUPS = [
  { title: "Account", rows: [
    { id: "accounts", title: "Accounts & Keys", icon: "key", color: "#0a84ff", href: "#/accounts" },
    { id: "blocked", title: "Blocked", icon: "block", color: "#ff453a", href: "#/settings/blocked" },
    { id: "recently-deleted", title: "Recently Deleted", icon: "trash", color: "#8e8e93", href: "#/settings/recently-deleted" },
    { id: "following-backup", title: "Following Backup", icon: "people", color: "#40c8e0", href: "#/settings/following-backup" },
    { id: "wallet", title: "Wallet", icon: "bolt", color: "#ff9f0a", href: "#/wallet" },
  ] },
  { title: "Relays", rows: [
    { id: "relays", title: "Relays", icon: "relays", color: "var(--accent)", href: "#/settings/relays" },
    { id: "media-servers", title: "Media Servers", icon: "server", color: "#30d158", href: "#/settings/media-servers" },
  ] },
  { title: "Your Vault Relay", rows: [
    { id: "relay-access", title: "Who Can Reach You", icon: "reach", color: "#0a84ff", href: "#/relay" },
    { id: "import", title: "Import Notes", icon: "import", color: "#ff9f0a", href: "#/settings/import" },
    { id: "backup", title: "Backup & Restore", icon: "drive", color: "#5e5ce6", href: "#/settings/backup" },
  ] },
  { title: "Advanced", rows: [
    { id: "database", title: "Database & Reset", icon: "gear2", color: "#8e8e93", href: "#/settings/database" },
    { id: "logs", title: "Logs", icon: "logs", color: "#98989f", href: "#/settings/logs" },
  ] },
]

export const PAGES = Object.fromEntries(SETTINGS_GROUPS.flatMap(g => g.rows).filter(r => r.href.startsWith("#/settings/")).map(r => [r.href.slice("#/settings/".length), r]))
export const isPage = id => Object.hasOwn(PAGES, id ?? "")

/** Relay rows from a kind 10002 (NIP-65): every listed relay with its read and write marks, dead hosts dropped. */
export function relayRows(ev) {
  const { read, write } = relayLists(ev)
  const listed = ev ? [...new Set([...read, ...write])] : []
  return listed.map(url => ({ url, read: read.includes(url), write: write.includes(url) }))
}

/** Media servers from a kind 10063 (BUD-03), as upload.js picks them. */
export const mediaServerRows = ev => serverList(ev).map(url => ({ url, listed: !!ev }))

// ---- Backup & Restore ----

/** Everything Haven's outbox holds by the user, newest first, read in pages (the route caps one answer). */
export async function readEverything(vault, me, { page = 500, query = f => vault.outbox.query(f) } = {}) {
  const all = new Map()
  let until
  for (;;) {
    const evs = await query({ authors: [me], limit: page, ...(until ? { until } : {}) })
    let oldest = until
    let fresh = 0
    for (const ev of evs) {
      if (!all.has(ev.id)) { all.set(ev.id, ev); fresh++ }
      if (oldest === undefined || ev.created_at < oldest) oldest = ev.created_at
    }
    if (!fresh || evs.length < page) break
    until = oldest
  }
  return [...all.values()].sort((a, b) => b.created_at - a.created_at)
}

/** The backup text: one signed event per line, the phone's export shape, with nothing added. */
export const backupLines = events => events.map(ev => JSON.stringify(pick(ev))).join("\n") + (events.length ? "\n" : "")
const pick = ({ id, pubkey, created_at, kind, tags, content, sig }) => ({ id, pubkey, created_at, kind, tags, content, sig })

/** A backup file's name: nostr-vault-<npub start>-<date>.jsonl */
export const backupName = (me, at = new Date()) => `nostr-vault-${me.slice(0, 8)}-${at.toISOString().slice(0, 10)}.jsonl`

/**
 * Read a backup: JSON lines or a JSON array. Only events that verify and were signed by `me` are kept; the rest are
 * counted and named so the page can say what it skipped. -> { events, skipped: { unreadable, badSignature, notYours } }
 */
export function parseBackup(text, me) {
  const skipped = { unreadable: 0, badSignature: 0, notYours: 0 }
  let items = []
  const trimmed = (text ?? "").trim()
  if (trimmed.startsWith("[")) {
    try { items = JSON.parse(trimmed) } catch { return { events: [], skipped: { ...skipped, unreadable: 1 } } }
    if (!Array.isArray(items)) items = []
  } else {
    for (const line of trimmed.split(/\r?\n/)) {
      if (!line.trim()) continue
      try { items.push(JSON.parse(line)) } catch { skipped.unreadable++ }
    }
  }
  const events = []
  const seen = new Set()
  for (const ev of items) {
    if (!ev || typeof ev !== "object" || typeof ev.id !== "string") { skipped.unreadable++; continue }
    if (seen.has(ev.id)) continue
    seen.add(ev.id)
    if (ev.pubkey !== me) { skipped.notYours++; continue }
    let ok = false
    try { ok = verifyEvent(ev) } catch {}
    if (!ok) { skipped.badSignature++; continue }
    events.push(ev)
  }
  return { events, skipped }
}

/** Put a backup's events into Haven's outbox. -> { stored, duplicate, refused: [{ id, message }] } */
export async function restoreBackup(vault, events, { onProgress = () => {} } = {}) {
  const out = { stored: 0, duplicate: 0, refused: [] }
  for (const [i, ev] of events.entries()) {
    const r = await vault.outbox.event(ev).catch(e => ({ ok: false, message: String(e?.message ?? e) }))
    if (r.ok) out.stored++
    else if (/^duplicate:/.test(r.message ?? "")) out.duplicate++
    else out.refused.push({ id: ev.id, message: r.message })
    onProgress({ done: i + 1, of: events.length })
  }
  return out
}

// ---- Logs ----

/** The page's own log (main.jsx log), newest last, as the Logs page shows it. */
export const logLines = (lines = globalThis.nvLog ?? []) => lines.map(l => `${l.t}  ${l.type}  ${JSON.stringify(rest(l))}`)
const rest = ({ t, type, ...r }) => r
