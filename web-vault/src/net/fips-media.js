// Note photos that live on a FIPS vault: a NIP-F1 link `http://<npub>.fips/<sha256>`, or an https photo whose server
// can't serve it while the author's 10063 lists a `fipsmesh://<npub>/` vault and the imeta gives its hash (x). As on
// iPhone, only notes from people you follow (or your own) use the mesh, an https photo only once its server failed,
// and Settings › Media Servers can turn it off (on by default). Then the first photo starts web-relay's photo-only
// reader: a fresh key, never saved, the public seeds only, no relay, nothing published; it stops again once no photo
// needs it. Each photo is read by hash and checked against it (blob-get.js), then shown from a blob: URL. One read
// per hash; reads take turns one vault at a time, so no note's vault list can hold the line; a vault may answer the
// page only while a read is asking it (and its stream is closing).
import { fipsRef, meshVaults } from "./fips-ref.js"
import { pool, DEFAULT_RELAYS, PROFILE_RELAYS, BROADCAST_RELAYS, uniq } from "./pool.js"

const SHA256 = /^[0-9a-f]{64}$/
/** Vault reads at once: each is a TCP stream over the seeds, and the blob node caps its readers. */
export const MAX_READS = 2
/** One vault, connect to bytes (and between bytes), before the next is tried. */
export const READ_TIMEOUT_MS = 45_000
/** One photo, start to bytes, across all its vaults; no new vault is tried past it. */
export const PHOTO_TIMEOUT_MS = 90_000
/** Vaults one photo may ask: a 10063 can list any number, only the first few are tried. */
export const MAX_VAULTS = 3
/** Photos kept as blob: URLs once nothing on the page shows them; past this the oldest is released. */
export const MAX_KEPT = 60
/** With no photo reading, the reader is stopped after this long (sockets and timer gone). */
export const IDLE_STOP_MS = 60_000

const KEY = "nv:fips-photos"
/** Settings switch: FIPS photos on unless the person turned them off in this browser. */
export const meshPhotosOn = (storage = globalThis.localStorage) => { try { return storage?.getItem(KEY) !== "off" } catch { return true } }
export const setMeshPhotosOn = (on, storage = globalThis.localStorage) => {
  try { on ? storage?.removeItem(KEY) : storage?.setItem(KEY, "off") } catch {}
  gateChanged()
}

// A photo already on the page re-checks the gate when it changes (MediaImage): a follow added or the switch flipped.
const watchers = new Set()
/** Call `fn` whenever who may use the mesh changes; returns the unsubscribe. */
export const onMeshGate = fn => { watchers.add(fn); return () => watchers.delete(fn) }
const gateChanged = () => { for (const fn of [...watchers]) fn() }

// Whose notes may use the mesh: the signed-in account and the people it follows (main.jsx keeps this current).
let me, follows = [], followSet = new Set()
export function setMeshPeople(pubkey, list = []) {
  if (pubkey === me && list === follows) return
  const next = new Set(list)
  const same = pubkey === me && next.size === followSet.size && [...next].every(k => followSet.has(k))
  me = pubkey; follows = list; followSet = next
  if (!same) gateChanged()
}
/** May this author's note photos use the mesh? Yours or a follow's, with the switch on. */
export const meshAllowed = (author, on = meshPhotosOn()) => on && !!author && (author === me || followSet.has(author))

const aborted = () => Object.assign(new Error("photo no longer shown"), { name: "AbortError" })

/**
 * The loader. `startReader` is web-relay's startPhotoReader (tests pass a fake); `query` reads a 10063; `clock` and
 * `timers` are for tests; `allow(author)` says whose notes may use the mesh (meshAllowed). The reader may only ask the
 * vaults a note named, so a photo never goes anywhere a note didn't point.
 */
