// The notes a bookmark list names (Vault › Bookmarks, and the Reader's Bookmarks on desktop, napplet/reader-bookmarks.js):
// ids through this browser's vault and the relays, addresses asked of the relays. Reads only.
import { fetchNotes } from "./notifications.js"
import { pool } from "./pool.js"

/** The events for `list` (bookmarks.js entries), in its order, null where none was found. */
export async function fetchEntries(ctx, list, relays) {
  const ids = list.filter(e => e.startsWith("e:")).map(e => e.slice(2))
  const byId = ids.length ? await fetchNotes(ctx.vault, ids, relays).catch(() => new Map()) : new Map()
  const byAddr = new Map()
  await Promise.all(list.filter(e => e.startsWith("a:")).map(async e => {
    const [kind, pubkey, ...d] = e.slice(2).split(":")
    const evs = await pool.querySync(relays, { kinds: [Number(kind)], authors: [pubkey], "#d": [d.join(":")] }, { maxWait: 6000 }).catch(() => [])
    const ev = evs.sort((a, b) => b.created_at - a.created_at)[0]
    if (ev) byAddr.set(e, ev)
  }))
  return list.map(e => (e.startsWith("e:") ? byId.get(e.slice(2)) : byAddr.get(e)) ?? null)
}
