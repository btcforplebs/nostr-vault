// The Articles feed and its reader (the iPhone's ArticleCardView and ArticleReaderView): Following or Global (your
// web of trust),
// cards with image, title, summary, author, date and reading time; a card opens the article with its body rendered
// and an "Open in YakiHonne" link.
import { useEffect, useRef, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { useBlocks } from "../components/useBlocks.js"
import { visibleNotes } from "../net/blocks.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { ARTICLE_SCOPES, PAGE, fetchArticles, loadScope, saveScope } from "./articles.js"
import { displayDate, displayTitle, longFormMeta, plainText, readingMinutes } from "./longform.js"
import { eventWebLink } from "../net/web-link.js"
import { Markdown } from "./Markdown.jsx"
import { ArticleEngagement } from "./Engagement.jsx"
import { EmptyState } from "./EmptyState.jsx"
import { copyLink, shareLink, threadLink } from "./share.js"
import { fanfaresLink, gatedArticle, lockStatus, stripTeaser } from "./gated.js"
import { useProfile } from "../components/useProfile.js"
import { SkeletonRows } from "../components/FeedExtras.jsx"

if (import.meta.env) import("./readers.css")

export function ArticlesScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
  const [scope, setScope] = useState(loadScope)
  const [items, setItems] = useState(null)
  const [status, setStatus] = useState("")
  const [open, setOpen] = useState(null)
  const [more, setMore] = useState(true)
  const { blocked } = useBlocks(ctx)
  const seq = useRef(0)
  const relays = scope === "following" ? uniq([...account.relays.read, ...DEFAULT_RELAYS]) : account.relays.read

  const load = async until => {
    const n = ++seq.current
    if (!follows.length) { setItems([]); return setStatus("") }
    setStatus(until ? "Fetching older articles…" : "Loading articles…")
    try {
      const { articles, fromNetwork } = await fetchArticles({ scope, me: ctx.session?.pubkey, follows, relays, vault, until })
      if (n !== seq.current) return
      setItems(have => (until ? [...(have ?? []), ...articles.filter(a => !have?.some(h => h.id === a.id))] : articles))
      setMore(articles.length >= PAGE / 2)
      setStatus(!fromNetwork && navigator.onLine === false ? "Offline: showing saved articles" : "")
      fetchProfiles(vault, articles.map(a => a.pubkey), account.relays.read, { save: scope === "following" }).catch(() => {})
    } catch (e) { if (n === seq.current) setStatus(`Couldn't load (${e?.message ?? e})`) }
  }
  useEffect(() => { setItems(null); setOpen(null); load() }, [scope, follows.length])

  if (open) return <ArticleReader event={open} onBack={() => setOpen(null)} ctx={ctx} />
  const pick = s => { saveScope(s); setScope(s) }
  const shown = items && visibleNotes(items, blocked)
  return (
    <div class="reader-feed">
      <Scopes scopes={ARTICLE_SCOPES} value={scope} onPick={pick} onRefresh={() => load()} />
      {status && <div class="status-line">{status}</div>}
      {!follows.length ? <p class="empty">{!account.loaded ? "Loading your follows…" : scope === "following" ? "Follow someone to see their articles here."
          : "Global shows articles from people your web of trust vouches for. Follow a few people first."}</p>
        : items === null ? <SkeletonRows count={3} label="Loading articles…" />
        : !shown.length ? (items.length ? <p class="empty">Every article loaded here is from someone you blocked.</p>
          : <EmptyState title="No articles yet" detail={scope === "following" ? "Long-form posts from people you follow show up here. Nothing to read yet." : "Long-form posts from across Nostr show up here. Nothing to read yet."} />)
        : <>
          {shown.map(a => <ArticleRow key={a.id} event={a} onOpen={() => setOpen(a)} />)}
          {more && <button class="more" onClick={() => load(items.at(-1).created_at - 1)}>Older articles</button>}
        </>}
    </div>
  )
}

/** Following / Global capsules and Refresh, under the feed picker. Shared by the reader feeds. */
export function Scopes({ scopes, value, onPick, onRefresh }) {
  return (
    <div class="reader-scopes">
      <div class="reader-scope-row" role="tablist" aria-label="Show">
        {scopes.map(s => <button key={s.id} type="button" role="tab" aria-selected={value === s.id} class={value === s.id ? "on" : ""} onClick={() => onPick(s.id)}>{s.label}</button>)}
      </div>
      {onRefresh && <button type="button" class="small" onClick={onRefresh}>Refresh</button>}
    </div>
  )
}

const dateText = ts => new Date(ts * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })

/** One card: hero image, title, a two-line preview, then author · date · minutes · Open in YakiHonne (the iPhone's
 *  long-press "Open in …"). */
