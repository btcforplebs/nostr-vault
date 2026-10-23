// The site shell (website/shell.js): nostrvault.app opens this app full screen in a frame, and "What is Nostr Vault?"
// shrinks it into a phone on the marketing page. The shell is the same origin, so the app calls it directly.
// Opened on its own (nostrvault.app/vault/, an installed app), the same links go to the marketing page instead.

/** The shell this app is framed in, or null. */
function shell() {
  try { return window.parent !== window ? window.parent.nvShell ?? null : null } catch { return null }
}

export const inShell = () => !!shell()

/** Show the marketing page around the app (`anchor`: a section of it, as "platforms"). */
export function learn(anchor = "") {
  const s = shell()
  if (s) return s.learn(anchor)
  location.assign(`/#${anchor || "about"}`)
}

/** Some extensions only reach the top page, not a frame in it: the shell's window.nostr, if the app has none. */
export function shellNostr() {
  try { return window.parent !== window && shell() ? window.parent.nostr : undefined } catch { return undefined }
}
