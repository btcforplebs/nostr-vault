// Our napplets carry one copy of the theme code (theme-client.js), put into each index.html where it says
// /*@nv-theme*/, the way the WoT maths go in (wot-inject.js). Pure: first-party.js passes the file's text (vite ?raw),
// tools/napplet-release.mjs and the node tests read it from disk, so the app and the published bytes match.
import { asScript } from "./wot-inject.js"

export const THEME_MARKER = "/*@nv-theme*/"

/** The napplet's html with the theme code in place of its marker; a napplet without one is left as it is. */
export function injectTheme(html, source) {
  const parts = html.split(THEME_MARKER).length
  if (parts === 1) return html
  if (parts !== 2) throw new Error("theme-inject: a napplet takes at most one theme marker")
  const code = asScript(source)
  return html.replace(THEME_MARKER, () => code)
}
