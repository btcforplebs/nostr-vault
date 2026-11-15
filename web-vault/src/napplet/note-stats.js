// A note's Like and zap numbers for the Reader napplet (bug run, group 6): the classic card's own state (net/actions.js
// actionState/reactionOf, net/zaps.js zapTotal) put into plain strings and numbers for the napplet to draw. The shell
// pushes a fresh copy (inc topic nv.note.stats) whenever either changes for a note the Reader asked about.
export const STATS_TOPIC = "nv.note.stats"

/** -> { id, like: "sent" | "pending" | "busy" | "error" | null, error, emoji, zapSats, zapMine }. `display`: the
 *  classic displayEmoji (ReactionButton.jsx). */
export function statsOf(id, { state = {}, reaction = null, total = { sats: 0, mine: false } } = {}, display = e => e) {
  const s = state.like
  const like = s === "sent" || s === "pending" || s === "busy" ? s : s?.error ? "error" : null
  return {
    id, like, error: s?.error ? String(s.error).slice(0, 200) : "",
    emoji: like === "sent" || like === "pending" ? display(reaction) : "",
    zapSats: Number.isFinite(total?.sats) ? Math.max(0, Math.floor(total.sats)) : 0, zapMine: !!total?.mine,
  }
}

// Built lazily and guarded: a /v regex literal or a top-level Intl.Segmenter would break this whole chunk on browsers
// without them (Safari < 17, Firefox < 125). There, a napplet's emoji is just refused (a plain tap still likes).
let rules
function emojiRules() {
  if (rules === undefined) {
    try {
      rules = { graphemes: new Intl.Segmenter(undefined, { granularity: "grapheme" }),
        format: new RegExp("[\\p{Cf}--[\\u200D\\uFE0F]]", "v"), emoji: new RegExp("^\\p{RGI_Emoji}$", "v") }
    } catch { rules = null }
  }
  return rules
}

/** The emoji a napplet asked to react with: exactly one emoji (one grapheme that is a whole RGI emoji, so no text after
 *  it, no repeats, no direction or other format characters beside ZWJ and VS16). Anything else is no emoji (a plain
 *  tap: the heart, or taking your reaction back). */
export function askedEmoji(raw) {
  if (typeof raw !== "string") return undefined
  const t = raw.trim()
  const r = emojiRules()
  if (!t || t.length > 16 || !r || r.format.test(t)) return undefined
  return [...r.graphemes.segment(t)].length === 1 && r.emoji.test(t) ? t : undefined
}
