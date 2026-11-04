// The Global feed on the web of trust, as the iPhone's FeedFilterEngine.filterFeedNotes `mode == .global` branch and
// FeedService.trustScopedFilters: a note shows when its author (for a repost, the reposter: the phone checks
// note.pubkey) is in your web, and never when it is a reply. No web yet (no follows) shows nothing: Global fails
// closed rather than handing a new account the open firehose. The web's trust set is readers/trust.js globalTrust
// (you, your follows and the people they follow), the one the reader feeds' Global already uses.
// Not here yet: the phone's "Everyone" shield (HavenConfig.globalShowsEveryone) and Global languages
// (globalFeedLanguages). The web has no settings for them, so Global is always the web of trust, in any language.
import { isReply } from "./feed-filters.js"

/** The author inside a repost (kind 6 or 16): its content's pubkey, else its `p` tag. Null for anything else. */
export function repostedAuthor(note) {
  if (note?.kind !== 6 && note?.kind !== 16) return null
  let pk
  try { pk = JSON.parse(note.content)?.pubkey } catch {}
  return pk ?? (note.tags ?? []).find(t => t[0] === "p")?.[1] ?? null
}

/** Whether a note is from inside `trust`: its author, and for a repost the reposted note's author too, so a trusted
 *  person reposting a stranger doesn't carry the stranger in (Logen 2026-11-04). */
export function trustShows(note, trust) {
  if (!trust?.size || !trust.has(note.pubkey)) return false
  const inner = repostedAuthor(note)
  return !inner || trust.has(inner)
}

/** Whether Global shows this note under `trust` (a Set, or null for no web yet). */
export function globalShows(note, trust) {
  return trustShows(note, trust) && !isReply(note)
}

/** The notes Global shows, in their order. */
export const filterGlobal = (notes, trust) => notes.filter(n => globalShows(n, trust))
