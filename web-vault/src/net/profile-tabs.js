// A profile's tabs, as the iPhone's (ProfileSection.swift): Notes, Replies, Media and Articles. Notes and Replies are
// one pile of kind 1s split by NIP-10 (net/thread.js replyRefs); Media is the notes with an image or video
// (net/media.js); Articles are kind 30023. Pure: the screens fetch, this only sorts what they have.
import { replyRefs } from "./thread.js"
import { mediaTiles } from "./media.js"

export const PROFILE_TABS = [
  { id: "notes", label: "Notes" },
  { id: "replies", label: "Replies" },
  { id: "media", label: "Media" },
  { id: "articles", label: "Articles" },
]

/** A kind 1 that answers another note. A note that only quotes (mention markers) isn't one. */
export const isReply = ev => !!replyRefs(ev).parent

/** -> { notes, replies, media } from a profile's kind 1s, each in the order given (newest first from the screens). */
export function splitProfileNotes(events) {
  const notes = [], replies = []
  for (const ev of events) if (ev?.kind === 1) (isReply(ev) ? replies : notes).push(ev)
  return { notes, replies, media: mediaTiles(notes.concat(replies).sort((a, b) => b.created_at - a.created_at)) }
}

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
