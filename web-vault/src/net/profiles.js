// Names and pictures of the people in the feed (kind 0). Haven /feed keeps them (owner streams may cache kind 0
// there), so they're there offline; this module holds the ones in use in memory and tells the screens.
import { pool, PROFILE_RELAYS, uniq } from "./pool.js"

const cache = new Map()
const listeners = new Set()
const inflight = new Set()

// M1 kept them in localStorage; Haven has them now.
globalThis.localStorage?.removeItem("nv-profiles")

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
  cache.set(ev.pubkey, { name: str(c.display_name) || str(c.name), picture: str(c.picture), about: str(c.about), banner: str(c.banner), nip05: str(c.nip05), lud16: str(c.lud16), website: link(c.website), created_at: ev.created_at })
  return true
}

function changed() { for (const cb of listeners) cb() }

/**
 * Load kind 0 for any of these pubkeys not in memory yet: from Haven /feed first, then the network for the rest
 * (or all of them, with force), writing what the network returns into Haven. `query` is for tests.
 */
export async function fetchProfiles(vault, pubkeys, relays, { force = false, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const want = uniq(pubkeys).filter(pk => (force || !cache.has(pk)) && !inflight.has(pk))
  if (!want.length) return
  want.forEach(pk => inflight.add(pk))
  try {
    for (let i = 0; i < want.length; i += 200) {
      const chunk = want.slice(i, i + 200)
      const local = await vault.feed.query({ kinds: [0], authors: chunk })
      if (local.map(store).some(Boolean)) changed()
      const missing = force ? chunk : chunk.filter(pk => !cache.has(pk))
      if (!missing.length || globalThis.navigator?.onLine === false) continue
      const evs = await query(uniq([...relays, ...PROFILE_RELAYS]), { kinds: [0], authors: missing }, { maxWait: 6000 })
      if (evs.map(store).some(Boolean)) changed()
      for (const ev of evs) await vault.feed.event(ev)
    }
  } finally {
    want.forEach(pk => inflight.delete(pk))
  }
}

const str = v => (typeof v === "string" ? v.trim() : "")

// A profile's website, only ever as an http(s) URL: a bare "example.com" gets https://, any other scheme
// (javascript:, data:, nostr:) is dropped, so the chip's href can't run anything.
export function link(v) {
  const s = str(v)
  if (!s) return ""
  try {
    const u = new URL(/^[a-z][a-z0-9+.-]*:/i.test(s) ? s : `https://${s}`)
    return u.protocol === "http:" || u.protocol === "https:" ? u.href : ""
  } catch { return "" }
}
