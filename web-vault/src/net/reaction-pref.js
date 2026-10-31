// Settings › Reactions › Default Reaction (iPhone AppearanceSettingsView, HavenConfig.defaultReactionEmoji): the emoji a
// one-tap like sends. ❤️ by default. Kept in this browser; read at each tap, so a change applies to the next like.
export const DEFAULT_REACTION = "❤️"
const KEY = "display.defaultReactionEmoji"
const PICTO = /\p{Extended_Pictographic}|\p{Regional_Indicator}/u

/** One emoji (a grapheme that is pictographic), else "". */
const oneEmoji = s => {
  const g = [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(String(s ?? "").trim())]
  return g.length === 1 && PICTO.test(g[0].segment) ? g[0].segment : ""
}

export function defaultReaction(storage = globalThis.localStorage) {
  let raw = null
  try { raw = storage?.getItem?.(KEY) } catch {}
  return oneEmoji(raw) || DEFAULT_REACTION
}

export function setDefaultReaction(emoji, storage = globalThis.localStorage) {
  const e = oneEmoji(emoji)
  if (!e) return
  try { e === DEFAULT_REACTION ? storage?.removeItem?.(KEY) : storage?.setItem?.(KEY, e) } catch {}
}
