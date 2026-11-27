// Where a reply's ancestors may live besides the user's own relays: the relay hint in each ancestor's `e` tag and
// the write relays of each ancestor's author (the tag's fifth slot, else the reply's `p` target), as Android
// (FeedServiceNoteFetching.kt) and the iPhone (ParentLookupRelays.swift) ask. A parent that lives only on its
// author's relay (a Mostr reply's parent on relay.ditto.pub) never loaded before. NIP-22 comments name their root only
// in an uppercase `E` tag, with the author in the fourth slot, and a phone-only poster's hint is their own
// ws://127.0.0.1 (2026-11-26 Mostr thread): `E` tags count and loopback/LAN hints are dropped.
import { isLoopback, pool } from "./pool.js"
import { followOutboxes } from "./relay-suggestions.js"
import { replyToPubkey } from "./thread.js"

const HEX64 = /^[0-9a-f]{64}$/
export const OUTBOX_PER_AUTHOR = 3
export const MAX_EXTRA = 8

const key = url => String(url).trim().toLowerCase().replace(/\/+$/, "")

const PRIVATE_V4 = /^(10|127|0)\.|^172\.(1[6-9]|2\d|3[01])\.|^192\.168\.|^169\.254\.|^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./
const LAN_SUFFIX = /\.(localhost|local|lan|home\.arpa|internal|ts\.net)$/

/** `url` when it is a websocket address others can reach: not loopback, a home network or a bare name. */
export function reachableHint(url) {
  const u = String(url ?? "").trim()
  const m = /^wss?:\/\/(\[[^\]]*\]|[^/:?#]+)/i.exec(u)
  if (!m || isLoopback(u)) return null
  const host = m[1].replace(/^\[|\]$/g, "").toLowerCase().replace(/\.+$/, "")
  if (host.includes(":")) return /^(::1?|f[cd]|fe[89ab])/.test(host) ? null : u
  if (!host.includes(".") || LAN_SUFFIX.test(host) || PRIVATE_V4.test(host)) return null
  return u
}

// NIP-10 puts the author fifth; NIP-22 (`e` and `E`) fourth, where NIP-10 has its marker, never 64 hex.
const tagAuthor = t => HEX64.test(t[4] ?? "") ? t[4] : HEX64.test(t[3] ?? "") ? t[3] : null
const isRef = t => (t[0] === "e" || t[0] === "E")

/** The `e`/`E` hints and ancestor authors the `events` give for `ids`. -> { hints: [url], authors: [pubkey] } */
export function parentRefs(events, ids) {
  const want = new Set(ids), hints = [], authors = []
  for (const ev of events) {
    let named = false
    for (const t of ev?.tags ?? []) {
      if (!isRef(t) || !want.has(t[1]) || t[3] === "mention") continue
      const hint = reachableHint(t[2])
      if (hint) hints.push(hint)
      const a = tagAuthor(t)
      if (a) { authors.push(a); named = true }
    }
    const p = !named && (ev?.tags ?? []).some(t => isRef(t) && want.has(t[1])) ? replyToPubkey(ev) : null
    if (p) authors.push(p)
  }
  return { hints: [...new Set(hints)], authors: [...new Set(authors)] }
}

/** The relay hints the card's parent preview asks, at most two: the parent's own `e`/`E` tag hint first, then the
 *  other thread tags' (a NIP-22 comment's root `E` often names the relay the whole thread lives on, when the parent's
 *  hint is the poster's 127.0.0.1). Loopback and home-network hints are dropped. */
export function parentHintRelays(ev, parentId) {
  const tags = (ev?.tags ?? []).filter(t => isRef(t) && t[3] !== "mention")
  const own = tags.filter(t => t[1] === parentId), rest = tags.filter(t => t[1] !== parentId)
  return [...new Set([...own, ...rest].map(t => reachableHint(t[2])).filter(Boolean))].slice(0, 2)
}

/** The relays to add for `ids` beyond `known`: hints first, then up to 3 write relays per author, MAX_EXTRA in all. */
export function extraRelays({ hints, authors }, outbox, known = []) {
  const seen = new Set(known.map(key)), out = []
  const add = url => { if (out.length < MAX_EXTRA && /^wss?:\/\//.test(url ?? "") && !seen.has(key(url))) { seen.add(key(url)); out.push(url) } }
  hints.forEach(add)
  for (const pk of authors) (outbox.get(pk) ?? []).slice(0, OUTBOX_PER_AUTHOR).forEach(add)
  return out
}

/** Ask the hinted and author relays for `ids` the user's relays didn't have. Read-only: nothing is signed.
 *  -> Map id -> event (those found; each checked by the pool). */
export async function fetchFromParentRelays({ vault, events, ids, relays, outboxes = followOutboxes, query = (r, f, o) => pool.querySync(r, f, o) }) {
  const found = new Map()
  if (!ids.length) return found
  const refs = parentRefs(events, ids)
  if (!refs.hints.length && !refs.authors.length) return found
  const outbox = refs.authors.length ? await outboxes({ vault, follows: refs.authors, relays, query }).catch(() => new Map()) : new Map()
  const urls = extraRelays(refs, outbox, relays)
  if (!urls.length) return found
  const want = new Set(ids)
  for (const ev of await query(urls, { ids }, { maxWait: 6000 }).catch(() => [])) if (want.has(ev?.id)) found.set(ev.id, ev)
  return found
}
