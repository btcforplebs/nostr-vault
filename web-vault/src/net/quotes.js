// Quoted notes: a nostr:nevent / note / naddr reference in a note's text, read from Haven /feed first and the
// relays only for what /feed doesn't have (what they return is verified and written into /feed, so the next
// open finds it there). Read-only on the network: nothing here signs. The screens never see the vault here:
// main.jsx registers it once with setQuoteSource(), and the cards read it through quoteSource().
import { decode } from "nostr-tools/nip19"
import { pool, uniq } from "./pool.js"
import { repostedNote, verifiedCopy } from "./thread.js"

const HEX64 = /^[0-9a-f]{64}$/

let source = null
/** main.jsx: the signed-in user's vault and read relays, once the account is loaded. */
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
    case "nevent": return { type: "note", id: d.data.id, relays }
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
export const hasQuote = key => cache.has(key)
export function onQuotes(cb) { listeners.add(cb); return () => listeners.delete(cb) }
function changed() { for (const cb of listeners) cb() }

/**
 * The event for a parsed note/addr reference: Haven /feed (or a repost there that carries it), else the relays
 * plus the reference's own hints. Resolves to the event, or null when nowhere has it. One fetch per key at a time.
 * `query` is for tests.
 */
export function fetchQuote(q, { vault, relays = [], query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const key = quoteKey(q)
  if (cache.has(key)) return Promise.resolve(cache.get(key))
  if (inflight.has(key)) return inflight.get(key)
  const run = (async () => {
    const ev = await lookup(q, { vault, relays, query })
    cache.set(key, ev)
    changed()
    return ev
  })().finally(() => inflight.delete(key))
  inflight.set(key, run)
  return run
}

async function lookup(q, { vault, relays, query }) {
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
  const found = newest((await query(urls, filter, { maxWait: 6000 })).map(verifiedCopy).filter(Boolean))
  if (!found) return null
  if (q.type === "note" && found.id !== q.id) return null
  if (vault) await vault.feed.event(found).catch(() => {})
  return found
}

// A replaceable (naddr) event may come back in several versions: the newest wins.
const newest = evs => evs.reduce((best, ev) => (ev && (!best || ev.created_at > best.created_at) ? ev : best), null)

/** Where a tap on a quoted card goes: the event's own thread. */
export const quoteHash = ev => `#/thread/${ev.id}`
