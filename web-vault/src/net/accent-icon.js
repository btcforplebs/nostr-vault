// The tab icon (favicon) and the iPhone home-screen icon follow the accent, live (Logen 2026-11-17, all platforms).
// The web can tint to the exact colour, so unlike the phone apps it does not snap to the nearest preset. Only the
// accent parts of public/icon.svg change: the doorway glow and the two outlines, from the accent A and its "hi" shade
// (RESEARCH/NV_ACCENT_ICONS/README.md: the same HLS lightness and saturation step as the app's #E67326 -> #FA9447).
// The default orange leaves the file icons alone. The tinted SVG is also saved so public/theme-boot.js can set it
// before the app loads. The installed PWA's manifest icon is fixed at install time and stays the app's own icon.
import { ACCENT_DEFAULT, accent, normalizeHex, onAccent } from "./accent.js"

export const ICON_KEY = "display.accentIcon"
const TOUCH_SIZE = 180

// ---- colour maths (HLS, as Python's colorsys, which made the art) -------------------------------------------------

function toHls([r, g, b]) {
  r /= 255; g /= 255; b /= 255
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2
  if (mx === mn) return [0, l, 0]
  const d = mx - mn
  const s = l <= 0.5 ? d / (mx + mn) : d / (2 - mx - mn)
  const rc = (mx - r) / d, gc = (mx - g) / d, bc = (mx - b) / d
  let h = r === mx ? bc - gc : g === mx ? 2 + rc - bc : 4 + gc - rc
  h = ((h / 6) % 1 + 1) % 1
  return [h, l, s]
}
function fromHls([h, l, s]) {
  if (s === 0) return [l, l, l].map(v => v * 255)
  const m2 = l <= 0.5 ? l * (1 + s) : l + s - l * s, m1 = 2 * l - m2
  const v = hue => {
    hue = ((hue % 1) + 1) % 1
    if (hue < 1 / 6) return m1 + (m2 - m1) * hue * 6
    if (hue < 0.5) return m2
    if (hue < 2 / 3) return m1 + (m2 - m1) * (2 / 3 - hue) * 6
    return m1
  }
  return [v(h + 1 / 3), v(h), v(h - 1 / 3)].map(x => x * 255)
}
const clamp = x => Math.min(1, Math.max(0, x))
const rgbOf = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16))
const hexOf = c => "#" + c.map(x => Math.round(x).toString(16).padStart(2, "0")).join("")

// The art's step from the app's orange to its lighter shade (make_icons.py measures it the same way).
const [, L0, S0] = toHls(rgbOf("#e67326")), [, L1, S1] = toHls(rgbOf("#fa9447"))
const DL = L1 - L0, DS = S1 - S0

/** The accent and its lighter "hi" shade, as the icon art uses them. */
export function iconShades(hex) {
  const a = normalizeHex(hex) ?? ACCENT_DEFAULT
  if (a === ACCENT_DEFAULT) return { a, hi: "#fa9447" }
  const [h, l, s] = toHls(rgbOf(a))
  return { a, hi: hexOf(fromHls([h, clamp(l + DL), clamp(s + DS)])) }
}

/** public/icon.svg with its orange swapped for [hex]; the text unchanged for the default. */
export function tintIconSvg(svg, hex) {
  const { a, hi } = iconShades(hex)
  if (a === ACCENT_DEFAULT) return svg
  return svg.replace(/#e67326/gi, a).replace(/#fa9447/gi, hi)
}

export const svgDataUrl = svg => "data:image/svg+xml," + encodeURIComponent(svg)

// ---- painting ------------------------------------------------------------------------------------------------------

let template = null
async function iconTemplate(doc) {
  if (!template) {
    const url = new URL("./icon.svg", doc.baseURI)
    template = fetch(url).then(r => (r.ok ? r.text() : Promise.reject(new Error(String(r.status)))))
    template.catch(() => { template = null })
  }
  return template
}

/** Points the tab icon (and, given a PNG, the home-screen icon) at [href]; null puts the files back. */
export function paintIcon(href, touchHref, doc = globalThis.document) {
  const icon = doc?.querySelector?.('link[rel="icon"]')
  const touch = doc?.querySelector?.('link[rel="apple-touch-icon"]')
  icon?.setAttribute("href", href ?? "./icon.svg")
  touch?.setAttribute("href", touchHref ?? "./icon-180.png")
}

/** The iPhone home-screen icon wants a PNG: draws the tinted SVG at 180 px. Null where there is no canvas. */
function touchPng(href, doc) {
  return new Promise(resolve => {
    try {
      const img = new Image()
      img.onload = () => {
        try {
          const c = doc.createElement("canvas")
          c.width = c.height = TOUCH_SIZE
          c.getContext("2d").drawImage(img, 0, 0, TOUCH_SIZE, TOUCH_SIZE)
          resolve(c.toDataURL("image/png"))
        } catch { resolve(null) }
      }
      img.onerror = () => resolve(null)
      img.src = href
    } catch { resolve(null) }
  })
}

let latest = 0
export async function applyIcon(hex, { doc = globalThis.document, storage = globalThis.localStorage } = {}) {
  const pick = normalizeHex(hex) ?? ACCENT_DEFAULT
  const run = ++latest
  if (pick === ACCENT_DEFAULT) {
    try { storage?.removeItem?.(ICON_KEY) } catch {}
    paintIcon(null, null, doc)
    return
  }
  let svg
  try { svg = tintIconSvg(await iconTemplate(doc), pick) } catch { return }
  if (run !== latest) return
  const href = svgDataUrl(svg)
  try { storage?.setItem?.(ICON_KEY, href) } catch {}
  paintIcon(href, null, doc)
  const png = await touchPng(href, doc)
  if (run === latest && png) paintIcon(href, png, doc)
}

/** At startup: the icon for the saved accent, then every change (this tab or another). */
export function startAccentIcon(win = globalThis) {
  const doc = win?.document
  if (!doc) return
  const now = accent(win.localStorage)
  if (now !== ACCENT_DEFAULT || win.localStorage?.getItem?.(ICON_KEY)) applyIcon(now, { doc, storage: win.localStorage })
  onAccent(hex => applyIcon(hex, { doc, storage: win.localStorage }))
  win.addEventListener?.("storage", e => { if (e.key === "display.accent") applyIcon(accent(win.localStorage), { doc, storage: win.localStorage }) })
}

