// New Vault activity while this tab is open (the phone's Vault tab notifications, pull only): no push server, no Web
// Push, no service worker. While a page of the app is open, even in a background tab, the user's relays are asked
// every POLL_MS for what tags them. What came in is folded into the Vault list's lines (vault-lists.js activityRows),
// a line newer than the user last looked raises one browser notification (Notification API, off until the user turns
// it on in Settings), and the count of lines newer than the Vault list's "seen" mark is shown in the tab's title.
import { activityRows, followersOf } from "./vault-lists.js"
import { formatSats, reactionEmojiSummary } from "./notifications.js"

export const POLL_MS = 60_000
/** At most this many notifications at once; more become one "N new in your Vault". */
export const MAX_AT_ONCE = 3

const PREF = "nv-browser-notify"
const MARK = "nv-notify-mark"

/** Whether browser notifications are on for this browser. Off until the user turns them on. */
export function notifyOn(storage = globalThis.localStorage) {
  try { return storage?.getItem(PREF) === "on" } catch { return false }
}
export function setNotifyOn(on, storage = globalThis.localStorage) {
  try { storage?.setItem(PREF, on ? "on" : "off") } catch {}
  for (const cb of prefListeners) cb()
}
const prefListeners = new Set()
export const onNotifyPref = cb => { prefListeners.add(cb); return () => prefListeners.delete(cb) }

/** What the browser allows: "granted", "denied", "default", or "unsupported" (no Notification API, e.g. iOS Safari
 *  outside a Home Screen app). */
export const permission = (N = globalThis.Notification) => (typeof N === "function" ? N.permission : "unsupported")

/**
 * Turning the switch on: asks the browser for permission, so it must run from the user's tap. -> the permission.
 * Only a "granted" turns it on.
 */
export async function turnOn(N = globalThis.Notification, storage = globalThis.localStorage) {
  if (typeof N !== "function") return "unsupported"
  const p = N.permission === "granted" ? "granted" : await N.requestPermission()
  setNotifyOn(p === "granted", storage)
  return p
}

/** The newest line time already raised for an account; the first time, now, so old lines never pop up. */
export function readMark(me, { storage = globalThis.localStorage, now = Math.floor(Date.now() / 1000) } = {}) {
  let v = 0
  try { v = Number(storage?.getItem(`${MARK}:${me}`)) || 0 } catch {}
  if (v > 0) return v
  writeMark(me, now, storage)
  return now
}
export function writeMark(me, at, storage = globalThis.localStorage) {
  try { storage?.setItem(`${MARK}:${me}`, String(at)) } catch {}
}

/** The Vault list's lines from what the browser holds, as the Vault tab builds its "Vault" list. */
export const vaultLines = ({ inbound, own, lists, me, blocked, trusted }) =>
  activityRows(inbound, me, { mine: own, follows: followersOf(lists, me, blocked), blocked, trusted })

const SINCE = "nv-notify-since"
/** When this browser first watched the account: lines before it are old news even if the Vault list was never
 *  opened (a first visit's mark, as the phone's). Set once. */
export function readSince(me, { storage = globalThis.localStorage, now = Math.floor(Date.now() / 1000) } = {}) {
  let v = 0
  try { v = Number(storage?.getItem(`${SINCE}:${me}`)) || 0 } catch {}
  if (v > 0) return v
  try { storage?.setItem(`${SINCE}:${me}`, String(now)) } catch {}
  return now
}

/** Where unread starts: the Vault list's seen mark (vault-new.js readSeen().activity), else readSince. */
export const unreadFrom = (seenAt, since) => (seenAt > 0 ? seenAt : since)

/** Lines newer than `from` (unreadFrom). */
export const unreadLines = (lines, from) => (from > 0 ? lines.filter(r => r.created_at > from) : [])

/** "(3) Nostr Vault", or the title alone at 0. */
export const titleWith = (n, base) => (n > 0 ? `(${n > 99 ? "99+" : n}) ${base}` : base)

/** Where a click on a line's notification goes (VaultScreen ActivityRow): the note, the Followers list for a day of
 *  several follows, else the person. */
