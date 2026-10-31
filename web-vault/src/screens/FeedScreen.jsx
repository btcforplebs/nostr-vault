// The Feed, with the picker (net/feeds.js). Following and Media are rendered only from Haven /feed; the network fills
// /feed in the background. Global, Hashtag and Popular come from the network into memory only: strangers' notes never
// go into /feed.
import { useEffect, useRef, useState } from "preact/hooks"
import { FeedRows, rootFetcher } from "../components/FeedRows.jsx"
import { MediaGrid } from "../components/MediaGrid.jsx"
import { feedPostOpen, useFeedSpot } from "../components/feed-tap.js"
import { FeedModeMenu, FeedToolbar } from "../components/FeedPickerMenu.jsx"
import { EditFeeds } from "../components/EditFeeds.jsx"
import { readFeed, syncFeed, FEED_KINDS } from "../net/sync.js"
import { watchFollowing } from "../net/feed-live.js"
import { pool, DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { fetchProfiles } from "../net/profiles.js"
import { backgroundFill } from "../net/vault-ready.js"
import { markSynced, syncedRecently } from "../net/feed-synced.js"
import { visibleNotes } from "../net/blocks.js"
import { useBlocks } from "../components/useBlocks.js"
import { feedList, loadMenu, saveMenu, visibleFeeds, PINNED_FEED, loadChoice, tagChoice, saveChoice, normalizeTag, fetchStrangerFeed, mergePage, statusGate, heldNotes, holdNotes, noteAuthors, feedKey, readsHaven, globalLike, withScope, saveMediaScope } from "../net/feeds.js"
import { fetchPopular } from "../net/popular.js"
import { discoverNetwork, fetchDiscover } from "../net/discover.js"
import { globalTrust } from "../readers/trust.js"
import { mediaTiles } from "../net/media.js"
import { READERS } from "../readers/index.js"
import { withParam } from "../desktop/routes.js"
import { hasLayouts, loadLayout, nextLayout, saveLayout } from "../net/feed-layout.js"
import { applyFilters, loadFilters, newerNotes, saveFilters } from "../net/feed-filters.js"
import { EmptyFollowing, NewPostsPill, OlderButton, PullIndicator, SkeletonRows, usePullToRefresh } from "../components/FeedExtras.jsx"

if (import.meta.env) import("../styles/feeds.css")

const PAGE = 100
const MEDIA_PAGE = 300 // most notes have no media, so Media reads more at a time (the iPhone asks for 300)
const FEEDS = feedList(READERS)
const readerFor = mode => READERS.find(r => r.id === mode)
// A saved feed that Edit Feeds has since hidden opens Following; a #tag link still opens its tag.
const pickedChoice = () => withScope(tagChoice(globalThis.location?.hash) ?? loadChoice(globalThis.localStorage, visibleFeeds(FEEDS, loadMenu())))
// Once the Feed has taken a #tag link's tag, the address drops it: Back and a reload keep the feed the user is on.
const dropTag = () => history.replaceState(history.state, "", withParam(location.hash, "tag", null))

export function FeedScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
  const me = ctx.session?.pubkey
  const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const [notes, setNotes] = useState(null)
  const [status, setStatus] = useState("")
  const [syncing, setSyncing] = useState(false)
  const { blocked, privateNote } = useBlocks(ctx)
  const [choice, setChoice] = useState(pickedChoice)
  const [strange, setStrange] = useState(() => heldNotes(pickedChoice()))
  // Expanded / Compact / Threaded, one per feed (FeedView+Layout). Re-read when the feed changes.
  const [layouts, setLayouts] = useState({})
  const layout = layouts[choice.mode] ?? loadLayout(choice.mode)
  const cycleLayout = () => { const l = nextLayout(layout); saveLayout(choice.mode, l); setLayouts({ ...layouts, [choice.mode]: l }) }
  // Replies, Reposts and Auto-load (FeedView+ToolbarMenu), for every feed of notes.
  const [filters, setFilters] = useState(loadFilters)
  const changeFilters = f => { saveFilters(f); setFilters(f) }
  // New notes a background sync found, held behind the pill until it is tapped (or loaded at once with Auto-load).
  const [pending, setPending] = useState([])
  // Older: "" | "busy" | "end" | an error message. One load at a time; a feed switch starts over.
  const [olderState, setOlderState] = useState("")
  // A reader (Articles, Live, …) draws its own list under the picker; the notes below are not loaded for it.
  const Reader = readerFor(choice.mode)?.Screen
  // `following`: read from Haven /feed (Following, and Media on Following). Media on Global is a stranger feed.
  const following = readsHaven(choice), media = choice.mode === "media", popular = choice.mode === "popular"
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
  const pick = c => { c = withScope(c); seq.current++; saveChoice(c); setChoice(c); setStrange(heldNotes(c)); setStatus(""); setOlderState("") }
  // Media's Following / Global buttons (FeedView+Toolbar.swift).
  const pickScope = scope => { if (scope !== choice.scope) { saveMediaScope(scope); pick({ ...choice, scope }) } }
  const sayer = () => statusGate(seq, setStatus)
  // Edit Feeds: the picker's order and hidden feeds. Hiding the feed you're on takes you back to Following.
  const [menu, setMenu] = useState(loadMenu)
  const [editing, setEditing] = useState(false)
  const changeMenu = m => {
    saveMenu(m, FEEDS)
    setMenu(m)
    if (choice.mode !== PINNED_FEED && m.hidden.includes(choice.mode)) pick({ mode: PINNED_FEED, tag: choice.tag })
  }
  // A #tag link (NoteText) opens that tag's feed, from any screen; the Feed may already be up behind it (desktop).
  useEffect(() => {
    if (!globalThis.location) return
    const take = () => { const c = tagChoice(location.hash); if (c) { pick(c); dropTag() } }
    take()
    addEventListener("hashchange", take)
    return () => removeEventListener("hashchange", take)
  }, [])

  const reload = async () => { const read = await readFeed(vault, follows, { limit: Math.max(shownNow.current.page, shownNow.current.have) }); setNotes(read); setPending([]); return read }
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
      say(n ? `${n} notes saved to your relay` : "Up to date")
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
    setNotes(prev => [...(prev ?? []), ...more.filter(m => !prev?.some(n => n.id === m.id))])
    return more.length
  })
  // While the Feed is on screen, the follows' new notes arrive live (net/feed-live.js), are saved to /feed and wait
  // behind the pill: the list never moves under the reader. With Auto-load on and the feed at the top, they go straight
  // in (the iPhone's). A dropped subscription opens again and syncs what it missed.
  const notesNow = useRef(notes)
  notesNow.current = notes
  useEffect(() => {
    if (!following || !follows.length) return
    const show = async () => {
      if (!notesNow.current) return // the first read is still coming and will have them
      const fresh = newerNotes(notesNow.current, await readFeed(vault, follows, { limit: PAGE }))
      if (!fresh.length) return
      if (filters.autoLoad && scrollY < 80 && !feedPostOpen()) setNotes(prev => [...fresh, ...(prev ?? [])])
      else setPending(fresh)
    }
    const catchUp = async () => {
      if (!navigator.onLine) return
      try { await syncFeed(vault, follows, relays, {}); markSynced(me, follows); await show() } catch {}
    }
    const close = watchFollowing({ vault, follows, relays, onNotes: () => show().catch(() => {}), onReopen: catchUp })
    globalThis.addEventListener?.("online", catchUp)
    return () => { close(); globalThis.removeEventListener?.("online", catchUp) }
  }, [following, follows.length, filters.autoLoad])
  const showPending = () => { setNotes(prev => [...pending, ...(prev ?? [])]); setPending([]); scrollTo({ top: 0, behavior: "smooth" }) }

  // Global, Hashtag and Popular. Each load is for one feed: once the picker has moved on, a late answer is dropped.
  const loadStrange = async (c, until) => {
    const n = ++seq.current
    if (c.mode === "hashtag" && !c.tag) return setStatus("")
    if ((c.mode === "popular" || globalLike(c) || c.mode === "discovery") && !follows.length) return setStatus("")
    if (!navigator.onLine) return setStatus(`Offline: ${FEEDS.find(f => f.id === c.mode).label} needs the network`)
    setStatus(until ? "Fetching older notes…" : c.mode === "popular" ? "Ranking the last day's likes, reposts and zaps…"
      : c.mode === "discovery" && !network.current ? "Finding the people your follows follow…" : "Loading…")
    try {
      const page = c.mode === "popular"
        ? (await fetchPopular({ me: ctx.session?.pubkey, follows, relays, vault, blocked })).notes
        : c.mode === "discovery" ? await fetchDiscover(await discoverPeople(), account.relays.read, { until })
        : await fetchStrangerFeed(c, account.relays.read, { until, limit: c.mode === "media" ? MEDIA_PAGE : PAGE, trust: globalLike(c) ? await globalTrust(ctx.session?.pubkey, follows) : null })
      if (n !== seq.current) return
      const all = until ? mergePage(heldNotes(c) ?? [], page) : page
      holdNotes(c, all)
      setStrange(all)
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

  // Refresh three ways, as on the iPhone: the header button, a pull down from the top, and the Feed tab tapped at the top.
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
  const shown = list && visibleNotes(media ? list : applyFilters(list, filters, { threaded }), blocked)
  const newCount = following && !media ? visibleNotes(applyFilters(pending, filters, { threaded }), blocked).length : 0
  const tiles = media && shown && mediaTiles(shown.filter(n => n.kind === 1 || n.kind === 6)) // notes, as the iPhone's grid
  // Back from a thread finds the list where it was left (the phone layout draws the Feed again).
  useFeedSpot(`${feedKey(choice)}:${layout}`, !!shown?.length)
  // The same toggles the old Feed options menu offered: Auto-load on Following and Media, Replies off on Global and Threaded.
  const toggles = Reader || !hasLayouts(choice.mode) ? []
    : [following && "autoLoad", "reposts", !global && !threaded && "replies"].filter(Boolean)
  return (
    <main class="screen">
      <header class="screen-head feed-head">
        <FeedModeMenu feeds={visibleFeeds(FEEDS, menu)} choice={choice} onPick={pick} onEdit={() => setEditing(true)} />
        <FeedToolbar layout={!Reader && hasLayouts(choice.mode) ? layout : null} onCycleLayout={cycleLayout}
          filters={filters} onFilters={changeFilters} toggles={toggles} onRefresh={Reader ? null : refresh}
          scope={media ? choice.scope : null} onScope={pickScope} />
      </header>
      {editing && <EditFeeds feeds={FEEDS} menu={menu} onChange={changeMenu} onClose={() => setEditing(false)} />}
      {choice.mode === "hashtag" && <HashtagBox choice={choice} onPick={pick} />}
      <PullIndicator pull={pull} busy={syncing && pull > 0} />
      {Reader ? <Reader ctx={ctx} /> : <>
      {/* Always there, so the list doesn't move when "Syncing…" comes and goes. */}
      <div class="status-line keep">{status}</div>
      {privateNote && !ctx.signer?.readOnly && <div class="status-line">Your private blocks weren't read ({privateNote}), so those people may still show.</div>}
      {newCount > 0 && <NewPostsPill count={newCount} onShow={showPending} />}
      {following
        ? !follows.length ? account.loaded ? <EmptyFollowing onRefresh={sync} /> : <SkeletonRows label="Loading your follows…" />
          : notes === null ? <SkeletonRows label="Opening your relay…" />
          : !notes.length ? syncing ? <SkeletonRows label="Fetching notes from the people you follow…" /> : <p class="empty">No notes saved yet.</p>
          : media ? <Media tiles={tiles} blockedAll={!shown.length} onOlder={older} olderState={olderState} />
          : <Notes shown={shown} onOlder={older} olderState={olderState} layout={layout} fetchRoots={rootFetcher(vault, relays)} />
        : choice.mode === "hashtag" && !choice.tag ? <p class="empty">Type a hashtag to see notes tagged with it.</p>
          : popular && !follows.length ? <p class="empty">{account.loaded ? "Popular counts what the people you follow, and the people they follow, liked. Follow someone first." : "Loading your follows…"}</p>
          : global && !follows.length ? <p class="empty">{account.loaded ? "Follow people to build your web of trust" : "Loading your follows…"}</p>
          : discover && !follows.length ? account.loaded ? <DiscoverEmpty text="Follow more people on Nostr to build your extended network" />
            : <p class="empty">Loading your follows…</p>
          : strange === null ? navigator.onLine ? <SkeletonRows /> : <p class="empty">This feed needs the network.</p>
          : !strange.length && discover ? <DiscoverEmpty onRefresh={refresh} text={network.current?.people.length
              ? "No notes from your extended network on these relays yet." : "No follow lists came back from your relays. Try refreshing."} />
          : media ? <Media tiles={tiles} blockedAll={!!strange.length && !shown.length}
              onOlder={() => runOlder(() => loadStrange(choice, strange.at(-1)?.created_at - 1))} olderState={olderState} />
          : !strange.length ? <p class="empty">{popular ? "Nothing popular in the last day yet: a note needs likes, reposts or zaps from three people your follows follow." : global ? "No notes from your web of trust on these relays yet." : "No notes found."}</p>
          : <Notes shown={shown} memoryOnly layout={layout} keepFeedOrder fetchRoots={rootFetcher(vault, account.relays.read, { save: false })}
              olderState={olderState} onOlder={popular ? null : () => runOlder(() => loadStrange(choice, strange.at(-1)?.created_at - 1))} />}
      </>}
    </main>
  )
}

/** The notes left after blocks, then Older (none for Popular, which is one ranked page). When every loaded note is
 *  from someone blocked, say so above Older. `memoryOnly`: strangers' notes, so their cards write nothing to /feed. */
export function Notes({ shown, onOlder, olderState, memoryOnly = false, layout = "expanded", keepFeedOrder = false, fetchRoots }) {
  return <>
    {shown.length ? <FeedRows notes={shown} layout={layout} memoryOnly={memoryOnly} keepFeedOrder={keepFeedOrder} fetchRoots={fetchRoots} />
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

/** Discover with nothing to show, as the iPhone's empty state (FeedView+EmptyStates.swift): why, and Refresh when that
 *  can help. */
function DiscoverEmpty({ text, onRefresh }) {
  return (
    <div class="discover-empty">
      <strong>No Discovery Feed</strong>
      <p>{text}</p>
      {onRefresh && <button type="button" class="small" onClick={onRefresh}>Refresh</button>}
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
