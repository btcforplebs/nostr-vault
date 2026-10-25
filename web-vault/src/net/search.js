// Search: NIP-50 `search` filters against the search relays. A pasted npub / nprofile / hex pubkey is not searched:
// it names one profile, so it goes straight there; a pasted note1 / nevent opens that note. The rest mirrors the
// iPhone's Search tab (Views/Search): the who/when filter, the Hashtags and Links pulled from matching notes, and the
// Recent list. Read-only; nothing here signs.
import { decode } from "nostr-tools/nip19"
import { pool } from "./pool.js"

// The iPhone's Global search services (SearchRelayDefaults.relays), probed again 2026-10-25: nostr.wine answers people
// and notes in 0.4-1.3 s, search.nos.today in 0.6-1.6 s (its people now and then 13 s), relay.vertexlab.io and
// profiles.nostrver.se search people only (vertexlab CLOSES a notes REQ). relay.nostr.band still times out.
export const SEARCH_RELAYS = ["wss://nostr.wine", "wss://search.nos.today", "wss://relay.vertexlab.io", "wss://profiles.nostrver.se"]

/** What the box holds: nothing, one profile (with any relay hints), or text to search for. */
export function parseQuery(input) {
  const q = String(input ?? "").trim()
  if (!q) return { type: "empty" }
  const ref = q.replace(/^nostr:/i, "")
  if (/^[0-9a-f]{64}$/i.test(ref)) return { type: "profile", pubkey: ref.toLowerCase(), relays: [] }
  if (/^(npub|nprofile|note|nevent)1[02-9ac-hj-np-z]+$/i.test(ref)) {
    try {
      const { type, data } = decode(ref.toLowerCase())
      if (type === "npub") return { type: "profile", pubkey: data, relays: [] }
      if (type === "nprofile") return { type: "profile", pubkey: data.pubkey, relays: data.relays ?? [] }
      if (type === "note") return { type: "note", id: data, relays: [] }
      if (type === "nevent") return { type: "note", id: data.id, relays: data.relays ?? [] }
    } catch {}
  }
  return { type: "search", text: q }
}

/** "#bitcoin" on its own names a hashtag feed (Return opens it, as on the Mac); -> "bitcoin", or null. */
export function hashtagOf(input) {
  const m = /^#([^\s#]{2,})$/.exec(String(input ?? "").trim())
  return m ? m[1].toLowerCase() : null
}

/** The live search waits for 2 characters, as the iPhone's does. */
export const MIN_QUERY = 2

/** Who / When: narrows what came back, never re-asks the relays (SearchFilter.swift). */
export const WHO = [
  { id: "everyone", label: "Everyone" },
  { id: "follows", label: "People you follow" },
  { id: "you", label: "You" },
]
export const WHEN = [
  { id: "any", label: "Any time", window: 0 },
  { id: "day", label: "Last 24 hours", window: 86400 },
  { id: "week", label: "Last week", window: 7 * 86400 },
  { id: "month", label: "Last month", window: 30 * 86400 },
]
export const NO_FILTER = { who: "everyone", when: "any" }

/** "People you follow · Last week", or null when nothing is filtered. */
export function filterCaption(f) {
  const parts = []
  if (f.who !== "everyone") parts.push(WHO.find(w => w.id === f.who)?.label)
  if (f.when !== "any") parts.push(WHEN.find(w => w.id === f.when)?.label)
  return parts.length ? parts.join(" · ") : null
}

/** Own first, then the people you follow, then the rest of your web of trust, then everyone; the order inside each
 *  group is kept (GlobalSearchMerge's ranking). */
function rank(list, pubkeyOf, me, follows, wot = new Set()) {
  const tier = pk => (pk === me ? 0 : follows.has(pk) ? 1 : wot.has(pk) ? 2 : 3)
  return list.map((x, i) => [x, i]).sort((a, b) => tier(pubkeyOf(a[0])) - tier(pubkeyOf(b[0])) || a[1] - b[1]).map(([x]) => x)
}

