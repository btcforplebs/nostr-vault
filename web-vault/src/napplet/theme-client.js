// Runs INSIDE our own napplets (plan step 1): put into each one's index.html at its theme marker
// (theme-inject.js), so all of them follow the shell's theme the same way. The shell already wrote the tokens into the
// document before the first paint (theme.js themeHead); this keeps them in step: theme.get once, then every
// theme.changed. Napplet CSS uses the same names as styles/tokens.css (var(--s1), var(--text-2), …).
// `island: "dark"` keeps the napplet on the dark set whatever the mode (the trust globe, as the classic screen does).
// Every change also fires a window "nv-theme" event, for napplets that paint with the colours themselves (canvas).
// No imports and plain `function`s: inlined as a script (wot-inject.js asScript).
export function nvTheme(n, opts) {
  const root = document.documentElement
  const island = opts && opts.island === "dark"
  const apply = t => {
    const nv = t && t.nv
    const set = (island ? nv && nv.dark : nv && nv.tokens) || nvColors(t)
    for (const k of Object.keys(set || {})) {
      const v = set[k]
      if (/^--[a-z0-9-]+$/.test(k) && typeof v === "string" && v && !/[<>{};\\]/.test(v)) root.style.setProperty(k, v)
    }
    const mode = island ? "dark" : nv && nv.mode === "light" ? "light" : "dark"
    root.style.colorScheme = mode
    root.dataset.theme = mode
    try { dispatchEvent(new CustomEvent("nv-theme", { detail: { mode } })) } catch (e) {}
  }
  try {
    if (n && n.theme && n.theme.get) n.theme.get().then(apply, () => {})
    if (n && n.theme && n.theme.onChanged) n.theme.onChanged(apply)
  } catch (e) {}
}

// An older shell (or another one) sends only NIP-5D's three colours.
export function nvColors(t) {
  const c = (t && t.colors) || {}, out = {}
  if (c.background) out["--bg"] = c.background
  if (c.text) out["--text"] = c.text
  if (c.primary) out["--accent"] = c.primary
  return out
}
