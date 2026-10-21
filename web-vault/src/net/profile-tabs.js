// A profile's tabs, as the iPhone's (ProfileSection.swift): Notes, Media, Replies, Reposts and Tagged on every
// profile, then Articles only once this person has some (ProfileContent+Sections visibleSections). Notes and Replies
// are one pile of kind 1s split by NIP-10 (net/thread.js replyRefs); Media is their own notes and replies with an
// image or video (net/media.js); Reposts are their kind 6s; Tagged is other people's notes that tag them; Articles are
// kind 30023. Pure: the screens fetch, this only sorts what they have and says what an empty tab reads.
import { replyRefs } from "./thread.js"
import { mediaTiles } from "./media.js"

export const PROFILE_TABS = [
  { id: "notes", label: "Notes" },
  { id: "media", label: "Media" },
  { id: "replies", label: "Replies" },
  { id: "reposts", label: "Reposts" },
  { id: "tagged", label: "Tagged" },
  { id: "articles", label: "Articles", late: true },
]

/** The tabs filled from the profile's note streams (ProfileSection.isNoteTab); Tagged pages its own stream. */
export const isNoteTab = id => id !== "articles"

/** The tabs on show: the late ones (Articles) only when the profile has some. */
export const visibleTabs = articles => PROFILE_TABS.filter(t => !t.late || (articles?.length ?? 0) > 0)

/** A kind 1 that answers another note. A note that only quotes (mention markers) isn't one. */
export const isReply = ev => !!replyRefs(ev).parent

/** -> { notes, replies, reposts, media } from a profile's kind 1s and 6s, each in the order given (newest first from
 *  the screens). A repost's media is someone else's, so it stays out of Media (ProfileFeedLoader.rebucket). */
export function splitProfileNotes(events) {
  const notes = [], replies = [], reposts = []
  for (const ev of events) {
    if (ev?.kind === 6) reposts.push(ev)
    else if (ev?.kind === 1) (isReply(ev) ? replies : notes).push(ev)
  }
  return { notes, replies, reposts, media: mediaTiles(notes.concat(replies).sort(newestFirst)) }
}

/** Tagged: notes that tag `pubkey`, never their own (ProfileFeedLoader.rebucket), and none by someone blocked. */
export const taggedNotes = (events, pubkey, blocked) => events.filter(ev => ev?.kind === 1 && ev.pubkey !== pubkey && !blocked?.has(ev.pubkey))

/** Kind 30023s, one per `d` (the newest edit wins), newest first. */
export function latestArticles(events) {
  const byD = new Map()
  for (const ev of events) {
    if (ev?.kind !== 30023) continue
    const key = `${ev.pubkey}:${ev.tags.find(t => t[0] === "d")?.[1] ?? ""}`
    const have = byD.get(key)
    if (!have || ev.created_at > have.created_at) byD.set(key, ev)
  }
  return [...byD.values()].sort((a, b) => b.created_at - a.created_at)
}

/** Newest first, ties by id: a total order, so the oldest note (the next page's `until`) is always the same one. */
export const newestFirst = (a, b) => b.created_at - a.created_at || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0)

/** A page added to what a stream has, once each, in order. `grew`: the page brought something new. */
export function mergeOlder(have, page) {
  const ids = new Set(have.map(e => e.id))
  const fresh = page.filter(e => e && !ids.has(e.id) && ids.add(e.id))
  return { list: fresh.length ? [...have, ...fresh].sort(newestFirst) : have, grew: fresh.length > 0 }
}

/** Empty pages in a row that end paging: one quiet page is a slow relay more often than the end (finishOlderPage). */
export const QUIET_PAGES = 2
/** Pages an empty tab asks for by itself before it offers "Look further back" (autoPageEmptyTab). */
export const AUTO_PAGES = 8

/** What an empty note tab says (emptyNoteSection): loading, nothing in what has loaded yet, or nothing at all. */
export function emptyText(tab, { loading, olderLeft }) {
  if (loading) return "Loading…"
  if (olderLeft) return "None in the latest posts"
  return `No ${(PROFILE_TABS.find(t => t.id === tab)?.label ?? tab).toLowerCase()} yet`
}
