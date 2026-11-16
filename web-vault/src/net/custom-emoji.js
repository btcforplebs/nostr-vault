// NIP-30 custom emoji where the classic web shows text: a `:shortcode:` in a note, a name or a reaction is drawn as
// its picture when the event carries ["emoji", shortcode, url] for it (components/CustomEmoji.jsx). Your own emoji
// (the sets your 10030 names, net/emoji-sets.js) feed the pickers, and a reaction with one carries its emoji tag.
// Reactions only keep their content as text, so the pictures seen with them are remembered here by shortcode.
import { isShortcode, httpsUrl, readEmojiList, listedSets, fetchSets } from "./emoji-sets.js"

/** An event's emoji tags -> Map shortcode -> https url (the first per shortcode). */
export function emojiMap(tags) {
  const out = new Map()
  for (const t of Array.isArray(tags) ? tags : []) {
    if (!Array.isArray(t) || t[0] !== "emoji" || !isShortcode(t[1]) || out.has(t[1])) continue
    const url = httpsUrl(t[2])
    if (url) out.set(t[1], url)
  }
  return out
}

const CODE = /:([A-Za-z0-9_-]+):/g
/** Text -> [text, code, text, …]: only shortcodes `map` has a picture for are split out; others stay text. */
export function splitShortcodes(text, map) {
  const s = String(text ?? "")
  if (!map?.size || !s.includes(":")) return [s]
  const out = [""]
  let last = 0
  for (const m of s.matchAll(CODE)) {
    if (!map.has(m[1])) continue
    out[out.length - 1] += s.slice(last, m.index)
    out.push(m[1], "")
    last = m.index + m[0].length
  }
  out[out.length - 1] += s.slice(last)
  return out
}

/** A reaction's content that is one shortcode -> that code, else null. */
export const reactionCode = content => /^:([A-Za-z0-9_-]+):$/.exec(String(content ?? "").trim())?.[1] ?? null

// Pictures seen with reactions (and your own emoji): shortcode -> url, newest seen wins. Your own emoji are kept apart
// too, so a stranger's :fire: never becomes the picture your reaction sends.
const seen = new Map(), own = new Map()
const listeners = new Set()
export const seenEmoji = () => seen
export const onSeenEmoji = cb => { listeners.add(cb); return () => listeners.delete(cb) }
/** Remember the emoji tags of an event (a reaction), so its `:code:` can show as a picture. */
export function rememberEmoji(tags) {
  let changed = false
  for (const [code, url] of emojiMap(tags)) if (seen.get(code) !== url) { seen.set(code, url); changed = true }
  if (changed) for (const cb of listeners) cb()
}

/** The tags a reaction with `content` carries: one emoji tag when it is a shortcode with a known picture. */
export function reactionEmojiTags(content) {
  const code = reactionCode(content)
  const url = code && (own.get(code) ?? seen.get(code))
  return url ? [["emoji", code, url]] : []
}

// Your emoji, for the pickers: per account, loaded once a session. -> [{ code, url, set }]
const mine = new Map()
export function myEmoji(ctx, { read = readEmojiList, sets = fetchSets } = {}) {
  const me = ctx?.session?.pubkey
  if (!me) return Promise.resolve([])
  if (!mine.has(me)) {
    const p = (async () => {
      const r = await read(ctx)
      const addresses = listedSets(r?.event)
      const got = await sets(ctx, addresses)
      return ownEmoji(addresses.map(a => got.get(a)).filter(Boolean))
    })().catch(() => { mine.delete(me); return [] })
    mine.set(me, p)
  }
  return mine.get(me)
}
/** Sets -> their emoji, each shortcode once (first set first), remembered so a reaction with one carries its tag. */
export function ownEmoji(sets) {
  const out = [], codes = new Set()
  for (const s of sets) for (const e of s.emoji ?? []) {
    if (codes.has(e.code)) continue
    codes.add(e.code)
    out.push({ code: e.code, url: e.url, set: s.title })
  }
  for (const e of out) own.set(e.code, e.url)
  rememberEmoji(out.map(e => ["emoji", e.code, e.url]))
  return out
}
/** Forget the loaded list (after the Emoji page adds or removes a set). */
export const forgetMyEmoji = pk => { if (pk) mine.delete(pk); else mine.clear() }