export function ArticleRow({ event, onOpen }) {
  const m = longFormMeta(event)
  const link = eventWebLink(event)
  const gated = gatedArticle(event)
  const preview = m.summary || plainText(gated ? stripTeaser(event.content) : event.content, 200)
  const minutes = readingMinutes(event.content)
  const topics = m.topics.slice(0, 3) // a handful keeps the card one line; authors sometimes attach a dozen
  return (
    <article class="article reader-card" tabindex="0" onClick={onOpen} onKeyDown={e => { if (e.key === "Enter") onOpen() }}>
      {m.image && <img class="article-image" src={m.image} alt="" loading="lazy" referrerpolicy="no-referrer" />}
      <h3>{displayTitle(event)}</h3>
      {preview && <p class="reader-preview">{preview}</p>}
      {topics.length > 0 && <div class="reader-topics">{topics.map(t => <span key={t} class="reader-topic">{t}</span>)}</div>}
      <div class="reader-byline muted small">
        <a class="reader-author" href={`#/profile/${event.pubkey}`} onClick={e => e.stopPropagation()}><Avatar pubkey={event.pubkey} size={20} />
        <AuthorName pubkey={event.pubkey} /></a>
        <span>·</span><time datetime={new Date(displayDate(event) * 1000).toISOString()}>{dateText(displayDate(event))}</time>
        {gated ? <><span>·</span><span class="reader-locked">🔒 Locked</span></> : minutes && <><span>·</span><span>{minutes} min read</span></>}
        {link && <><span>·</span><OpenInWeb link={link} /></>}
      </div>
    </article>
  )
}

/** The article, full width: image, title, author line, the body, and Open in YakiHonne (zap.cooking for a recipe).
 *  With `ctx`, its likes, comments, zaps and highlights follow, read-only. */
export function ArticleReader({ event, onBack, ctx }) {
  const m = longFormMeta(event)
  const gated = gatedArticle(event)
  const minutes = gated ? null : readingMinutes(event.content)
  const link = eventWebLink(event)
  const web = threadLink(event)
  const [said, setSaid] = useState("")
  const tell = r => { setSaid(r === "copied" ? "Link copied" : r === "failed" ? "Couldn't copy the link" : ""); if (r === "copied") setTimeout(() => setSaid(""), 2000) }
  useEffect(() => { globalThis.scrollTo?.(0, 0) }, [event.id])
  return (
    <article class="reader">
      <div class="reader-bar">
        <button type="button" class="small" onClick={onBack}>‹ Back</button>
        {link && <OpenInWeb link={link} />}
      </div>
      {m.image && <img class="reader-hero" src={m.image} alt="" referrerpolicy="no-referrer" />}
      <h1 class="reader-title">{displayTitle(event)}</h1>
      <a class="reader-byline muted small" href={`#/profile/${event.pubkey}`}>
        <Avatar pubkey={event.pubkey} size={24} />
        <AuthorName pubkey={event.pubkey} />
        <span>·</span><span>{dateText(displayDate(event))}</span>
        {gated ? <><span>·</span><span class="reader-locked">🔒 Locked</span></> : minutes && <><span>·</span><span>{minutes} min read</span></>}
      </a>
      {m.summary && <p class="reader-summary">{m.summary}</p>}
      {web && (
        <div class="reader-actions">
          <button type="button" class="small" onClick={async () => tell(await shareLink(web, displayTitle(event)))}>Share</button>
          <button type="button" class="small" onClick={async () => tell(await copyLink(web))}>{said || "Copy link"}</button>
        </div>
      )}
      {gated ? <LockedBody event={event} gated={gated} summary={m.summary} /> : <Markdown body={event.content} />}
      {ctx && <ArticleEngagement ctx={ctx} article={event} />}
    </article>
  )
}

/** "Open in zap.cooking" and friends (the iPhone's OpenInWebButton): a new tab on the post's site. A click or Enter on it never
 *  opens the card it sits on. */
export function OpenInWeb({ link }) {
  return <a class="reader-web small" href={link.url} target="_blank" rel="noopener noreferrer" title={`Open in ${link.site}`} onClick={e => e.stopPropagation()} onKeyDown={e => e.stopPropagation()}>Open in {link.site}</a>
}

/** A locked article: its teaser, then a lock card that links out. The web never pays for or unlocks an article. */
export function LockedBody({ event, gated, summary }) {
  const profile = useProfile(event.pubkey)
  return <LockedTeaser event={event} gated={gated} summary={summary} author={profile?.display_name || profile?.name || "the author"} />
}

export function LockedTeaser({ event, gated, summary, author }) {
  const teaser = stripTeaser(event.content)
  const url = fanfaresLink(event, gated)
  return (
    <>
      {teaser && teaser !== summary && <Markdown body={teaser} />}
      <div class="reader-lock">
        <strong>🔒 Locked article</strong>
        <p class="muted small">{lockStatus(author, gated.isFanfares)}</p>
        {url && <a class="reader-lock-open" href={url} target="_blank" rel="noopener noreferrer">Open in Fanfares</a>}
      </div>
    </>
  )
}
