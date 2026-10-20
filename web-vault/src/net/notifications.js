// Notifications: other people's replies, mentions, quotes, reposts, reactions, zaps, follows, articles and
// highlights that tag the user (`#p`), as the iPhone's Vault list reads them (Models/VaultActivity.swift).
// Read straight from the user's read relays and never signed. Haven has no route for other people's
// reactions, so for M1 these aren't stored; the note each one is about is read from Haven's outbox first
// (the user's own notes live there) and only then from the network.
import { verifyEvent } from "nostr-tools/pure"
import { pool } from "./pool.js"

/** Notes, contact lists (a follow), reposts, reactions, generic reposts, highlights, zaps, long-form articles. */
export const NOTIFICATION_KINDS = [1, 3, 6, 7, 16, 9802, 9735, 30023]
const HEX64 = /^[0-9a-f]{64}$/

/** Fetch events of the notification kinds that tag `pubkey`, newest first, the user's own left out. */
export async function fetchNotifications(pubkey, relays, { limit = 100, since, until, trust = async evs => evs } = {}) {
  const filter = { kinds: NOTIFICATION_KINDS, "#p": [pubkey], limit, ...(since ? { since } : {}), ...(until ? { until } : {}) }
  const evs = await pool.querySync(relays, filter, { maxWait: 8000 })
  return groupNotifications(await trust(evs), pubkey) // `trust`: zaps.js trustedReceipts, dropping forged receipts
}

/**
 * Turn raw events into rows, newest first: own events dropped, each event classified (who / what / which note),
 * and reposts, reactions and zaps on the same note folded into one row so ten likes aren't ten rows. A zap with a
 * comment, or on the profile, keeps its own row; follows on one day share one (VaultActivity.build).
 * -> [{ id, type, who: [pubkey...], noteId, sats, emoji, comment, created_at, events }]
 */
export function groupNotifications(evs, pubkey) {
  const seen = new Set()
  const items = []
  for (const ev of evs) {
    if (!ev || seen.has(ev.id)) continue
    seen.add(ev.id)
    const n = classify(ev, pubkey)
    if (n) items.push(n)
  }
  items.sort((a, b) => b.created_at - a.created_at)
  const rows = [], byKey = new Map()
  for (const n of items) {
    const key = foldKey(n)
    const row = key && byKey.get(key)
    if (row) {
      if (!row.who.includes(n.who)) row.who.push(n.who)
      row.sats += n.sats
      row.events.push(n.event)
      continue
    }
    const r = { id: n.event.id, type: n.type, who: [n.who], noteId: n.noteId, sats: n.sats, emoji: n.emoji, comment: n.comment, created_at: n.created_at, events: [n.event] }
    rows.push(r)
    if (key) byKey.set(key, r)
  }
  return rows
}

/** Which row an item folds into, or null for its own row. Reposts, reactions and plain zaps fold per note; follows per day. */
function foldKey(n) {
  if (n.type === "follow") return `follow:${new Date(n.created_at * 1000).toISOString().slice(0, 10)}`
  if (!n.noteId) return null
  if (n.type === "repost" || n.type === "reaction") return `${n.type}:${n.noteId}`
  if (n.type === "zap" && !n.comment) return `zap:${n.noteId}`
  return null
}

/** The Mentions filter: someone wrote to or about the user (VaultActivityList: replies, mentions and quotes). */
export const MENTION_TYPES = new Set(["reply", "mention", "quote"])
export const filterRows = (rows, filter) => filter === "mentions" ? rows.filter(r => MENTION_TYPES.has(r.type)) : rows

/** Where the account's "seen up to" time is kept (unix seconds). Not secret: only when the list was last open. */
export const seenKey = pubkey => `nv:notifications-seen:${pubkey}`

/**
 * The list coming on screen (`arriving`) or leaving it, as the iPhone marks it (VaultActivityList.activityVisit).
 * Both move the mark to now. Arriving returns the last visit's time: rows newer than it are unread. A first visit
 * returns now, so nothing reads as new.
 */
