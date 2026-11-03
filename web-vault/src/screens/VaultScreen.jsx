// The Vault tab (iPhone VaultTabView): a mode pill on the left (Vault · Notes · Articles · Highlights · Media ·
// Likes · Zaps · Followers, then Messages and the Vault Dashboard: VaultPagesMenu.jsx), and on the right one pill with
// the mode's filters as bare icons and search (VaultToolbar trailingPill). Messages has no envelope there any more
// (Logen, 2026-11-03): it is a page of its own in the menu. A floating "Vault" capsule, coloured by the app's relay
// connections, opens the Vault Dashboard sheet (VaultView+Layout; components/VaultButton.jsx, VaultDashboard.jsx).
// Your own events come from Haven's outbox; what others sent you from Haven's inbox and the relays.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName, NoteCard } from "../components/NoteCard.jsx"
import { ArticleCard } from "../components/ArticleCard.jsx"
import { NoteText } from "../components/NoteText.jsx"
import { MediaImage } from "../components/MediaImage.jsx"
import { imageItem } from "../net/note-media.js"
import { ago } from "../components/time.js"
import { useBlocks } from "../components/useBlocks.js"
import { useDmTrust } from "../components/useDmTrust.js"
import { readSince, unreadFrom, getVaultUnread } from "../net/notify-watch.js"
import { Faces, Who as Names } from "../components/ActivityFaces.jsx"
import { fetchProfiles } from "../net/profiles.js"
import { formatSats, fetchNotes, reactionEmojiSummary } from "../net/notifications.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { receiptTrust } from "../net/zaps.js"
import { VaultSearch } from "./VaultSearch.jsx"
import { BlossomGallery } from "./BlossomGallery.jsx"
import { newestByMode, readSeen, writeSeen, markSeen, baseline, newModes } from "../net/vault-new.js"
import {
  MODES, FILTERS, isMode, defaultFilter, previewOf, highlightSource, followersOf, followersSeenAt, markFollowersSeen,
  readOwn, readInbound, readOlder, fetchVault, READ_PAGE, keepVault, keptVault, sinceKept,
  readLists, keepLists, mergeLists, itemsFor, peopleOf, newestShown, splitArrivals, heldCount,
} from "../net/vault-lists.js"
import { PagedList, FIRST_ROWS, MORE_ROWS } from "../components/PagedList.jsx"
import { SkeletonGrid, SkeletonList } from "../components/Loading.jsx"
import { NewPostsPill, SkeletonRows } from "../components/FeedExtras.jsx"
import { VaultButton } from "../components/VaultButton.jsx"
import { dashboardHref, openDashboard } from "../net/dashboard-route.js"
import { ICONS, filterIcon, Icon, Chevron, Menu, MenuItem } from "./vault-ui.jsx"
import { VaultPagesMenu } from "./VaultPagesMenu.jsx"

