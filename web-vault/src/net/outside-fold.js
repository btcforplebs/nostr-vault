// Strangers folded away rather than listed (Logen 2026-11-13 "go all" on the stricter web-of-trust options, A and B):
// likes and reposts from outside your web leave Notifications for one "N from outside your web" line, and Search
// folds people and notes from outside your web the same way (net/search.js shapeResults). The thread view already
// folds replies so (web-trust.js splitOutside). iPhone/Mac twin: VaultActivity.build(foldsOutsideLikes:) and
// GlobalSearchRanking.splitOutside. Read-only; nothing here signs.
import { classify, isOutside } from "./notifications.js"

/** The notification types that fold when they come from outside your web. Zaps cost the sender sats and follows are
 *  about you, so both keep their rows; replies, mentions and quotes from outside are already left out (insideRows). */
export const FOLDED_TYPES = new Set(["reaction", "repost"])

/**
 * Notification events split by the web: `outside` holds likes and reposts from outside it, `inside` everything else
 * (each still grouped by groupNotifications). `trusted` null: the web isn't in yet, so only you, your follows and the
 * whitelist are inside; a like from further out folds until the web arrives, then moves up (fails closed).
 * -> { inside: [event], outside: [event] }
 */
export function splitOutsideLikes(events, owner, { trusted = null, follows = [], whitelist = new Set() } = {}) {
  const known = trusted === null ? new Set([owner, ...follows, ...whitelist]) : null
  const out = pk => known ? !known.has(pk) : isOutside(pk, owner, whitelist, trusted)
  const inside = [], outside = []
  for (const ev of events ?? []) {
    const n = classify(ev, owner)
    ;(n && FOLDED_TYPES.has(n.type) && out(n.who) ? outside : inside).push(ev)
  }
  return { inside, outside }
}

/** The fold line's N: each person once per row, the way a row's faces count them. */
export const outsideCount = rows => (rows ?? []).reduce((sum, r) => sum + new Set(r.who ?? []).size, 0)

/** "Show 3 from outside your web" / "Hide 3 from outside your web". */
export const outsideLabel = (n, open) => `${open ? "Hide" : "Show"} ${n} from outside your web`
