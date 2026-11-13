// Emoji copies as the vault's /files room lists them (RESEARCH/NV_CUSTOM_EMOJI_PLAN.md §4.1, the contract every
// platform shares; fixtures in docs/fixtures/emoji-notes/): a kind 1063 file note with ["t","nv-emoji"] marks a vault
// file as a saved emoji image. Its ["emoji", code, url] tags say which shortcodes use it, its ["a","30030:<pk>:<d>"]
// tags which sets. A tag of the wrong shape is skipped; the note is still an emoji note. The web only reads these: the
// apps write them with their mesh key when you tap Save copies.
import { isShortcode, httpsUrl, parseAddress } from "./emoji-sets.js"

export const EMOJI_NOTE_TAG = "nv-emoji"

/** The emoji part of a file note, or null for a plain one. -> { codes: [[code, url]], sets: [address] } */
export function emojiPart(ev) {
  const tags = Array.isArray(ev?.tags) ? ev.tags.filter(Array.isArray) : []
  if (!tags.some(t => t[0] === "t" && t[1] === EMOJI_NOTE_TAG)) return null
  const codes = [], sets = []
  for (const t of tags) {
    if (t[0] === "emoji" && isShortcode(t[1]) && httpsUrl(t[2]) && !codes.some(c => c[0] === t[1] && c[1] === t[2])) codes.push([t[1], t[2]])
    if (t[0] === "a" && parseAddress(t[1]) && !sets.includes(t[1])) sets.push(t[1])
  }
  return { codes, sets }
}

/** Hashes Media hides: every live note for them is an emoji note. One plain note keeps a file in Media.
 *  `notes`: the parsed notes (FileNotesState.notes values), each with its `emoji` part or null. */
export function emojiOnlyHashes(notes) {
  const plain = new Set(), emoji = new Set()
  for (const n of notes) (n.emoji ? emoji : plain).add(n.sha256)
  return new Set([...emoji].filter(sha => !plain.has(sha)))
}

/** The saved emoji images: Map sha256 -> { sha256, mime, size, codes: [[code, url]], sets: [address], urls }.
 *  Newest note first; every emoji note's codes and sets merged, each once. */
export function emojiCopies(notes) {
  const out = new Map()
  const newest = [...notes].filter(n => n.emoji).sort((a, b) => b.createdAt - a.createdAt || (a.id < b.id ? -1 : 1))
  for (const n of newest) {
    const c = out.get(n.sha256) ?? { sha256: n.sha256, mime: n.mime, size: n.size, codes: [], sets: [], urls: [] }
    for (const code of n.emoji.codes) if (!c.codes.some(x => x[0] === code[0] && x[1] === code[1])) c.codes.push(code)
    for (const a of n.emoji.sets) if (!c.sets.includes(a)) c.sets.push(a)
    for (const u of n.urls) if (!c.urls.includes(u)) c.urls.push(u)
    out.set(n.sha256, c)
  }
  return out
}

/** Is this emoji of `set` saved? By its link or, failing that, by its shortcode in a copy filed under the set. */
export function savedCopyFor(copies, set, { code, url }) {
  for (const c of copies.values()) if (c.codes.some(x => x[1] === url)) return c
  for (const c of copies.values()) if (c.sets.includes(set.address) && c.codes.some(x => x[0] === code)) return c
  return null
}
