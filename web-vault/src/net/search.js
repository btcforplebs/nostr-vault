// Search: NIP-50 `search` filters against the search relays. A pasted npub / nprofile / hex pubkey is not searched:
// it names one profile, so it goes straight there. Read-only; nothing here signs or stores.
import { decode } from "nostr-tools/nip19"
import { pool } from "./pool.js"

// relay.nostr.band answered no NIP-50 query on 2026-10-13 and held each one to the timeout; of five probed, only
// search.nos.today returned results.
export const SEARCH_RELAYS = ["wss://search.nos.today"]

/** What the box holds: nothing, one profile (with any relay hints), or text to search for. */
export function parseQuery(input) {
  const q = String(input ?? "").trim()
  if (!q) return { type: "empty" }
  const ref = q.replace(/^nostr:/i, "")
  if (/^[0-9a-f]{64}$/i.test(ref)) return { type: "profile", pubkey: ref.toLowerCase(), relays: [] }
  if (/^(npub|nprofile)1[02-9ac-hj-np-z]+$/i.test(ref)) {
    try {
      const { type, data } = decode(ref.toLowerCase())
      if (type === "npub") return { type: "profile", pubkey: data, relays: [] }
      if (type === "nprofile") return { type: "profile", pubkey: data.pubkey, relays: data.relays ?? [] }
    } catch {}
  }
  return { type: "search", text: q }
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

/** People (kind 0) and notes (kind 1) matching text, from the search relays. */
export async function searchNostr(text, { limit = 20, relays = SEARCH_RELAYS } = {}) {
  const [people, notes] = await Promise.all([
    pool.querySync(relays, { kinds: [0], search: text, limit }, { maxWait: 6000 }),
    pool.querySync(relays, { kinds: [1], search: text, limit }, { maxWait: 6000 }),
  ])
  return { people: dedupePeople(people), notes: sortNotes(notes) }
}
