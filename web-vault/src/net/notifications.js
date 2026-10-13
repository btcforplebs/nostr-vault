// Notifications: other people's replies, mentions, reposts, reactions and zaps that tag the user (`#p`).
// Read straight from the user's read relays and never signed. Haven has no route for other people's
// reactions, so for M1 these aren't stored; the note each one is about is read from Haven's outbox first
// (the user's own notes live there) and only then from the network.
import { pool } from "./pool.js"

export const NOTIFICATION_KINDS = [1, 6, 7, 9735]
const HEX64 = /^[0-9a-f]{64}$/

/** Fetch events of the notification kinds that tag `pubkey`, newest first, the user's own left out. */
export async function fetchNotifications(pubkey, relays, { limit = 100, since, until } = {}) {
  const filter = { kinds: NOTIFICATION_KINDS, "#p": [pubkey], limit, ...(since ? { since } : {}), ...(until ? { until } : {}) }
  const evs = await pool.querySync(relays, filter, { maxWait: 8000 })
  return groupNotifications(evs, pubkey)
}

/**
 * Turn raw events into rows, newest first: own events dropped, each event classified (who / what / which note),
 * and reposts, reactions and zaps on the same note folded into one row so ten likes aren't ten rows.
 * -> [{ id, type, who: [pubkey...], noteId, sats, emoji, created_at, events }]
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
    const key = n.type !== "reply" && n.type !== "mention" && n.noteId ? `${n.type}:${n.noteId}` : null
    const row = key && byKey.get(key)
    if (row) {
      if (!row.who.includes(n.who)) row.who.push(n.who)
      row.sats += n.sats
      row.events.push(n.event)
      continue
    }
    const r = { id: n.event.id, type: n.type, who: [n.who], noteId: n.noteId, sats: n.sats, emoji: n.emoji, created_at: n.created_at, events: [n.event] }
    rows.push(r)
    if (key) byKey.set(key, r)
  }
  return rows
}

/** One event -> { type, who, noteId, sats, emoji, created_at, event }, or null when it isn't a notification for the user. */
export function classify(ev, pubkey) {
  if (!ev || !Array.isArray(ev.tags)) return null
  if (!ev.tags.some(t => t[0] === "p" && t[1] === pubkey)) return null
  if (ev.pubkey === pubkey && ev.kind !== 9735) return null // own events aren't notifications; a zap's sender is checked below
  const base = { who: ev.pubkey, noteId: null, sats: 0, emoji: "", created_at: ev.created_at, event: ev }
  switch (ev.kind) {
    case 1: {
      const parent = replyTarget(ev.tags)
      return parent ? { ...base, type: "reply", noteId: parent } : { ...base, type: "mention" }
    }
    case 6: return { ...base, type: "repost", noteId: lastTag(ev.tags, "e") }
    case 7: return { ...base, type: "reaction", noteId: lastTag(ev.tags, "e"), emoji: reactionEmoji(ev.content) }
    case 9735: {
      const req = zapRequest(ev)
      const who = req?.pubkey || tagValue(ev.tags, "P") || ev.pubkey
      if (who === pubkey) return null // the user zapping themself
      return { ...base, who, type: "zap", noteId: lastTag(ev.tags, "e"), sats: zapSats(ev) }
    }
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
const lastTag = (tags, name) => { const v = tags.filter(t => t[0] === name && HEX64.test(t[1] ?? "")); return v.length ? v[v.length - 1][1] : null }

/** "+" and "" are a like; anything else (an emoji, "-") is shown as it is. Custom `:shortcode:` reactions show their name. */
export function reactionEmoji(content) {
  const c = (content ?? "").trim()
  if (c === "" || c === "+") return "❤️"
  if (c === "-") return "👎"
  return c.length > 8 ? c.slice(0, 8) : c
}

/** The kind 9734 zap request inside a 9735's `description` tag, or null. */
export function zapRequest(ev) {
  const d = tagValue(ev.tags, "description")
  if (!d) return null
  try {
    const req = JSON.parse(d)
    return req && req.kind === 9734 && HEX64.test(req.pubkey ?? "") ? req : null
  } catch { return null }
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