const nowSec = () => Math.floor(Date.now() / 1000)
const scroller = el => el?.closest(".desk-list") ?? null
const modeOf = (hash = location.hash) => { const m = /^#\/?vault\/([a-z]+)/.exec(hash)?.[1]; return isMode(m) ? m : null }

/** `desk`: the desktop's list column, where the modes are a segmented header and Messages is a sidebar row. */
export function VaultScreen({ ctx, desk = false }) {
  const { vault, account, session } = ctx
  const me = session.pubkey
  const relays = uniq([...account.relays.read, ...account.relays.write, ...DEFAULT_RELAYS])
  // Coming back to the tab finds it as it was left (the phone keeps VaultTabView alive): list, mode, filter, scroll.
  const [k] = useState(() => keptVault(me))
  const link = modeOf()
  // The phone opens on "Vault"; "#/vault/notes" opens a list straight from a link. The tab's dot goes to where the
  // news is, not to the list you left (BottomTabBar opensNewActivity).
  const [mode, setMode] = useState(() => link ?? (getVaultUnread() > 0 ? "activity" : k?.mode ?? "activity"))
  const [filter, setFilter] = useState(() => k && mode === k.mode ? k.filter : defaultFilter(mode))
  const [own, setOwn] = useState(() => k?.own ?? [])
  const [inboundAll, setInbound] = useState(() => k?.inbound ?? [])
  // Kind 3 lists naming the user, cut down (vault-lists.js compactLists) and kept in this browser between visits.
  const [lists, setLists] = useState(() => k?.lists ?? readLists(me))
  const [givenAll, setGiven] = useState(() => k?.given ?? []) // zap receipts the user paid
  // Zap receipts their payee's zap service didn't publish (forged), by id. Checked after the first draw, since
  // resolving a zap service takes the network; until then a receipt still needs a valid signed zap request.
  const [forged, setForged] = useState(() => k?.forged ?? new Set())
  const trust = receiptTrust(ctx)
  const screen = async evs => {
    const kept = new Set((await trust(evs).catch(() => evs)).map(e => e.id))
    const out = evs.filter(e => !kept.has(e.id)).map(e => e.id)
    if (out.length) setForged(f => new Set([...f, ...out]))
  }
  const inbound = useMemo(() => forged.size ? inboundAll.filter(e => !forged.has(e.id)) : inboundAll, [inboundAll, forged])
  const given = useMemo(() => forged.size ? givenAll.filter(e => !forged.has(e.id)) : givenAll, [givenAll, forged])
  // Answers newer than the list on screen wait behind the "N new" pill instead of moving its rows
  // (vault-lists.js splitArrivals). `top`: the newest moment the list showed when drawn; 0 until it is.
  const [held, setHeld] = useState(() => k?.held ?? { inbound: [], lists: [] })
  const top = useRef(k?.top ?? 0)
  const holding = useRef(true) // Refresh shows everything it finds at once: it was asked for
  const [notes, setNotes] = useState(() => k?.notes ?? new Map())
  const [status, setStatus] = useState("")
  const [loaded, setLoaded] = useState(!!k)
  const { blocked } = useBlocks(ctx)
  const network = useDmTrust(ctx) // who counts as inside the network: notes from outside it stay out of the Vault list
  const seenAt = useRef(followersSeenAt(me))
  // Lines newer than the last look show a dot (VaultActivityList unreadSince): the Vault list's mark as this visit
  // found it, else when this browser started watching the account (notify-watch.js readSince).
  const unreadSince = useRef(unreadFrom(readSeen(me)?.activity ?? 0, readSince(me)))
  const [searching, setSearching] = useState(false)
  const [refreshes, setRefreshes] = useState(0) // Refresh also asks the media servers again (BlossomGallery)
  // Rows drawn so far, and whether Haven may hold older own or inbox events than those read (the phone's loadMore).
  const [shown, setShown] = useState(() => k && !link ? k.shown : FIRST_ROWS)
  const [older, setOlder] = useState(() => k?.older ?? { own: false, inbound: false })
  const [paging, setPaging] = useState(false)

  useEffect(() => { const f = () => { const m = modeOf(); if (m) pick(m) }; addEventListener("hashchange", f); return () => removeEventListener("hashchange", f) }, [])

  // A network answer goes in now, or behind the pill once the list is drawn. The first inbound answer on an empty
  // list is what gets drawn: later ones hold from there.
  const arrive = (kind, fresh) => {
    const put = kind === "inbound" ? evs => setInbound(prev => merge(prev, evs)) : evs => setLists(prev => mergeLists(prev, evs, me))
    if (!holding.current) return put(fresh)
    const { own: o, lists: l } = keep.current
    const { now, later } = splitArrivals(kind, fresh, { top: top.current, me, own: o, lists: l, blocked })
    if (now.length) put(now)
    if (later.length) setHeld(h => ({ ...h, [kind]: merge(h[kind], later) }))
    if (!top.current && kind === "inbound") top.current = newestShown(now)
  }
  const showHeld = () => {
    const h = held
    setInbound(prev => merge(prev, h.inbound)); setLists(prev => mergeLists(prev, h.lists, me))
    setHeld({ inbound: [], lists: [] }); setShown(FIRST_ROWS)
    top.current = Math.max(top.current, newestShown(h.inbound, h.lists))
    const el = scroller(root.current); if (el) el.scrollTop = 0; else scrollTo(0, 0)
  }
  const load = async ({ hold = true } = {}) => {
    const [o, i] = await Promise.all([readOwn(vault, me).catch(() => []), readInbound(vault, me)])
    // Refresh (`hold` false) also lets in what the pill held, and this round's answers go straight in.
    const h = hold ? null : held
    setOwn(o); setInbound(h ? merge(i, h.inbound) : i); setLoaded(true); setShown(FIRST_ROWS)
    if (h) { setLists(prev => mergeLists(prev, h.lists, me)); setHeld({ inbound: [], lists: [] }) }
    holding.current = hold
    top.current = hold ? newestShown(i, keep.current.lists) : 0
    setOlder({ own: o.length >= READ_PAGE, inbound: i.length >= READ_PAGE })
    screen(i) // receipts kept before this check existed
    const settled = () => { setFetched(true); setListsFetched(true); setGivenFetched(true); setOwnFetched(true) }
    if (!navigator.onLine) { setStatus("Offline: showing what this browser's relay holds"); settled(); return }
    setStatus("Checking your relays…")
    // Each answer draws as it lands: the list never waits on the slowest (zaps given, net/vault-lists.js fetchVault).
    const err = await fetchVault(vault, me, relays, { trust, on: {
      inbound: fresh => { arrive("inbound", fresh); setFetched(true) },
      lists: l => { arrive("lists", l); setListsFetched(true) },
      given: g => { setGiven(prev => merge(prev, g)); setGivenFetched(true) },
      own: async () => { const fresh = await readOwn(vault, me).catch(() => []); setOwn(prev => merge(prev, fresh)); setOwnFetched(true) },
      // Enough relays answered, maybe with nothing: an empty mode says so now, not after the slowest (a new account).
      settled: kind => kind === "inbound" ? setFetched(true) : kind === "lists" ? setListsFetched(true)
        : kind === "own" && readOwn(vault, me).catch(() => []).then(fresh => { setOwn(prev => merge(prev, fresh)); setOwnFetched(true) }),
    } })
    setStatus(err ? `Couldn't reach your relays (${err?.message ?? err})` : "")
    settled()
  }
  // Back on a kept tab: only what's new since it was left, merged in; the rows drawn and the scroll stay.
  const update = async since => {
    const [o, i] = await Promise.all([readOwn(vault, me).catch(() => []), readInbound(vault, me)])
    setOwn(prev => merge(prev, o)); setInbound(prev => merge(prev, i))
    holding.current = true
    if (!top.current) top.current = newestShown(merge(keep.current.inbound, i), keep.current.lists)
    if (!navigator.onLine) { setStatus("Offline: showing what this browser's relay holds"); return }
    const err = await fetchVault(vault, me, relays, { trust, since, on: {
      inbound: fresh => arrive("inbound", fresh),
      lists: l => arrive("lists", l),
      given: g => setGiven(prev => merge(prev, g)),
      own: async () => { const fresh = await readOwn(vault, me).catch(() => []); setOwn(prev => merge(prev, fresh)) },
    } })
    setStatus(err ? `Couldn't reach your relays (${err?.message ?? err})` : "")
  }
  useEffect(() => {
    if (!k) { load(); return }
    if (!link && k.scrollY) requestAnimationFrame(() => { const el = scroller(root.current); if (el) el.scrollTop = k.scrollY; else scrollTo(0, k.scrollY) })
    update(sinceKept(k))
  }, [me])
  // What the tab keeps when it's left. The scroll (the desktop's list column, else the page) is noted as it moves:
  // by the time the screen unmounts, the next one may already have changed it.
  const root = useRef()
  const scrolled = useRef(k && !link ? k.scrollY : 0)
  useEffect(() => {
    const el = scroller(root.current), on = el ?? window
    const f = () => { scrolled.current = el ? el.scrollTop : scrollY }
    on.addEventListener("scroll", f, { passive: true }); return () => on.removeEventListener("scroll", f)
  }, [])
  const keep = useRef()
  keep.current = { me, mode, filter, own, inbound: inboundAll, lists, given: givenAll, forged, notes, shown, older, held, top: top.current }
  useEffect(() => () => { const { me: who, ...state } = keep.current; keepVault(who, { ...state, top: top.current, scrollY: scrolled.current }) }, [])

  const pick = m => { setMode(m); setFilter(defaultFilter(m)); setShown(FIRST_ROWS) }
  const choose = id => { setFilter(id); setShown(FIRST_ROWS) }
  // The end of the list nears: draw more rows, and once all are drawn read the page before them from Haven.
  const onMore = async atEnd => {
    if (!atEnd) { setShown(n => n + MORE_ROWS); return }
    if (paging || !(older.own || older.inbound)) return
    setPaging(true)
    const r = await readOlder(vault, me, { own, inbound: inboundAll, more: older }).catch(() => null)
    if (r) {
      if (r.own.length) setOwn(prev => merge(prev, r.own))
      if (r.inbound.length) { setInbound(prev => merge(prev, r.inbound)); screen(r.inbound) }
      setOlder(r.more); setShown(n => n + MORE_ROWS)
    } else setOlder({ own: false, inbound: false })
    setPaging(false)
  }
  const followers = useMemo(() => followersOf(lists, me, blocked), [lists, blocked])
  // Seeing the Followers list is what makes its "new" ones old, as on the phone; the current visit still shows them.
  useEffect(() => { if (mode === "followers" && followers.length) markFollowersSeen(me, followers[0].at) }, [mode, followers.length])

  // "New" in the mode menu: what others sent since each mode was last open. The mode on screen counts as looked at.
  const [seen, setSeen] = useState(() => readSeen(me))
  const [fetched, setFetched] = useState(!!k) // the relays were asked: only then is a first look's baseline whole
  const [listsFetched, setListsFetched] = useState(!!k) // Followers' own answer
  const [givenFetched, setGivenFetched] = useState(!!k) // Zaps given's own answer, after every payee is checked
  const [ownFetched, setOwnFetched] = useState(!!k) // your likes and highlights from the relays
  // The next visit draws its Followers and follow lines from these before any relay answers.
  useEffect(() => { if (listsFetched) keepLists(me, lists) }, [lists, listsFetched])
  // Which answer a mode's "nothing here" waits for; until then it shows its skeleton.
  const ready = mode === "followers" ? listsFetched : mode === "zaps" && filter === "given" ? givenFetched
    : (mode === "likes" && filter === "given") || mode === "highlights" ? fetched && ownFetched : fetched
  const newest = newestByMode(inbound, me, blocked)
  useEffect(() => {
    if (!loaded || (!seen && !fetched)) return
    let next = (seen && readSeen(me)) ?? seen ?? baseline(newest) // the stored marks: leaving the Vault list moves them
    if (newest[mode]) next = markSeen(next, mode, newest[mode])
    // The Vault list shows every line, follows and held arrivals included, so a look at it sees all of them up to now
    // (the iPhone's activityVisit marks now): the tab's dot and the title's count clear (useNotifyWatch).
    if (mode === "activity") next = markSeen(next, "activity", nowSec())
    if (JSON.stringify(next) !== JSON.stringify(seen)) { setSeen(next); writeSeen(me, next) }
  }, [loaded, fetched, mode, newest[mode], seen === null])
  // Leaving the Vault list moves its mark to now too, as the iPhone's does: what came in while it was open was seen.
  useEffect(() => {
    if (mode !== "activity") return
    return () => { const s = readSeen(me); if (s) writeSeen(me, markSeen(s, "activity", nowSec())) }
  }, [mode, me])
  const followersSeen = followersSeenAt(me)
  const fresh = loaded && seen ? newModes(newest, seen, { current: mode, followersAt: followers[0]?.at, followersSeen: followersSeen || Infinity }) : new Set()

  // The current list's rows, sorted once per change of what they're built from, not on every render.
  const items = useMemo(() => itemsFor(mode, filter, { own, inbound, given, followers, me, blocked, seenAt: seenAt.current, trusted: network }), [mode, filter, own, inbound, given, followers, blocked, network])
  const newCount = useMemo(() => heldCount(held, me, own, blocked), [held, own, blocked])
  // Likes and Zaps rows name the note they were about.
  const wanted = mode === "likes" || mode === "zaps" ? items.map(r => r.noteId).filter(id => id && !notes.has(id)) : []
  useEffect(() => { if (wanted.length) fetchNotes(vault, wanted, relays).then(found => setNotes(prev => new Map([...prev, ...found]))).catch(() => {}) }, [wanted.join()])
  // Names and faces, asked once for everyone the list names: the rows drawn so far first, then the rest
  // (net/profiles.js reads Haven /feed, then the relays, and keeps what they send).
  const asked = useRef(new Set())
  const people = useMemo(() => peopleOf(mode, items), [mode, items])
  useEffect(() => {
    const onScreen = peopleOf(mode, items.slice(0, shown)).filter(pk => !asked.current.has(pk))
    const rest = people.filter(pk => !asked.current.has(pk) && !onScreen.includes(pk))
    for (const pk of [...onScreen, ...rest]) asked.current.add(pk)
    if (onScreen.length) fetchProfiles(vault, onScreen, relays).catch(() => {})
    if (rest.length) fetchProfiles(vault, rest, relays).catch(() => {})
  }, [people, shown])

  // Anyone can reply, react, zap or follow: only a follow's (or your own) picture host and inline images are fetched.
  const trusted = pk => pk === me || account.follows.includes(pk)
  const filters = FILTERS[mode]
  const f = filters.find(x => x.id === filter)
  return (
    <main class="screen vault" ref={root}>
      <header class="screen-head vault-head">
        {desk ? (
          <div class="vault-modes" role="tablist" aria-label="Vault">
            {MODES.map(x => <button key={x.id} role="tab" aria-selected={x.id === mode} class={x.id === mode ? "on" : ""} title={fresh.has(x.id) ? `${x.title}: new` : x.title} onClick={() => pick(x.id)}><Icon d={ICONS[x.id]} /><span>{x.title}</span>{fresh.has(x.id) && <span class="vault-new-dot" aria-label="new" />}</button>)}
          </div>
        ) : (
          <VaultPagesMenu ctx={ctx} current={mode} fresh={fresh} onPick={pick} onRefresh={() => { setRefreshes(n => n + 1); load({ hold: false }) }} />
        )}
        {!desk ? (
          <div class="vault-capsule">
            {filters.length > 0 && <>
              <div class="vault-capsule-filters" role="group" aria-label={`Filter: ${f?.title}`}>
                {filters.map(x => <button key={x.id} class={`vault-capsule-btn ${x.id === filter ? "on" : ""}`} aria-pressed={x.id === filter} aria-label={x.title} title={x.title} onClick={() => choose(x.id)}><Icon d={filterIcon(mode, x.id)} size={18} /></button>)}
              </div>
              <span class="vault-capsule-line" aria-hidden="true" />
            </>}
            <button class={`vault-capsule-btn ${searching ? "on" : ""}`} onClick={() => setSearching(!searching)} aria-label="Search your vault" aria-pressed={searching} title="Search your vault"><Icon d={ICONS.search} size={18} /></button>
          </div>
        ) : (
        <div class="vault-right">
          <a class="vault-pill-btn" href={dashboardHref()} onClick={e => { e.preventDefault(); openDashboard() }} aria-label="Vault Dashboard" title="Vault Dashboard"><Icon d={ICONS.dashboard} /></a>
          {filters.length > 0 && (
            <Menu label={<><Icon d={ICONS.filter} /><span>{f?.pill ?? f?.title}</span><Chevron /></>} title={`Filter: ${f?.title}`} align="right">
              {filters.map(x => <MenuItem key={x.id} on={x.id === filter} onClick={() => choose(x.id)}>{x.title}</MenuItem>)}
            </Menu>
          )}
          <button class="vault-pill-btn" onClick={() => setSearching(!searching)} aria-label="Search your vault" aria-pressed={searching} title="Search your vault"><Icon d={ICONS.search} /></button>
          <button class="vault-pill-btn" onClick={() => { setRefreshes(n => n + 1); load({ hold: false }) }} aria-label="Refresh" title="Refresh"><Icon d={ICONS.refresh} /></button>
        </div>
        )}
      </header>
      {searching ? <VaultSearch ctx={ctx} onClose={() => setSearching(false)} /> : <>
      <div class="status-line keep">{status}</div>
      {loaded && newCount > 0 && <NewPostsPill count={newCount} onShow={showHeld} text={n => `${n} new`} />}
      {!loaded ? <VaultSkeleton mode={mode} /> : <List ctx={ctx} mode={mode} filter={filter} items={items} me={me} followers={followers} notes={notes} trusted={trusted} unreadSince={unreadSince.current} refreshes={refreshes} fetched={ready} page={{ shown, onMore, busy: paging, older: older.own || older.inbound }} onFollowers={() => pick("followers")} />}
      </>}
      <VaultButton desk={desk} />
    </main>
  )
}


/** The list's shape while the relay is read: tiles for media, people rows for followers, cards otherwise. */
function VaultSkeleton({ mode }) {
  if (mode === "media") return <SkeletonGrid count={12} gridClass="vault-grid" tileClass="vault-thumb" label="Loading your media…" />
  if (mode === "followers") return <SkeletonList rowClass="person-row" label="Loading your followers…" />
  if (mode === "notes" || mode === "articles" || mode === "highlights") return <SkeletonRows count={4} label="Loading your vault…" />
  return <SkeletonList rowClass="note notification" avatar={32} label="Loading your vault…" />
}

function merge(prev, fresh) {
  const by = new Map(prev.map(e => [e.id, e]))
  for (const e of fresh) by.set(e.id, e)
  return [...by.values()]
}


const Grid = ({ children }) => <div class="vault-grid">{children}</div>

function List({ ctx, mode, filter, items, me, followers, notes, trusted, unreadSince = Infinity, refreshes = 0, fetched = true, page = { shown: Infinity, onMore: () => {} }, onFollowers }) {
  // Nothing in this browser's relay yet, but the relays are still being asked: placeholders, not "nothing here".
  const Empty = ({ text }) => fetched ? <p class="empty">{text}</p> : <VaultSkeleton mode={mode} />
  // A call, not a component made here: a new component type each render would draw every row again.
  // A list that is empty so far but may have older rows in Haven still pages, so its end marker can ask for them.
  const paged = (items, render, wrap) => <PagedList items={items} render={render} wrap={wrap} shown={page.shown} onMore={page.onMore} busy={page.busy} />
  switch (mode) {
    case "activity": {
      const rows = items
      return (rows.length || page.older) ? paged(rows, r => <ActivityRow key={r.id} row={r} trusted={trusted} unread={r.created_at > unreadSince} onFollowers={onFollowers} />) : <Empty text={filter === "mentions" ? "No replies, mentions or quotes yet." : "Nothing has come in yet. Replies, likes, zaps, reposts and new followers land here."} />
    }
    case "notes": {
      const list = items
      return (list.length || page.older) ? paged(list, n => <NoteCard key={n.id} event={n} />) : <Empty text={filter === "tagged" ? "No notes tag you yet." : "No notes yet."} />
    }
    case "articles": {
      const list = items
      return (list.length || page.older) ? paged(list, a => <ArticleCard key={a.id} event={a} />) : <Empty text={filter === "recipes" ? "No recipes found. Recipes are articles tagged zapcooking or nostrcooking." : "Long-form posts you write or are tagged in land here."} />
    }
    case "highlights": {
      const list = items
      return (list.length || page.older) ? paged(list, h => <HighlightCard key={h.id} event={h} trusted={trusted} />) : <Empty text="No highlights yet." />
    }
    case "media": {
      if (filter !== "notes") return <BlossomGallery ctx={ctx} filter={filter} refreshes={refreshes} />
      const list = items
      return (list.length || page.older)
        ? paged(list, p => <a key={p.url} href={`#/thread/${p.noteId}`} class="vault-thumb"><MediaImage item={p.item} author={me} loading="lazy" /></a>, Grid)
        : <Empty text="Pictures from your notes show here." />
    }
    case "likes": return (items.length || page.older) ? paged(items, r => <EngagementRow key={r.id} row={r} note={notes.get(r.noteId)} me={me} trusted={trusted} />) : <Empty text={filter === "given" ? "You haven't liked anything from here yet." : "No likes on your notes yet."} />
    case "zaps": return (items.length || page.older) ? paged(items, r => <EngagementRow key={r.id} row={r} note={notes.get(r.noteId)} me={me} trusted={trusted} />) : <Empty text={filter === "given" ? "No zaps you paid were found on your relays." : "No zaps on your notes yet."} />
    case "followers": {
      const list = items
      return list.length
        ? <>{followers.length > 0 && <div class="section-label">{followers.length} follower{followers.length === 1 ? "" : "s"}</div>}{paged(list, f => <a key={f.pubkey} class="person-row" href={`#/profile/${f.pubkey}`}><Avatar pubkey={f.pubkey} size={40} load={trusted(f.pubkey)} /><span class="person-names"><AuthorName pubkey={f.pubkey} /><span class="person-sub">followed you {ago(f.at)} ago</span></span></a>)}</>
        : <Empty text={filter === "new" ? "No new followers since you last looked." : "No followers found on your relays yet."} />
    }
    default: return null
  }
}


/** One "Vault" line: who did what, the text or the note it was about, the pictures as thumbnails (your own notes').
 *  `trusted(pubkey)`: whose avatar and inline images may load; a stranger's would tell their server your IP.
 *  A tap opens what it's about (VaultActivityList.openActivity): the note, else the Followers list when several
 *  followed you that day (`onFollowers`), else the person. */
export function ActivityRow({ row, trusted = () => false, unread = false, onFollowers }) {
  const ok = trusted(row.actors[0])
  const open = row.openId ? () => { location.hash = `#/thread/${row.openId}` }
    : row.kind === "follow" && row.actors.length > 1 && onFollowers ? onFollowers
    : row.actors[0] ? () => { location.hash = `#/profile/${row.actors[0]}` } : undefined
  return (
    <article class={`note notification${unread ? " unread" : ""}${open ? " tappable" : ""}`} onClick={open && (e => { if (!e.target.closest("a, button")) open() })}>
      <div class="note-head">
        <Faces who={row.actors} trusted={trusted} />
        <time class="note-time" datetime={new Date(row.created_at * 1000).toISOString()}>{ago(row.created_at)}</time>
        {unread && <span class="notif-dot" role="img" aria-label="New" title="New" />}
      </div>
      <div class="notif-who"><Names who={row.actors} /> {verb(row)}</div>
      {["reply", "mention", "quote", "article", "highlight"].includes(row.kind)
        ? <NoteText content={row.preview} images={ok} />
        : row.preview ? <div class="repost-line vault-about"><span>{cut(row.preview)}</span></div> : null}
      {row.images.length > 0 && <div class="vault-thumbs">{row.images.slice(0, 4).map(u => <MediaImage key={u} item={imageItem(u)} author={row.imagesBy} loading="lazy" />)}</div>}
    </article>
  )
}

/** What they did, in the phone's words (VaultActivityList verb). */
export function verb(row) {
  switch (row.kind) {
    case "reply": return "replied to you"
    case "mention": return "mentioned you"
    case "quote": return "quoted your note"
    case "repost": return "reposted your note"
    case "like": { const e = reactionEmojiSummary(row.emojis); return e === "❤️" ? "liked your note" : `reacted ${e} to your note` }
    case "zap": return row.openId ? `zapped your note ${row.sats.toLocaleString()} sats` : `zapped you ${row.sats.toLocaleString()} sats`
    case "follow": return "followed you"
    case "article": return "tagged you in an article"
    case "highlight": return "highlighted you"
    default: return ""
  }
}

/** A Likes or Zaps row: who, what, and the note it was about. */
function EngagementRow({ row, note, me, trusted = () => false }) {
  const mine = row.who[0] === me
  const open = row.noteId ? () => { location.hash = `#/thread/${row.noteId}` } : undefined
  return (
    <article class={`note notification ${open ? "tappable" : ""}`} onClick={open && (e => { if (!e.target.closest("a, button")) open() })}>
      <div class="note-head">
        <Avatar pubkey={row.who[0]} size={32} load={trusted(row.who[0])} />
        <span class="notif-who">{mine ? "You" : <Who who={row.who} />} {row.type === "reaction" ? `liked ${row.emoji !== "❤️" ? row.emoji : ""}`.trim() : "⚡ zapped"}{mine && row.to && <> <AuthorName pubkey={row.to} /></>}{row.type === "zap" && row.sats ? ` ${formatSats(row.sats)} sats` : ""}</span>
        <time class="note-time" datetime={new Date(row.created_at * 1000).toISOString()}>{ago(row.created_at)}</time>
      </div>
      {row.noteId && <About note={note} />}
    </article>
  )
}

function Who({ who }) {
  const [a, b, ...rest] = who
  if (!b) return <AuthorName pubkey={a} />
  if (!rest.length) return <><AuthorName pubkey={a} /> and <AuthorName pubkey={b} /></>
  return <><AuthorName pubkey={a} />, <AuthorName pubkey={b} /> and {rest.length} other{rest.length > 1 ? "s" : ""}</>
}

function About({ note }) {
  if (!note) return <div class="repost-line vault-about muted">a note</div>
  return <div class="repost-line vault-about"><span style="flex: none"><AuthorName pubkey={note.pubkey} />:</span><span>{cut(previewOf(note)) || "(media)"}</span></div>
}

const cut = s => s.length > 140 ? s.slice(0, 140) + "…" : s

/** A NIP-84 highlight: the quoted text and where it came from. */
function HighlightCard({ event, trusted = () => false }) {
  const src = highlightSource(event)
  return (
    <article class="note highlight">
      <div class="note-head"><Avatar pubkey={event.pubkey} size={32} load={trusted(event.pubkey)} /><AuthorName pubkey={event.pubkey} /><time class="note-time">{ago(event.created_at)}</time></div>
      <blockquote class="vault-quote">{event.content}</blockquote>
      {src && <div class="person-sub">{/^https?:/.test(src) ? <a href={src} target="_blank" rel="noopener">{src}</a> : /^[0-9a-f]{64}$/.test(src) ? <a href={`#/thread/${src}`}>from a note</a> : src}</div>}
    </article>
  )
}
