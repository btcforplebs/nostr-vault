// NIP-88 polls, as the iPhone counts them (Models/NIP88Poll.swift): a kind 1068 poll names its options in `option`
// tags and its relays in `relay` tags; a kind 1018 vote names the poll by `e` and its picks by `response`. Anyone can
// publish a vote, so the count is kept honest here: one vote per person (their newest), only options the poll has,
// nothing after it closes, and nothing dated past the clock's drift.
import { isLoopback } from "../net/pool.js"
export const POLL_KIND = 1068, VOTE_KIND = 1018
const MAX_FUTURE_SKEW = 600
const MAX_RELAYS = 8

/** The poll in a kind 1068, or null when it isn't one or has no options. */
export function parsePoll(ev) {
  if (ev?.kind !== POLL_KIND) return null
  const seen = new Set()
  const options = (ev.tags ?? []).filter(t => t.length >= 3 && t[0] === "option")
    .map(t => ({ id: String(t[1]).trim(), label: String(t[2]).trim() }))
    .filter(o => o.id && o.label && !seen.has(o.id) && seen.add(o.id))
  if (!options.length) return null
  const ends = Number((ev.tags ?? []).find(t => t[0] === "endsAt")?.[1])
  return {
    id: ev.id, pubkey: ev.pubkey, question: String(ev.content ?? "").trim(), options,
    multiple: (ev.tags ?? []).find(t => t[0] === "polltype")?.[1] === "multiplechoice",
    endsAt: ends > 0 ? ends : null,
    relays: (ev.tags ?? []).filter(t => t[0] === "relay" && t[1]).map(t => String(t[1])),
  }
}

export const isClosed = (poll, now = Date.now() / 1000) => poll.endsAt != null && poll.endsAt <= now

const MAX_RELAY_URL = 256

/** A public wss/ws relay: a stranger's poll must not make this browser dial into a LAN or loopback. IPv6 literals are
 *  checked without their brackets (anything under ::/16 — loopback, IPv4-mapped, the old IPv4-compatible [::a.b.c.d] —
 *  NAT64 64:ff9b::, unique-local fc00::/7, link-local fe80::/10), and a trailing dot doesn't hide a name. IPv4 also
 *  refuses CGNAT 100.64.0.0/10 (Tailscale's range) and 192.0.0.0/24. The URL parser has already compressed every
 *  IPv6 form and read every IPv4 form as dotted decimal. */
export function isPublicRelay(url) {
  let u
  const raw = String(url ?? "").trim()
  if (raw.length > MAX_RELAY_URL) return false
  try { u = new URL(raw) } catch { return false }
  if (!/^wss?:$/.test(u.protocol)) return false
  if (isLoopback(raw)) return false
  const h = u.hostname.toLowerCase().replace(/^\[|\]$/g, "").replace(/\.+$/, "")
  if (h === "localhost" || h.endsWith(".localhost") || h.endsWith(".local") || h.endsWith(".onion") || h === "0.0.0.0" || h === "::" || h === "::1") return false
  if (h.includes(":") && (/^::/.test(h) || /^64:ff9b:/.test(h) || /^f[cd][0-9a-f]{2}:/.test(h) || /^fe[89ab][0-9a-f]:/.test(h))) return false
  const p = h.split(".").map(Number)
  if (p.length === 4 && p.every(n => Number.isInteger(n))) {
    if (p[0] === 0 || p[0] === 10 || p[0] === 127 || (p[0] === 192 && p[1] === 168) || (p[0] === 169 && p[1] === 254) || (p[0] === 172 && p[1] >= 16 && p[1] <= 31)) return false
    if ((p[0] === 100 && p[1] >= 64 && p[1] <= 127) || (p[0] === 192 && p[1] === 0 && p[2] === 0)) return false
  }
  return true
}

/** Where votes are read from and sent: the poll's own public relays first (NIP-88), then `fallback`, at most 8. */
export function pollRelays(poll, fallback = []) {
  const seen = new Set(), out = []
  for (const r of [...poll.relays.filter(isPublicRelay), ...fallback]) {
    const key = String(r).trim().toLowerCase().replace(/\/+$/, "")
    if (!/^wss?:\/\//.test(key) || seen.has(key)) continue
    seen.add(key); out.push(String(r).trim())
  }
  return out.slice(0, MAX_RELAYS)
}

/** -> { voters: Set, byOption: Map<optionId, Set<pubkey>>, picks: Map<pubkey, [optionId]> }. `blocked` left out. */
export function tally(events, poll, { now = Date.now() / 1000, blocked = new Set() } = {}) {
  const known = new Set(poll.options.map(o => o.id))
  const latest = Math.min(now + MAX_FUTURE_SKEW, poll.endsAt ?? Infinity)
  const newest = new Map()
  for (const ev of events) {
    if (ev?.kind !== VOTE_KIND || blocked.has(ev.pubkey) || !(ev.created_at <= latest)) continue
    if (!(ev.tags ?? []).some(t => t[0] === "e" && t[1] === poll.id)) continue
    const cur = newest.get(ev.pubkey)
    if (cur && (cur.created_at > ev.created_at || (cur.created_at === ev.created_at && cur.id < ev.id))) continue
    let picks = [...new Set((ev.tags ?? []).filter(t => t[0] === "response" && known.has(t[1])).map(t => t[1]))]
    if (!poll.multiple) picks = picks.slice(0, 1)
    newest.set(ev.pubkey, { created_at: ev.created_at, id: ev.id, picks })
  }
  const out = { voters: new Set(), byOption: new Map(), picks: new Map() }
  for (const [pk, v] of newest) {
    if (!v.picks.length) continue
    out.voters.add(pk); out.picks.set(pk, v.picks)
    for (const id of v.picks) { if (!out.byOption.has(id)) out.byOption.set(id, new Set()); out.byOption.get(id).add(pk) }
  }
  return out
}

/** An option's share of the people who voted, 0..1 (a multiple-choice poll's add up past 1, as other clients show). */
export const share = (t, id) => t.voters.size ? (t.byOption.get(id)?.size ?? 0) / t.voters.size : 0

/** NIP-88 vote tags: the poll, its author, then one `response` per pick (the first only, single-choice). */
export function voteTags(poll, optionIds, relayHint = "") {
  if (!isPublicRelay(relayHint)) relayHint = "" // signed into the vote: only a short public relay URL
  const known = new Set(poll.options.map(o => o.id))
  const picks = [...new Set(optionIds.filter(id => known.has(id)))]
  return [["e", poll.id, relayHint], ["p", poll.pubkey], ...(poll.multiple ? picks : picks.slice(0, 1)).map(id => ["response", id])]
}
