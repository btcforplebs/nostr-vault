// The tab bar and list under a profile header (net/profile-tabs.js), shared by your profile and someone else's.
// `notes` is the profile's own stream (kind 1s and 6s) and `tagged` the notes that tag it, each from useNoteStream;
// `articles` its kind 30023s, null while they load (the Articles tab shows only once there are some). `pubkey` keeps
// their own notes out of Tagged, `blocked` keeps out people the user blocked. `shop` is their listings (net/profile-tabs.js
// fetchShop), null while they load; `own` keeps the Shop tab up on your own profile with nothing listed.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { NoteCard } from "../components/NoteCard.jsx"
import { ArticleCard } from "../components/ArticleCard.jsx"
import { MediaGrid } from "../components/MediaGrid.jsx"
import { OlderButton, SkeletonRows } from "../components/FeedExtras.jsx"
import { SkeletonGrid } from "../components/Loading.jsx"
import { AUTO_PAGES, QUIET_PAGES, emptyText, isNoteTab, latestArticles, mergeOlder, shopEmptyText, splitProfileNotes, taggedNotes, visibleTabs } from "../net/profile-tabs.js"
import { ListingView, MarketTile } from "../readers/MarketplaceScreen.jsx"

if (import.meta.env) import("../styles/feeds.css")

if (import.meta.env) import("../styles/profile.css")

// Icons only, with the count beside them, as the iPhone's tabs (ProfileContent+Sections): its SF Symbols drawn as
// paths: text.bubble, photo.on.rectangle, arrowshape.turn.up.left, arrow.2.squarepath, at, doc.richtext, bag.
const TAB_ICONS = {
  notes: "M4 5h16v11H9l-4 3v-3H4zM8 9h8M8 12h5",
  media: "M7 7h13v11H7zM4 4h13M4 4v11M10 15l3-3 2 2 2-2 3 3M15.5 10.5h.01",
  replies: "M10 5L4 11l6 6M4 11h10a6 6 0 0 1 6 6v2",
  reposts: "M17 3l3 3-3 3M4 11V9a3 3 0 0 1 3-3h13M7 21l-3-3 3-3M20 13v2a3 3 0 0 1-3 3H4",
  tagged: "M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0zM16 12v1.5a2.5 2.5 0 0 0 5 0V12a9 9 0 1 0-3.5 7.1",
  articles: "M6 3h9l4 4v14H6zM14 3v5h5M9 12h7M9 15h7M9 18h4",
  shop: "M5 8h14l-1 13H6zM9 8V6a3 3 0 0 1 6 0v2",
}
const TabIcon = ({ id, size = 16 }) => (
  <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={TAB_ICONS[id]} /></svg>
)
// "48", or "48+" while older pages may still raise it: the notes loaded, not totals (the iPhone's countLabel).
const countLabel = (n, more) => (n > 0 ? (n >= 1000 ? (n / 1000).toFixed(1).replace(/\.0$/, "") + "k" : String(n)) + (more ? "+" : "") : "")

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

export function ProfileTabs({ notes, tagged, articles, shop, own = false, pubkey, blocked }) {
  const [tab, setTab] = useState("notes")
  const [listing, setListing] = useState(null)
  const split = useMemo(() => splitProfileNotes(notes.items), [notes.items])
  const tags = useMemo(() => taggedNotes(tagged.items, pubkey, blocked), [tagged.items, pubkey, blocked])
  const arts = useMemo(() => (articles ? latestArticles(articles) : []), [articles])
  const listings = shop ?? []
  const tabs = visibleTabs(arts, listings, own)
  const on = tabs.some(t => t.id === tab) ? tab : "notes"
  const stream = on === "tagged" ? tagged : notes
  const list = on === "shop" ? listings : on === "articles" ? arts : on === "tagged" ? tags : split[on]
  const olderLeft = stream.hasMore && stream.items.length > 0
  const loading = (stream.opening && !list.length) || stream.paging
  const tabCount = id => (id === "shop" ? listings.length : id === "articles" ? arts.length : id === "tagged" ? tags.length : split[id]?.length ?? 0)

  // An empty tab pages back by itself, up to AUTO_PAGES, then offers "Look further back" (autoPageEmptyTab).
  const spent = useRef({})
  useEffect(() => {
    if (!isNoteTab(on) || list.length || stream.opening || stream.paging || !olderLeft) return
    const n = spent.current[on] ?? 0
    if (n >= AUTO_PAGES) return
    spent.current[on] = n + 1
    stream.loadOlder()
  }, [on, list.length, stream.opening, stream.paging, olderLeft])

  // A listing opens in place of the tabs, as the Marketplace's does; Back returns to the Shop.
  if (listing) return <ListingView listing={listing} onBack={() => setListing(null)} />
  return (
    <>
      <div class="segmented profile-tabs" role="tablist" aria-label="Profile">
        {tabs.map(t => {
          const count = countLabel(tabCount(t.id), isNoteTab(t.id) && (t.id === "tagged" ? tagged : notes).hasMore)
          return (
            <button key={t.id} role="tab" aria-selected={on === t.id} class={on === t.id ? "on" : ""} title={t.label}
              aria-label={count ? `${t.label}, ${count}` : t.label} onClick={() => setTab(t.id)}>
              <TabIcon id={t.id} />{count && <span class="tab-count">{count}</span>}
            </button>
          )
        })}
      </div>
      {on === "shop" ? (!list.length
        ? <div class="empty" style="padding-block:36px"><span style="opacity:.5"><TabIcon id="shop" size={24} /></span><p style="margin:10px 0 0">{shopEmptyText({ loading: shop === null, own })}</p></div>
        : <div class="market-grid">{list.map(l => <MarketTile key={l.id} listing={l} onOpen={() => setListing(l)} />)}</div>)
        : !list.length && loading ? (on === "media" ? <SkeletonGrid count={9} tileClass="media-tile" /> : <SkeletonRows count={3} label={emptyText(on, { loading })} />)
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
