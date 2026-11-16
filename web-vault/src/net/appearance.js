// Settings › Appearance › Mode: Dark (the default, the app's one look until now), Light (warm paper, PLANS/
// NV_LIGHT_MODE_AND_CUSTOM_COLORS.md) or Auto (follows the device). Kept in this browser. The page carries the
// answer as <html data-theme="light">, which styles/light.css keys on; public/theme-boot.js sets it before paint.

export const APPEARANCE_KEY = "display.appearance"
export const APPEARANCE_CHOICES = ["dark", "light", "auto"]
export const APPEARANCE_DEFAULT = "dark"
export const APPEARANCE_LABELS = { dark: "Dark", light: "Light", auto: "Auto" }
import { accent, paper } from "./accent.js"

// The page colour per mode, for the browser's own bars (<meta name="theme-color">). Same as --bg in each mode: Light's
// paper carries 5% of the accent.
const bar = (mode, storage) => (mode === "light" ? paper(accent(storage)) : "#000000")

const listeners = new Set()

/** The saved choice; anything that isn't one of the choices is the default. */
export function appearance(storage = globalThis.localStorage) {
  try {
    const v = storage?.getItem?.(APPEARANCE_KEY)
    return APPEARANCE_CHOICES.includes(v) ? v : APPEARANCE_DEFAULT
  } catch { return APPEARANCE_DEFAULT }
}

/** "light" or "dark": what the page shows for a choice. Auto asks the device. */
export function resolveAppearance(choice, win = globalThis) {
  if (choice === "light" || choice === "dark") return choice
  return win?.matchMedia?.("(prefers-color-scheme: light)")?.matches ? "light" : "dark"
}

// The Web of Trust always draws Dark (Logen 2026-11-16): while a WoT screen is up (holdDark), the whole page paints
// dark, so the tab bar, menus and buttons around the globe stay readable. Light comes back when the last one closes.
let darkHolds = 0
export const darkHeld = () => darkHolds > 0

/** Paints the page dark until the returned release is called (once). WotScreen and the WoT napplet pane hold it. */
export function holdDark(win = globalThis) {
  darkHolds++
  repaint(win)
  let done = false
  return () => {
    if (done) return
    done = true
    darkHolds--
    repaint(win)
  }
}
const repaint = win => paintAppearance(resolveAppearance(appearance(win?.localStorage), win), win?.document, win?.localStorage)

/** Puts a resolved mode on the page: the data-theme attribute and the browser bar colour. A dark hold wins. */
export function paintAppearance(mode, doc = globalThis.document, storage = globalThis.localStorage) {
  if (!doc?.documentElement) return
  if (darkHolds > 0) mode = "dark"
  if (mode === "light") doc.documentElement.dataset.theme = "light"
  else delete doc.documentElement.dataset.theme
  doc.querySelector?.('meta[name="theme-color"]')?.setAttribute("content", bar(mode, storage))
}

export function setAppearance(choice, storage = globalThis.localStorage, win = globalThis) {
  const v = APPEARANCE_CHOICES.includes(choice) ? choice : APPEARANCE_DEFAULT
  try { storage?.setItem?.(APPEARANCE_KEY, v) } catch {}
  paintAppearance(resolveAppearance(v, win), win?.document, storage)
  listeners.forEach(f => f(v))
}

export function onAppearance(fn) { listeners.add(fn); return () => listeners.delete(fn) }

/** At startup: paints the saved mode, and on Auto follows the device when it switches (sunset, Control Centre). */
export function startAppearance(win = globalThis) {
  const paint = () => repaint(win)
  paint()
  win?.matchMedia?.("(prefers-color-scheme: light)")?.addEventListener?.("change", () => { if (appearance(win?.localStorage) === "auto") paint() })
  // Another tab changed it.
  win?.addEventListener?.("storage", e => { if (e.key === APPEARANCE_KEY) paint() })
}
