// Face pictures for the Web of Trust globe: each picture drawn once into a small round bitmap, and at most `max` of
// them kept, least recently drawn dropped first. A big account's follows can't grow canvas memory without limit (3,000
// follows at 96 px was ~110 MB of canvas once everyone had turned past; iPhone Safari caps a page's canvas memory).
// Entries are a bitmap, "loading" or "failed"; a dropped one is simply loaded again if its face comes back.

/** Bitmap side in pixels: 64 px is ~16 KB a face, sharp for a follow's face on a 3x screen. */
export const FACE_PX = 64
/** How many bitmaps are kept. */
export const FACE_MAX = 600

/**
 * An LRU map of picture URL -> entry. `get` counts as a use. Setting past `max` drops the least recently used entry
 * that isn't still loading (a load in flight would only be started again). `onDrop(entry)` lets the caller free it.
 */
export function faceCache({ max = FACE_MAX, onDrop = () => {} } = {}) {
  const map = new Map()
  const touch = (k, v) => { map.delete(k); map.set(k, v) }
  return {
    get(k) { if (!map.has(k)) return undefined; const v = map.get(k); touch(k, v); return v },
    set(k, v) {
      touch(k, v)
      if (map.size <= max) return
      for (const [old, entry] of map) {
        if (map.size <= max) break
        if (entry === "loading" || old === k) continue
        map.delete(old); onDrop(entry)
      }
    },
    get size() { return map.size },
    has: k => map.has(k),
  }
}