export function createFipsMedia({
  startReader = defaultReader, query = (r, f, o) => pool.querySync(r, f, o), allow = author => meshAllowed(author),
  relays = uniq([...DEFAULT_RELAYS, ...BROADCAST_RELAYS, ...PROFILE_RELAYS]),
  clock = () => Date.now(), setTimer = (fn, ms) => { const t = setTimeout(fn, ms); t?.unref?.(); return t }, clearTimer = clearTimeout,
} = {}) {
  const allowed = new Set() // vaults a read is asking right now: the shim drops segments from anyone else
  const asking = new Map() // vault -> reads asking it
  const photos = new Map() // sha256 -> entry, oldest first
  const lists = new Map() // author -> Promise<vaults>
  const waiting = [] // { go, entry }
  let reader, running = 0, idle

  const getReader = () => {
    if (idle) { clearTimer(idle); idle = undefined }
    return (reader ??= startReader({ getPhotoVaults: () => allowed }).catch(e => { reader = undefined; throw e }))
  }
  const maybeStop = () => {
    if (idle || !reader || running || waiting.length || [...photos.values()].some(e => !e.done)) return
    idle = setTimer(() => {
      idle = undefined
      const r = reader
      reader = undefined
      r?.then(x => x.stop?.(), () => {})
    }, IDLE_STOP_MS)
  }

  const ask = v => { asking.set(v, (asking.get(v) ?? 0) + 1); allowed.add(v) }
  const unask = v => { const n = (asking.get(v) ?? 1) - 1; if (n > 0) asking.set(v, n); else { asking.delete(v); allowed.delete(v) } }

  // One slot per vault attempt, first come first served: a photo with many vaults queues again after each one, so
  // every other photo's next attempt gets its turn in between.
  const slot = entry => {
    if (running < MAX_READS) { running++; return Promise.resolve() }
    return new Promise((go, stop) => waiting.push({ go: () => { running++; go() }, stop, entry }))
  }
  const release = () => { running--; waiting.shift()?.go() }

  async function read(entry) {
    const r = await getReader()
    const end = clock() + PHOTO_TIMEOUT_MS
    let last
    for (const vault of entry.vs) {
      if (entry.users === 0) throw aborted()
      const left = end - clock()
      if (left <= 0) throw last ?? new Error("timed out")
      await slot(entry)
      ask(vault)
      const c = (entry.attempt = new AbortController())
      let closed
      try {
        const got = await r.getBlob(vault, entry.sha, { timeoutMs: Math.min(READ_TIMEOUT_MS, left), signal: c.signal })
        closed = got.closed
        return URL.createObjectURL(new Blob([got.bytes], { type: got.type }))
      } catch (e) {
        last = e
      } finally {
        entry.attempt = undefined
        // The slot frees now; the vault stays allowed until a polite close has finished, so its ACK/FIN still gets in.
        if (closed) Promise.resolve(closed).then(() => unask(vault), () => unask(vault))
        else unask(vault)
        release()
      }
    }
    throw last ?? new Error("no vault")
  }

  // Release the oldest photos nothing shows any more, down to MAX_KEPT. A photo still on screen is never revoked.
  const trim = () => {
    for (const [sha, e] of photos) {
      if (photos.size <= MAX_KEPT) break
      if (e.done && e.url && e.users === 0) { photos.delete(sha); URL.revokeObjectURL(e.url) }
    }
  }

  /**
   * A blob: URL for this hash from the first of `vaults` that has it. Rejects when none can be reached. `signal`:
   * abort when the photo leaves the page; before it loads that stops its read (no further vault is asked), after it
   * lets the URL be released.
   */
  function photo(vaults, sha256, { signal } = {}) {
    const sha = String(sha256 ?? "").toLowerCase()
    const vs = uniq((vaults ?? []).filter(v => SHA256.test(v))).slice(0, MAX_VAULTS)
    if (!SHA256.test(sha) || !vs.length) return Promise.reject(new Error("not a mesh photo"))
    if (signal?.aborted) return Promise.reject(aborted())
    const have = photos.get(sha)
    // Same hash, same bytes: a read already under way serves this photo too. If it fails, a note naming a vault it
    // didn't try still gets its own read (the failed one has left the cache by then).
    if (have) {
      return hold(have, signal).catch(e => {
        if (e?.name === "AbortError" || vs.every(v => have.vs.includes(v))) throw e
        return photo(vs, sha, { signal })
      })
    }
    const entry = { sha, vs, users: 0, done: false, url: undefined }
    entry.p = read(entry).then(
      u => { entry.done = true; entry.url = u; if (entry.users === 0) trim(); maybeStop(); return u },
      e => {
        entry.done = true
        if (photos.get(sha) === entry) photos.delete(sha) // a later scroll may find the vault up
        maybeStop()
        throw e
      },
    )
    photos.set(sha, entry)
    const out = hold(entry, signal)
    trim()
    return out
  }

  // One more user of `entry` until `signal` aborts. Counted now, so trim can't revoke a URL a caller is about to get.
  function hold(entry, signal) {
    entry.users++
    let gone = false
    const drop = () => {
      if (gone) return
      gone = true
      entry.users--
      if (entry.users === 0 && !entry.done) cancel(entry)
      if (entry.done) trim()
    }
    signal?.addEventListener("abort", drop, { once: true })
    return new Promise((resolve, reject) => {
      signal?.addEventListener("abort", () => reject(aborted()), { once: true })
      entry.p.then(resolve, e => { drop(); reject(e) })
    })
  }

  // No one wants it any more: leave the queue, and reset a vault attempt under way so its slot frees at once.
  function cancel(entry) {
    for (let i = waiting.length - 1; i >= 0; i--) if (waiting[i].entry === entry) waiting.splice(i, 1)[0].stop(aborted())
    entry.attempt?.abort()
    entry.p.catch(() => {})
  }

  /** The author's mesh vaults from their newest 10063; [] when they list none. One query per author. */
  function authorVaults(pubkey) {
    if (!SHA256.test(String(pubkey ?? ""))) return Promise.resolve([])
    let p = lists.get(pubkey)
    if (!p) {
      p = query(relays, { kinds: [10063], authors: [pubkey] }, { maxWait: 4000 })
        .then(evs => meshVaults((evs ?? []).filter(e => e?.kind === 10063 && e.pubkey === pubkey).sort((a, b) => b.created_at - a.created_at)[0]).slice(0, MAX_VAULTS))
        .catch(() => [])
      lists.set(pubkey, p)
    }
    return p
  }

  /** Where a media item's image is on the mesh: its .fips link, else its imeta hash on the author's mesh vaults.
   *  Undefined when it has none. Reads a 10063 at most; no FIPS. */
  async function source(item, author) {
    const ref = fipsRef(item.url)
    if (ref) return { vaults: [ref.vault], sha256: ref.sha256 }
    if (!item.x) return undefined
    const vaults = await authorVaults(author)
    return vaults.length ? { vaults, sha256: item.x } : undefined
  }

  /** A media item's image from the mesh (see source). Rejects when the author may not use the mesh (allow), the
   *  item has no mesh source, or none answers. */
  async function fallback(item, author, opts) {
    if (!allow(author)) throw new Error("not from someone you follow")
    const src = await source(item, author)
    if (!src) throw new Error(fipsRef(item.url) || item.x ? "no mesh vault" : "no hash")
    return photo(src.vaults, src.sha256, opts)
  }

  return { photo, authorVaults, source, fallback, allowed }
}

async function defaultReader(opts) {
  const { startPhotoReader } = await import("../../../web-relay/src/fips/photo-reader.js")
  return startPhotoReader(opts)
}

let shared
/** The page's one loader (one reader, one cache). */
export const fipsMedia = () => (shared ??= createFipsMedia())
