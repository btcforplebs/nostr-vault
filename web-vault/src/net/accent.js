// Settings › Appearance › Accent: the app's orange, one of eight ready-made colours, or any colour from the wheel
// (PLANS/NV_LIGHT_MODE_AND_CUSTOM_COLORS.md). Kept in this browser. The default paints nothing: tokens.css and
// light.css already are the orange. Any other colour becomes one <style id="nv-accent"> with a dark set and a light
// set, also saved as text so public/theme-boot.js can put it in before the first paint.
//
// Dark mode shows the colour as picked, lifted only if it would be too dark to read on a card. Light mode never puts
// a pale colour on white as text: --accent there is the colour darkened until it reads (4.5:1 on white), and the
// colour itself stays for glows (--accent-rgb) and, as far as a label allows, the light end of fills (--accent-light).

export const ACCENT_KEY = "display.accent"
export const ACCENT_CSS_KEY = "display.accentCss"
export const ACCENT_DEFAULT = "#e67326"
/** The ready-made row, orange first. Apple's system colours, so each sits well on black. */
export const ACCENT_PRESETS = [
  { hex: "#e67326", name: "Orange" },
  { hex: "#ffd60a", name: "Yellow" },
  { hex: "#30d158", name: "Green" },
  { hex: "#40c8e0", name: "Teal" },
  { hex: "#0a84ff", name: "Blue" },
  { hex: "#5e5ce6", name: "Indigo" },
  { hex: "#bf5af2", name: "Purple" },
  { hex: "#ff375f", name: "Pink" },
]
const CARD_DARK = "#1c1c1e" // --s1 in dark: text in the accent sits on cards
const WHITE = "#ffffff"
const TEXT_MIN = 4.5 // WCAG body text
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
/** White or black for a label on a fill of this colour: white whenever it reads as a bold label. */
export const labelOn = hex => (contrast(WHITE, hex) >= LABEL_MIN ? "#fff" : "#000")

/** Every accent token for both modes, from one colour. */
export function accentTokens(hex) {
  const pick = normalizeHex(hex) ?? ACCENT_DEFAULT
  const rgb = rgbOf(pick).join(" ")
  const dark = readableOn(pick, CARD_DARK, TEXT_MIN, 1)
  const lightText = readableOn(pick, WHITE, TEXT_MIN, -1)
  return {
    dark: { "--accent": dark, "--accent-rgb": rgb, "--accent-light": shade(dark, 0.08), "--accent-dark": shade(dark, -0.12), "--on-accent": labelOn(dark) },
    // The fill's light end: the colour itself only as pale as a white label can stand (3:1), so a gradient
    // button never fades its label out at one end.
    light: { "--accent": lightText, "--accent-rgb": rgb, "--accent-light": readableOn(pick, WHITE, LABEL_MIN, -1), "--accent-dark": shade(lightText, -0.1), "--on-accent": labelOn(lightText) },
  }
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
