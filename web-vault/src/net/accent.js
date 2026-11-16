// Settings › Appearance › Accent: the app's orange, one of eight ready-made colours, or any colour from the wheel
// (PLANS/NV_LIGHT_MODE_AND_CUSTOM_COLORS.md). Kept in this browser. The default paints nothing: tokens.css and
// light.css already are the orange. Any other colour becomes one <style id="nv-accent"> with a dark set and a light
// set, also saved as text so public/theme-boot.js can put it in before the first paint.
//
// Dark mode is neon: the same hue pushed to the most colour sRGB allows, made lighter only as far as text needs to
// read on a card (neon()); buttons and text both use it. Light mode uses the colour exactly as picked for buttons and
// fills; only accent text (--accent-text: #tags, links) is darkened, and only for colours too pale to read on white
// (under 3.5:1, e.g. gold, green, teal, orange), until it reads at 4.5:1.

export const ACCENT_KEY = "display.accent"
export const ACCENT_CSS_KEY = "display.accentCss"
export const ACCENT_DEFAULT = "#e67326"
/** The ready-made row, orange first: three anchors (the app's orange, Nostr purple from the Nostr logo, Android
 *  green) and the colours around them. Light shows these exactly; Dark shows neon() of each. */
export const ACCENT_PRESETS = [
  { hex: "#e67326", name: "Orange" },
  { hex: "#ffb800", name: "Gold" },
  { hex: "#3ddc84", name: "Green" },
  { hex: "#00c2b8", name: "Teal" },
  { hex: "#2e7dff", name: "Blue" },
  { hex: "#662482", name: "Nostr purple" },
  { hex: "#ff2d87", name: "Pink" },
  { hex: "#a8071a", name: "Blood red" },
]
const CARD_DARK = "#1c1c1e" // --s1 in dark: text in the accent sits on cards
const WHITE = "#ffffff"
const TEXT_MIN = 4.5 // WCAG body text
const LIGHT_TEXT_KEEP = 3.5 // Light keeps the exact colour as text at or above this on white; under it, text is darkened
const LABEL_MIN = 3 // a bold label on a fill (WCAG large text): keeps today's white on orange

// ---- colour maths -----------------------------------------------------------------------------------------------

export function normalizeHex(v) {
  const m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(String(v ?? "").trim())
  if (!m) return null
  const h = m[1].length === 3 ? [...m[1]].map(c => c + c).join("") : m[1]
  return "#" + h.toLowerCase()
}
const rgbOf = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16))
const hexOf = rgb => "#" + rgb.map(v => Math.round(Math.min(255, Math.max(0, v))).toString(16).padStart(2, "0")).join("")
const lin = c => { c /= 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4 }
const unlin = c => 255 * (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055)

export function luminance(hex) {
  const [r, g, b] = rgbOf(normalizeHex(hex) ?? "#000000").map(lin)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}
export function contrast(a, b) {
  const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p)
  return (x + 0.05) / (y + 0.05)
}

// OKLab (Björn Ottosson): changing only L keeps the hue and how colourful it looks.
function toLab(hex) {
  const [r, g, b] = rgbOf(hex).map(lin)
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  return [0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s, 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s, 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s]
}
function fromLab([L, A, B]) {
  const l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3
  const m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3
  const s = (L - 0.0894841775 * A - 1.291485548 * B) ** 3
  return hexOf([4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s, -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s, -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s].map(c => unlin(Math.min(1, Math.max(0, c)))))
}
/** The colour moved lighter (dir 1) or darker (-1) in small steps until it reads at `min` on `bg`. */
export function readableOn(hex, bg, min, dir) {
  if (contrast(hex, bg) >= min) return hex
  const [L, A, B] = toLab(hex)
  for (let i = 1; i <= 100; i++) {
    const next = fromLab([Math.min(1, Math.max(0, L + dir * i * 0.01)), A, B])
    if (contrast(next, bg) >= min) return next
  }
  return dir < 0 ? "#000000" : WHITE
}
const shade = (hex, dL) => { const [L, A, B] = toLab(hex); return fromLab([Math.min(1, Math.max(0, L + dL)), A, B]) }

// OKLCH (OKLab as lightness, chroma, hue) for neon(): the most chroma sRGB holds at a lightness and hue.
const labRgb = ([L, A, B]) => {
  const l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3
  const m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3
  const s = (L - 0.0894841775 * A - 1.291485548 * B) ** 3
  return [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s, -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s, -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s]
}
const lchLab = (L, C, H) => [L, C * Math.cos(H), C * Math.sin(H)]
function maxChroma(L, H) {
  let lo = 0, hi = 0.4
  for (let i = 0; i < 30; i++) {
    const mid = (lo + hi) / 2
    if (labRgb(lchLab(L, mid, H)).every(c => c >= -1e-4 && c <= 1 + 1e-4)) lo = mid; else hi = mid
  }
  return lo
}
/** Dark mode's neon of a colour: its hue at (nearly) the most chroma sRGB allows, at the darkest lightness from
 *  max(its own, 0.55) up that reads 4.5:1 on the dark card. Greys have no hue to push, so they only get lighter. */
