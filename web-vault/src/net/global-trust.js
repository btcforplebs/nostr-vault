// The Global feed on the web of trust, as the iPhone's FeedFilterEngine.filterFeedNotes `mode == .global` branch and
// FeedService.trustScopedFilters: a note shows when its author (for a repost, the reposter: the phone checks
// note.pubkey) is in your web, and never when it is a reply. No web yet (no follows) shows nothing: Global fails
// closed rather than handing a new account the open firehose. The web's trust set is readers/trust.js globalTrust
// (you, your follows and the people they follow), the one the reader feeds' Global already uses.
// Not here yet: the phone's "Everyone" shield (HavenConfig.globalShowsEveryone) and Global languages
// (globalFeedLanguages). The web has no settings for them, so Global is always the web of trust, in any language.
import { isReply } from "./feed-filters.js"

/** Whether Global shows this note under `trust` (a Set, or null for no web yet). */
export function globalShows(note, trust) {
  if (!trust?.size || !trust.has(note.pubkey)) return false
  return !isReply(note)
}

/** The notes Global shows, in their order. */
export const filterGlobal = (notes, trust) => notes.filter(n => globalShows(n, trust))
