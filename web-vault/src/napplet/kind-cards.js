// The Reader napplet's article, highlight and poll cards (bug run, group 4): what each card shows is worked out here,
// in the shell, from the signed event with the classic feed card's own functions (FeedKinds.jsx: longFormMeta,
// gatedArticle, highlightSource, parsePoll, tally), so the two can't drift. The napplet only draws the strings.
import { displayTitle, longFormMeta, plainText, readingMinutes } from "../readers/longform.js"
import { gatedArticle, stripTeaser } from "../readers/gated.js"
import { highlightSource } from "../components/highlight-source.js"
import { isClosed, parsePoll, share, tally } from "../components/polls.js"

export const CARD_KINDS = [30023, 9802, 1068]
const HEX = /^[0-9a-f]{64}$/

/** An article: picture, title, "Long-form · N min read" (or Locked), the summary or the first 200 characters. */
export function articleCard(ev) {
  const m = longFormMeta(ev), gated = gatedArticle(ev)
  const minutes = gated ? null : readingMinutes(ev.content)
  return {
    type: "article", title: displayTitle(ev), image: /^https:\/\//i.test(m.image ?? "") ? m.image : null,
    meta: `Long-form${gated ? " · 🔒 Locked" : minutes ? ` · ${minutes} min read` : ""}`,
    preview: m.summary || plainText(gated ? stripTeaser(ev.content) : ev.content, 200) || "",
  }
}

/** A highlight: the highlighter's comment, the passage, and where it came from (a note id, an article's address
 *  parts, or a web page). */
export function highlightCard(ev) {
  const tags = ev.tags ?? []
  const src = highlightSource(tags)
  const source = src?.q?.type === "note" ? { note: src.q.id }
    : src?.q?.type === "addr" && Number.isInteger(src.q.kind) && HEX.test(src.q.pubkey) ? { addr: { kind: src.q.kind, pubkey: src.q.pubkey, d: src.q.d } }
    : src?.url ? { url: src.url } : null
  return { type: "highlight", comment: tags.find(t => t[0] === "comment")?.[1]?.trim() || "", passage: String(ev.content ?? "").trim(), source }
}

/** A poll with its count: options with their share once you voted or it closed, "N votes", Pick any, Ends. */
export function pollCard(ev, votes, { me = "", blocked = new Set(), now = Date.now() / 1000 } = {}) {
  const poll = parsePoll(ev)
  if (!poll) return null
  const t = tally(votes, poll, { now, blocked })
  const closed = isClosed(poll, now)
  const mine = t.picks.get(me) ?? []
  const results = closed || mine.length > 0
  return {
    type: "poll", question: poll.question, multiple: poll.multiple, endsAt: poll.endsAt, closed, mine, results, voters: t.voters.size,
    options: poll.options.map(o => ({ id: o.id, label: o.label, votes: results ? t.byOption.get(o.id)?.size ?? 0 : null, pct: results ? Math.round(share(t, o.id) * 100) : null })),
  }
}