export function neon(hex) {
  const pick = normalizeHex(hex) ?? ACCENT_DEFAULT
  const [L0, A, B] = toLab(pick)
  const C0 = Math.hypot(A, B), H = Math.atan2(B, A)
  if (C0 < 0.03) return readableOn(pick, CARD_DARK, TEXT_MIN, 1)
  const start = Math.max(L0, 0.55)
  for (let i = 0; start + i * 0.005 <= 0.95; i++) {
    const L = start + i * 0.005, max = maxChroma(L, H)
    const c = fromLab(lchLab(L, Math.min(max, Math.max(C0, max * 0.97)), H))
    if (contrast(c, CARD_DARK) >= TEXT_MIN) return c
  }
  return fromLab(lchLab(0.95, maxChroma(0.95, H), H))
}

/** White or black for a label on a fill of this colour: white whenever it reads as a bold label. */
export const labelOn = hex => (contrast(WHITE, hex) >= LABEL_MIN ? "#fff" : "#000")

/** Every accent token for both modes, from one colour. --accent is the fill (buttons, rings, borders), --accent-text
 *  the colour for text. */
export function accentTokens(hex) {
  const pick = normalizeHex(hex) ?? ACCENT_DEFAULT
  const glow = neon(pick)
  const lightText = contrast(pick, WHITE) >= LIGHT_TEXT_KEEP ? pick : readableOn(pick, WHITE, TEXT_MIN, -1)
  // The fill's light end: a touch lighter, unless that would fade a white label under 3:1.
  const lift = shade(pick, 0.08)
  const lightEnd = labelOn(pick) === "#000" || contrast(WHITE, lift) >= LABEL_MIN ? lift : pick
  return {
    dark: { "--accent": glow, "--accent-text": glow, "--accent-rgb": rgbOf(glow).join(" "), "--accent-light": shade(glow, 0.08), "--accent-dark": shade(glow, -0.12), "--on-accent": labelOn(glow) },
    light: { "--bg": paper(pick), "--accent": pick, "--accent-text": lightText, "--accent-rgb": rgbOf(pick).join(" "), "--accent-light": lightEnd, "--accent-dark": shade(pick, -0.1), "--on-accent": labelOn(pick) },
  }
}

/** Light mode's page colour: the warm paper with 5% of the picked accent (light.css --bg does the same in CSS). */
export const PAPER = "#f6f1eb"
export const PAPER_TINT = 0.05
export function paper(hex) {
  const a = rgbOf(PAPER), b = rgbOf(normalizeHex(hex) ?? ACCENT_DEFAULT)
  return hexOf(a.map((v, i) => v + (b[i] - v) * PAPER_TINT))
}

const block = (sel, t) => `${sel} { ${Object.entries(t).map(([k, v]) => `${k}: ${v};`).join(" ")} }`
/** The stylesheet for a colour; empty for the default (the CSS files already are the orange). `html` in front of
 *  each selector outranks tokens.css and light.css whatever order the sheets load in; the trust globe's dark
 *  island (data-theme="dark" inside the page) gets the dark set, and the picker's light preview the light one. */
export function accentCss(hex) {
  const pick = normalizeHex(hex)
  if (!pick || pick === ACCENT_DEFAULT) return ""
  const t = accentTokens(pick)
  return block('html:root, html [data-theme="dark"]', t.dark) + "\n" + block('html:root[data-theme="light"], html [data-theme="light"]', t.light)
}

// ---- the setting --------------------------------------------------------------------------------------------------

const listeners = new Set()
export function accent(storage = globalThis.localStorage) {
  try { return normalizeHex(storage?.getItem?.(ACCENT_KEY)) ?? ACCENT_DEFAULT } catch { return ACCENT_DEFAULT }
}
export function paintAccent(css, doc = globalThis.document) {
  if (!doc?.head) return
  let el = doc.getElementById("nv-accent")
  if (!css) { el?.remove(); return }
  if (!el) { el = doc.createElement("style"); el.id = "nv-accent"; doc.head.appendChild(el) }
  el.textContent = css
}
export function setAccent(hex, storage = globalThis.localStorage, doc = globalThis.document) {
  const pick = normalizeHex(hex) ?? ACCENT_DEFAULT
  const css = accentCss(pick)
  try {
    storage?.setItem?.(ACCENT_KEY, pick)
    if (css) storage?.setItem?.(ACCENT_CSS_KEY, css)
    else storage?.removeItem?.(ACCENT_CSS_KEY)
  } catch {}
  paintAccent(css, doc)
  // Light's page (and so the browser bar) carries 5% of the accent.
  if (doc?.documentElement?.dataset?.theme === "light") doc.querySelector?.('meta[name="theme-color"]')?.setAttribute("content", paper(pick))
  listeners.forEach(f => f(pick))
}
export function onAccent(fn) { listeners.add(fn); return () => listeners.delete(fn) }
/** At startup: rebuilds the sheet from the saved colour (the boot copy may be from an older build). */
export function startAccent(win = globalThis) {
  const css = accentCss(accent(win?.localStorage))
  try { if (css) win?.localStorage?.setItem?.(ACCENT_CSS_KEY, css) } catch {}
  paintAccent(css, win?.document)
  win?.addEventListener?.("storage", e => { if (e.key === ACCENT_KEY) paintAccent(accentCss(accent(win.localStorage)), win.document) })
}
