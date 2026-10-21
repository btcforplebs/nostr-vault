// The timeline kinds beyond notes and kind 6 reposts, read as the iPhone reads them: NIP-22 comments (1111) on notes,
// NIP-68 picture posts (20) and NIP-18 generic reposts (16). Pure, so the feed, the card and the tests share one copy
// (GenericRepost.swift, NIP10Thread.swift, FeedServiceTypes.timelineKinds).
import { verifiedCopy } from "./thread.js"

export const COMMENT_KIND = 1111, PICTURE_KIND = 20, GENERIC_REPOST_KIND = 16
const HEX64 = /^[0-9a-f]{64}$/

/** A kind 6 or a kind 16: both are reposts to every feed rule (the Reposts switch, the reposter's name). */
export const isRepost = ev => ev?.kind === 6 || ev?.kind === GENERIC_REPOST_KIND

/** A comment on a kind 1 note (K tag "1"). Comments on videos, articles and the rest are not note threads, so the
 *  timeline leaves them out (FeedService+NoteBatching). */
export const isNoteComment = ev => ev?.kind === COMMENT_KIND && (ev.tags ?? []).some(t => t[0] === "K" && t[1] === "1")

/** A comment's parent event (its lowercase e tag), or null when it answers an a/i target. */
export const commentParent = ev =>
  ev?.kind === COMMENT_KIND ? (ev.tags ?? []).find(t => t[0] === "e" && HEX64.test(t[1] ?? ""))?.[1] ?? null : null

/** The author a comment answers: its lowercase p tag (NIP-22). */
export const commentParentAuthor = ev =>
  commentParent(ev) ? (ev.tags ?? []).find(t => t[0] === "p" && HEX64.test(t[1] ?? ""))?.[1] ?? null : null

/** The kinds a repost may carry into a timeline: the ones drawn as a card there (GenericRepost.shownKinds). */
export const SHOWN_REPOST_KINDS = new Set([1, COMMENT_KIND, 30023, 1068, PICTURE_KIND, 9802])

/** The event a repost embeds in its content, parsed (not verified), or null. No kind reads as a text note. */
export function embedded(ev) {
  try {
    const inner = JSON.parse(ev?.content ?? "")
    return inner && typeof inner === "object" && typeof inner.pubkey === "string" ? inner : null
  } catch { return null }
}
const embeddedKind = ev => { const inner = embedded(ev); return inner ? (Number.isInteger(inner.kind) ? inner.kind : 1) : null }

/** What a kind 16 points at: its e tag, else its a coordinate. -> { type: "note", id } | { type: "addr", … } | null */
export function repostRef(ev) {
  const e = (ev?.tags ?? []).find(t => t[0] === "e" && HEX64.test(t[1] ?? ""))?.[1]
  if (e) return { type: "note", id: e, relays: [] }
  const a = (ev?.tags ?? []).find(t => t[0] === "a" && typeof t[1] === "string")?.[1]
  const m = /^(\d+):([0-9a-f]{64}):(.*)$/.exec(a ?? "")
  return m ? { type: "addr", kind: Number(m[1]), pubkey: m[2], d: m[3], relays: [] } : null
}

/** Whether a timeline shows this kind 16: by its k tag, else by what it embeds, else (bare, untagged) yes. */
export function isShownRepost(ev) {
  const k = (ev?.tags ?? []).find(t => t[0] === "k" && /^\d+$/.test(t[1] ?? ""))?.[1]
  if (k != null) return SHOWN_REPOST_KINDS.has(Number(k))
  const kind = embeddedKind(ev)
  return kind == null || SHOWN_REPOST_KINDS.has(kind)
}

/** The event a kind 16 carries, signature checked and of a kind a timeline draws, or null (then the card fetches it
 *  by repostRef, as the iPhone fetches a bare repost). */
export function genericRepostInner(ev) {
  if (ev?.kind !== GENERIC_REPOST_KIND) return null
  const inner = embedded(ev)
  const copy = inner && verifiedCopy(inner)
  return copy && SHOWN_REPOST_KINDS.has(copy.kind) ? copy : null
}

/** Whether a timeline draws this event at all: comments only on notes, kind 16 only when it carries a shown kind. */
export function timelineShows(ev) {
  if (ev?.kind === COMMENT_KIND) return isNoteComment(ev)
  if (ev?.kind === GENERIC_REPOST_KIND) return isShownRepost(ev)
  return true
}
