// The theme a napplet draws with (plan step 1, OUTBOX/NV_WEB_ONE_PLAN.md; design RESEARCH/NV_NAPPLET_EVERY_PAGE_PLAN.md
// §4): the shell owns it. A napplet gets NIP-5D's three colours (background, text, primary) so an outside napplet can
// follow, and inside the theme object an `nv` block: the mode and every token of styles/tokens.css as the page has it
// now (light.css and the accent already applied), plus the dark set for a dark island (the trust globe stays dark in
// Light, as the classic screen does). Sent at first paint (themeHead, in the srcdoc) and again on every change
// (onThemeChange -> theme.changed, runtime.js). Pure apart from readTheme/onThemeChange's document and window.

/** Every token in styles/tokens.css, by name (test/napplet-theme.test.mjs keeps the two lists equal). */
export const THEME_TOKENS = [
  "--bg", "--s1", "--s2", "--s3", "--accent", "--accent-rgb", "--accent-light", "--accent-dark", "--accent-pale", "--accent-line",
  "--accent-grad", "--on-accent", "--on-badge", "--online", "--verified", "--booting", "--danger", "--orange", "--green", "--red",
  "--blue", "--yellow", "--gold", "--purple", "--grey", "--text", "--ink", "--text-2", "--text-3", "--hair", "--strong",
  "--s1-hover", "--action", "--action-bg", "--seg-on", "--menu", "--shade", "--shade-k", "--scrim-k", "--bar-rgb", "--dock",
  "--glass", "--glass-blur", "--font", "--font-round", "--mono", "--t-title", "--t-title2", "--t-headline", "--t-body", "--t-sub",
  "--t-foot", "--t-cap", "--radius", "--gutter", "--tabbar-h", "--tabbar-gap", "--press",
]

// A token value goes into a <style> block and a style property: a value that could end the rule or the block is dropped.
const safe = v => typeof v === "string" && v !== "" && v.length < 400 && !/[<>{};\\]/.test(v)
const NAME = /^--[a-z0-9-]+$/

/** Only the well-formed name/value pairs of a token map. */
export function cleanTokens(tokens) {
  const out = {}
  if (tokens && typeof tokens === "object") for (const [k, v] of Object.entries(tokens)) if (NAME.test(k) && safe(v)) out[k] = v
  return out
}

/** The tokens as computed on an element. */
export function tokensOf(el, win = globalThis) {
  const css = win.getComputedStyle(el), out = {}
  for (const n of THEME_TOKENS) { const v = css.getPropertyValue(n).trim(); if (v) out[n] = v }
  return out
}

/** The theme object for theme.get / theme.changed, from the page as it is drawn now. */
export function readTheme(doc = globalThis.document, win = globalThis) {
  const root = doc.documentElement
  const mode = root.dataset.theme === "light" ? "light" : "dark"
  const tokens = cleanTokens(tokensOf(root, win))
  let dark = tokens
  if (mode === "light") {
    // The dark set as the page would draw a [data-theme="dark"] island (tokens.css + the accent's dark block).
    const probe = doc.createElement("div")
    probe.dataset.theme = "dark"
    probe.hidden = true
    ;(doc.body ?? root).appendChild(probe)
    try { dark = cleanTokens(tokensOf(probe, win)) } finally { probe.remove() }
  }
  return {
    colors: { background: tokens["--bg"] || "#000", text: tokens["--text"] || "#fff", primary: tokens["--accent"] || "#e67326" },
    title: "Nostr Vault",
    nv: { mode, tokens, dark },
  }
}

/** The first-paint block for a napplet's srcdoc: its :root gets the tokens before any of its own CSS or script runs.
 *  `:root:root` outranks the napplet's own `:root { --bg: … }` defaults, whatever order they come in. */
export function themeHead(theme) {
  const nv = theme?.nv, tokens = cleanTokens(nv?.tokens)
  if (!Object.keys(tokens).length) return ""
  const mode = nv?.mode === "light" ? "light" : "dark"
  return `<style id="nv-theme">:root:root { color-scheme: ${mode}; ${Object.entries(tokens).map(([k, v]) => `${k}: ${v};`).join(" ")} }</style>`
}

export const THEME_STORAGE_KEYS = ["display.appearance", "display.accent", "display.accentCss"]

/** Calls fn (once per burst) whenever what the page draws with may have changed: Mode or accent set here
 *  (appearance.js / accent.js listeners), Auto following the device, or another tab changing either. -> unsubscribe. */
export function onThemeChange(fn, { win = globalThis, onAppearance, onAccent } = {}) {
  let queued = false
  // After the page's own listeners have repainted (they run first: registered at startup), on the next frame.
  const fire = () => {
    if (queued) return
    queued = true
    const run = () => { queued = false; try { fn() } catch {} }
    if (typeof win.requestAnimationFrame === "function") win.requestAnimationFrame(run)
    else setTimeout(run, 0)
  }
  const offs = []
  if (onAppearance) offs.push(onAppearance(fire))
  if (onAccent) offs.push(onAccent(fire))
  const mq = win.matchMedia?.("(prefers-color-scheme: light)")
  if (mq?.addEventListener) { mq.addEventListener("change", fire); offs.push(() => mq.removeEventListener("change", fire)) }
  const onStorage = e => { if (THEME_STORAGE_KEYS.includes(e.key)) fire() }
  win.addEventListener?.("storage", onStorage)
  offs.push(() => win.removeEventListener?.("storage", onStorage))
  return () => offs.forEach(off => { try { off() } catch {} })
}