export function visitNotifications(pubkey, { arriving, storage = globalThis.localStorage, now = Math.floor(Date.now() / 1000) } = {}) {
  let last = 0
  try { last = Number(storage?.getItem(seenKey(pubkey))) || 0 } catch {}
  try { storage?.setItem(seenKey(pubkey), String(now)) } catch {}
  return arriving ? (last > 0 ? last : now) : null
}

/** One event -> { type, who, noteId, sats, emoji, comment, created_at, event }, or null when it isn't a notification for the user. */
export function classify(ev, pubkey) {
  if (!ev || !Array.isArray(ev.tags)) return null
  if (!ev.tags.some(t => t[0] === "p" && t[1] === pubkey)) return null
  if (ev.pubkey === pubkey && ev.kind !== 9735) return null // own events aren't notifications; a zap's sender is checked below
  const base = { who: ev.pubkey, noteId: null, sats: 0, emoji: "", comment: "", created_at: ev.created_at, event: ev }
  switch (ev.kind) {
    case 1: {
      // A quote names the quoted note in a `q` tag (NIP-18); the iPhone reads it before any `e` tag.
      const quoted = firstTag(ev.tags, "q")
      if (quoted) return { ...base, type: "quote", noteId: quoted }
      const parent = replyTarget(ev.tags)
      return parent ? { ...base, type: "reply", noteId: parent } : { ...base, type: "mention" }
    }
    // A contact list that names the user: they follow them. It is replaceable, so this is when their list last
    // changed, the closest a browser gets to the iPhone's follower ledger.
    case 3: return { ...base, type: "follow" }
    case 6: case 16: return { ...base, type: "repost", noteId: lastTag(ev.tags, "e") }
    case 7: return { ...base, type: "reaction", noteId: lastTag(ev.tags, "e"), emoji: reactionEmoji(ev.content) }
    case 9735: {
      // Who zapped is only ever the signer of a valid zap request: the receipt, its `P` tag and its invoice are
      // whatever the receipt's publisher wrote. Who may publish receipts is checked by zaps.js trustedReceipts.
      const req = zapRequest(ev)
      if (!req) return null
      const who = req.pubkey
      if (who === pubkey) return null // the user zapping themself
      // The note and the words come from the signed request, as the iPhone reads them; the receipt's own are the
      // zap service's to write.
      const noteId = firstTag(req.tags, "e") ?? lastTag(ev.tags, "e")
      return { ...base, who, type: "zap", noteId, sats: zapSats(ev), comment: (req.content ?? "").trim() }
    }
    case 9802: return { ...base, type: "highlight", noteId: lastTag(ev.tags, "e") }
    case 30023: return { ...base, type: "article", comment: tagValue(ev.tags, "title") ?? "" }
    default: return null
  }
}

/** The note a kind 1 replies to: the NIP-10 `reply` marker, else `root`, else the last positional `e` tag. */
export function replyTarget(tags) {
  const es = tags.filter(t => t[0] === "e" && HEX64.test(t[1] ?? ""))
  if (!es.length) return null
  const marked = m => es.find(t => t[3] === m)?.[1]
  return marked("reply") || marked("root") || es[es.length - 1][1]
}

const tagValue = (tags, name) => tags.find(t => t[0] === name)?.[1]
const firstTag = (tags, name) => tags.find(t => t[0] === name && HEX64.test(t[1] ?? ""))?.[1] ?? null
const lastTag = (tags, name) => { const v = tags.filter(t => t[0] === name && HEX64.test(t[1] ?? "")); return v.length ? v[v.length - 1][1] : null }

/** "+" and "" are a like; anything else (an emoji, "-") is shown as it is. Custom `:shortcode:` reactions show their name. */
export function reactionEmoji(content) {
  const c = (content ?? "").trim()
  if (c === "" || c === "+") return "❤️"
  if (c === "-") return "👎"
  return c.length > 8 ? c.slice(0, 8) : c
}

