// When the Following feed last finished asking the relays, per account and follow list, for this tab (sessionStorage:
// it outlives a reload, not the tab). Coming back to the Feed within FRESH_MS shows what Haven has and asks nothing:
// every visit used to ask every relay about every follow again (1,054 follows: ~45 REQs, ~16 s of "Syncing x/1054
// follows"). The Feed's two-minute background sync keeps it current meanwhile; Refresh always asks.

const KEY = "nv-feed-synced"
/** The Feed's background sync interval (FeedScreen BACKGROUND_SYNC_MS): newer than this, a visit asks nothing. */
export const FRESH_MS = 120_000

/** The follow list as a short key: a follow or unfollow is a new list, which syncs at once. */
export function followsKey(follows) {
  let h = 0
  for (const pk of follows) for (let i = 0; i < pk.length; i += 8) h = (Math.imul(h, 31) + parseInt(pk.slice(i, i + 8), 16)) | 0
  return `${follows.length}:${(h >>> 0).toString(36)}`
}

const read = storage => { try { return JSON.parse(storage?.getItem(KEY) ?? "{}") ?? {} } catch { return {} } }

/** Did a sync of this follow list finish less than FRESH_MS ago? */
export function syncedRecently(pubkey, follows, { now = Date.now(), storage = globalThis.sessionStorage } = {}) {
  const s = read(storage)[pubkey]
  return !!s && s.key === followsKey(follows) && now - s.at >= 0 && now - s.at < FRESH_MS
}

export function markSynced(pubkey, follows, { now = Date.now(), storage = globalThis.sessionStorage } = {}) {
  if (!pubkey) return
  try { storage?.setItem(KEY, JSON.stringify({ ...read(storage), [pubkey]: { at: now, key: followsKey(follows) } })) } catch {}
}

/** Sign-out: this account's mark goes with it. */
export function forgetSynced(pubkey, { storage = globalThis.sessionStorage } = {}) {
  const all = read(storage)
  if (!(pubkey in all)) return
  delete all[pubkey]
  try { Object.keys(all).length ? storage.setItem(KEY, JSON.stringify(all)) : storage.removeItem(KEY) } catch {}
}
