// The Vault's Media tab as a mosaic (the web twin of Apple's MediaMosaicLayout.swift, PR 2193): each photo or video
// keeps its own shape in fixed-width columns, each tile going to the shortest column so far, and each tile's height
// known before any pixels load, so nothing moves when a picture arrives. A tile whose shape isn't known is square.
// Shapes come from, in order: what this browser learned from the picture before (read once when the grid goes up,
// so a shape learned now never moves a tile on screen), the file note's `dim`, and the server's NIP-94 `dim`.
// The media napplet (napplets/media/index.html) carries a copy of deal/columnsFor in its pure block.

/** Narrowest shape a tile may take (width / height): twice as tall as wide. Widest: twice as wide as tall. */
export const MIN_ASPECT = 0.5, MAX_ASPECT = 2

/** `aspect` limited to what a tile may show; 1 (square) when unknown. */
export const clampAspect = a => (Number.isFinite(a) && a > 0 ? Math.min(Math.max(a, MIN_ASPECT), MAX_ASPECT) : 1)

/** width / height from a `dim` value such as "1920x1080"; null when it isn't one. */
export function aspectFromDim(dim) {
  const m = /^\s*(\d+(?:\.\d+)?)\s*x\s*(\d+(?:\.\d+)?)\s*$/i.exec(typeof dim === "string" ? dim : "")
  if (!m) return null
  const w = Number(m[1]), h = Number(m[2])
  return w > 0 && h > 0 ? w / h : null
}

/** Columns for a grid `width` px wide: 3 on a phone, as on the iPhone; more as it widens (iPad 3-6, Mac 4). */
export const columnsFor = width => (width < 600 ? 3 : width < 900 ? 4 : width < 1200 ? 5 : 6)

/**
 * `items` dealt into `columns` columns, each to the shortest so far (ties to the leftmost, so the first ones read
 * across the top row in order). Order within a column is kept, and adding items at the end never moves the ones
 * placed before them. `aspectOf(item)` -> width / height or null (square). -> [[item]]
 */
export function deal(items, columns, aspectOf) {
  const n = Math.max(1, columns | 0), cols = Array.from({ length: n }, () => []), filled = new Array(n).fill(0)
  for (const item of items) {
    let s = 0
    for (let i = 1; i < n; i++) if (filled[i] < filled[s] - 1e-4) s = i
    cols[s].push(item)
    filled[s] += 1 / clampAspect(aspectOf(item)) + 0.03 // unit-width heights plus the gap: widths cancel out
  }
  return cols
}

// Shapes learned from pictures that loaded, by file hash, written in batches. A grid reads them once when it is put on
// screen (shapesNow), so one learned while it is up never moves a tile there; the next visit to the tab uses it.
const KEY = "nv-media-shapes", CAP = 3000, FLUSH_MS = 1500
let pending = null, timer = 0
const read = store => { try { const o = JSON.parse(store?.getItem(KEY) ?? "{}"); return o && typeof o === "object" && !Array.isArray(o) ? o : {} } catch { return {} } }

/** The shapes learned so far (saved and waiting): hash -> width / height. */
export function shapesNow(store = globalThis.localStorage) {
  const all = new Map(Object.entries(read(store)).filter(([, a]) => Number.isFinite(a) && a > 0))
  for (const [k, a] of pending ?? []) all.set(k, a)
  return all
}

/** Keep the shape of a picture that loaded (`w` x `h` px) for the next visit; this one's tiles don't change. */
export function learnShape(sha256, w, h, store = globalThis.localStorage) {
  if (!/^[0-9a-f]{64}$/.test(sha256 ?? "") || !(w > 0) || !(h > 0)) return
  ;(pending ??= new Map()).set(sha256, Math.round(w / h * 1000) / 1000)
  if (!timer) { timer = setTimeout(() => flush(store), FLUSH_MS); timer.unref?.() }
}

/** Write what was learned (oldest dropped past CAP). */
export function flush(store = globalThis.localStorage) {
  clearTimeout(timer); timer = 0
  if (!pending?.size) return
  const all = read(store)
  for (const [k, a] of pending) { delete all[k]; all[k] = a }
  pending = null
  const keys = Object.keys(all)
  for (const k of keys.slice(0, Math.max(0, keys.length - CAP))) delete all[k]
  try { store?.setItem(KEY, JSON.stringify(all)) } catch {}
}

/** For tests: forget anything waiting. */
export const _resetShapes = () => { pending = null; clearTimeout(timer); timer = 0 }

/** A file's shape before it loads: learned before this grid went up (`shapes`, from shapesNow), then its own `dim`. */
export const shapeOf = (blob, shapes) => shapes?.get(blob?.sha256) ?? aspectFromDim(blob?.dim)