/**
 * The kind 9734 zap request inside a 9735's `description` tag, or null unless it holds up (NIP-57 Appendix F):
 * signed by its pubkey, for the person the receipt pays (`p`), by the sender the receipt names (`P`, when there is
 * one), and for the amount the invoice charges (`amount`, when there is one). Anyone can publish a 9735, so without
 * this a receipt could say anybody zapped anybody, for any amount. Checked once per receipt.
 */
export function zapRequest(ev) {
  if (!ev || typeof ev !== "object") return null
  if (!checkedRequests.has(ev)) checkedRequests.set(ev, checkRequest(ev))
  return checkedRequests.get(ev)
}
const checkedRequests = new WeakMap()
function checkRequest(ev) {
  const tags = Array.isArray(ev.tags) ? ev.tags : []
  const d = tagValue(tags, "description")
  if (!d) return null
  let req
  try { req = JSON.parse(d) } catch { return null }
  if (!req || req.kind !== 9734 || !HEX64.test(req.pubkey ?? "") || !Array.isArray(req.tags)) return null
  // A copy of only the signed fields: verifyEvent trusts a "verified" flag the parsed object could carry.
  const { id, pubkey, created_at, kind, content, sig } = req
  try { if (!verifyEvent({ id, pubkey, created_at, kind, tags: req.tags, content, sig })) return null } catch { return null }
  const payee = tagValue(tags, "p")
  if (!payee || tagValue(req.tags, "p") !== payee) return null
  const sender = tagValue(tags, "P")
  if (sender && sender !== req.pubkey) return null
  const asked = tagValue(req.tags, "amount")
  const charged = bolt11Sats(tagValue(tags, "bolt11"))
  if (asked != null && charged > 0 && Math.floor(Number(asked) / 1000) !== charged) return null
  return { id, pubkey, created_at, kind, tags: req.tags, content, sig }
}

/** Sats a 9735 paid: from the bolt11 invoice's amount, else the zap request's `amount` tag (millisats). */
export function zapSats(ev) {
  const fromInvoice = bolt11Sats(tagValue(ev.tags, "bolt11"))
  if (fromInvoice > 0) return fromInvoice
  const req = zapRequest(ev)
  const msat = Number(tagValue(req?.tags ?? [], "amount"))
  return Number.isFinite(msat) && msat > 0 ? Math.floor(msat / 1000) : 0
}

// bolt11 amounts live in the human-readable part: ln + network + digits + optional multiplier, before the "1" separator.
const MULT = { m: 1e-3, u: 1e-6, n: 1e-9, p: 1e-12 }
const HRP = /^ln(bcrt|bc|tbs|tb)(\d+)([munp])?1/

/** Sats from a bolt11 invoice string, 0 when it has no amount or isn't an invoice. */
export function bolt11Sats(invoice) {
  const m = HRP.exec((invoice ?? "").trim().toLowerCase())
  if (!m) return 0
  const btc = Number(m[2]) * (m[3] ? MULT[m[3]] : 1)
  return Math.floor(Math.round(btc * 1e8 * 1e3) / 1e3) // round away float dust (e.g. 21u -> 2100.0000000000005)
}

/** Short sats text: 21, 1.2k, 1.5M. */
export function formatSats(n) {
  if (n >= 1e6) return `${trim((n / 1e6).toFixed(1))}M`
  if (n >= 1e3) return `${trim((n / 1e3).toFixed(1))}k`
  return String(n)
}
const trim = s => s.replace(/\.0$/, "")

/** The notes rows are about, by id: Haven's outbox first (the user's own notes are there), then the network. */
export async function fetchNotes(vault, ids, relays) {
  const want = [...new Set(ids.filter(id => HEX64.test(id ?? "")))]
  const notes = new Map()
  if (!want.length) return notes
  try { for (const ev of await vault.outbox.query({ ids: want })) notes.set(ev.id, ev) } catch {}
  const missing = want.filter(id => !notes.has(id))
  if (missing.length && navigator.onLine) {
    for (let i = 0; i < missing.length; i += 100) {
      const evs = await pool.querySync(relays, { ids: missing.slice(i, i + 100) }, { maxWait: 6000 }).catch(() => [])
      for (const ev of evs) notes.set(ev.id, ev)
    }
  }
  return notes
}