/** What the search relays answered, through the who/when filter and ranked own -> follows -> web of trust -> everyone, with the
 *  Hashtags and Links found in the notes that survived (so they follow the filter too).
 *  -> { people: [pubkey], notes: [event], hashtags: [tag], links: [{ url, title, noteId }] } */
export function shapeResults({ people, notes }, query, { me, follows = [], wot, filter = NO_FILTER, now = Date.now() / 1000 }) {
  const fset = new Set(follows)
  const allows = pk => filter.who === "you" ? pk === me : filter.who === "follows" ? fset.has(pk) : true
  const window = WHEN.find(w => w.id === filter.when)?.window
  const shownPeople = rank(people.filter(allows), pk => pk, me, fset, wot)
  const shownNotes = rank(notes.filter(n => allows(n.pubkey) && (!window || n.created_at >= now - window)), n => n.pubkey, me, fset, wot)
  return { people: shownPeople, notes: shownNotes, hashtags: hashtagsIn(shownNotes, query), links: linksIn(shownNotes) }
}

/** Hashtags written in the notes whose name contains the query, lowercased, A-Z. */
export function hashtagsIn(notes, query) {
  const q = String(query ?? "").trim().toLowerCase().replace(/^#/, "")
  const found = new Set()
  for (const n of notes) for (const m of String(n.content ?? "").matchAll(/#([\p{L}\p{N}_]+)/gu)) {
    const tag = m[1].toLowerCase()
    if (tag.includes(q)) found.add(tag)
  }
  return [...found].sort()
}

/** Each link in the notes once, titled without its scheme, with the note it came from. */
export function linksIn(notes) {
  const seen = new Set(), links = []
  for (const n of notes) for (const [url] of String(n.content ?? "").matchAll(/https?:\/\/[^\s]+/g)) {
    if (seen.has(url)) continue
    seen.add(url)
    links.push({ url, title: url.replace(/^https?:\/\//, ""), noteId: n.id })
  }
  return links
}

/** The Recent list: 8 at most, newest first, one per query whatever its case, 2 characters or more. */
export const RECENT_KEY = "nv.search.recent"
export function loadRecent(storage) {
  try { const v = JSON.parse(storage?.getItem(RECENT_KEY) ?? "[]"); return Array.isArray(v) ? v.filter(x => typeof x === "string") : [] } catch { return [] }
}
export function saveRecent(storage, query) {
  const q = String(query ?? "").trim()
  const list = loadRecent(storage)
  if (q.length < MIN_QUERY) return list
  const next = [q, ...list.filter(x => x.toLowerCase() !== q.toLowerCase())].slice(0, 8)
  try { storage?.setItem(RECENT_KEY, JSON.stringify(next)) } catch {}
  return next
}
export function clearRecent(storage) { try { storage?.removeItem(RECENT_KEY) } catch {} return [] }

/** Trending: the 8 `t` tags used most in the notes on hand (the feed), most used first. */
export function trendingTags(notes) {
  const counts = new Map()
  for (const n of notes) for (const t of n.tags ?? []) if (t[0] === "t" && t[1]) {
    const tag = t[1].toLowerCase()
    counts.set(tag, (counts.get(tag) ?? 0) + 1)
  }
  return [...counts].sort((a, b) => b[1] - a[1]).slice(0, 8).map(([tag]) => tag)
}

/** Active in your feed: the 6 people other than you who posted most in the notes on hand, most first. */
export function activePosters(notes, me, blocked = new Set()) {
  const counts = new Map()
  for (const n of notes) if (n.pubkey !== me && !blocked.has(n.pubkey)) counts.set(n.pubkey, (counts.get(n.pubkey) ?? 0) + 1)
  return [...counts].sort((a, b) => b[1] - a[1]).slice(0, 6).map(([pk]) => pk)
}

/** Kind 0 results, one per pubkey (newest wins), in the order the relays ranked them. */
export function dedupePeople(events) {
  const best = new Map()
  for (const ev of events) {
    if (ev?.kind !== 0) continue
    const have = best.get(ev.pubkey)
    if (!have || ev.created_at > have.created_at) best.set(ev.pubkey, ev)
  }
  return [...best.values()]
}

/** Kind 1 results, one per id, newest first. */
export function sortNotes(events) {
  const byId = new Map(events.filter(ev => ev?.kind === 1).map(ev => [ev.id, ev]))
  return [...byId.values()].sort((a, b) => b.created_at - a.created_at)
}

/** Kind 0 only: the read-only sign-in's "find yourself by name". */
export async function searchPeople(text, { limit = 20, relays = SEARCH_RELAYS } = {}) {
  return dedupePeople(await pool.querySync(relays, { kinds: [0], search: text, limit }, { maxWait: 6000 }))
}

/** People (kind 0) and notes (kind 1) matching text, from the search relays, after the slowest (the mention picker). */
export async function searchNostr(text, { limit = 20, relays = SEARCH_RELAYS } = {}) {
  const [people, notes] = await Promise.all([
    pool.querySync(relays, { kinds: [0], search: text, limit }, { maxWait: 6000 }),
    pool.querySync(relays, { kinds: [1], search: text, limit }, { maxWait: 6000 }),
  ])
  return { people: dedupePeople(people), notes: sortNotes(notes) }
}

// Global search, as the iPhone's GlobalSearchSession: this browser's Haven (/feed and your own notes) and every search
// relay at once, each with its own status, merged and published as they answer. A people-only service CLOSES the
// notes REQ, so each kind is its own REQ. No source is waited on past HARD_CAP_MS.
export const HARD_CAP_MS = 15000
export const NOTE_LIMIT = 50 // per service, GlobalSearchSession.serviceNoteLimit
export const PEOPLE_LIMIT = 30 // serviceProfileLimit
export const HAVEN_NOTE_LIMIT = 300 // own store (macNoteLimit)
export const HAVEN_PEOPLE_LIMIT = 100
export const MAX_NOTES = 200 // most notes one update carries
const PUBLISH_MS = 100 // coalesces bursts of events into one screen update
export const HAVEN_SOURCE = "haven"
const hostLabel = url => { try { return new URL(url).hostname } catch { return url } }

/** The last finished answers, so a query asked again (a Recent chip, a retyped word) shows at once while it re-asks. */
const answered = new Map()
const ANSWERED_MAX = 12
export const forgetAnswers = () => answered.clear()

/**
 * Starts one Global search. `onUpdate({ people: [kind 0], notes: [kind 1], sources: [{ id, label, state, count, reason }],
 * finished })` runs as results land; state is "searching" | "found" | "failed". -> cancel(): nothing is published after it.
 * `subscribe`, `online` and the timers are for tests.
 */
export function startSearch(text, { vault, me, relays = SEARCH_RELAYS, onUpdate, online = globalThis.navigator?.onLine !== false,
  subscribe = (urls, filter, params) => pool.subscribeEose(urls, filter, params), hardCap = HARD_CAP_MS,
  setTimer = setTimeout, clearTimer = clearTimeout }) {
  const key = text.trim().toLowerCase()
  const people = new Map(), notes = new Map(), sources = new Map()
  let done = false, cancelled = false, scheduled = null, started = false, cap = null
  const closers = []
  const add = (id, label) => sources.set(id, { id, label, state: "searching", count: 0, hits: new Set(), open: 0, reasons: [] })
  const take = (src, ev) => {
    if (done || !ev?.id) return
    if (ev.kind === 0) { const have = people.get(ev.pubkey); if (!have || ev.created_at > have.created_at) people.set(ev.pubkey, ev) }
    else if (ev.kind === 1) notes.set(ev.id, ev)
    else return
    src.hits.add(ev.kind === 0 ? `p:${ev.pubkey}` : ev.id)
    src.count = src.hits.size
    publishSoon()
  }
  const snapshot = () => ({
    people: [...people.values()],
    notes: sortNotes([...notes.values()]).slice(0, MAX_NOTES),
    sources: [...sources.values()].map(({ id, label, state, count, reason }) => ({ id, label, state, count, reason })),
    finished: [...sources.values()].every(s => s.state !== "searching"),
  })
  const publish = () => {
    scheduled = null
    if (cancelled) return
    const snap = snapshot()
    if (snap.finished) finish(snap)
    onUpdate?.(snap)
  }
  const publishSoon = () => { if (!scheduled && !done) scheduled = setTimer(publish, PUBLISH_MS) }
  const finish = snap => {
    if (done) return
    done = true
    clearTimer(cap)
    if (scheduled) { clearTimer(scheduled); scheduled = null }
    if (snap.people.length || snap.notes.length) {
      answered.delete(key); answered.set(key, { people: snap.people, notes: snap.notes })
      while (answered.size > ANSWERED_MAX) answered.delete(answered.keys().next().value)
    }
  }
  const settle = (src, failed, reason) => {
    if (src.state !== "searching") return
    src.state = failed && !src.count ? "failed" : "found"
    if (src.state === "failed") src.reason = reason
    if (!started) return // set up still running: the first update below carries it
    if (scheduled) clearTimer(scheduled)
    publish()
  }

  // This browser's Haven: offline too. The notes Haven keeps and your own, and the profiles it holds.
  add(HAVEN_SOURCE, "This browser")
  const haven = sources.get(HAVEN_SOURCE)
  if (vault) {
    Promise.all([
      vault.feed.query([{ kinds: [1], search: text, limit: HAVEN_NOTE_LIMIT }, { kinds: [0], search: text, limit: HAVEN_PEOPLE_LIMIT }]).catch(() => []),
      me ? vault.outbox.query({ kinds: [1], authors: [me], search: text, limit: 100 }).catch(() => []) : [],
    ]).then(([feed, own]) => { for (const ev of [...own, ...feed]) take(haven, ev); settle(haven, false) })
  } else settle(haven, true, "Haven not open")

  for (const url of relays) {
    const id = `relay:${url}`
    if (sources.has(id)) continue
    add(id, hostLabel(url))
    const src = sources.get(id)
    if (!online) { src.state = "failed"; src.reason = "offline"; continue }
    for (const filter of [{ kinds: [1], search: text, limit: NOTE_LIMIT }, { kinds: [0], search: text, limit: PEOPLE_LIMIT }]) {
      src.open++
      try {
        closers.push(subscribe([url], filter, {
          maxWait: hardCap + 1000, // the cap below ends it first and calls it "timed out"
          onevent: ev => take(src, ev),
          onclose: reasons => {
            const why = [reasons].flat().find(r => r && !/closed automatically on eose|closed by caller/i.test(r))
            if (why) src.reasons.push(String(why))
            if (--src.open === 0) settle(src, src.reasons.length >= 2, shortReason(src.reasons[0])) // failed: neither REQ was answered
          },
        }))
      } catch (e) { src.reasons.push(String(e?.message ?? e)); if (--src.open === 0) settle(src, src.reasons.length >= 2, shortReason(src.reasons[0])) }
    }
  }

  cap = setTimer(() => {
    for (const s of sources.values()) if (s.state === "searching") { s.state = s.count ? "found" : "failed"; if (!s.count) s.reason = "timed out" }
    publish()
    closers.forEach(c => { try { c.close() } catch {} })
  }, hardCap + 200)

  const before = answered.get(key)
  if (before) { for (const ev of before.people) people.set(ev.pubkey, ev); for (const ev of before.notes) notes.set(ev.id, ev) }
  // The first screen at once: what this query found last time, and every source "searching".
  started = true
  queueMicrotask(() => { if (!done) publish() })
  return () => {
    cancelled = true
    if (done) return
    done = true
    clearTimer(cap)
    if (scheduled) clearTimer(scheduled)
    closers.forEach(c => { try { c.close() } catch {} })
  }
}

/** A relay's reason, short enough for a chip: "can't connect", "timed out", or its own words cut to 40. */
export function shortReason(r) {
  const s = String(r ?? "").replace(/^(CLOSED|NOTICE|error):\s*/i, "").trim()
  if (!s) return "no answer"
  if (/timeout|timed out/i.test(s)) return "timed out"
  if (/connect|websocket|network|refused|dead relay|sockets busy/i.test(s)) return "can't connect"
  return s.length > 40 ? s.slice(0, 39) + "…" : s
}
