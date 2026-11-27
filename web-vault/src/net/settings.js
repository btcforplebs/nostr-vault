// Settings (iPhone SettingsView): the groups and rows the phone shows, trimmed to what the web can do, and the
// work behind its pages: restoring an older web backup (JSON lines) into Haven,
// the relay and media-server lists as your account publishes them, and this page's own log. Nothing here signs.
import { verifyEvent } from "nostr-tools/pure"
import pkg from "../../package.json" with { type: "json" }
import { relayLists } from "./pool.js"
import { serverList } from "./upload.js"

export const APP_VERSION = pkg.version
/** The commit this build came from (vite.config.js), "" when unknown, as in Node tests. */
export const APP_COMMIT = typeof __NV_COMMIT__ === "string" ? __NV_COMMIT__ : ""
/** About's line: "Version 1.0.0 (web) · 63059b4702c2", the commit linked when it's a clean one. */
export const commitUrl = c => /^[0-9a-f]{7,40}$/.test(c) ? `https://github.com/btcforplebs/nostr-vault/commit/${c}` : ""
/** The developer's npub for support and abuse reports, as the phone's About section shows it. */
export const SUPPORT_NPUB = "npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx"
export const PRIVACY_URL = "https://nostrvault.app/privacy.html"

/**
 * The phone's groups (SettingsView.groups), with the rows the web has. A row's `href` is where it goes: a page of
 * this screen ("#/settings/<page>"), another screen ("#/accounts" is the Accounts & Keys screen). Feed, Appearance, Media & Cache, Privacy
 * and Notifications are pages as on the phone (screens/settings/, Logen 2026-11-05). Rows the phone has and the web
 * doesn't are left out rather than shown dead: Sync with Vault on Mac, Tutorials, Proof of Work, Start Relay
 * Automatically.
 */
/** The rows' icons (SVG path data), shared by the Settings screen and the Settings napplet's answer. */
export const SETTINGS_ICONS = {
  // A key on its own (key.fill), not Accounts & Keys' person with a key.
  secretKey: "M10.5 13.5L20 4M17 7l3 3M15 9l2 2M11 16a4 4 0 1 1-8 0 4 4 0 0 1 8 0z",
  key: "M15 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0zM3 21a8 8 0 0 1 11-7.4M16 14l4 4-2 2-1-1-1 1-1-1 1-1-1-1 1-1",
  // A speech bubble with a line through it: words that are hidden.
  mutedWords: "M4 5h16v11H9l-5 4zM3 3l18 18",
  block: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM5.6 5.6l12.8 12.8",
  relays: "M5 7a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM19 7a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM12 21a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM6.5 6.5L17.5 6.5M6 7l5 10M18 7l-5 10",
  server: "M4 4h16v6H4zM4 14h16v6H4zM8 7h.01M8 17h.01",
  reach: "M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20a6.5 6.5 0 0 1 13 0M18 8v6M15 11h6",
  import: "M12 3v12M7 10l5 5 5-5M4 17v3h16v-3",
  drive: "M3 13h18v7H3zM3 13l3-9h12l3 9M7 17h.01",
  gear2: "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6l1.4 1.4M17 17l1.4 1.4M5.6 18.4L7 17M17 7l1.4-1.4",
  logs: "M4 5h16M4 10h16M4 15h10M4 20h7",
  bolt: "M13 2 4.5 13.5H11L10 22l8.5-11.5H12z",
  trash: "M4 7h16M10 11v6M14 11v6M5 7l1 13h12l1-13M9 7V4h6v3",
  learn: "M2 4h6a4 4 0 0 1 4 4v13a3 3 0 0 0-3-3H2zM22 4h-6a4 4 0 0 0-4 4v13a3 3 0 0 1 3-3h7z",
  docs: "M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9zM14 3v6h6M8 13h8M8 17h5",
  people: "M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20a6.5 6.5 0 0 1 13 0M16 4.3a3.5 3.5 0 0 1 0 6.4M18 14.2a6.5 6.5 0 0 1 3.5 5.8",
  // A circle arrow going back (arrow.counterclockwise): an older version of a list.
  restore: "M4 12a8 8 0 1 0 2.3-5.6M4 4v4h4",
  // Feed & Display, Notifications and Privacy (newspaper, paintpalette, photo.on.rectangle, bell.badge, hand.raised).
  news: "M4 5h13v14H6a2 2 0 0 1-2-2zM17 9h3v8a2 2 0 0 1-2 2M8 9h5M8 13h5M8 17h3",
  palette: "M12 21a9 9 0 1 1 9-9c0 2-1.5 3-3 3h-2a2 2 0 0 0-1.5 3.3A1.6 1.6 0 0 1 12 21zM7.5 11h.01M10 7.5h.01M14 7.5h.01M16.5 11h.01",
  photo: "M4 5h16v14H4zM4 15l4-4 5 5M13 13l2-2 5 5M15.5 9h.01",
  bell: "M6 16V11a6 6 0 1 1 12 0v5l1.5 2h-15zM10 20a2 2 0 0 0 4 0",
  hand: "M8 13V5.5a1.5 1.5 0 0 1 3 0V12M11 11V4a1.5 1.5 0 0 1 3 0v8M14 11.5V5.5a1.5 1.5 0 0 1 3 0V14a7 7 0 0 1-12.5 4.3L3 15.8a1.6 1.6 0 0 1 2.5-2L8 16",
}

export const SETTINGS_GROUPS = [
  { title: "Account", rows: [
    { id: "accounts", title: "Accounts & Keys", icon: "key", color: "#0a84ff", href: "#/accounts" },
    { id: "blocked", title: "Blocked", icon: "block", color: "#ff453a", href: "#/settings/blocked" },
    { id: "muted-words", title: "Muted Words", icon: "mutedWords", color: "#ff9f0a", href: "#/settings/muted-words" },
    { id: "recently-deleted", title: "Recently Deleted", icon: "trash", color: "#8e8e93", href: "#/settings/recently-deleted" },
    { id: "following-backup", title: "Following Backup", icon: "people", color: "#40c8e0", href: "#/settings/following-backup" },
    { id: "recover-list", title: "Recover a List", icon: "restore", color: "#64d2ff", href: "#/settings/recover-list" },
    { id: "wallet", title: "Wallet", icon: "bolt", color: "#ff9f0a", href: "#/wallet" },
    { id: "privacy", title: "Privacy", icon: "hand", color: "#0a84ff", href: "#/settings/privacy" },
  ] },
  { title: "Feed & Display", rows: [
    { id: "feed", title: "Feed", icon: "news", color: "#ff375f", href: "#/settings/feed" },
    { id: "appearance", title: "Appearance", icon: "palette", color: "#bf5af2", href: "#/settings/appearance" },
    { id: "media", title: "Media & Cache", icon: "photo", color: "#5e5ce6", href: "#/settings/media" },
  ] },
  { title: "Notifications", rows: [
    { id: "notifications", title: "Notifications", icon: "bell", color: "#ff453a", href: "#/settings/notifications" },
  ] },
  { title: "Relays", rows: [
    { id: "relays", title: "Relays", icon: "relays", color: "var(--accent)", href: "#/settings/relays" },
    { id: "media-servers", title: "Media Servers", icon: "server", color: "#30d158", href: "#/settings/media-servers" },
  ] },
  { title: "Your Vault", rows: [
    { id: "relay-access", title: "Who Can Reach You", icon: "reach", color: "#0a84ff", href: "#/settings/relay-access" },
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

/**
 * Read an older web backup (this app downloaded .jsonl before the .zip): JSON lines or a JSON array. Only events that verify and were signed by `me` are kept; the rest are
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
