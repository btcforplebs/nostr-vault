// Quoted notes: a nostr:nevent / note / naddr reference in a note's text, read from Haven /feed first and the
// relays only for what /feed doesn't have (what they return is verified and written into /feed, so the next
// open finds it there, unless the card is a stranger's: then `save: false` keeps it in memory only). Read-only on
// the network: nothing here signs. The screens never see the vault here:
// main.jsx registers it once with setQuoteSource(), and the cards read it through quoteSource().
import { decode } from "nostr-tools/nip19"
import { isDead, pool, uniq } from "./pool.js"
import { reachableHint } from "./parent-hints.js"
import { followOutboxes, relayKey } from "./relay-suggestions.js"
import { repostedNote, verifiedCopy } from "./thread.js"

const HEX64 = /^[0-9a-f]{64}$/

let source = null
/** main.jsx: the signed-in user's vault, pubkey (`me`) and read relays, once the account is loaded. */
export function setQuoteSource(s) { source = s; changed() }
export const quoteSource = () => source

/**
 * What a nostr: reference points at (the part after "nostr:"). A bare 64-hex is a pubkey, as it was before.
 * -> { type: "profile", pubkey, relays } | { type: "note", id, relays } | { type: "addr", kind, pubkey, d, relays } | null
 */
export function parseRef(ref) {
  if (HEX64.test(ref)) return { type: "profile", pubkey: ref, relays: [] }
  let d
  try { d = decode(ref) } catch { return null }
  const relays = (d.data?.relays ?? []).filter(r => /^wss?:\/\//.test(r))
  switch (d.type) {
    case "npub": return { type: "profile", pubkey: d.data, relays }
    case "nprofile": return { type: "profile", pubkey: d.data.pubkey, relays }
    case "note": return { type: "note", id: d.data, relays }
    case "nevent": return { type: "note", id: d.data.id, relays, ...(HEX64.test(d.data.author ?? "") ? { author: d.data.author } : {}) }
    case "naddr": return { type: "addr", kind: d.data.kind, pubkey: d.data.pubkey, d: d.data.identifier, relays }
    default: return null
  }
}

/** One key per quoted thing, so two notes quoting the same note share a fetch and a cache entry. */
export const quoteKey = q => (q.type === "note" ? q.id : q.type === "addr" ? `${q.kind}:${q.pubkey}:${q.d}` : q.pubkey)

const cache = new Map() // key -> event | null (null: looked everywhere, not found)
const inflight = new Map() // key -> promise
const listeners = new Set()
export const getQuote = key => cache.get(key)
/** A quoted event already fetched, by its id (a 3D object, kind 33331, which Haven /feed doesn't keep, opens its thread
 *  from here). -> event | undefined */
export const quotedById = id => [...cache.values()].find(ev => ev?.id === id)
export const hasQuote = key => cache.has(key)
/** Drop a "not found" so the next fetch asks again: Retry on a reply whose parent never came. */
export const forgetQuote = key => { if (cache.get(key) == null) cache.delete(key) }
export function onQuotes(cb) { listeners.add(cb); return () => listeners.delete(cb) }
function changed() { for (const cb of listeners) cb() }

/**
 * The event for a parsed note/addr reference: Haven /feed (or a repost there that carries it), else the relays
 * plus the reference's own hints. Resolves to the event, or null when nowhere has it. One fetch per key at a time.
 * `save: false` doesn't write what the relays return into /feed. `query` is for tests.
 */
export function fetchQuote(q, { vault, relays = [], save = true, query = (r, f, o) => pool.querySync(r, f, o), outboxes = followOutboxes } = {}) {
  const key = quoteKey(q)
  if (cache.has(key)) return Promise.resolve(cache.get(key))
  if (inflight.has(key)) return inflight.get(key)
  const run = (async () => {
    const ev = await lookup(q, { vault, relays, save, query, outboxes })
    cache.set(key, ev)
    changed()
    return ev
  })().finally(() => inflight.delete(key))
  inflight.set(key, run)
  return run
}

async function lookup(q, { vault, relays, save, query, outboxes }) {
  const filter = q.type === "note" ? { ids: [q.id] } : { kinds: [q.kind], authors: [q.pubkey], "#d": [q.d] }
  if (vault) {
    const local = newest(await vault.feed.query(filter))
    if (local) return local
    if (q.type === "note") {
      const carried = await repostedNote(vault, q.id)
      if (carried) return carried
    }
  }
  if (globalThis.navigator?.onLine === false) return null
  const urls = uniq([...relays, ...q.relays])
  if (!urls.length) return null
  // Only what was asked for: a relay may answer with extra or unrelated events, and a validly signed article from
  // another key with the same d tag must not stand in for this one.
  // A note id names one event, so the read ends at the first verified copy instead of waiting for the slowest relay
  // (LivePool.querySync `first`). An naddr may come back in several versions and the newest wins, so that read waits.
  const first = q.type === "note" ? ev => matches(q, ev) && !!verifiedCopy(ev) : undefined
  const read = async at => !at.length ? null : newest((await query(at, filter, { maxWait: 6000, first }).catch(() => [])).map(verifiedCopy).filter(ev => ev && matches(q, ev)))
  const found = (await read(urls)) ?? (await read(await authorRelays(q, { vault, relays, query, outboxes }, urls)))
  if (!found) return null
  if (vault && save) await vault.feed.event(found).catch(() => {})
  return found
}

/** When the read relays and hints miss (the hint is down, the note sits on one of the author's own relays: Tidy,
 *  2026-11-27), up to MAX_OUTBOX of the author's kind 10002 write relays not asked yet, loopback/LAN and dead hosts
 *  skipped. The author comes from the nevent, or the naddr's key. -> [url] (empty: nothing more to ask) */
export const MAX_OUTBOX = 8
async function authorRelays(q, { vault, relays, query, outboxes }, asked) {
  const author = q.type === "addr" ? q.pubkey : q.author
  if (!author) return []
  const outbox = await outboxes({ vault, follows: [author], relays, query }).catch(() => new Map())
  const skip = new Set(asked.map(relayKey))
  return uniq((outbox.get(author) ?? []).filter(u => reachableHint(u) && !isDead(u) && !skip.has(relayKey(u)))).slice(0, MAX_OUTBOX)
}

/** True when ev is the event q points at: the note with that id, or that author's event of that kind and d tag. */
export function matches(q, ev) {
  if (q.type === "note") return ev.id === q.id
  if (q.type === "addr") return ev.kind === q.kind && ev.pubkey === q.pubkey && (ev.tags ?? []).some(t => t[0] === "d" && t[1] === q.d)
  return false
}

// A replaceable (naddr) event may come back in several versions: the newest wins.
const newest = evs => evs.reduce((best, ev) => (ev && (!best || ev.created_at > best.created_at) ? ev : best), null)

/** Where a tap on a quoted card goes: the event's own thread. */
export const quoteHash = ev => `#/thread/${ev.id}`
