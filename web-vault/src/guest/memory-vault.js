// A guest's stand-in for Haven (src/haven/vault.js): the same feed / outbox / inbox stores the thread screen, profiles
// and quotes read and fill, kept in memory for this page only. No haven.wasm, no IndexedDB: a shared link opened by
// someone who isn't signed in leaves nothing behind in their browser. Only signed events go in, as Haven's would.
import { matchFilter } from "nostr-tools/filter"
import { verifiedCopy } from "../net/thread.js"

/** Replaceable kinds (NIP-01): one event per author and kind, the newest. Parameterised ones per `d` too. */
const replaceable = k => k === 0 || k === 3 || (k >= 10000 && k < 20000)
const addressable = k => k >= 30000 && k < 40000
const slotOf = ev => replaceable(ev.kind) ? `${ev.kind}:${ev.pubkey}`
  : addressable(ev.kind) ? `${ev.kind}:${ev.pubkey}:${ev.tags.find(t => t[0] === "d")?.[1] ?? ""}` : null

/** Most events a store keeps; past it the oldest-received goes. A thread with its profiles is a few hundred. */
export const MAX_EVENTS = 5000

/** One store: `query(filter)` (newest first, `limit` honoured) and `event(ev)` -> { ok, reason? }. */
export function memoryStore({ max = MAX_EVENTS } = {}) {
  const byId = new Map()
  const slots = new Map() // replaceable slot -> id
  return {
    async query(filter) {
      const out = [...byId.values()].filter(ev => matchFilter(filter, ev)).sort((a, b) => b.created_at - a.created_at)
      return filter?.limit > 0 ? out.slice(0, filter.limit) : out
    },
    async event(ev) {
      const e = verifiedCopy(ev)
      if (!e) return { ok: false, reason: "invalid: bad signature" }
      if (byId.has(e.id)) return { ok: true, reason: "duplicate:" }
      const slot = slotOf(e)
      if (slot) {
        const had = byId.get(slots.get(slot))
        if (had && had.created_at >= e.created_at) return { ok: false, reason: "duplicate: have a newer one" }
        if (had) byId.delete(had.id)
        slots.set(slot, e.id)
      }
      byId.set(e.id, e)
      while (byId.size > max) {
        const oldest = byId.keys().next().value
        const gone = byId.get(oldest)
        byId.delete(oldest)
        const s = slotOf(gone)
        if (s && slots.get(s) === oldest) slots.delete(s)
      }
      return { ok: true }
    },
  }
}

/** The vault shape the app's screens use ({ feed, outbox, inbox }), all in memory. */
export const memoryVault = () => ({ guest: true, feed: memoryStore(), outbox: memoryStore(), inbox: memoryStore() })
