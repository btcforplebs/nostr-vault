// What the network says about an article, read-only: likes, comments, zaps and highlights (the iPhone's
// ArticleEngagement, ArticleTally, ArticleHighlight and ArticleBlockFilter, Models/ArticleEngagement.swift). Liking,
// commenting and zapping are drawn by ArticleActions.jsx; this file only builds what they send. Nothing is stored.
import { zapSats } from "../net/notifications.js"
import { isNoiseOrSpam } from "./spam.js"

export const REACTION = 7, NOTE = 1, COMMENT = 1111, ZAP_RECEIPT = 9735, HIGHLIGHT = 9802
/** NIP-84 passages are a sentence or a paragraph; anything longer isn't a highlight. */
export const MAX_PASSAGE = 1000
/** The newest this many highlights are shown: keys are free, so the count is the publisher's choice. */
export const MAX_HIGHLIGHTS = 50
/** How far ahead of the clock an event may be dated, for clock drift. A highlight dated 2099 would otherwise push every
 *  real one off the newest-first list. */
export const MAX_FUTURE_SKEW = 600

/** `30023:<pubkey>:<d>`, or null without a `d` tag. */
export function coordinate(ev) {
  const d = ev?.tags?.find(t => t[0] === "d" && t.length >= 2)?.[1]
  return d == null ? null : `${ev.kind}:${ev.pubkey}:${d}`
}

/** Filters for likes, zaps and comments: by `a` coordinate (survives edits) and this version's `e` id; a NIP-22 comment
 *  also names the article as its uppercase root, the only tag a reply to a comment has that points at it. */
export function engagementFilters(id, coord, limit = 500) {
  const kinds = [REACTION, ZAP_RECEIPT, COMMENT, NOTE]
  const out = [{ kinds, "#e": [id], limit }, { kinds: [COMMENT], "#E": [id], limit }]
  if (coord) out.push({ kinds, "#a": [coord], limit }, { kinds: [COMMENT], "#A": [coord], limit })
  return out
}

/** Filters for highlights of the article, by coordinate and by id. */
export function highlightFilters(id, coord, limit = 200) {
  const out = [{ kinds: [HIGHLIGHT], "#e": [id], limit }]
  if (coord) out.unshift({ kinds: [HIGHLIGHT], "#a": [coord], limit })
  return out
}

/** Blocked people's highlights, likes and comments out, before anything is counted or drawn. Zap receipts stay: they
 *  are signed by the recipient's Lightning provider, not the zapper. */
export const visibleEvents = (evs, blocked) => (blocked?.size ? evs.filter(ev => ev.kind === ZAP_RECEIPT || !blocked.has(ev.pubkey)) : evs)

const names = (value, tagNames, tags) => tags.some(t => t.length >= 2 && tagNames.includes(t[0]) && t[1] === value)

/** Counts what points at this article; a relay may answer a tag filter loosely, so each event is checked.
 *  -> { likers: Set, zaps, zapSats, commentCount, topLevel: [event] oldest first, replyCounts: Map } */
export function tally(evs, articleId, coord, now = Math.floor(Date.now() / 1000)) {
  const pointsHere = (tags, lower = true, upper = false) => {
    const e = [...(lower ? ["e"] : []), ...(upper ? ["E"] : [])], a = [...(lower ? ["a"] : []), ...(upper ? ["A"] : [])]
    return names(articleId, e, tags) || (coord != null && names(coord, a, tags))
  }
  const out = { likers: new Set(), zaps: 0, zapSats: 0, commentCount: 0, topLevel: [], replyCounts: new Map() }
  const seen = new Set(), comments = []
  for (const ev of evs) {
    if (!ev?.id || seen.has(ev.id) || !Array.isArray(ev.tags) || !(ev.created_at <= now + MAX_FUTURE_SKEW)) continue
    seen.add(ev.id)
    const { tags } = ev, content = typeof ev.content === "string" ? ev.content : ""
    if (ev.kind === REACTION) {
      if (pointsHere(tags) && content !== "-") out.likers.add(ev.pubkey) // "-" is a dislike (NIP-25)
    } else if (ev.kind === ZAP_RECEIPT) {
      if (pointsHere(tags)) { out.zaps++; out.zapSats += zapSats(ev) }
    } else if ((ev.kind === COMMENT || ev.kind === NOTE) && isNoiseOrSpam(content, tags)) {
      continue // spam comments are dropped as the thread view drops them (ArticleReaderView.showEngagement)
    } else if (ev.kind === COMMENT) {
      if (!pointsHere(tags, true, true)) continue
      // Lowercase tags name the parent: the article means top-level, else the comment its `e` names.
      comments.push({ ev, parent: pointsHere(tags) ? null : tags.find(t => t.length >= 2 && t[0] === "e")?.[1] ?? null })
    } else if (ev.kind === NOTE) {
      // A mention or quote names the article without replying to it.
      const reply = tags.filter(t => t.length >= 2 && (t[0] === "e" || t[0] === "a") && (t.length < 4 || t[3] !== "mention"))
      if (!pointsHere(reply)) continue
      // NIP-10: the reply-marked `e` is the parent; with no markers, the last `e`.
      const es = reply.filter(t => t[0] === "e")
      const parent = (es.find(t => t.length >= 4 && t[3] === "reply") ?? es.at(-1))?.[1] ?? null
      comments.push({ ev, parent: parent === articleId ? null : parent })
    }
  }
  out.commentCount = comments.length
  for (const c of comments) if (c.parent) out.replyCounts.set(c.parent, (out.replyCounts.get(c.parent) ?? 0) + 1)
  out.topLevel = comments.filter(c => !c.parent).map(c => c.ev).sort((a, b) => a.created_at - b.created_at || (a.id < b.id ? -1 : 1))
  return out
}