export function lineHref(row) {
  if (row.openId) return `#/thread/${row.openId}`
  if (row.kind === "follow" && row.actors.length > 1) return "#/vault/followers"
  return row.actors[0] ? `#/profile/${row.actors[0]}` : "#/vault/activity"
}

/** "Ann", "Ann and Bob", "Ann and 3 others". `nameOf(pubkey)` -> a name or "". */
export function whoText(actors, nameOf) {
  const n = pk => nameOf(pk) || "Someone"
  if (actors.length <= 1) return n(actors[0])
  if (actors.length === 2) return `${n(actors[0])} and ${n(actors[1])}`
  return `${n(actors[0])} and ${actors.length - 1} others`
}

// The phone's notification text (LocalNotificationService content): title and body per kind of line.
const TEXT = {
  reply: (who, r) => [`${who} replied to your note`, cut(r.preview ?? "")],
  mention: (who, r) => [`${who} mentioned you`, cut(r.preview ?? "")],
  quote: (who, r) => [`${who} quoted your note`, cut(r.preview ?? "")],
  zap: (who, r) => ["⚡ New zap", r.sats ? `${who} zapped you ${formatSats(r.sats)} sats` : `${who} zapped you`],
  like: (who, r) => [`${who} reacted ${reactionEmojiSummary(r.emojis ?? [])}`, "Tap to view your note"],
  repost: who => [`${who} reposted your note`, ""],
  follow: who => [`${who} followed you`, ""],
}
/** Kinds of line the phone notifies by default (NotificationPolicy: mentions, replies, zaps, follows on; reactions and
 *  reposts off). Articles and highlights never raise one there. The title's count still has every line. */
export const NOTIFIED = new Set(["reply", "mention", "quote", "zap", "follow"])

// A notification is plain text: `nostr:` people as a short @npub, as the rows show them before names load, and
// links to notes left out.
const plain = s => s.replace(/nostr:((?:npub|nprofile)1[02-9ac-hj-np-z]+)/g, (_, b) => `@${b.slice(0, 12)}…`).replace(/nostr:(?:note|nevent|naddr)1[02-9ac-hj-np-z]+/g, "").replace(/\s+/g, " ").trim()
const cut = (s, n = 140) => { s = plain(s); return s.length > n ? `${s.slice(0, n - 1)}…` : s }

/** A line as a notification: { title, body, tag, href }. The tag is the line's id, so the same line from two open
 *  tabs, or a fold that grew, replaces its notification rather than adding another. */
export function lineNotice(row, nameOf = () => "") {
  const [title, body] = (TEXT[row.kind] ?? (who => [`${who} sent you something`, ""]))(whoText(row.actors, nameOf), row)
  return { title, body, tag: `nv:${row.id}`, href: lineHref(row) }
}

/**
 * Which notifications to raise for `lines`: lines of a NOTIFIED kind newer than both `mark` (already raised) and
 * `seenAt` (looked at in the Vault list), newest first, at most MAX_AT_ONCE, else one summary.
 * -> { notices, mark } with the new mark.
 */
export function noticesFor(lines, { mark, seenAt = 0, nameOf, now = Math.floor(Date.now() / 1000) } = {}) {
  const fresh = lines.filter(r => NOTIFIED.has(r.kind) && r.created_at > mark && r.created_at > seenAt).sort((a, b) => b.created_at - a.created_at)
  // Every line moves the mark, notified or not; one dated ahead of now can't hold the next ones back.
  const next = Math.max(mark, Math.min(now, lines.reduce((m, r) => Math.max(m, r.created_at), mark)))
  if (!fresh.length) return { notices: [], mark: next }
  if (fresh.length > MAX_AT_ONCE) return { notices: [{ title: `${fresh.length} new in your Vault`, body: lineNotice(fresh[0], nameOf).title, tag: "nv:summary", href: "#/vault/activity" }], mark: next }
  return { notices: fresh.map(r => lineNotice(r, nameOf)), mark: next }
}

/** Whether the user is looking at the Vault list now, so a notification would only repeat what's on screen. */
export const lookingAtVault = (doc = globalThis.document, hash = globalThis.location?.hash ?? "") =>
  doc?.visibilityState === "visible" && /^#\/?vault(\/activity)?\/?$/.test(hash)
