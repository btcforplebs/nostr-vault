// Clean mode (Logen 11-27): a setting on this device, off by default and never published, that shows swear words from
// the built-in list (docs/clean-words/en.txt, copied to clean-words-en.txt) as their first letter plus asterisks, the
// same length, the first letter's case kept: "Fuck" -> "F***". It changes only what is drawn: note and reply text,
// messages and their previews, notifications, link cards, bios and names. It never changes the composer, drafts,
// what is sent or signed, search, or anything stored. Whole words only, so "Scunthorpe" and "class" are left alone.
// The list is handed in by clean-words.js (a Vite ?raw import), so this file loads in node tests too.

const KEY = "nv-clean-mode"
let words = new Set()
let on = null // cached setting; null = read it again

/** Use these words (one per line, as the list file holds them). */
export function setCleanWords(text) {
  words = new Set(String(text ?? "").split("\n").map(w => w.trim().toLowerCase()).filter(Boolean))
}
export const cleanWordCount = () => words.size

/** Settings › Muted Words › Clean mode, off unless turned on. */
export function cleanMode(storage = globalThis.localStorage) {
  if (on !== null && storage === globalThis.localStorage) return on
  let v = false
  try { v = storage?.getItem(KEY) === "1" } catch {}
  if (storage === globalThis.localStorage) on = v
  return v
}
export function setCleanMode(value, storage = globalThis.localStorage) {
  try { if (value) storage?.setItem(KEY, "1"); else storage?.removeItem(KEY) } catch {}
  on = null
  return cleanMode(storage)
}
// Another tab changed it.
globalThis.addEventListener?.("storage", e => { if (e.key === KEY || e.key === null) on = null })

// A run of letters, marks and digits is one word; anything else (spaces, punctuation, apostrophes) ends it.
const RUN = /[\p{L}\p{M}\p{N}]+/gu

/** `text` with each listed word masked, whatever clean mode says. */
export function maskWords(text, list = words) {
  if (!list.size || !text) return text
  return text.replace(RUN, w => {
    if (!list.has(w.toLowerCase())) return w
    const chars = [...w]
    return chars[0] + "*".repeat(chars.length - 1)
  })
}

/** What to draw for `text`: masked when clean mode is on, else `text` as it is. Anything not a string passes through. */
export const clean = text => (typeof text === "string" && words.size && cleanMode() ? maskWords(text) : text)
