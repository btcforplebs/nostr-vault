// The dashboard's GM tile (iPhone/Mac GreetingCounts.swift, Android GreetingCounts.kt): how many of your own notes
// were a "GM", and how many a "Pura Vida", today and all time. Read from this browser's own vault (the outbox route);
// no network and nothing published. A note counts only when it is basically just the greeting: the greeting plus at
// most MAX_EXTRA_WORDS other words. Links, nostr: mentions and #tags are ignored, so a "gm" with a photo still counts;
// a longer note that happens to contain "gm" does not.

export const MAX_EXTRA_WORDS = 2
const LINK = /\b(?:https?:\/\/|nostr:|www\.)\S+/giu
const TAG = /(?<!\S)#\S+/gu
const WORD = /[\p{L}\p{N}']+/gu
const GM = /^(?:gm)+m*$/

/** The greetings `content` is ("gm", "pv"), or an empty set when it is more than a greeting. */
export function greetings(content) {
  const text = String(content ?? "").replace(LINK, " ").replace(TAG, " ").toLowerCase()
  const words = (text.match(WORD) ?? []).map(w => w.replace(/^'+|'+$/g, "")).filter(Boolean)
  const found = new Set()
  let greetingWords = 0
  for (let i = 0; i < words.length;) {
    const w = words[i], next = words[i + 1]
    if (GM.test(w)) { found.add("gm"); greetingWords += 1; i += 1 }
    else if (w === "good" && (next === "morning" || next === "mornin")) { found.add("gm"); greetingWords += 2; i += 2 }
    else if (w === "pv") { found.add("pv"); greetingWords += 1; i += 1 }
    else if (w === "pura" && next === "vida") { found.add("pv"); greetingWords += 2; i += 2 }
    else i += 1
  }
  return found.size && words.length - greetingWords <= MAX_EXTRA_WORDS ? found : new Set()
}

/** The counts over `notes` by `author` (kind 1 only), "today" meaning created at or after `todayStart` (seconds). */
export function countGreetings(notes, author, todayStart) {
  const c = { gmToday: 0, gmAll: 0, pvToday: 0, pvAll: 0 }
  const seen = new Set()
  for (const n of notes) {
    if (n?.kind !== 1 || n.pubkey?.toLowerCase() !== author.toLowerCase() || seen.has(n.id)) continue
    seen.add(n.id)
    const g = greetings(n.content)
    const today = (n.created_at ?? 0) >= todayStart
    if (g.has("gm")) { c.gmAll++; if (today) c.gmToday++ }
    if (g.has("pv")) { c.pvAll++; if (today) c.pvToday++ }
  }
  return c
}

/** The query's filter for one page of `author`'s notes, newest first, at or before `until`. */
export const pageFilter = (author, until, limit) => ({ kinds: [1], authors: [author.toLowerCase()], limit, ...(until != null ? { until } : {}) })

/** Every note of `author`'s that `read` (one page per call) gives, walking back with `until` until a page is empty.
 *  `until` is inclusive, so a second shared at a page edge is read again and dropped as seen; a page of nothing new
 *  steps one second past the edge. Stopping only on an empty page means a store cap below `pageSize` never cuts the
 *  count short. */
export async function readAll(author, read, { pageSize = 500, maxPages = 200 } = {}) {
  const byId = new Map()
  let until
  for (let p = 0; p < maxPages; p++) {
    const page = await read(pageFilter(author, until, pageSize))
    if (!page?.length) break
    let added = 0, oldest = Infinity
    for (const e of page) {
      if (!byId.has(e.id)) { byId.set(e.id, e); added++ }
      oldest = Math.min(oldest, e.created_at ?? 0)
    }
    until = added ? oldest : oldest - 1
  }
  return [...byId.values()]
}

/** Local midnight today, in seconds. */
export const todayStart = (now = new Date()) => Math.floor(new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() / 1000)

/** "GM 12 · PV 3". */
export const greetingLabel = (gm, pv) => `GM ${gm.toLocaleString()} · PV ${pv.toLocaleString()}`

/** Your counts from the vault's outbox (`outbox.query(filters)`); null when it can't answer. */
export async function readGreetings(outbox, me) {
  try {
    const notes = await readAll(me, f => outbox.query([f]))
    return countGreetings(notes, me, todayStart())
  } catch { return null }
}
