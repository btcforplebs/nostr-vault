// The Global feed on the web of trust, as the iPhone's FeedFilterEngine.filterFeedNotes `mode == .global` branch and
// FeedService.trustScopedFilters: a note shows when its signer (for a repost, the reposter, as the phone's
// `repostedBy ?? pubkey`) is in your web, and never when it is a reply. No web yet (no follows) shows nothing: Global fails
// closed rather than handing a new account the open firehose. The web's trust set is readers/trust.js globalTrust
// (you, your follows and the people they follow), the one the reader feeds' Global already uses.
// The phone's "Everyone" shield (HavenConfig.globalShowsEveryone, FeedView+TrustScope.swift; parity #20): Global (and
// Media on Global) can show everyone's notes, unfiltered, behind the phone's warning and only once you follow
// FOLLOWS_NEEDED people (TrustScopeLock.swift). Kept on this browser; the web of trust stays the default. Not here yet:
// Global languages (globalFeedLanguages), which needs a language detector the web doesn't have.
import { isReply } from "./feed-filters.js"

/** Whether a note is from inside `trust`: its signer, so for a repost the reposter, whoever wrote the note it reposts
 *  (Logen 2026-11-11, as iPhone/Mac FeedFilterEngine `repostedBy ?? pubkey` and Android). Blocked people are taken
 *  out separately (blocks.js visibleNotes), reposts of them included. */
export function trustShows(note, trust) {
  return !!trust?.size && trust.has(note.pubkey)
}

const EVERYONE_KEY = "nv-global-everyone"
/** TrustScopeLock.followsNeeded: Everyone unlocks once you follow this many people. */
export const FOLLOWS_NEEDED = 5
export const everyoneOn = (storage = globalThis.localStorage) => { try { return storage?.getItem(EVERYONE_KEY) === "on" } catch { return false } }
export const setEveryone = (on, storage = globalThis.localStorage) => { try { storage?.setItem(EVERYONE_KEY, on ? "on" : "off") } catch {} }
/** TrustScopeLock.isLocked: turning Everyone on is refused below FOLLOWS_NEEDED follows (yourself not counted); never
 *  while it is already on, so a choice already made is left alone. */
export const everyoneLocked = (follows, me, on = false) => !on && new Set(follows.filter(f => f !== me)).size < FOLLOWS_NEEDED
/** TrustScopeLock.progressText. */
export function unlockText(follows, me) {
  const left = Math.max(0, FOLLOWS_NEEDED - new Set(follows.filter(f => f !== me)).size)
  return left > 0 ? `Follow ${left} more ${left === 1 ? "person" : "people"} to unlock Everyone` : "Everyone is unlocked"
}
/** The phone's warning before Everyone (feed.alert.sensitiveContent). */
export const EVERYONE_WARNING = {
  title: "Sensitive Content Warning",
  text: "Everyone shows posts from people outside your Web of Trust, unfiltered. Expect spam and sensitive content.",
  proceed: "Proceed",
  cancel: "Cancel",
}
/** What Global shows with Everyone on: anyone's note, still never a reply (FeedFilterEngine). */
export const everyoneShows = note => !isReply(note)

/** Whether Global shows this note under `trust` (a Set, or null for no web yet). */
export function globalShows(note, trust) {
  return trustShows(note, trust) && !isReply(note)
}

/** The notes Global shows, in their order. */
export const filterGlobal = (notes, trust) => notes.filter(n => globalShows(n, trust))
/** The line Global wears while Everyone is on (Logen 2026-11-13 "go all", option C), so a shield flipped once and kept
 *  in this browser can't go unnoticed. iPhone/Mac twin: EveryoneBanner.swift. */
export const EVERYONE_BANNER = {
  text: "Everyone is on: these posts come from outside your web too, unfiltered.",
  back: "Back to your web",
}
