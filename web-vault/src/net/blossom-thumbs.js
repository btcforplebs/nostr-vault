// Small copies of your Blossom pictures for the Vault › Media grid. Each tile drew the full-size original, every visit:
// Blossom files live on other hosts, which sw.js doesn't cache. Now a picture is fetched once, drawn down to THUMB_PX on
// its long side and kept in Cache Storage under its sha256 (a Blossom file never changes under its hash, so a kept copy
// never goes stale). The next visit draws it from there with no network. Anything that can't be made small (a server
// without CORS, a format the browser can't decode, no Cache Storage) gets null, and the tile shows the original as before.
// Blossom has no thumbnail endpoint (BUD-01 serves the file itself), so there is no server copy to ask for.

/** Long side of a kept copy in pixels: a grid tile is ~130 CSS px, so 320 is sharp on a 2x-3x screen. */
export const THUMB_PX = 320
/** How many copies are kept (~20 KB each); the oldest kept goes first past it. */
export const THUMB_MAX = 1500
export const THUMB_CACHE = "nv-blossom-thumbs-v1"
/** Pictures fetched at once on a first visit, so a long grid doesn't open every original together. */
const AT_ONCE = 4

const keyOf = sha => `https://nv-thumb.invalid/${sha}`

/** `blob` (a picture file) drawn down to `px` on its long side, as WebP (JPEG where WebP can't be written), or null. */
export async function shrinkImage(blob, px = THUMB_PX) {
  try {
    const bmp = await createImageBitmap(blob)
    const scale = Math.min(1, px / Math.max(bmp.width, bmp.height))
    const w = Math.max(1, Math.round(bmp.width * scale)), h = Math.max(1, Math.round(bmp.height * scale))
    const canvas = typeof OffscreenCanvas === "function" ? new OffscreenCanvas(w, h) : Object.assign(document.createElement("canvas"), { width: w, height: h })
    const g = canvas.getContext("2d")
    g.imageSmoothingQuality = "high"
    g.drawImage(bmp, 0, 0, w, h)
    bmp.close?.()
    const encode = type => canvas.convertToBlob ? canvas.convertToBlob({ type, quality: 0.8 }) : new Promise(r => canvas.toBlob(r, type, 0.8))
    let out = await encode("image/webp")
    if (out?.type !== "image/webp") out = await encode("image/jpeg")
    return out || null
  } catch { return null }
}

/**
 * `get(blob)` -> the small copy (a Blob) of a picture `{ sha256, url, kind }`, or null to show the original. Kept copies
 * come from Cache Storage; a miss fetches the original once (AT_ONCE at a time, one fetch per hash), shrinks and keeps it.
 * A copy no smaller than the original keeps the original's bytes. GIFs and videos are left alone (a still frame would
 * stop a GIF moving; videos draw their own frame).
 */
export function thumbStore({ cacheStorage = globalThis.caches, fetchFn = (...a) => fetch(...a), shrink = shrinkImage, max = THUMB_MAX } = {}) {
  const loading = new Map() // sha256 -> Promise<Blob|null>
  let active = 0
  const waiting = []
  const slot = () => active < AT_ONCE ? (active++, Promise.resolve()) : new Promise(r => waiting.push(r))
  const free = () => { const next = waiting.shift(); next ? next() : active-- }
  let open = null
  const cache = () => (open ||= cacheStorage.open(THUMB_CACHE))

  async function make(blob) {
    const c = await cache()
    const hit = await c.match(keyOf(blob.sha256))
    if (hit) return hit.blob()
    await slot()
    try {
      const res = await fetchFn(blob.url, { mode: "cors" })
      if (!res.ok) return null
      const original = await res.blob()
      const small = await shrink(original, THUMB_PX)
      if (!small) return null
      const kept = small.size < original.size ? small : original
      await c.put(keyOf(blob.sha256), new Response(kept, { headers: { "Content-Type": kept.type || original.type } }))
      const keys = await c.keys()
      for (const k of keys.slice(0, Math.max(0, keys.length - max))) await c.delete(k)
      return kept
    } finally { free() }
  }

  return {
    get(blob) {
      if (!cacheStorage || blob?.kind !== "photo" || !blob.sha256 || !blob.url) return Promise.resolve(null)
      if (!loading.has(blob.sha256)) {
        const p = make(blob).catch(() => null)
        loading.set(blob.sha256, p)
        p.then(() => loading.delete(blob.sha256))
      }
      return loading.get(blob.sha256)
    },
  }
}
