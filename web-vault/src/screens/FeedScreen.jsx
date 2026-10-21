// The Feed, with the picker (net/feeds.js). Following and Media are rendered only from Haven /feed; the network fills
// /feed in the background. Global, Hashtag and Popular come from the network into memory only: strangers' notes never
// go into /feed.
import { useEffect, useRef, useState } from "preact/hooks"
import { FeedRows, rootFetcher } from "../components/FeedRows.jsx"
import { MediaGrid } from "../components/MediaGrid.jsx"
import { readFeed, syncFeed, FEED_KINDS } from "../net/sync.js"
import { pool, DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { fetchProfiles } from "../net/profiles.js"
import { visibleNotes } from "../net/blocks.js"
import { useBlocks } from "../components/useBlocks.js"
import { feedList, loadChoice, tagChoice, saveChoice, normalizeTag, fetchStrangerFeed, mergePage, statusGate, heldNotes, holdNotes, noteAuthors, feedKey, fromHaven } from "../net/feeds.js"
import { fetchPopular } from "../net/popular.js"
import { mediaTiles } from "../net/media.js"
import { READERS } from "../readers/index.js"
import { withParam } from "../desktop/routes.js"
import { LAYOUT_NAME, hasLayouts, loadLayout, nextLayout, saveLayout } from "../net/feed-layout.js"
import { applyFilters, loadFilters, newerNotes, saveFilters } from "../net/feed-filters.js"
import { EmptyFollowing, FilterMenu, NewPostsPill, OlderButton, PullIndicator, SkeletonRows, usePullToRefresh } from "../components/FeedExtras.jsx"

if (import.meta.env) import("../styles/feeds.css")

const PAGE = 100
const BACKGROUND_SYNC_MS = 120_000 // new notes from the people you follow, held behind the pill
const MEDIA_PAGE = 300 // most notes have no media, so Media reads more at a time (the iPhone asks for 300)
const FEEDS = feedList(READERS)
const readerFor = mode => READERS.find(r => r.id === mode)
const pickedChoice = () => tagChoice(globalThis.location?.hash) ?? loadChoice(globalThis.localStorage, FEEDS)
// Once the Feed has taken a #tag link's tag, the address drops it: Back and a reload keep the feed the user is on.
const dropTag = () => history.replaceState(history.state, "", withParam(location.hash, "tag", null))

export function FeedScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
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
  const following = fromHaven(choice.mode), media = choice.mode === "media", popular = choice.mode === "popular"
  const page = media ? MEDIA_PAGE : PAGE
  // A sync started on Following reloads when it ends, maybe after a switch to Media: it reads with the page size
  // and note count of the feed shown then, not of the render that started it.
  const shownNow = useRef({})
  shownNow.current = { page, have: notes?.length ?? 0 }
  // One number per feed shown: picking a feed or starting a stranger load bumps it, and work started under an older
  // number (a Following sync, a Global page) no longer writes the status line.
  const seq = useRef(0)
  const pick = c => { seq.current++; saveChoice(c); setChoice(c); setStrange(heldNotes(c)); setStatus(""); setOlderState("") }
  const sayer = () => statusGate(seq, setStatus)
  // A #tag link (NoteText) opens that tag's feed, from any screen; the Feed may already be up behind it (desktop).
  useEffect(() => {
    if (!globalThis.location) return
    const take = () => { const c = tagChoice(location.hash); if (c) { pick(c); dropTag() } }
    take()
    addEventListener("hashchange", take)
    return () => removeEventListener("hashchange", take)
  }, [])

  const reload = async () => { setNotes(await readFeed(vault, follows, { limit: Math.max(shownNow.current.page, shownNow.current.have) })); setPending([]) }
  const sync = async () => {
    // No follow list yet (still loading, or nobody followed): there is nothing to sync, so nothing is "up to date".
    const say = sayer()
    if (!follows.length) return say("")
    if (!navigator.onLine) return say("Offline: showing your saved feed")
    say("Syncing…")
    setSyncing(true)
    // Show notes as each chunk of follows lands, not after the last one. Reloads queue so an older read can't
    // land after a newer one.
    let shown = Promise.resolve(), seen = 0
    try {
      const n = await syncFeed(vault, follows, relays, { onProgress: p => {
        say(`Syncing ${p.done}/${p.of} follows · ${p.stored} saved`)
        if (p.stored > seen) { seen = p.stored; shown = shown.then(reload) }
      } })
      await shown
      await reload()
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
  // Every two minutes while the Feed is on screen, sync quietly and hold what's new behind the pill: the list never
  // moves under the reader. With Auto-load on and the feed at the top, new notes go straight in (the iPhone's).
  const notesNow = useRef(notes)
  notesNow.current = notes
  useEffect(() => {
    if (!following || !follows.length) return
    const tick = async () => {
      if (document.hidden || !navigator.onLine || !notesNow.current) return
      try {
        await syncFeed(vault, follows, relays, {})
        const fresh = newerNotes(notesNow.current, await readFeed(vault, follows, { limit: PAGE }))
        if (!fresh.length) return
        if (filters.autoLoad && scrollY < 80) setNotes(prev => [...fresh, ...(prev ?? [])])
        else setPending(fresh)
      } catch {}
    }
    const t = setInterval(tick, BACKGROUND_SYNC_MS)
    t.unref?.() // node (the tests) only: a timer must not keep the process up
    return () => clearInterval(t)
  }, [following, follows.length, filters.autoLoad])
  const showPending = () => { setNotes(prev => [...pending, ...(prev ?? [])]); setPending([]); scrollTo({ top: 0, behavior: "smooth" }) }

  // Global, Hashtag and Popular. Each load is for one feed: once the picker has moved on, a late answer is dropped.
  const loadStrange = async (c, until) => {
    const n = ++seq.current
    if (c.mode === "hashtag" && !c.tag) return setStatus("")
    if (c.mode === "popular" && !follows.length) return setStatus("")
    if (!navigator.onLine) return setStatus(`Offline: ${FEEDS.find(f => f.id === c.mode).label} needs the network`)
    setStatus(until ? "Fetching older notes…" : c.mode === "popular" ? "Ranking the last day's likes, reposts and zaps…" : "Loading…")
    try {
      const page = c.mode === "popular"
        ? (await fetchPopular({ me: ctx.session?.pubkey, follows, relays, vault, blocked })).notes
        : await fetchStrangerFeed(c, account.relays.read, { until })
      if (n !== seq.current) return
      const all = until ? mergePage(heldNotes(c) ?? [], page) : page
      holdNotes(c, all)
      setStrange(all)
      setStatus("")
      return page.length
    } catch (e) { if (n === seq.current) setStatus(`Couldn't load (${e?.message ?? e})`) }
  }

  useEffect(() => { if (following) reload().then(sync) }, [follows.length, following])
  // Following and Media share the notes read from /feed; Media reads a bigger page, so switching to it reads again.
  useEffect(() => { if (following && notes) reload() }, [media])
  useEffect(() => { if (!Reader && !following && !heldNotes(choice)) loadStrange(choice) }, [feedKey(choice), popular && follows.length > 0])
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
  const label = FEEDS.find(f => f.id === choice.mode).label
  return (
    <main class="screen">
      <header class="screen-head">
        <h2>{choice.mode === "hashtag" && choice.tag ? `#${choice.tag}` : label}</h2>
        {!Reader && hasLayouts(choice.mode) && <LayoutButton layout={layout} onClick={cycleLayout} />}
        {!Reader && hasLayouts(choice.mode) && <FilterMenu filters={filters} onChange={changeFilters} replies={choice.mode !== "global" && !threaded} autoLoad={following} />}
        {!Reader && <button class="small" onClick={refresh}>Refresh</button>}
      </header>
      <FeedPicker choice={choice} onPick={pick} />
      <PullIndicator pull={pull} busy={syncing && pull > 0} />
      {Reader ? <Reader ctx={ctx} /> : <>
      {status && <div class="status-line">{status}</div>}
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
          : strange === null ? navigator.onLine ? <SkeletonRows /> : <p class="empty">This feed needs the network.</p>
          : !strange.length ? <p class="empty">{popular ? "Nothing popular in the last day yet: a note needs likes, reposts or zaps from three people your follows follow." : "No notes found."}</p>
          : <Notes shown={shown} memoryOnly layout={layout} keepFeedOrder fetchRoots={rootFetcher(vault, account.relays.read)}
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

/** The feeds, and the tag box when Hashtag is picked. */
function FeedPicker({ choice, onPick }) {
  const [draft, setDraft] = useState(choice.tag)
  const submit = e => { e.preventDefault(); const tag = normalizeTag(draft); setDraft(tag); onPick({ mode: "hashtag", tag }) }
  return (
    <div class="feed-picker">
      <div class="feed-modes" role="tablist" aria-label="Feed">
        {FEEDS.map(f => (
          <button key={f.id} type="button" role="tab" aria-selected={choice.mode === f.id} class={choice.mode === f.id ? "on" : ""}
            onClick={() => onPick({ mode: f.id, tag: choice.tag })}>{f.label}</button>
        ))}
      </div>
      {choice.mode === "hashtag" && (
        <form class="feed-tag" onSubmit={submit}>
          <input type="search" value={draft} onInput={e => setDraft(e.currentTarget.value)} placeholder="#bitcoin" aria-label="Hashtag"
            enterkeyhint="go" autocapitalize="off" autocorrect="off" spellcheck={false} />
          <button type="submit" class="small">Show</button>
        </form>
      )}
    </div>
  )
}

/** One button cycles Expanded -> Compact -> Threaded (FeedLayoutMode.next); it names where it goes next. */
function LayoutButton({ layout, onClick }) {
  const next = LAYOUT_NAME[nextLayout(layout)]
  return (
    <button type="button" class="small layout-button" onClick={onClick} title={`${LAYOUT_NAME[layout]}. Switch to ${next}`}
      aria-label={`${LAYOUT_NAME[layout]}. Switch to ${next}`}>
      <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true">
        <path d={LAYOUT_ICON[layout]} />
      </svg>
      <span>{LAYOUT_NAME[layout].replace(" View", "")}</span>
    </button>
  )
}
const LAYOUT_ICON = {
  expanded: "M4 4h16v7H4zM4 14h16v6H4z",
  condensed: "M4 5h16M4 10h16M4 15h16M4 20h16",
  threaded: "M4 5h16M8 10h12M8 15h12M4 20h16",
}
