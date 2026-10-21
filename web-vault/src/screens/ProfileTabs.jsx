// The tab bar and list under a profile header (net/profile-tabs.js), shared by your profile and someone else's.
// `notes` is the profile's own stream (kind 1s and 6s) and `tagged` the notes that tag it, each from useNoteStream;
// `articles` its kind 30023s, null while they load (the Articles tab shows only once there are some). `pubkey` keeps
// their own notes out of Tagged, `blocked` keeps out people the user blocked.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { NoteCard } from "../components/NoteCard.jsx"
import { ArticleCard } from "../components/ArticleCard.jsx"
import { MediaGrid } from "../components/MediaGrid.jsx"
import { OlderButton, SkeletonRows } from "../components/FeedExtras.jsx"
import { SkeletonGrid } from "../components/Loading.jsx"
import { AUTO_PAGES, QUIET_PAGES, emptyText, isNoteTab, latestArticles, mergeOlder, splitProfileNotes, taggedNotes, visibleTabs } from "../net/profile-tabs.js"

if (import.meta.env) import("../styles/feeds.css")

// Six text tabs are wider than a phone with .segmented's button padding: tighter here, and the bar scrolls rather than
// the page. Inline until the icon tabs (styles, another lane) replace the words.
const BAR = { overflowX: "auto", scrollbarWidth: "none" }
const TAB = { padding: "0 6px", minWidth: "max-content" }

/**
 * One of a profile's note streams, paged back as the iPhone's ProfileFeedLoader pages: `open(show)` loads the opening
 * list (show() puts up a first, cached one meanwhile); `older(until)` a page at or before `until`. Two quiet pages in a
 * row end it. `deps` start it again. -> { items, opening, paging, hasMore, loadOlder, reload }
 */
export function useNoteStream(open, older, deps) {
  const [items, setItems] = useState([])
  const [opening, setOpening] = useState(true)
  const [paging, setPaging] = useState(false)
  const [hasMore, setHasMore] = useState(true)
  const s = useRef({ gen: 0, quiet: 0, items: [], paging: false, opening: true }).current
  const fns = useRef({})
  fns.current = { open, older }
  const reload = async () => {
    const gen = ++s.gen
    s.quiet = 0; s.opening = true
    setOpening(true); setHasMore(true)
    const show = evs => { if (gen === s.gen) { s.items = evs; setItems(evs) } }
    try { show(await fns.current.open(show)) } catch {} finally { if (gen === s.gen) { s.opening = false; setOpening(false) } }
  }
  useEffect(() => { reload(); return () => { s.gen++ } }, deps)
  const loadOlder = async () => {
    // Not while the opening load runs: its list replaces what a page would add.
    if (s.opening || s.paging || !s.items.length) return
    const gen = s.gen
    s.paging = true; setPaging(true)
    try {
      const page = await fns.current.older(s.items.at(-1).created_at).catch(() => [])
      if (gen !== s.gen) return
      const { list, grew } = mergeOlder(s.items, page)
      s.quiet = grew ? 0 : s.quiet + 1
      if (s.quiet >= QUIET_PAGES) setHasMore(false)
      s.items = list; setItems(list)
    } finally { s.paging = false; setPaging(false) }
  }
  return { items, opening, paging, hasMore, loadOlder, reload }
}

export function ProfileTabs({ notes, tagged, articles, pubkey, blocked }) {
  const [tab, setTab] = useState("notes")
  const split = useMemo(() => splitProfileNotes(notes.items), [notes.items])
  const tags = useMemo(() => taggedNotes(tagged.items, pubkey, blocked), [tagged.items, pubkey, blocked])
  const arts = useMemo(() => (articles ? latestArticles(articles) : []), [articles])
  const tabs = visibleTabs(arts)
  const on = tabs.some(t => t.id === tab) ? tab : "notes"
  const stream = on === "tagged" ? tagged : notes
  const list = on === "articles" ? arts : on === "tagged" ? tags : split[on]
  const olderLeft = stream.hasMore && stream.items.length > 0
  const loading = (stream.opening && !list.length) || stream.paging

  // An empty tab pages back by itself, up to AUTO_PAGES, then offers "Look further back" (autoPageEmptyTab).
  const spent = useRef({})
  useEffect(() => {
    if (!isNoteTab(on) || list.length || stream.opening || stream.paging || !olderLeft) return
    const n = spent.current[on] ?? 0
    if (n >= AUTO_PAGES) return
    spent.current[on] = n + 1
    stream.loadOlder()
  }, [on, list.length, stream.opening, stream.paging, olderLeft])

  return (
    <>
      <div class="segmented profile-tabs" role="tablist" aria-label="Profile" style={BAR}>
        {tabs.map(t => <button key={t.id} role="tab" aria-selected={on === t.id} class={on === t.id ? "on" : ""} style={TAB} onClick={() => setTab(t.id)}>{t.label}</button>)}
      </div>
      {!list.length && loading ? (on === "media" ? <SkeletonGrid count={9} tileClass="media-tile" /> : <SkeletonRows count={3} label={emptyText(on, { loading })} />)
        : !list.length ? (
        <>
          <p class="empty">{emptyText(on, { loading, olderLeft })}</p>
          {olderLeft && <button type="button" class="more" onClick={stream.loadOlder}>Look further back</button>}
        </>
      ) : on === "media" ? <MediaGrid tiles={list} />
        : on === "articles" ? list.map(a => <ArticleCard key={a.id} event={a} />)
        : list.map(n => <NoteCard key={n.id} event={n} memoryOnly={on === "tagged"} />)}
      {list.length > 0 && isNoteTab(on) && !stream.opening && <OlderButton onOlder={stream.loadOlder} state={stream.paging ? "busy" : stream.hasMore ? "" : "end"} />}
    </>
  )
}
