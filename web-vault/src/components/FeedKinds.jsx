// The other posts a Following feed carries, drawn inside a note card as the iPhone draws them (FeedNoteRow+NoteBody):
// an article (ArticleInlineBody), a highlight (HighlightInlineBody) and a poll (PollCardView). The card around them
// keeps its header, its actions and its tap to the thread; an article's thread is the article itself.
import { useEffect, useState } from "preact/hooks"
import { verifyEvent } from "nostr-tools/pure"
import { NoteText } from "./NoteText.jsx"
import { QuotedNote } from "./QuotedNote.jsx"
import { LinkCard } from "./LinkCard.jsx"
import { displayTitle, longFormMeta, plainText, readingMinutes } from "../readers/longform.js"
import { gatedArticle, stripTeaser } from "../readers/gated.js"
import { isClosed, parsePoll, pollRelays, share, tally, voteTags, VOTE_KIND } from "./polls.js"
import { pool } from "../net/pool.js"
import { getBlocks, onBlocks } from "../net/blocks.js"
import { actionContext, publishAction } from "../net/actions.js"
import { READ_ONLY_SHORT } from "../signer/readonly.js"

if (import.meta.env) import("../styles/feed-kinds.css")

export const ARTICLE_KIND = 30023, HIGHLIGHT_KIND = 9802
/** Kinds a note card draws with its own body here. */
export const hasKindBody = ev => ev?.kind === ARTICLE_KIND || ev?.kind === HIGHLIGHT_KIND || ev?.kind === 1068

export function KindBody({ event, memoryOnly }) {
  if (event.kind === ARTICLE_KIND) return <ArticleBody event={event} />
  if (event.kind === HIGHLIGHT_KIND) return <HighlightBody event={event} memoryOnly={memoryOnly} />
  const poll = parsePoll(event)
  return poll ? <PollBody poll={poll} event={event} memoryOnly={memoryOnly} /> : <NoteText content={event.content} tags={event.tags} memoryOnly={memoryOnly} />
}

/** Image, title (three lines), "Long-form · N min read" (or Locked), then the summary or the first 200 characters. */
function ArticleBody({ event }) {
  const m = longFormMeta(event)
  const gated = gatedArticle(event)
  const minutes = gated ? null : readingMinutes(event.content)
  const preview = m.summary || plainText(gated ? stripTeaser(event.content) : event.content, 200)
  return (
    <div class="kind-article">
      {m.image && <img class="kind-article-image" src={m.image} alt="" loading="lazy" referrerpolicy="no-referrer" onError={e => e.currentTarget.remove()} />}
      <h3 class="kind-article-title">{displayTitle(event)}</h3>
      <div class="kind-meta"><DocIcon />Long-form{gated ? " · 🔒 Locked" : minutes ? ` · ${minutes} min read` : ""}</div>
      {preview && <p class="kind-article-preview">{preview}</p>}
    </div>
  )
}

/** What the highlighter said, "Highlighted", the passage in serif beside a bar (eight lines), then where it came
 *  from: the note or article as a quote, or the web page as a link. */
function HighlightBody({ event, memoryOnly }) {
  const tags = event.tags ?? []
  const comment = tags.find(t => t[0] === "comment")?.[1]?.trim()
  const source = highlightSource(tags)
  return (
    <div class="kind-highlight">
      {comment && <p class="kind-highlight-comment">{comment}</p>}
      <div class="kind-meta"><MarkerIcon />Highlighted</div>
      <blockquote class="kind-highlight-passage">{String(event.content ?? "").trim()}</blockquote>
      {source?.q && <QuotedNote q={source.q} short="source" memoryOnly={memoryOnly} />}
      {source?.url && <LinkCard url={source.url} />}
    </div>
  )
}

