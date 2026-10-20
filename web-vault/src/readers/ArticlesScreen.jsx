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
import { displayDate, displayTitle, longFormLink, longFormMeta, plainText, readingMinutes } from "./longform.js"
import { Markdown } from "./Markdown.jsx"

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

  if (open) return <ArticleReader event={open} onBack={() => setOpen(null)} />
  const pick = s => { saveScope(s); setScope(s) }
  const shown = items && visibleNotes(items, blocked)
  return (
    <div class="reader-feed">
      <Scopes scopes={ARTICLE_SCOPES} value={scope} onPick={pick} onRefresh={() => load()} />
      {status && <div class="status-line">{status}</div>}
      {!follows.length ? <p class="empty">{!account.loaded ? "Loading your follows…" : scope === "following" ? "Follow someone to see their articles here."
          : "Global shows articles from people your web of trust vouches for. Follow a few people first."}</p>
        : items === null ? <p class="empty">Loading articles…</p>
        : !shown.length ? <p class="empty">{items.length ? "Every article loaded here is from someone you blocked." : scope === "following" ? "The people you follow haven't written any articles yet." : "No articles found."}</p>
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

/** One card: hero image, title, a two-line preview, then author · date · minutes. */
export function ArticleRow({ event, onOpen }) {
  const m = longFormMeta(event)
  const preview = m.summary || plainText(event.content, 200)
  const minutes = readingMinutes(event.content)
  return (
    <article class="article reader-card" tabindex="0" onClick={onOpen} onKeyDown={e => { if (e.key === "Enter") onOpen() }}>
      {m.image && <img class="article-image" src={m.image} alt="" loading="lazy" referrerpolicy="no-referrer" />}
      <h3>{displayTitle(event)}</h3>
      {preview && <p class="reader-preview">{preview}</p>}
      <div class="reader-byline muted small">
        <Avatar pubkey={event.pubkey} size={20} />
        <AuthorName pubkey={event.pubkey} />
        <span>·</span><time datetime={new Date(displayDate(event) * 1000).toISOString()}>{dateText(displayDate(event))}</time>
        {minutes && <><span>·</span><span>{minutes} min read</span></>}
      </div>
    </article>
  )
}

/** The article, full width: image, title, author line, the body, and Open in YakiHonne (zap.cooking for a recipe). */
export function ArticleReader({ event, onBack }) {
  const m = longFormMeta(event)
  const minutes = readingMinutes(event.content)
  const link = longFormLink(event)
  useEffect(() => { globalThis.scrollTo?.(0, 0) }, [event.id])
  return (
    <article class="reader">
      <div class="reader-bar">
        <button type="button" class="small" onClick={onBack}>‹ Back</button>
        {link && <a class="reader-web small" href={link.url} target="_blank" rel="noopener noreferrer">Open in {link.site}</a>}
      </div>
      {m.image && <img class="reader-hero" src={m.image} alt="" referrerpolicy="no-referrer" />}
      <h1 class="reader-title">{displayTitle(event)}</h1>
      <a class="reader-byline muted small" href={`#/profile/${event.pubkey}`}>
        <Avatar pubkey={event.pubkey} size={24} />
        <AuthorName pubkey={event.pubkey} />
        <span>·</span><span>{dateText(displayDate(event))}</span>
        {minutes && <><span>·</span><span>{minutes} min read</span></>}
      </a>
      {m.summary && <p class="reader-summary">{m.summary}</p>}
      <Markdown body={event.content} />
    </article>
  )
}
