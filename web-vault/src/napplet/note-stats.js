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

/** The emoji a napplet asked to react with: one emoji, at most 16 characters; anything else is no emoji (a plain tap:
 *  the heart, or taking your reaction back). */
export function askedEmoji(raw) {
  if (typeof raw !== "string") return undefined
  const t = raw.trim()
  return t && t.length <= 16 && /\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(t) && !/[<>"'`\\]/.test(t) ? t : undefined
}
