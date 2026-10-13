// Names and pictures of the people in the feed (kind 0). Haven has no route that stores other people's
// kind 0, so for M1 they're cached here, in localStorage, newest-wins, capped.
import { pool, PROFILE_RELAYS, uniq } from "./pool.js"

const KEY = "nv-profiles"
const MAX = 2000
const cache = new Map(Object.entries(JSON.parse(localStorage.getItem(KEY) ?? "{}")))
const listeners = new Set()
const inflight = new Set()

export const getProfile = pk => cache.get(pk)
export function onProfiles(cb) { listeners.add(cb); return () => listeners.delete(cb) }

/** Store one kind 0 and tell the screens (main.jsx's own-profile path). Batches use store() + one changed(). */
export function putProfile(ev) {
  const stored = store(ev)
  if (stored) changed()
  return stored
}

function store(ev) {
  if (ev?.kind !== 0) return false
  const have = cache.get(ev.pubkey)
  if (have && have.created_at >= ev.created_at) return false
  let c
  try { c = JSON.parse(ev.content) } catch { return false }
  cache.delete(ev.pubkey)
  cache.set(ev.pubkey, { name: str(c.display_name) || str(c.name), picture: str(c.picture), about: str(c.about), banner: str(c.banner), nip05: str(c.nip05), lud16: str(c.lud16), created_at: ev.created_at })
  return true
}

let saveTimer
function changed() {
  clearTimeout(saveTimer)
  saveTimer = setTimeout(() => {
    while (cache.size > MAX) cache.delete(cache.keys().next().value)
    try { localStorage.setItem(KEY, JSON.stringify(Object.fromEntries(cache))) } catch {}
  }, 500)
  for (const cb of listeners) cb()
}

/** Fetch kind 0 for any of these pubkeys not cached yet (or all, with force). */
export async function fetchProfiles(pubkeys, relays, { force = false } = {}) {
  const want = uniq(pubkeys).filter(pk => (force || !cache.has(pk)) && !inflight.has(pk))
  if (!want.length) return
  want.forEach(pk => inflight.add(pk))
  try {
    for (let i = 0; i < want.length; i += 200) {
      const evs = await pool.querySync(uniq([...relays, ...PROFILE_RELAYS]), { kinds: [0], authors: want.slice(i, i + 200) }, { maxWait: 6000 })
      if (evs.map(store).some(Boolean)) changed()
    }
  } finally {
    want.forEach(pk => inflight.delete(pk))
  }
}

const str = v => (typeof v === "string" ? v.trim() : "")