/** A highlight's source (FeedHighlight): its `a` article, else its `e` note, else an http(s) `r` page. */
export function highlightSource(tags) {
  const a = tags.find(t => t[0] === "a" && t[1])?.[1]
  if (a) {
    const [kind, pubkey, ...d] = a.split(":")
    if (/^[0-9a-f]{64}$/.test(pubkey ?? "")) return { q: { type: "addr", kind: Number(kind), pubkey, d: d.join(":"), relays: [] } }
  }
  const e = tags.find(t => t[0] === "e" && /^[0-9a-f]{64}$/.test(t[1] ?? ""))?.[1]
  if (e) return { q: { type: "note", id: e, relays: [] } }
  const r = tags.find(t => t[0] === "r" && /^https?:\/\//.test(t[1] ?? ""))?.[1]
  return r ? { url: r } : null
}

// The votes on each poll this session, so a poll scrolled back to shows its count at once (PollStore).
const votes = new Map() // poll id -> { events: Map, at }
const RELOAD_AFTER_MS = 30_000

/** The question, the options (results once you voted or it closed), and "N votes · Pick any · Ends …". */
function PollBody({ poll, memoryOnly }) {
  const ctx = actionContext()
  const me = ctx?.session?.pubkey ?? ""
  const [evs, setEvs] = useState(() => [...(votes.get(poll.id)?.events.values() ?? [])])
  const [loading, setLoading] = useState(false)
  const [blocked, setBlocked] = useState(() => getBlocks().blocked)
  useEffect(() => onBlocks(() => setBlocked(getBlocks().blocked)), [])
  useEffect(() => {
    const held = votes.get(poll.id)
    if (held && Date.now() - held.at < RELOAD_AFTER_MS) return
    const relays = pollRelays(poll, [...(ctx?.account?.relays?.read ?? [])])
    if (!relays.length) return
    let live = true
    setLoading(true)
    pool.querySync(relays, { kinds: [VOTE_KIND], "#e": [poll.id], limit: 1000 }, { maxWait: 6000 }).then(found => {
      const store = votes.get(poll.id) ?? { events: new Map(), at: 0 }
      for (const ev of found) if (ev?.kind === VOTE_KIND && verifyEvent({ ...ev })) store.events.set(ev.id, ev)
      store.at = Date.now()
      votes.set(poll.id, store)
      if (live) setEvs([...store.events.values()])
    }).catch(() => {}).finally(() => { if (live) setLoading(false) })
    return () => { live = false }
  }, [poll.id])
  const t = tally(evs, poll, { blocked })
  const closed = isClosed(poll)
  const mine = t.picks.get(me) ?? []
  const results = closed || mine.length > 0
  const n = t.voters.size
  // Voting (PollModel.vote): a kind 1018 with the picks, signed by your signer, sent to your write relays and the
  // poll's own public ones, and counted at once. Single choice votes on the tap; multiple choice gathers picks first.
  const [picked, setPicked] = useState(null) // multiple choice: the picks being gathered
  const [sending, setSending] = useState(false)
  const [error, setError] = useState("")
  const canVote = !closed && !!me
  const readOnly = !!ctx?.signer?.readOnly
  const vote = async ids => {
    if (readOnly) return setError(READ_ONLY_SHORT)
    if (sending || !ids.length || closed) return
    setSending(true); setError("")
    try {
      // The poll's own public relays, deduplicated and at most 8 (the read path's set): a stranger's poll must not
      // choose how many hosts get your signed vote and your IP.
      const pub = pollRelays(poll)
      const template = { kind: VOTE_KIND, created_at: Math.floor(Date.now() / 1000), content: "", tags: voteTags(poll, ids, pub[0] ?? "") }
      const { event } = await publishAction(ctx, template)
      if (pub.length) Promise.allSettled(pool.publish(pub, event)).catch(() => {})
      const store = votes.get(poll.id) ?? { events: new Map(), at: Date.now() }
      store.events.set(event.id, event); votes.set(poll.id, store)
      setEvs([...store.events.values()]); setPicked(null)
    } catch (e) { setError(String(e?.message ?? e)) }
    finally { setSending(false) }
  }
  const tap = id => {
    if (!canVote || sending) return
    if (!poll.multiple) { if (!(mine.length === 1 && mine[0] === id)) vote([id]); return }
    const cur = new Set(picked ?? mine)
    cur.has(id) ? cur.delete(id) : cur.add(id)
    setPicked([...cur])
  }
  const gathered = picked ?? mine
  const changed = poll.multiple && picked && picked.length > 0 && [...picked].sort().join() !== [...mine].sort().join()
  return (
    <div class="kind-poll">
      {poll.question && <p class="kind-poll-question">{poll.question}</p>}
      <div class="kind-poll-options">
        {poll.options.map(o => {
          const s = share(t, o.id), selected = poll.multiple ? gathered.includes(o.id) : mine.includes(o.id)
          return (
            <button type="button" key={o.id} class={`kind-poll-option${selected ? " picked" : ""}`} disabled={!canVote || sending}
              aria-pressed={selected} aria-label={results ? `${o.label}, ${t.byOption.get(o.id)?.size ?? 0} votes` : o.label}
              onClick={e => { e.stopPropagation(); tap(o.id) }}>
              {results && <span class="kind-poll-bar" style={`width: ${Math.round(s * 100)}%`} aria-hidden="true" />}
              <span class="kind-poll-mark" aria-hidden="true">{poll.multiple ? (selected ? "☑" : "☐") : (selected ? "◉" : "○")}</span>
              <span class="kind-poll-label">{o.label}</span>
              {results && <span class="kind-poll-pct">{Math.round(s * 100)}%</span>}
            </button>
          )
        })}
      </div>
      {changed && <button type="button" class="primary kind-poll-vote" disabled={sending} onClick={e => { e.stopPropagation(); vote(picked) }}>{mine.length ? "Change vote" : "Vote"}</button>}
      <div class="kind-meta">
        <ChartIcon />{n === 1 ? "1 vote" : `${n} votes`}{poll.multiple ? " · Pick any" : ""}
        {poll.endsAt && (closed ? " · Final results" : ` · Ends ${endsIn(poll.endsAt)}`)}
        {(loading || sending) && <span class="kind-spinner" aria-label={sending ? "Sending your vote" : "Loading votes"} />}
      </div>
      {error && <p class="kind-poll-error" role="alert">{error}</p>}
    </div>
  )
}

/** "in 3 hours", "tomorrow": when an open poll closes. */
function endsIn(ts) {
  const s = ts - Date.now() / 1000
  const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" })
  if (s < 3600) return rtf.format(Math.max(1, Math.round(s / 60)), "minute")
  if (s < 86400) return rtf.format(Math.round(s / 3600), "hour")
  return rtf.format(Math.round(s / 86400), "day")
}

const icon = d => () => <svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>
const DocIcon = icon("M6 3h8l4 4v14H6zM14 3v4h4M9 12h6M9 16h6")
const MarkerIcon = icon("M15 4l5 5-9 9H6v-5zM4 21h7")
const ChartIcon = icon("M4 20V10M10 20V4M16 20v-7M22 20H2")
