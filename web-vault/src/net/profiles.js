// Names and pictures of the people in the feed (kind 0). Haven /feed keeps them (owner streams may cache kind 0
// there), so they're there offline; this module holds the ones in use in memory and tells the screens.
import { pool, PROFILE_RELAYS, uniq } from "./pool.js"
import { storeAll } from "./sync.js"

const cache = new Map()
const listeners = new Set()
// pubkey -> the fetch asking for it now: a second ask waits on that one instead of asking again.
const inflight = new Map()

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
 * (or all of them, with force), writing what the network returns into Haven. `save: false` keeps what the network
 * returns in memory only (strangers on the Global and Hashtag feeds). Each relay's answer is drawn as it lands and
 * written in one batch, not one event at a time after the slowest relay. Pubkeys another call is fetching right
 * now are waited on, not asked again. `query` is for tests.
 */
export async function fetchProfiles(vault, pubkeys, relays, { force = false, save = true, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const all = uniq(pubkeys)
  const waits = uniq(all.filter(pk => inflight.has(pk)).map(pk => inflight.get(pk)))
  const want = all.filter(pk => (force || !cache.has(pk)) && !inflight.has(pk))
  const work = want.length ? load(vault, want, relays, { force, save, query }) : null
  if (work) want.forEach(pk => inflight.set(pk, work))
  try {
    await Promise.all([work, ...waits].filter(Boolean).map(p => p.catch(() => {})))
    await work
  } finally {
    if (work) want.forEach(pk => { if (inflight.get(pk) === work) inflight.delete(pk) })
  }
}

// Network asks in flight at once, per relay: a relay answers several, but 8 chunks of 200 one after another each
// waited on the slowest relay (6 s), and a big Followers list never finished naming.
const WAVE = 3

async function load(vault, want, relays, { force, save, query }) {
  const urls = uniq([...relays, ...PROFILE_RELAYS])
  const chunks = []
  for (let i = 0; i < want.length; i += 200) chunks.push(want.slice(i, i + 200))
  // Haven first, for every chunk: a local read takes milliseconds, a relay's answer seconds.
  for (const chunk of chunks) {
    const local = await vault.feed.query({ kinds: [0], authors: chunk })
    if (local.map(store).some(Boolean)) changed()
  }
  if (globalThis.navigator?.onLine === false) return
  const ask = async chunk => {
    const missing = force ? chunk : chunk.filter(pk => !cache.has(pk))
    if (!missing.length) return
    await Promise.all(urls.map(async url => {
      const evs = await query([url], { kinds: [0], authors: missing }, { maxWait: 6000 }).catch(() => [])
      // Only what is newer than what is held: the same kind 0 from a second relay isn't drawn or written again.
      const fresh = evs.filter(store)
      if (!fresh.length) return
      changed()
      if (save) await storeAll(vault.feed, fresh)
    }))
  }
  for (let i = 0; i < chunks.length; i += WAVE) await Promise.all(chunks.slice(i, i + WAVE).map(ask))
}

/** Resolves once every one of `pubkeys` has a name in memory, or `work` (the fetch for them) has settled. */
export function namesIn(pubkeys, work) {
  const named = () => pubkeys.every(pk => cache.has(pk))
  if (named()) return Promise.resolve()
  return new Promise(resolve => {
    const done = () => { off(); resolve() }
    const off = onProfiles(() => { if (named()) done() })
    Promise.resolve(work).then(done, done)
  })
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
