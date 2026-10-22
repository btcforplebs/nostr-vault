// The page server's copy of share-page mesh photos: one warm FIPS photo reader (web-relay src/fips/photo-reader.js,
// a throwaway key, the public seeds only) reads the shared post's photo by hash from the vault its author's 10063
// names, and keeps the hash-checked bytes, so a repeat visit shows the photo from GET /thread/photo/<sha256> in a
// moment instead of a fresh mesh read. The browser's own mesh read (share-photos.js) stays the fallback.
// Only what a page build armed is ever read, from only that post's vaults. An entry is served only while a page
// build has confirmed it lately (CHECK_TTL_MS): the post still there, not deleted, its author's newest 10063 still
// naming the vault. A build that finds otherwise drops it at once, so a deleted photo stays deleted.

const HEX = /^[0-9a-f]{64}$/
export const MAX_PHOTO_BYTES = 16 * 1024 * 1024 // same cap as the browser read (share-photos.js)
export const MAX_TOTAL_BYTES = 128 * 1024 * 1024
export const CHECK_TTL_MS = 15 * 60_000 // longer than the page cache (10 min), so a cached page's photo still serves
export const MAX_AGE_MS = 24 * 60 * 60_000
export const READ_TIMEOUT_MS = 45_000 // per vault, as in the browser
export const MAX_READS = 2
export const MAX_QUEUED = 20
export const WAIT_MS = 30_000 // a request for a photo still being read waits this long for it

/**
 * `startReader(getPhotoVaults)` starts the photo reader (tests pass a fake); it is started once and kept warm, and
 * started again after a failure. `clock` is for tests.
 */
export function createPhotoCache({
  startReader,
  clock = () => Date.now(),
  limits: { photoBytes = MAX_PHOTO_BYTES, totalBytes = MAX_TOTAL_BYTES, checkTtl = CHECK_TTL_MS, maxAge = MAX_AGE_MS,
    reads = MAX_READS, queued = MAX_QUEUED, timeoutMs = READ_TIMEOUT_MS } = {},
} = {}) {
  const photos = new Map() // sha256 -> { bytes, type, from: vault, notes: Map<noteId, vaults>, checkedAt, storedAt }
  const pending = new Map() // sha256 -> { notes: Map<noteId, vaults>, done: Promise }
  const allowed = new Set() // the vaults a read is asking right now: the reader drops anyone else
  const queue = []
  let reader, running = 0, total = 0

  const getReader = () => (reader ??= Promise.resolve().then(() => startReader(() => allowed)).catch(e => { reader = undefined; throw e }))

  function forget(x) {
    const e = photos.get(x)
    if (!e) return
    total -= e.bytes.length
    photos.delete(x)
  }

  function keep(x, got, notes, from) {
    forget(x)
    while (photos.size && total + got.bytes.length > totalBytes) forget(photos.keys().next().value) // oldest first
    const now = clock()
    photos.set(x, { bytes: got.bytes, type: got.type || "application/octet-stream", from, notes, checkedAt: now, storedAt: now })
    total += got.bytes.length
  }

  async function readOne(x, job) {
    const r = await getReader()
    const vaults = [...new Set([...job.notes.values()].flat())]
    // A note whose vaults no longer include this one (sync while it read) doesn't keep what it serves.
    const named = vault => new Map([...job.notes].filter(([, vs]) => vs.includes(vault)))
    for (const vault of vaults) {
      if (!job.notes.size) return // every note that named it was dropped while it waited
      allowed.add(vault)
      try {
        const got = await r.getBlob(vault, x, { timeoutMs })
        if (got.bytes.length > photoBytes) continue
        const notes = named(vault)
        if (notes.size) keep(x, got, notes, vault)
        return
      } catch { /* the next vault */ } finally { allowed.delete(vault) }
    }
  }

  function next() {
    while (running < reads && queue.length) {
      const { x, job, done } = queue.shift()
      running++
      readOne(x, job).catch(() => { reader = undefined }).finally(() => {
        running--
        pending.delete(x)
        done()
        next()
      })
    }
  }

  /**
   * A page build found post `noteId` with photo hashes `xs`, its author's 10063 naming `vaults` (x-only hex): confirm
   * what is kept for it, drop what no longer holds, and read over the mesh what isn't kept yet.
   */
  function sync(noteId, xs, vaults) {
    const want = new Set(xs.filter(x => HEX.test(x)))
    const vs = vaults.filter(v => HEX.test(v))
    if (!want.size || !vs.length) return drop(noteId)
    for (const [x, e] of photos) if (e.notes.has(noteId) && !want.has(x)) unlink(x, e, noteId)
    for (const [x, p] of pending) if (p.notes.has(noteId) && !want.has(x)) p.notes.delete(noteId)
    const now = clock()
    for (const x of want) {
      const e = photos.get(x)
      if (e) {
        // Kept from a vault this note's 10063 no longer names: this note no longer vouches for it.
        if (!vs.includes(e.from)) { unlink(x, e, noteId); if (!photos.has(x)) arm(x, noteId, vs); continue }
        e.notes.set(noteId, vs)
        e.checkedAt = now
        continue
      }
      arm(x, noteId, vs)
    }
  }

  function arm(x, noteId, vs) {
    const p = pending.get(x)
    if (p) { p.notes.set(noteId, vs); return }
    if (queue.length >= queued) return
    const job = { notes: new Map([[noteId, vs]]) }
    job.done = new Promise(done => queue.push({ x, job, done }))
    pending.set(x, job)
    next()
  }

  function unlink(x, e, noteId) {
    e.notes.delete(noteId)
    if (!e.notes.size) forget(x)
  }

  /** The post is gone, deleted, or its author's 10063 no longer names a vault: nothing of it is kept or read. */
  function drop(noteId) {
    for (const [x, e] of [...photos]) if (e.notes.has(noteId)) unlink(x, e, noteId)
    for (const p of pending.values()) p.notes.delete(noteId)
  }

  /** The kept photo `x` if a page build confirmed it lately: { bytes, type }, else undefined. */
  function get(x) {
    const e = photos.get(x)
    if (!e) return undefined
    const now = clock()
    if (now - e.storedAt > maxAge) { forget(x); return undefined }
    if (now - e.checkedAt > checkTtl) return undefined
    return { bytes: e.bytes, type: e.type }
  }

  /** As get, but waits up to `ms` for a read of `x` in flight. */
  async function lookup(x, ms = WAIT_MS) {
    if (!HEX.test(x)) return undefined
    const p = pending.get(x)
    if (!get(x) && p) {
      let t
      await Promise.race([p.done, new Promise(r => { t = setTimeout(r, ms); t.unref?.() })])
      clearTimeout(t)
    }
    return get(x)
  }

  return {
    sync, drop, get, lookup,
    /** Starts the reader now, so the first photo doesn't wait for the seed handshake. */
    warm: () => getReader().catch(() => {}),
    stats: () => ({ photos: photos.size, bytes: total, pending: pending.size, running, queued: queue.length }),
    stop: async () => { const r = reader; reader = undefined; await r?.then(x => x.stop?.()).catch(() => {}) },
  }
}
