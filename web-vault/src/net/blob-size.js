// Vault › Media list (Z1): a file's size when no list or note gave one (a link in someone else's post, or a server
// that leaves `size` out). One HEAD per hash, asked only for rows on screen, remembered in this browser by sha256:
// a Blossom file's size never changes for a given hash. Only a real size is kept; a failed or sizeless answer is
// asked again next time. Twins: Apple Models/MediaSizeCache.swift + Services/MediaCache/MediaSizeLookup.swift,
// Android service/blossom/BlobSizeLookup.kt.

const KEY = "nv-blob-sizes"
/** Hashes kept (localStorage is small and shared); the oldest are asked again. */
export const SIZE_MAX = 5000
const HEX64 = /^[0-9a-f]{64}$/

/** The file size a HEAD answer gives, or null. Only a plain 200 counts: a 206 is a range's length, and a missing,
 *  zero or unparsable Content-Length is unknown, not empty. */
export function sizeFromHead(status, contentLength) {
  if (status !== 200 || contentLength == null) return null
  const s = String(contentLength).trim()
  if (!/^\d+$/.test(s)) return null
  const n = Number(s)
  return n > 0 && Number.isSafeInteger(n) ? n : null
}

/** { cached(sha), size(sha, url) } over `storage` (localStorage) and `fetch`. */
export function blobSizes({ storage = globalThis.localStorage, fetch = globalThis.fetch, timeoutMs = 5000, max = SIZE_MAX } = {}) {
  let known = null // Map sha -> size, oldest first
  const load = () => {
    if (known) return known
    try { known = new Map(JSON.parse(storage?.getItem(KEY) ?? "[]")) } catch { known = new Map() }
    return known
  }
  let saveTimer = null
  const save = () => {
    clearTimeout(saveTimer)
    saveTimer = setTimeout(() => { try { storage?.setItem(KEY, JSON.stringify([...known])) } catch {} }, 0)
  }
  const inFlight = new Map()

  const cached = sha => load().get(String(sha).toLowerCase()) ?? null

  async function size(sha, url) {
    const key = String(sha ?? "").toLowerCase()
    if (!HEX64.test(key) || !/^https?:\/\//i.test(url ?? "")) return null
    const have = cached(key)
    if (have) return have
    if (inFlight.has(key)) return inFlight.get(key)
    const ask = (async () => {
      try {
        const res = await fetch(url, { method: "HEAD", signal: AbortSignal.timeout?.(timeoutMs) })
        return sizeFromHead(res.status, res.headers?.get?.("Content-Length"))
      } catch { return null }
    })()
    inFlight.set(key, ask)
    const n = await ask
    inFlight.delete(key)
    if (n) {
      const m = load()
      m.delete(key); m.set(key, n)
      while (m.size > max) m.delete(m.keys().next().value)
      save()
    }
    return n
  }
  return { cached, size }
}

let shared = null
/** The page's one store. */
export const blobSizeStore = () => (shared ??= blobSizes())
