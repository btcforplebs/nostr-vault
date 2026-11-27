// The profile page's own gate on who it draws (Logen 2026-11-27, RESEARCH/NV_WEB_PROFILE_OUTSIDE_WEB_AUDIT.md 1-3, 6):
// a profile shows its owner in full, and anyone else it brings in (a reposted or quoted note's author, "reply to
// @name", a bio's nostr:npub) only when they are inside your web (useWebTrust). Someone outside is a short line with
// nothing fetched for them: no name, no picture, no note text. The value is `outside(pubkey) -> boolean`; with no
// provider (the feeds, threads, the Vault) nothing changes.
import { createContext } from "preact"
import { useContext } from "preact/hooks"

export const OutsideWeb = createContext(null)

/** `outside(pubkey)` from the nearest profile page, or null when the view isn't gated this way. The node tests call
 *  NoteCard, NoteBody and QuotedNote as plain functions, with no render around them and so no context: that is null too. */
export const useOutside = () => { try { return useContext(OutsideWeb) } catch { return null } }

/** The profile's gate: outside unless useWebTrust's `inside` lets them in. `owner`: always shown. */
export const profileOutside = (inside, owner) => pk => !!pk && !inside(pk, [owner])

/** The words on a card whose author is outside your web, so the page says something was there. */
export const OUTSIDE_TEXT = {
  repost: "Reposted a note by someone outside your web",
  quote: "Quote from someone outside your web",
  reply: "someone outside your web",
}
