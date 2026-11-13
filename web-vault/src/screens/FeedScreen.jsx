// The Feed, with the picker (net/feeds.js). Following and Media are rendered only from Haven /feed; the network fills
// /feed in the background. Global, Hashtag and Popular come from the network into memory only: strangers' notes never
// go into /feed.
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks"
import { FeedRows, rootFetcher } from "../components/FeedRows.jsx"
import { MediaGrid } from "../components/MediaGrid.jsx"
import { feedPostOpen, savedFeedSpot, useFeedSpot } from "../components/feed-tap.js"
import { AT_TOP_PX, holdSpot, readingSpot, rebasePins } from "../components/feed-stay.js"
import { MAX_NOTES, DRAW_NOTES, GROW_PX, capNotes, capOlder, readLimit, drawNotes, nextDraw, freshNotes, insertNotes, mergeReload } from "../net/feed-window.js"
import { FeedModeMenu, FeedToolbar } from "../components/FeedPickerMenu.jsx"
import { EditFeeds } from "../components/EditFeeds.jsx"
import { FeedDashboard } from "../components/FeedDashboard.jsx"
import { readFeed, syncFeed, FEED_KINDS } from "../net/sync.js"
import { watchFollowing, watchLive } from "../net/feed-live.js"
import { pool, DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { fetchProfiles } from "../net/profiles.js"
import { backgroundFill } from "../net/vault-ready.js"
import { markSynced, syncedRecently } from "../net/feed-synced.js"
import { visibleNotes } from "../net/blocks.js"
import { useBlocks } from "../components/useBlocks.js"
import { feedList, loadMenu, saveMenu, visibleFeeds, PINNED_FEED, loadChoice, linkChoice, feedRelays, LINK_PARAMS, saveChoice, normalizeTag, fetchStrangerFeed, mergePage, statusGate, heldNotes, holdNotes, noteAuthors, feedKey, readsHaven, globalLike, withScope, saveMediaScope, liveFilters, liveKeeps, trustScoped } from "../net/feeds.js"
import { fetchPopular, audienceKeeps, popularRanks } from "../net/popular.js"
import { setEveryone, everyoneLocked } from "../net/global-trust.js"
import { SCREENED_LINE } from "../net/topic-filter.js"
import { EveryoneShieldDialog } from "../components/EveryoneShieldDialog.jsx"
import { EveryoneBanner } from "../components/EveryoneBanner.jsx"
import { discoverNetwork, fetchDiscover } from "../net/discover.js"
import { globalTrust } from "../readers/trust.js"
import { mediaTiles } from "../net/media.js"
import { READERS } from "../readers/index.js"
import { withParam } from "../desktop/routes.js"
import { resolveList } from "../net/list-feed.js"
import { hasLayouts, loadLayout, migrateCondensedLayouts, nextLayout, saveLayout } from "../net/feed-layout.js"
import { applyFilters, layoutFilters, loadFilters, newerNotes, saveFilters } from "../net/feed-filters.js"
import { EmptyFollowing, NewPostsPill, OlderButton, PullIndicator, SkeletonRows, usePullToRefresh, feedScroller, scrollTopOf, scrollToTop } from "../components/FeedExtras.jsx"

if (import.meta.env) import("../styles/feeds.css")

const PAGE = 100
const LIVE_SINCE_S = 60 // a live REQ opens this far back, so a note whose author's clock is a little behind still arrives
const POPULAR_RECHECK_MS = 10 * 60_000 // Popular is ranked again this often while it is on screen
const OPEN_RETRY_MS = 1500 // new notes wait while a post is open in place; looked at again this often
const EMPTY_RETRY_MS = 60_000 // an empty Discover asks its relays again this often while it is on screen
const MEDIA_PAGE = 300 // most notes have no media, so Media reads more at a time (the iPhone asks for 300)
const FEEDS = feedList(READERS)
const FEED_IDS = FEEDS.map(f => f.id)
const readerFor = mode => READERS.find(r => r.id === mode)
// A saved feed that Edit Feeds has since hidden opens Following; a link still opens its feed: a #tag link its tag, a
// rail favourite its feed, relay or list (net/feeds.js linkChoice).
const pickedChoice = () => withScope(linkChoice(globalThis.location?.hash, FEED_IDS) ?? loadChoice(globalThis.localStorage, visibleFeeds(FEEDS, loadMenu())))
// Once the Feed has taken a link's feed, the address drops it: Back and a reload keep the feed the user is on.
const dropTag = () => history.replaceState(history.state, "", LINK_PARAMS.reduce((h, k) => withParam(h, k, null), location.hash))

export function FeedScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
  const me = ctx.session?.pubkey
  const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const [notes, setNotes] = useState(null)
  // How many of the notes to draw (Spec 2): the list in memory is capped at MAX_NOTES and the DOM at this window, which
  // grows in DRAW_NOTES steps as the reader nears the bottom (feed-window.js).
  const [drawCount, setDrawCount] = useState(DRAW_NOTES)
  const [status, setStatus] = useState("")
  const [syncing, setSyncing] = useState(false)
  const { blocked, privateNote } = useBlocks(ctx)
  const [choice, setChoice] = useState(pickedChoice)
  const [strange, setStrange] = useState(() => heldNotes(pickedChoice()))
  // Expanded / Threaded, one per feed (FeedView+Layout). Re-read when the feed changes.
  const [layouts, setLayouts] = useState({})
  const layout = layouts[choice.mode] ?? loadLayout(choice.mode)
  // Replies, Reposts and Auto-load (FeedView+ToolbarMenu), for every feed of notes.
  // A saved Compact View becomes expanded, which starts with Replies off (once: the rewrite is saved).
  const [filters, setFilters] = useState(() => {
    const f = loadFilters()
    if (!migrateCondensedLayouts()) return f
    const off = { ...f, replies: false }
    saveFilters(off)
    return off
  })
  const changeFilters = f => { saveFilters(f); setFilters(f) }
  const cycleLayout = () => {
    const l = nextLayout(layout)
    saveLayout(choice.mode, l)
    setLayouts({ ...layouts, [choice.mode]: l })
    // Expanded starts with Replies off, threaded with them on; the Replies switch can still flip them.
    const next = layoutFilters(l, filters)
    if (next !== filters) changeFilters(next)
  }
  // New notes a background sync found, held behind the pill until it is tapped (or loaded at once with Auto-load).
  const [pending, setPending] = useState([])
  // The same for Global, Hashtag, Discover (live, net/feed-live.js) and Popular (ranked again): held in memory, as their
  // notes are, and dropped on a switch. Popular's tap shows the whole new ranking (`popularNext`).
  const [strangePending, setStrangePending] = useState([])
  const popularNext = useRef(null)
  const popularScores = useRef(new Map()) // note id -> its Popular score (net/popular.js), for the rank line
  const [audience, setAudience] = useState("all") // Popular from (net/popular.js AUDIENCES), this visit only
  const [ranks, setRanks] = useState(false) // Popular's rank line, off as on the iPhone
  const [shieldAsk, setShieldAsk] = useState(null) // Global's Everyone: "warn" | "lock" while asking
  // Older: "" | "busy" | "end" | an error message. One load at a time; a feed switch starts over.
  const [olderState, setOlderState] = useState("")
  // A reader (Articles, Live, …) draws its own list under the picker; the notes below are not loaded for it.
  const Reader = readerFor(choice.mode)?.Screen
  // `following`: read from Haven /feed (Following, and Media on Following). Media on Global is a stranger feed.
  const following = readsHaven(choice), media = choice.mode === "media", popular = choice.mode === "popular"
  // A hashtag under the Everyone lock (fewer than 5 follows) opens screened, not empty (net/feeds.js screenedHashtag).
  const hashtagScreened = c => c.mode === "hashtag" && everyoneLocked(follows, me)
  // Global, Media on Global, Popular and Discover are all read through your web of trust, so they wait for your follows.
  const global = globalLike(choice), discover = choice.mode === "discovery", needsWeb = popular || global || discover
  // Discover's network (net/discover.js), worked out once per follow list and kept for Older: { key, people }.
  const network = useRef(null)
  const discoverPeople = async () => {
    const key = `${me}:${follows.length}:${blocked.size}`
    if (network.current?.key !== key || !network.current.people.length) network.current = { key, people: await discoverNetwork(me, follows, { blocked }) }
    return network.current.people
  }
  const page = media ? MEDIA_PAGE : PAGE
  // A sync started on Following reloads when it ends, maybe after a switch to Media: it reads with the page size
  // and note count of the feed shown then, not of the render that started it.
  const shownNow = useRef({})
  shownNow.current = { page, have: notes?.length ?? 0 }
  // One number per feed shown: picking a feed or starting a stranger load bumps it, and work started under an older
  // number (a Following sync, a Global page) no longer writes the status line.
  const seq = useRef(0)
  // The newest note this screen has ever shown. Only notes newer than this may join above the list: once "Older" has
  // trimmed the top (the ceiling), a reload's page is newer than the list's own top, and without the watermark the
  // whole page would go back in above the reader and push them down by every page they had scrolled past (mergeReload).
  const seenTop = useRef(0)
  const pick = c => { c = withScope(c); seq.current++; seenTop.current = 0; saveChoice(c); setChoice(c); setStrange(heldNotes(c)); setStrangePending([]); setStatus(""); setOlderState("") }
  // Media's Following / Global buttons (FeedView+Toolbar.swift).
  const pickScope = scope => { if (scope !== choice.scope) { saveMediaScope(scope); pick({ ...choice, scope }) } }
  const sayer = () => statusGate(seq, setStatus)
  // Edit Feeds: the picker's order and hidden feeds. Hiding the feed you're on takes you back to Following.
  const [menu, setMenu] = useState(loadMenu)
  const [editing, setEditing] = useState(false)
  const [dashboard, setDashboard] = useState(false) // the Feed Dashboard sheet (components/FeedDashboard.jsx)
  const changeMenu = m => {
    saveMenu(m, FEEDS)
    setMenu(m)
    if (choice.mode !== PINNED_FEED && m.hidden.includes(choice.mode)) pick({ mode: PINNED_FEED, tag: choice.tag })
  }
  // A #tag link (NoteText) opens that tag's feed, from any screen, and a rail favourite its feed, relay or list; the
  // Feed may already be up behind it (desktop). A list's people are read first, then its notes.
  useEffect(() => {
    if (!globalThis.location) return
    const take = () => {
      const c = linkChoice(location.hash, FEED_IDS)
      if (!c) return
      pick(c); dropTag()
      // Taken only while that list is still the feed shown (a load bumps seq, so the feed's key is what's compared).
      if (c.mode === "list") resolveList(ctx, c).then(full => { if (keyNow.current === feedKey(c)) pick(full) }).catch(() => {})
    }
    take()
    addEventListener("hashchange", take)
    return () => removeEventListener("hashchange", take)
  }, [])

  // A sync reloads what Haven has without rebuilding the list. It used to replace it (`setNotes(read)`): every card
  // above the reader was thrown away and drawn again on each reload and the page jumped (145 px measured). What is
  // already on screen keeps its note object and its row; only the notes that are new go in above, through the same
  // anchored path the live notes use (`putIn`), and the read is clamped at the ceiling so its cost stops growing
  // (feed-window.js readLimit, mergeReload).
  const reload = async () => {
    const read = await readFeed(vault, follows, { limit: readLimit(shownNow.current.page, shownNow.current.have) })
    const prev = notesNow.current
    setPending([])
    if (!prev?.length) {
      setNotes(capNotes(read))
      seenTop.current = Math.max(seenTop.current, read[0]?.created_at ?? 0)
      return read
    }
    const top = seenTop.current
    // The note the reader is on, taken before the list changes: it decides which end the ceiling gives way at, and it is
    // the row the anchor below puts back (`stay.current` is only set on the putIn path, which is not the only one).
    const spot = readingSpot(screen.current, feedScroller(screen.current))
    const merged = mergeReload(prev, read, { max: MAX_NOTES, protect: spot?.id, seenTop: top })
    // What is on screen, not what was read: a note the ceiling had to drop (the reader is at the bottom, so the
    // newest gives way) must still count as new on the next reload rather than be forgotten for good.
    seenTop.current = Math.max(top, merged.notes[0]?.created_at ?? 0)
    // New notes go in through putIn, which records the row the reader is on before the list changes (feed-stay.js).
    // A merge that only moved rows (the ceiling trimmed the top because the reader is at the bottom) is anchored the
    // same way: without a spot, those rows going would shift the reader by their height.
    if (merged.fresh.length) putIn(merged.fresh, () => setNotes(p => mergeReload(p, read, { max: MAX_NOTES, protect: stay.current?.id, seenTop: top }).notes))
    else if (merged.changed) putIn([], () => setNotes(merged.notes))
    return read
  }
  // `have`: how many notes are on screen, when the caller has just read them (the render that shows them may not have run).
  const sync = async ({ have } = {}) => {
    // No follow list yet (still loading, or nobody followed): there is nothing to sync, so nothing is "up to date".
    const say = sayer()
    if (!follows.length) return say("")
    if (!navigator.onLine) return say("Offline: showing your saved feed")
    // Counting follows only while the feed is still filling (nothing shown yet, or a first sign-in's fill): once notes
    // show, a sync is just a check for newer ones.
    const filling = !(have ?? shownNow.current.have) || !!backgroundFill()
    say(filling ? "Syncing…" : "Checking for new notes…")
    setSyncing(true)
    // Show notes as each chunk of follows lands, not after the last one. One read at a time, so an older read can't
    // land after a newer one, and at most one waiting: each read is of every follow, and a queue of one per answer
    // kept a first sync's screen busy ~20 s after the last note was saved.
    let shown = Promise.resolve(), seen = 0, waiting = false
    const show = () => {
      if (waiting) return
      waiting = true
      shown = shown.then(() => { waiting = false; return reload() })
    }
    try {
      const onProgress = p => {
        if (filling) say(`Syncing ${p.done}/${p.of} follows · ${p.stored} saved`)
        if (p.stored > seen) { seen = p.stored; show() }
      }
      // A first sign-in opens on the first page while its fill carries on: draw from that one, don't start another.
      const fill = backgroundFill()
      const n = await (fill ? fill.join(onProgress) : syncFeed(vault, follows, relays, { onProgress }))
      await shown
      await reload()
      markSynced(me, follows)
      say(n ? `${n} notes saved to your vault` : "Up to date")
    } catch (e) { say(`Sync failed (${e?.message ?? e}): showing your saved feed`) }
    finally { setSyncing(false) }
  }
  // Older, once at a time: it says when there is nothing older, and a failure leaves a Try again rather than a stuck line.
  const olderBusy = useRef(false)
  const runOlder = async load => {
    if (olderBusy.current) return
    olderBusy.current = true
    setOlderState("busy")
    try { const got = await load(); setOlderState(got === 0 ? "end" : "") }
    catch (e) { setOlderState(String(e?.message ?? e)) }
    finally { olderBusy.current = false }
  }
  const older = () => runOlder(async () => {
    const until = notes.at(-1)?.created_at - 1
    let more = await readFeed(vault, follows, { limit: page, until })
    if (more.length < page / 2 && navigator.onLine) {
      for (let i = 0; i < follows.length; i += 250) {
        const evs = await pool.querySync(relays, { kinds: FEED_KINDS, authors: follows.slice(i, i + 250), until, limit: 200 }, { maxWait: 8000 })
        for (const ev of evs) await vault.feed.event(ev)
      }
      more = await readFeed(vault, follows, { limit: page, until })
    }
    // Older joins at the bottom, so the ceiling trims the newest (feed-window.js capOlder): the page just read stays,
    // and the next `until` moves on. Capping the head here dropped exactly the page Older had fetched, every time (D1).
    // The rows dropped above the reader would pull the page up by their height, so once the head goes the note being
    // read is pinned where it is (stay, the list's layout effect), as the Global and Hashtag Older does.
    const spot = readingSpot(screen.current, feedScroller(screen.current))
    setNotes(prev => {
      const all = capOlder([...(prev ?? []), ...more.filter(m => !prev?.some(n => n.id === m.id))], MAX_NOTES, { protect: spot?.id })
      if (spot && all.length && all[0].id !== prev?.[0]?.id) stay.current = spot
      return all
    })
    return more.length
  })
  // While the Feed is on screen, the follows' new notes arrive live (net/feed-live.js), are saved to /feed and either go
  // straight in (Auto-load on: the iPhone's) or wait behind the pill (Auto-load off, Logen 2026-11-10). With Auto-load on
  // the list never moves under the reader: below the top the post being read is held at its height
  // (components/feed-stay.js, Logen 2026-11-04). A dropped subscription opens again and syncs what it missed.
  const notesNow = useRef(notes)
  notesNow.current = notes
  // The switches as they are now, for the watch above: turning Auto-load off must not re-open the subscription.
  const filtersNow = useRef(filters)
  filtersNow.current = filters
  // The Feed's <main>, to find what it scrolls in: its pane on the desktop layout, the window on the phone
  // (FeedExtras feedScroller). Auto-load and the pill read that, not always the window (desktop, Logen 2026-11-03).
  const screen = useRef(null)
  // The post being read when new notes went in below the top: held at its height once they are drawn.
  const stay = useRef(null)
  useLayoutEffect(() => {
    const spot = stay.current
    stay.current = null
    if (spot) holdSpot(screen.current, feedScroller(screen.current), spot)
    // Any list change resizes <main> (an "Older" page, a trim), which wakes the ResizeObserver of every live pin — the
    // one just made here and any older one still inside its 5 s. Re-point them all at the row the reader is on now, or an
    // older pin re-applies a spot they have left and drags them back: growing below must move nobody (R4).
    rebasePins(screen.current, feedScroller(screen.current))
  }, [notes, strange])
  // The watermark only ever moves forward, whatever path put the notes on screen (a live note, "Older", a reload): what
  // it must never do is come back down when the ceiling drops the newest notes off the top.
  useLayoutEffect(() => { const top = notes?.[0]?.created_at; if (top) seenTop.current = Math.max(seenTop.current, top) }, [notes])
  useEffect(() => {
    if (!following || !follows.length) return
    // `batch`, `unsaved`: notes Haven didn't save (net/feed-live.js), shown from memory beside what /feed has.
    const show = async (batch = [], { unsaved = false } = {}) => {
      if (!notesNow.current) return // the first read is still coming and will have them
      const read = await readFeed(vault, follows, { limit: PAGE }).catch(e => { if (unsaved) return []; throw e })
      // A note the subscription just handed us is new to this screen whatever its `created_at` (freshNotes): relays
      // deliver late and a sender's clock can be behind, and the watermark was dropping those in silence ("the posts
      // are not dropping in", Logen 2026-11-10). The watermark still guards the page a reload reads back.
      const fresh = freshNotes({ read, live: batch, seenTop: seenTop.current })
      if (!fresh.length) return
      if (filtersNow.current.autoLoad && !feedPostOpen()) {
        const pane = feedScroller(screen.current)
        stay.current = scrollTopOf(pane) < AT_TOP_PX ? null : readingSpot(screen.current, pane)
        setNotes(prev => insertNotes(prev, fresh, { protect: stay.current?.id }))
      } else setPending(prev => insertNotes(prev, fresh))
    }
    const catchUp = async () => {
      if (!navigator.onLine) return
      try { await syncFeed(vault, follows, relays, {}); markSynced(me, follows); await show() } catch {}
    }
    const close = watchFollowing({ vault, follows, relays, since: Math.floor(Date.now() / 1000) - LIVE_SINCE_S,
      onNotes: (evs, o) => show(evs, o).catch(() => {}), onReopen: catchUp })
    globalThis.addEventListener?.("online", catchUp)
    return () => { close(); globalThis.removeEventListener?.("online", catchUp) }
  }, [following, follows.length])
  // New notes go in on their own with Auto-load on, as in other Nostr clients (Logen 2026-11-04). Below the top the
  // post being read is held at its height (components/feed-stay.js). While a post is open in place they wait, and go in
  // once it closes: the open post never moves (the iPhone holds auto-load the same way). Auto-load off leaves them
  // behind the pill until it is tapped (Logen 2026-11-10). The other feeds' live notes always go in (putIn above).
  const putIn = (fresh, set) => {
    const pane = feedScroller(screen.current)
    stay.current = scrollTopOf(pane) < AT_TOP_PX ? null : readingSpot(screen.current, pane)
    set(fresh)
  }
  useEffect(() => {
    if (!pending.length && !strangePending.length) return
    let timer = null
    const tryIn = () => {
      if (following && !filtersNow.current.autoLoad) return // the pill holds them
      if (feedPostOpen()) { timer = setTimeout(tryIn, OPEN_RETRY_MS); return }
      if (following && pending.length) putIn(pending, fresh => { setNotes(prev => insertNotes(prev, fresh, { protect: stay.current?.id })); setPending([]) })
      else if (!following && strangePending.length) putIn(strangePending, () => showStrangePending())
    }
    tryIn()
    return () => clearTimeout(timer)
  }, [pending, strangePending, following, filters.autoLoad])

  // New posts on Global, Hashtag and Discover: their filters stay open from the first page on (the iPhone keeps its feed
  // REQ open) and what comes in goes in on its own (putIn above). Nothing is saved.
  const strangeNow = useRef(strange)
  strangeNow.current = strange
  const keyNow = useRef("")
  keyNow.current = feedKey(choice)
  const holdNew = (key, evs) => {
    if (key !== keyNow.current) return
    const fresh = newerNotes(strangeNow.current ?? [], evs)
    if (fresh.length) setStrangePending(prev => newerNotes([], [...fresh, ...prev.filter(p => !fresh.some(f => f.id === p.id))]))
  }
  useEffect(() => {
    if (Reader || following || popular || strange === null || !navigator.onLine) return
    const c = choice, key = feedKey(c)
    let close = () => {}, live = true
    ;(async () => {
      const trust = trustScoped(c) ? await globalTrust(me, follows) : null
      const network = c.mode === "discovery" ? await discoverPeople() : null
      // Screened hashtag pages (a new account) take new posts on the next load: each needs its author's follow count.
      const filters = hashtagScreened(c) ? [] : liveFilters(c, { trust, network })
      if (!live || !filters.length) return
      close = watchLive({ filters, relays: feedRelays(c, account.relays.read), keep: ev => liveKeeps(c, ev, { trust, network }), onNotes: evs => holdNew(key, evs) })
    })().catch(() => {})
    return () => { live = false; close() }
  }, [feedKey(choice), strange !== null, follows.length])
  // Popular is one ranked page, not a stream: it is ranked again every POPULAR_RECHECK_MS while it is on screen, and
  // when notes have joined the ranking the new ranking goes in on its own (putIn above).
  useEffect(() => {
    if (!popular || strange === null || !follows.length) return
    const t = setInterval(async () => {
      if (document.hidden || !navigator.onLine) return
      try {
        const got = await fetchPopular({ me, follows, relays, vault, blocked, ctx })
        const next = got.notes
        if (keyNow.current !== "popular") return
        popularScores.current = got.scores
        const shownIds = new Set((strangeNow.current ?? []).map(n => n.id))
        const joined = next.filter(n => !shownIds.has(n.id))
        popularNext.current = next
        setStrangePending(joined)
      } catch {}
    }, POPULAR_RECHECK_MS)
    t.unref?.() // node (the tests) only: a timer must not keep the process up
    return () => clearInterval(t)
  }, [popular, strange !== null, follows.length])
  const showStrangePending = () => {
    // New posts go in on top, so past the ceiling the oldest give way (capNotes), or the bottom would sit undrawn.
    const all = popular && popularNext.current ? popularNext.current : capNotes(mergePage(strangePending, strange ?? []))
    popularNext.current = null
    holdNotes(choice, all)
    setStrange(all)
    setStrangePending([])
  }
  // The pill's tap: what was held goes in and the reader is taken to it (the iPhone's "N New Posts").
  const showPending = () => {
    setNotes(prev => insertNotes(prev, pending))
    setPending([])
    scrollToTop(feedScroller(screen.current))
  }

  // Global, Hashtag and Popular. Each load is for one feed: once the picker has moved on, a late answer is dropped.
  const loadStrange = async (c, until) => {
    const n = ++seq.current
    if (c.mode === "hashtag" && !c.tag) return setStatus("")
    if (c.mode === "list" && !c.authors) return setStatus("Reading the list…")
    if ((c.mode === "popular" || globalLike(c) || c.mode === "discovery") && !follows.length) return setStatus("")
    if (!navigator.onLine) return setStatus(`Offline: ${FEEDS.find(f => f.id === c.mode)?.label ?? c.label ?? "this feed"} needs the network`)
    setStatus(until ? "Fetching older notes…" : c.mode === "popular" ? "Ranking the last day's likes, reposts and zaps…"
      : c.mode === "discovery" && !network.current ? "Finding the people your follows follow…" : "Loading…")
    try {
      const page = c.mode === "popular"
        ? await fetchPopular({ me: ctx.session?.pubkey, follows, relays, vault, blocked, ctx }).then(got => { popularScores.current = got.scores; return got.notes })
        : c.mode === "discovery" ? await fetchDiscover(await discoverPeople(), account.relays.read, { until })
        : await fetchStrangerFeed(c, account.relays.read, { until, limit: c.mode === "media" ? MEDIA_PAGE : PAGE, trust: trustScoped(c) ? await globalTrust(ctx.session?.pubkey, follows) : null,
          // Under the Everyone lock a hashtag opens screened (feeds.js screenedHashtag), so a new account can find people.
          screened: hashtagScreened(c), follows })
      if (n !== seq.current) return
      // Older joins at the bottom, so past the ceiling the newest give way (feed-window.js capOlder), as Following's
      // Older does. Uncapped, this list grew past MAX_NOTES while the draw window stops there: Older kept fetching pages
      // nobody could see, until "No older notes" sat under note 500. The rows dropped above the reader would pull the
      // page up, so the note being read is pinned where it is (stay, the list's layout effect).
      const spot = until ? readingSpot(screen.current, feedScroller(screen.current)) : null
      const all = until ? capOlder(mergePage(heldNotes(c) ?? [], page), MAX_NOTES, { protect: spot?.id }) : page
      if (spot && all.length && all[0].id !== (heldNotes(c) ?? [])[0]?.id) stay.current = spot
      holdNotes(c, all)
      setStrange(all)
      if (!until) setStrangePending([]) // a fresh first page has them
      setStatus("")
      return page.length
    } catch (e) { if (n === seq.current) setStatus(`Couldn't load (${e?.message ?? e})`) }
  }

  // Back on the Feed soon after a sync (from another screen, or a reload): show Haven's notes and ask nothing; the
  // background sync and Refresh bring newer ones. An empty Haven (signed out and in again: sign-out wiped it) syncs.
  useEffect(() => { if (following) reload().then(read => (read.length > 0 && syncedRecently(me, follows) ? undefined : sync({ have: read.length }))) }, [follows.length, following])
  // Following and Media share the notes read from /feed; Media reads a bigger page, so switching to it reads again.
  useEffect(() => { if (following && notes) reload() }, [media])
  useEffect(() => { if (!Reader && !following && !heldNotes(choice)) loadStrange(choice) }, [feedKey(choice), needsWeb && follows.length > 0])
  useEffect(() => {
    if (following && notes?.length) fetchProfiles(vault, noteAuthors(notes), relays).catch(() => {})
  }, [notes, following])
  useEffect(() => {
    if (!following && strange?.length) fetchProfiles(vault, noteAuthors(strange), account.relays.read, { save: false }).catch(() => {})
  }, [strange, following])

  // No Refresh button (Logen 2026-11-04): new notes come in on their own. A pull down from the top on the phone and the
  // Feed tab tapped at the top still look again, as in other Nostr clients.
  // An empty Discover (no follow lists came back yet) asks again on its own while it is on screen.
  useEffect(() => {
    if (!discover || strange === null || strange.length || !follows.length) return
    const t = setInterval(() => { if (!document.hidden && navigator.onLine) loadStrange(choice) }, EMPTY_RETRY_MS)
    t.unref?.()
    return () => clearInterval(t)
  }, [discover, strange?.length ?? -1, follows.length, feedKey(choice)])
  const refresh = () => (Reader ? null : following ? sync() : loadStrange(choice))
  const refreshNow = useRef(refresh)
  refreshNow.current = refresh
  const pull = usePullToRefresh(() => refreshNow.current(), { enabled: !Reader })
  useEffect(() => {
    if (!globalThis.addEventListener) return
    const on = () => refreshNow.current()
    addEventListener("nv:feed-refresh", on)
    return () => removeEventListener("nv:feed-refresh", on)
  }, [])

  // Blocked people's notes stay where they are and are only left out here, so unblocking brings them back.
  const list = following ? notes : strange
  const threaded = layout === "threaded" && hasLayouts(choice.mode)
  const followSet = new Set(follows)
  const shown = list && visibleNotes(media ? list : applyFilters(popular ? list.filter(n => audienceKeeps(n, audience, followSet)) : list, filters, { threaded }), blocked)
  // What the pill holds: the notes a sync or a live watch brought that are not on screen yet (Auto-load off, or a post
  // open in place). Media shows no pill, as before.
  const newCount = media ? 0 : visibleNotes(applyFilters(following ? pending : strangePending, filters, { threaded }), blocked).length
  // What is drawn: at most the window (feed-window.js). The whole list stays in memory under the ceiling; only this
  // many cards are in the DOM.
  const drawn = shown ? drawNotes(shown, drawCount) : shown
  // The window grows as the reader nears the bottom of what is drawn (below, and in the effect after it), so the DOM
  // stops at DRAW_NOTES · 41 nodes a card rather than 1,000 cards' worth.
  const windowNow = useRef({ drawn: 0, total: 0 })
  windowNow.current = { drawn: drawn?.length ?? 0, total: shown?.length ?? 0 }
  const growWindow = () => {
    const { drawn: have, total } = windowNow.current
    if (have >= total) return
    const pane = feedScroller(screen.current)
    const el = pane ?? globalThis.document?.scrollingElement ?? globalThis.document?.documentElement
    if (!el?.scrollHeight) return // no layout yet: the next draw asks again
    const gap = el.scrollHeight - (scrollTopOf(pane) + (pane ? pane.clientHeight : globalThis.innerHeight ?? 0))
    if (gap > GROW_PX) return
    // R4: this growth resizes <main>, which wakes the ResizeObserver of any live putIn/holdSpot pin (a sync prepend, a
    // live note). Re-point those pins at the row the reader is on now first, so none of them re-applies a spot the reader
    // has left: growing the window must never move them (feed-stay.js rebasePins).
    rebasePins(screen.current, pane)
    setDrawCount(n => nextDraw(n, total))
  }
  const growNow = useRef(growWindow)
  growNow.current = growWindow
  // D2: not only on a scroll. At exactly a window's worth of notes the page cannot scroll any further, so no scroll
  // event ever comes and the list would stop at DRAW_NOTES for good; every draw asks again.
  useEffect(() => { growNow.current() }, [drawn?.length, shown?.length])
  useEffect(() => {
    if (!globalThis.addEventListener) return
    let raf = 0
    // Scroll events do not bubble: capture gets the desktop pane's too (FeedExtras feedScroller).
    const onScroll = () => { if (!raf) raf = requestAnimationFrame(() => { raf = 0; growNow.current() }) }
    addEventListener("scroll", onScroll, { capture: true, passive: true })
    return () => { removeEventListener("scroll", onScroll, { capture: true }); cancelAnimationFrame(raf) }
  }, [])
  // A feed switch starts the window over; Back from a thread opens it wide enough to hold the note the reader was on
  // (feed-tap.js pins by note id, and a note that is not drawn cannot be pinned: the reader would land at the top).
  const spotKey = `${feedKey(choice)}:${layout}`
  useEffect(() => { setDrawCount(DRAW_NOTES) }, [spotKey])
  useEffect(() => {
    const spot = savedFeedSpot(spotKey)
    if (!spot || !shown) return
    const i = shown.findIndex(n => n.id === spot.id)
    if (i >= 0) setDrawCount(n => Math.max(n, Math.min(MAX_NOTES, i + 1)))
  }, [spotKey, shown?.length])
  // "🔥 #3 · 1.2k" above each scored note while ranks are on, numbered in the order shown (PopularRanking).
  const rankMap = popular && ranks && shown ? popularRanks(shown.map(n => n.id), popularScores.current) : null
  const rankOf = rankMap ? id => (rankMap.has(id) ? { rank: rankMap.get(id), score: popularScores.current.get(id) } : null) : null
  // Global's shield: off at once; on behind the phone's warning, or the lock while too few are followed.
  const flipShield = () => {
    if (choice.everyone) { setEveryone(false); pick({ ...choice, everyone: false }) }
    else setShieldAsk(everyoneLocked(follows, ctx.session?.pubkey) ? "lock" : "warn")
  }
  const proceedEveryone = () => { setShieldAsk(null); setEveryone(true); pick({ ...choice, everyone: true }) }
  const tiles = media && drawn && mediaTiles(drawn.filter(n => n.kind === 1 || n.kind === 6)) // notes, as the iPhone's grid
  // Back from a thread finds the list where it was left (the phone layout draws the Feed again).
  useFeedSpot(spotKey, !!drawn?.length)
  // The same toggles the old Feed options menu offered: Auto-load on Following, Replies off on Global only (the iPhone
  // shows them on a threaded feed too, and the switch filters there as well).
  const toggles = Reader || !hasLayouts(choice.mode) ? []
    : [following && "autoLoad", "reposts", !global && "replies"].filter(Boolean)
  return (
    <main class="screen" ref={screen}>
      <header class="screen-head feed-head">
        <FeedModeMenu feeds={visibleFeeds(FEEDS, menu)} choice={choice} onPick={pick} onEdit={() => setEditing(true)} onDashboard={() => setDashboard(true)} />
        <FeedToolbar layout={!Reader && hasLayouts(choice.mode) ? layout : null} onCycleLayout={cycleLayout}
          filters={filters} onFilters={changeFilters} toggles={toggles}
          scope={media ? choice.scope : null} onScope={pickScope}
          shield={global ? { everyone: !!choice.everyone, locked: everyoneLocked(follows, ctx.session?.pubkey) } : null} onShield={flipShield}
          audience={popular ? audience : null} onAudience={setAudience} ranks={popular ? ranks : null} onRanks={() => setRanks(!ranks)} />
      </header>
      {global && choice.everyone && <EveryoneBanner onBack={flipShield} />}
      {shieldAsk && <EveryoneShieldDialog ask={shieldAsk} follows={follows} me={ctx.session?.pubkey} onProceed={proceedEveryone} onClose={() => setShieldAsk(null)} />}
      {dashboard && <FeedDashboard ctx={ctx} blocked={blocked} onPick={pick} onClose={() => setDashboard(false)} />}
      {editing && <EditFeeds feeds={FEEDS} menu={menu} onChange={changeMenu} onClose={() => setEditing(false)} />}
      {choice.mode === "hashtag" && <HashtagBox choice={choice} onPick={pick} />}
      <PullIndicator pull={pull} busy={syncing && pull > 0} />
      {Reader ? <Reader ctx={ctx} /> : <>
      {/* Always there, so the list doesn't move when "Syncing…" comes and goes. */}
      <div class="status-line keep">{status}</div>
      {hashtagScreened(choice) && <div class="status-line muted small">{SCREENED_LINE}</div>}
      {privateNote && !ctx.signer?.readOnly && <div class="status-line">Your private blocks weren't read ({privateNote}), so those people may still show.</div>}
      {newCount > 0 && <NewPostsPill count={newCount} onShow={following ? showPending : showStrangePending} />}
      {following
        ? !follows.length ? account.loaded ? <EmptyFollowing /> : <SkeletonRows label="Loading your follows…" />
          : notes === null ? <SkeletonRows label="Opening your vault…" />
          : !notes.length ? syncing ? <SkeletonRows label="Fetching notes from the people you follow…" /> : <p class="empty">No notes saved yet.</p>
          : media ? <Media tiles={tiles} blockedAll={!shown.length} onOlder={older} olderState={olderState} />
          : <Notes shown={drawn} onOlder={older} olderState={olderState} layout={layout} fetchRoots={rootFetcher(vault, relays)} />
        : choice.mode === "hashtag" && !choice.tag ? <p class="empty">Type a hashtag to see notes tagged with it.</p>
          : popular && !follows.length ? <p class="empty">{account.loaded ? "Popular counts what the people you follow, and the people they follow, liked. Follow someone first." : "Loading your follows…"}</p>
          : global && !follows.length ? <p class="empty">{account.loaded ? "Follow people to build your web of trust" : "Loading your follows…"}</p>
          : discover && !follows.length ? account.loaded ? <DiscoverEmpty text="Follow more people on Nostr to build your extended network" />
            : <p class="empty">Loading your follows…</p>
          : strange === null ? navigator.onLine ? <SkeletonRows /> : <p class="empty">This feed needs the network.</p>
          : !strange.length && discover ? <DiscoverEmpty text={network.current?.people.length
              ? "No notes from your extended network on these relays yet." : "No follow lists came back from your relays yet. Asking again…"} />
          : media ? <Media tiles={tiles} blockedAll={!!strange.length && !shown.length}
              onOlder={() => runOlder(() => loadStrange(choice, strange.at(-1)?.created_at - 1))} olderState={olderState} />
          : !strange.length && choice.mode === "list" && choice.authors && !choice.authors.length ? <p class="empty">This list has no one in it, or it didn't come back from your relays.</p>
          : !strange.length ? <p class="empty">{popular ? "Nothing popular in the last day yet: a note needs likes, reposts or zaps from three people your follows follow." : global && !choice.everyone ? "No notes from your web of trust on these relays yet." : "No notes found."}</p>
          : <Notes shown={drawn} memoryOnly layout={layout} keepFeedOrder rankOf={rankOf} fetchRoots={rootFetcher(vault, account.relays.read, { save: false })}
              olderState={olderState} onOlder={popular ? null : () => runOlder(() => loadStrange(choice, strange.at(-1)?.created_at - 1))} />}
      </>}
    </main>
  )
}

/** The notes left after blocks, then Older (none for Popular, which is one ranked page). When every loaded note is
 *  from someone blocked, say so above Older. `memoryOnly`: strangers' notes, so their cards write nothing to /feed. */
export function Notes({ shown, onOlder, olderState, memoryOnly = false, layout = "expanded", keepFeedOrder = false, fetchRoots, rankOf = null }) {
  return <>
    {shown.length ? <FeedRows notes={shown} layout={layout} memoryOnly={memoryOnly} keepFeedOrder={keepFeedOrder} fetchRoots={fetchRoots} rankOf={rankOf} />
      : <p class="empty">Every note loaded here is from someone you blocked.</p>}
    {onOlder && <OlderButton onOlder={onOlder} state={olderState} />}
  </>
}

/** The Media grid, then Older. Most notes have none, so an empty grid says why and still offers Older. */
export function Media({ tiles, blockedAll, onOlder, olderState }) {
  return <>
    {tiles.length ? <MediaGrid tiles={tiles} />
      : <p class="empty">{blockedAll ? "Every note loaded here is from someone you blocked." : "No photos or videos in the notes loaded so far."}</p>}
    <OlderButton onOlder={onOlder} state={olderState} />
  </>
}

/** Discover with nothing to show, as the iPhone's empty state (FeedView+EmptyStates.swift): why. It asks again on its
 *  own (EMPTY_RETRY_MS), so there is no Refresh. */
function DiscoverEmpty({ text }) {
  return (
    <div class="discover-empty">
      <strong>No Discovery Feed</strong>
      <p>{text}</p>
    </div>
  )
}

/** The tag box, under the header when Hashtag is picked. */
function HashtagBox({ choice, onPick }) {
  const [draft, setDraft] = useState(choice.tag)
  const submit = e => { e.preventDefault(); const tag = normalizeTag(draft); setDraft(tag); onPick({ mode: "hashtag", tag }) }
  return (
    <form class="feed-tag" onSubmit={submit}>
      <input type="search" value={draft} onInput={e => setDraft(e.currentTarget.value)} placeholder="#bitcoin" aria-label="Hashtag"
        enterkeyhint="go" autocapitalize="off" autocorrect="off" spellcheck={false} />
      <button type="submit" class="small">Show</button>
    </form>
  )
}
