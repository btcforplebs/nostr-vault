// Face pictures for the Web of Trust globe: each picture drawn once into a small round bitmap, and at most `max` of
// them kept, least recently drawn dropped first. A big account's follows can't grow canvas memory without limit (3,000
// follows at 96 px was ~110 MB of canvas once everyone had turned past; iPhone Safari caps a page's canvas memory).
// Entries are a bitmap, "loading" or "failed"; a dropped one is simply loaded again if its face comes back.

/** Bitmap side in pixels: 64 px is ~16 KB a face, sharp for a follow's face on a 3x screen. */
export const FACE_PX = 64
/** How many bitmaps are kept. */
export const FACE_MAX = 600

/**
 * An LRU map of picture URL -> entry. `get` counts as a use and stamps the entry with the current frame. Setting past
 * `max` drops the least recently used entry that isn't still loading (a load in flight would only be started again) and
 * wasn't drawn this frame: an on-screen face is never dropped, so the cache sits over the cap while more than `max`
 * faces show, and comes back down as they leave the screen. Without that, a big screen full of faces evicts one it is
 * drawing, reloads it next frame and evicts another, forever. `frame()` starts a frame (the draw calls it first).
 * `onDrop(entry)` lets the caller free a dropped bitmap.
 */
export function faceCache({ max = FACE_MAX, onDrop = () => {} } = {}) {
  const map = new Map() // url -> { v, drawn: frame it was last drawn in }
  let now = 0
  const touch = (k, e) => { map.delete(k); map.set(k, e) }
  return {
    frame() { now++ },
    get(k) {
      const e = map.get(k)
      if (!e) return undefined
      e.drawn = now
      touch(k, e)
      return e.v
    },
    set(k, v) {
      const e = { v, drawn: now }
      touch(k, e)
      if (map.size <= max) return
      for (const [old, entry] of map) {
        if (map.size <= max) break
        if (entry.v === "loading" || entry.drawn === now || old === k) continue
        map.delete(old); onDrop(entry.v)
      }
    },
    get size() { return map.size },
    has: k => map.has(k),
  }
}
