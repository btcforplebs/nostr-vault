// Settings › Feed Text (iPhone AppearanceSettingsView): how many lines of text a post shows before it is cut off.
// Threaded View 5 by default, 1 to 12 (HavenConfig.threadedLineLimit); a reply shows one line fewer than its root
// (FeedThreadCard). Compact View is gone (2026-11-11), and its line count with it. Kept in this browser.
export const LINE_LIMITS = {
  threaded: { key: "display.threadedLineLimit", fallback: 5, title: "Threaded View" },
}
export const MIN_LINES = 1, MAX_LINES = 12

const clamp = n => Math.min(MAX_LINES, Math.max(MIN_LINES, n))

/** Lines for `view` ("threaded"): the saved whole number in range, else the default. */
export function lineLimit(view, storage = globalThis.localStorage) {
  const { key, fallback } = LINE_LIMITS[view]
  let raw = null
  try { raw = storage?.getItem?.(key) } catch {}
  const n = raw == null || String(raw).trim() === "" ? NaN : Number(raw)
  return Number.isInteger(n) && n >= MIN_LINES && n <= MAX_LINES ? n : fallback
}

export function setLineLimit(view, n, storage = globalThis.localStorage) {
  if (!Number.isFinite(n)) return
  try { storage?.setItem?.(LINE_LIMITS[view].key, String(clamp(Math.round(n)))) } catch {}
}

/** "1 line", "5 lines" (the stepper's value). */
export const linesText = n => (n === 1 ? "1 line" : `${n} lines`)
