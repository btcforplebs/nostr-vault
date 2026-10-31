// An article's likes, comments, zaps and highlights under the reader, read-only (the iPhone's ArticleReaderView
// action counts, commentsSection and highlights list). Zap receipts only count once their zap request checks out and
// the payee's zap service published them (net/zaps.js trustedReceipts), as in Live chat.
import { useEffect, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { NoteText } from "../components/NoteText.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { ago } from "../components/time.js"
import { formatSats } from "../net/notifications.js"
import { fetchPersonLists } from "../net/person.js"
import { pool } from "../net/pool.js"
import { fetchProfiles } from "../net/profiles.js"
import { receiptTrust } from "../net/zaps.js"
import { coordinate, engagementFilters, engagementRelays, highlightFilters, shownHighlights, tally, visibleEvents } from "./engagement.js"

/** Every event about the article: your read relays first, then the author's write relays as they become known. */
function useArticleEvents(ctx, article) {
  const [evs, setEvs] = useState(null)
  useEffect(() => {
    let live = true
    const all = new Map()
    const coord = coordinate(article)
    const filters = [...engagementFilters(article.id, coord), ...highlightFilters(article.id, coord)]
    const read = engagementRelays(ctx.account.relays.read)
    const ask = relays => Promise.all(filters.map(f => pool.querySync(relays, f, { maxWait: 8000 }).catch(() => [])))
      .then(lists => { if (!live) return; for (const ev of lists.flat()) all.set(ev.id, ev); setEvs([...all.values()]) })
    ask(read)
    fetchPersonLists(article.pubkey, read).then(({ relays }) => {
      const extra = engagementRelays(read, relays.write).filter(r => !read.includes(r))
      if (live && extra.length) return ask(extra)
    }).catch(() => {})
    return () => { live = false }
  }, [article.id])
  return evs
}

export function ArticleEngagement({ ctx, article }) {
  const evs = useArticleEvents(ctx, article)
  const { blocked } = useBlocks(ctx)
  const [trusted, setTrusted] = useState(null)
  useEffect(() => {
    if (!evs) return
    let live = true
    receiptTrust(ctx)(visibleEvents(evs, blocked)).then(ok => {
      if (!live) return
      setTrusted(ok)
      fetchProfiles(ctx.vault, [...new Set(ok.filter(e => e.kind !== 9735).map(e => e.pubkey))].slice(0, 200), ctx.account.relays.read, { save: false }).catch(() => {})
    })
    return () => { live = false }
  }, [evs, blocked.size])
  if (!trusted) return <p class="muted small reader-engage-loading">Loading likes and comments…</p>
  return <EngagementView article={article} events={trusted} />
}

const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`

/** The counts, the highlights, then the comments, from events already filtered for blocks and receipt trust. */
export function EngagementView({ article, events }) {
  const coord = coordinate(article)
  const t = tally(events, article.id, coord)
  const highlights = shownHighlights(events, article.id, coord)
  const counts = [
    t.likers.size && plural(t.likers.size, "like", "likes"),
    t.commentCount && plural(t.commentCount, "comment", "comments"),
    t.zapSats && `⚡ ${formatSats(t.zapSats)} sats`,
    highlights.length && plural(highlights.length, "highlight", "highlights"),
  ].filter(Boolean)
  return (
    <section class="reader-engage" aria-label="Likes, comments and highlights">
      <p class="muted small">{counts.length ? counts.join(" · ") : "No likes or comments yet."}</p>
      {highlights.length > 0 && <>
        <h2 class="reader-engage-head">Highlights · {highlights.length}</h2>
        {highlights.map(h => (
          <figure key={h.id} class="reader-highlight">
            <blockquote>{h.passage}</blockquote>
            <figcaption class="muted small">{h.comment && <span class="reader-highlight-comment">{h.comment} — </span>}<AuthorName pubkey={h.pubkey} /></figcaption>
          </figure>
        ))}
      </>}
      {t.commentCount > 0 && <>
        <h2 class="reader-engage-head">Comments · {t.commentCount}</h2>
        {t.topLevel.map(c => (
          <div key={c.id} class="reader-comment" role="link" tabindex="0" onClick={e => { if (!e.target.closest("a")) location.hash = `#/thread/${c.id}` }}
            onKeyDown={e => { if (e.key === "Enter") location.hash = `#/thread/${c.id}` }}>
            <div class="reader-byline muted small"><a href={`#/profile/${c.pubkey}`} class="reader-author"><Avatar pubkey={c.pubkey} size={20} /><AuthorName pubkey={c.pubkey} /></a>
              <time datetime={new Date(c.created_at * 1000).toISOString()}>{ago(c.created_at)}</time></div>
            {/* Names and links, as ArticleCommentRow's NostrContentFormatter; a stranger's quotes and names stay in memory. */}
            <div class="reader-comment-text"><NoteText content={String(c.content ?? "").trim()} tags={c.tags} author={c.pubkey} memoryOnly /></div>
            {t.replyCounts.get(c.id) > 0 && <span class="muted small">{plural(t.replyCounts.get(c.id), "reply", "replies")}</span>}
          </div>
        ))}
      </>}
    </section>
  )
}