/** A highlight of this article -> { id, pubkey, passage, comment, created_at }, or null: a 9802 that points here by
 *  coordinate or by this version's id, with a passage no longer than MAX_PASSAGE, not dated in the future. */
export function highlight(ev, articleId, coord, now = Math.floor(Date.now() / 1000)) {
  if (ev?.kind !== HIGHLIGHT || !ev.id || !Array.isArray(ev.tags) || typeof ev.content !== "string" || !(ev.created_at <= now + MAX_FUTURE_SKEW)) return null
  if (isNoiseOrSpam(ev.content, ev.tags)) return null // spam dropped as the thread view drops it
  const here = ev.tags.some(t => t.length >= 2 && ((t[0] === "e" && t[1] === articleId) || (t[0] === "a" && coord != null && t[1] === coord)))
  const passage = ev.content.trim()
  if (!here || !passage || [...passage].length > MAX_PASSAGE) return null
  const comment = ev.tags.find(t => t.length >= 2 && t[0] === "comment")?.[1]?.trim()
  return { id: ev.id, pubkey: ev.pubkey, passage, comment: comment || null, created_at: ev.created_at }
}

/** The highlights to show: newest first, once each, at most MAX_HIGHLIGHTS. */
export function shownHighlights(evs, articleId, coord, now) {
  const seen = new Set()
  return evs.map(ev => highlight(ev, articleId, coord, now)).filter(h => h && !seen.has(h.id) && seen.add(h.id))
    .sort((a, b) => b.created_at - a.created_at).slice(0, MAX_HIGHLIGHTS)
}

/** Where to ask: your read relays and the author's write relays, at most 8, as the iPhone's highlightRelays. */
export function engagementRelays(read, authorWrite = []) {
  const seen = new Set(), out = []
  for (const r of [...read, ...authorWrite]) {
    const u = String(r ?? "").trim()
    const k = u.toLowerCase().replace(/\/+$/, "")
    if (u && !seen.has(k)) { seen.add(k); out.push(u) }
  }
  return out.slice(0, 8)
}

/** A top-level NIP-22 comment on the article (NIP10Thread.topLevelCommentTags): rooted by A alone for an addressable
 *  article, with this version's e; by E for one without a d tag. Lowercase k and p name the article and its author. */
export function commentTemplate(article, content, relayHint = "", now = Math.floor(Date.now() / 1000)) {
  const coord = coordinate(article), kind = String(article.kind)
  const tags = coord
    ? [["A", coord, relayHint], ["K", kind], ["P", article.pubkey], ["a", coord, relayHint], ["e", article.id, relayHint, article.pubkey]]
    : [["E", article.id, relayHint, article.pubkey], ["K", kind], ["P", article.pubkey], ["e", article.id, relayHint, article.pubkey]]
  return { kind: COMMENT, created_at: now, tags: [...tags, ["k", kind], ["p", article.pubkey]], content: String(content).trim() }
}

/** The like count with your own like in it as soon as you tap (ArticleReaderView.likeCount), and out as soon as you
 *  take it back. `mine`: actions.js myReaction(id) — { emoji } liked here, { emoji: null } taken back, null unchanged. */
export function likeCount(likers, me, mine) {
  if (!mine || !me) return likers.size
  const counted = likers.has(me)
  return likers.size + (mine.emoji && !counted ? 1 : !mine.emoji && counted ? -1 : 0)
}
