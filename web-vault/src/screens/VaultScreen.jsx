// The Vault tab (iPhone VaultTabView): a mode pill on the left (Vault · Notes · Articles · Highlights · Media ·
// Likes · Zaps · Followers, then the Vault Dashboard), and on the right one pill with the Messages envelope, the mode's
// filters as bare icons and search (VaultToolbar trailingPill). A floating "Vault" capsule, coloured by how the relays
// answered, opens the Dashboard (VaultView+Layout). Your own events come from Haven's outbox; what others sent you from Haven's inbox and the relays.
// The web's Vault Dashboard is the Relay screen, which already shows the relay's counts and storage.
import { useEffect, useRef, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName, NoteCard } from "../components/NoteCard.jsx"
import { ArticleCard } from "../components/ArticleCard.jsx"
import { NoteText } from "../components/NoteText.jsx"
import { MediaImage } from "../components/MediaImage.jsx"
import { imageItem } from "../net/note-media.js"
import { ago } from "../components/time.js"
import { useBlocks } from "../components/useBlocks.js"
import { fetchProfiles } from "../net/profiles.js"
import { formatSats, fetchNotes } from "../net/notifications.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { receiptTrust } from "../net/zaps.js"
import { VaultSearch } from "./VaultSearch.jsx"
import { BlossomGallery } from "./BlossomGallery.jsx"
import { newestByMode, readSeen, writeSeen, markSeen, baseline, newModes } from "../net/vault-new.js"
import {
  MODES, FILTERS, isMode, defaultFilter, previewOf, activityRows, activityFilter, notesFor, articlesFor, highlightsFor, highlightSource,
  mediaFor, likesFor, zapsFor, followersOf, followersFilter, followersSeenAt, markFollowersSeen,
  readOwn, readInbound, fetchVault,
} from "../net/vault-lists.js"
import { SkeletonGrid, SkeletonList } from "../components/Loading.jsx"
import { SkeletonRows } from "../components/FeedExtras.jsx"

const ICONS = {
  activity: "M3 13h5l1.5 3h5L16 13h5M3 13l2-7h14l2 7v6H3z",
  notes: "M6 3h9l5 5v13H6zM14 3v6h6M9 13h6M9 17h6",
  articles: "M6 3h9l5 5v13H6zM14 3v6h6M9 12h3M9 16h6M14 12h1",
  highlights: "M4 20h7M14 3l7 7-9 9H7l-1-1zM9 14l5-5",
  media: "M3 6h14v12H3zM7 21h14V9M3 15l4-4 4 4 3-3 3 3",
  likes: "M12 20s-7-4.5-7-10a4 4 0 0 1 7-2.5A4 4 0 0 1 19 10c0 5.5-7 10-7 10z",
  zaps: "M13 2L4 14h7l-1 8 9-12h-7z",
  followers: "M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20a6.5 6.5 0 0 1 13 0M16 4.3a3.5 3.5 0 0 1 0 6.4M18 14.2a6.5 6.5 0 0 1 3.5 5.8",
  dashboard: "M4 4h16v16H4zM4 10h16M10 10v10",
  filter: "M4 6h16M7 12h10M10 18h4",
  envelope: "M4 5h16a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1zM3 7l9 6 9-6",
  // The Vault tab's own glyph, as on the phone, where the tab and the Dashboard share one symbol.
  safe: "M5 4h14a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1zM12 13.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM12 11v2M4 9h3M4 15h3",
  refresh: "M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7",
  search: "M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM21 21l-5-5",
  // The phone's filter glyphs (VaultToolbar trailingFilters), by filter id.
  stack: "M7 3h10M5 7h14M4 11h16v10H4z",
  at: "M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0zM16 12v1.5a2.5 2.5 0 0 0 5 0V12a9 9 0 1 0-3.5 7.1",
  person: "M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21a8 8 0 0 1 16 0",
  fork: "M7 3v8M5 3v5a2 2 0 0 0 4 0V3M7 11v10M17 3c-2 0-3 3-3 6s1 4 3 4v8",
  trayIn: "M3 14h5l1.5 3h5L16 14h5v6H3zM12 3v9M8.5 8.5L12 12l3.5-3.5",
  trayOut: "M3 14h5l1.5 3h5L16 14h5v6H3zM12 12V3M8.5 6.5L12 3l3.5 3.5",
  sparkles: "M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z",
  photo: "M4 5h16v14H4zM4 16l5-5 4 4 2-2 5 5M15.5 9.5h.01",
  video: "M4 6h12v12H4zM16 10l5-3v10l-5-3",
  gif: "M4 5h16v14H4zM10 10H8v4h2v-1.5M13 10v4M16.5 14v-4H18M16.5 12H18",
}
const FILTER_ICONS = { all: "stack", mentions: "at", tagged: "at", mine: "person", recipes: "fork", received: "trayIn", given: "trayOut", new: "sparkles", photos: "photo", videos: "video", gifs: "gif", notes: "notes" }
const filterIcon = (mode, id) => ICONS[mode === "followers" && id === "all" ? "followers" : FILTER_ICONS[id]]
const Icon = ({ d, size = 16, width = 1.8 }) => <svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" stroke-width={width} stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>

const modeOf = (hash = location.hash) => { const m = /^#\/?vault\/([a-z]+)/.exec(hash)?.[1]; return isMode(m) ? m : null }

/** `desk`: the desktop's list column, where the modes are a segmented header and Messages is a sidebar row. */
export function VaultScreen({ ctx, desk = false }) {
  const { vault, account, session } = ctx
  const me = session.pubkey
  const relays = uniq([...account.relays.read, ...account.relays.write, ...DEFAULT_RELAYS])
  // The phone opens on "Vault" each time; "#/vault/notes" opens a list straight from a link.
  const [mode, setMode] = useState(() => modeOf() ?? "activity")
  const [filter, setFilter] = useState(() => defaultFilter(mode))
  const [own, setOwn] = useState([])
  const [inboundAll, setInbound] = useState([])
  const [lists, setLists] = useState([]) // kind 3 lists naming the user
  const [givenAll, setGiven] = useState([]) // zap receipts the user paid
  // Zap receipts their payee's zap service didn't publish (forged), by id. Checked after the first draw, since
  // resolving a zap service takes the network; until then a receipt still needs a valid signed zap request.
  const [forged, setForged] = useState(() => new Set())
  const trust = receiptTrust(ctx)
  const screen = async evs => {
    const kept = new Set((await trust(evs).catch(() => evs)).map(e => e.id))
    const out = evs.filter(e => !kept.has(e.id)).map(e => e.id)
    if (out.length) setForged(f => new Set([...f, ...out]))
  }
  const inbound = forged.size ? inboundAll.filter(e => !forged.has(e.id)) : inboundAll
  const given = forged.size ? givenAll.filter(e => !forged.has(e.id)) : givenAll
  const [notes, setNotes] = useState(new Map())
  const [status, setStatus] = useState("")
  const [loaded, setLoaded] = useState(false)
  const { blocked } = useBlocks(ctx)
  const seenAt = useRef(followersSeenAt(me))
  const [searching, setSearching] = useState(false)
  const [refreshes, setRefreshes] = useState(0) // Refresh also asks the media servers again (BlossomGallery)
  const [reach, setReach] = useState("") // how the relays answered, for the status capsule's colour

  useEffect(() => { const f = () => { const m = modeOf(); if (m) pick(m) }; addEventListener("hashchange", f); return () => removeEventListener("hashchange", f) }, [])

  const load = async () => {
    const [o, i] = await Promise.all([readOwn(vault, me).catch(() => []), readInbound(vault, me)])
    setOwn(o); setInbound(i); setLoaded(true)
    screen(i) // receipts kept before this check existed
    const settled = () => { setFetched(true); setListsFetched(true); setGivenFetched(true); setOwnFetched(true) }
    if (!navigator.onLine) { setStatus("Offline: showing what this browser's relay holds"); setReach("down"); settled(); return }
    setStatus("Checking your relays…"); setReach("checking")
    // Each answer draws as it lands: the list never waits on the slowest (zaps given, net/vault-lists.js fetchVault).
    const err = await fetchVault(vault, me, relays, { trust, on: {
      inbound: fresh => { setInbound(prev => merge(prev, fresh)); setFetched(true) },
      lists: l => { setLists(l); setListsFetched(true) },
      given: g => { setGiven(g); setGivenFetched(true) },
      own: async () => { setOwn(await readOwn(vault, me).catch(() => o)); setOwnFetched(true) },
    } })
    setStatus(err ? `Couldn't reach your relays (${err?.message ?? err})` : ""); setReach(err ? "down" : "up")
    settled()
  }
  useEffect(() => { load() }, [me])

  const pick = m => { setMode(m); setFilter(defaultFilter(m)) }
  const followers = followersOf(lists, me, blocked)
  // Seeing the Followers list is what makes its "new" ones old, as on the phone; the current visit still shows them.
  useEffect(() => { if (mode === "followers" && followers.length) markFollowersSeen(me, followers[0].at) }, [mode, followers.length])

  // "New" in the mode menu: what others sent since each mode was last open. The mode on screen counts as looked at.
  const [seen, setSeen] = useState(() => readSeen(me))
  const [fetched, setFetched] = useState(false) // the relays were asked: only then is a first look's baseline whole
  const [listsFetched, setListsFetched] = useState(false) // Followers' own answer
  const [givenFetched, setGivenFetched] = useState(false) // Zaps given's own answer, after every payee is checked
  const [ownFetched, setOwnFetched] = useState(false) // your likes and highlights from the relays
  // Which answer a mode's "nothing here" waits for; until then it shows its skeleton.
  const ready = mode === "followers" ? listsFetched : mode === "zaps" && filter === "given" ? givenFetched
    : (mode === "likes" && filter === "given") || mode === "highlights" ? fetched && ownFetched : fetched
  const newest = newestByMode(inbound, me, blocked)
  useEffect(() => {
    if (!loaded || (!seen && !fetched)) return
    let next = seen ?? baseline(newest)
    if (newest[mode]) next = markSeen(next, mode, newest[mode])
    if (JSON.stringify(next) !== JSON.stringify(seen)) { setSeen(next); writeSeen(me, next) }
  }, [loaded, fetched, mode, newest[mode], seen === null])
  const followersSeen = followersSeenAt(me)
  const fresh = loaded && seen ? newModes(newest, seen, { current: mode, followersAt: followers[0]?.at, followersSeen: followersSeen || Infinity }) : new Set()

  // Likes and Zaps rows name the note they were about.
  const likes = mode === "likes" ? likesFor(own, inbound, me, filter, blocked) : []
  const zaps = mode === "zaps" ? zapsFor(given, inbound, me, filter, blocked) : []
  const wanted = [...likes, ...zaps].map(r => r.noteId).filter(id => id && !notes.has(id))
  useEffect(() => { if (wanted.length) fetchNotes(vault, wanted, relays).then(found => setNotes(prev => new Map([...prev, ...found]))).catch(() => {}) }, [wanted.join()])
  // Names and faces for whoever the current list shows.
  const faces = mode === "activity" ? activityRows(inbound, me).flatMap(r => r.actors) : mode === "followers" ? followers.map(f => f.pubkey) : [...likes, ...zaps].flatMap(r => r.who)
  useEffect(() => { if (faces.length) fetchProfiles(vault, faces, relays).catch(() => {}) }, [mode, faces.length])

  // Anyone can reply, react, zap or follow: only a follow's (or your own) picture host and inline images are fetched.
  const trusted = pk => pk === me || account.follows.includes(pk)
  const m = MODES.find(x => x.id === mode)
  const filters = FILTERS[mode]
  const f = filters.find(x => x.id === filter)
  return (
    <main class="screen vault">
      <header class="screen-head vault-head">
        {desk ? (
          <div class="vault-modes" role="tablist" aria-label="Vault">
            {MODES.map(x => <button key={x.id} role="tab" aria-selected={x.id === mode} class={x.id === mode ? "on" : ""} title={fresh.has(x.id) ? `${x.title}: new` : x.title} onClick={() => pick(x.id)}><Icon d={ICONS[x.id]} /><span>{x.title}</span>{fresh.has(x.id) && <span class="vault-new-dot" aria-label="new" />}</button>)}
          </div>
        ) : (
          <Menu label={<><Icon d={ICONS[mode]} /><b>{m.title}</b>{fresh.size > 0 && <span class="vault-new-dot" aria-label="new in another mode" />}<Chevron /></>} title={`Vault: ${m.title}`}>
            {MODES.map(x => <MenuItem key={x.id} on={x.id === mode} onClick={() => pick(x.id)}><Icon d={ICONS[x.id]} />{x.title}{fresh.has(x.id) && <span class="vault-new">New</span>}</MenuItem>)}
            <hr />
            <MenuItem onClick={() => { location.hash = "#/relay" }}><Icon d={ICONS.dashboard} />Vault Dashboard</MenuItem>
            <MenuItem onClick={() => { setRefreshes(n => n + 1); load() }}><Icon d={ICONS.refresh} />Refresh</MenuItem>
          </Menu>
        )}
        {!desk ? (
          <div class="vault-capsule">
            <a class="vault-capsule-btn" href="#/messages" aria-label="Messages" title="Messages"><Icon d={ICONS.envelope} size={18} /></a>
            {filters.length > 0 && <>
              <span class="vault-capsule-line" aria-hidden="true" />
              <div class="vault-capsule-filters" role="group" aria-label={`Filter: ${f?.title}`}>
                {filters.map(x => <button key={x.id} class={`vault-capsule-btn ${x.id === filter ? "on" : ""}`} aria-pressed={x.id === filter} aria-label={x.title} title={x.title} onClick={() => setFilter(x.id)}><Icon d={filterIcon(mode, x.id)} size={18} /></button>)}
              </div>
            </>}
            <span class="vault-capsule-line" aria-hidden="true" />
            <button class={`vault-capsule-btn ${searching ? "on" : ""}`} onClick={() => setSearching(!searching)} aria-label="Search your vault" aria-pressed={searching} title="Search your vault"><Icon d={ICONS.search} size={18} /></button>
          </div>
        ) : (
        <div class="vault-right">
          <a class="vault-pill-btn" href="#/relay" aria-label="Vault Dashboard" title="Vault Dashboard"><Icon d={ICONS.dashboard} /></a>
          {filters.length > 0 && (
            <Menu label={<><Icon d={ICONS.filter} /><span>{f?.pill ?? f?.title}</span><Chevron /></>} title={`Filter: ${f?.title}`} align="right">
              {filters.map(x => <MenuItem key={x.id} on={x.id === filter} onClick={() => setFilter(x.id)}>{x.title}</MenuItem>)}
            </Menu>
          )}
          <button class="vault-pill-btn" onClick={() => setSearching(!searching)} aria-label="Search your vault" aria-pressed={searching} title="Search your vault"><Icon d={ICONS.search} /></button>
          <button class="vault-pill-btn" onClick={() => { setRefreshes(n => n + 1); load() }} aria-label="Refresh" title="Refresh"><Icon d={ICONS.refresh} /></button>
        </div>
        )}
      </header>
      {searching ? <VaultSearch ctx={ctx} onClose={() => setSearching(false)} /> : <>
      <div class="status-line keep">{status}</div>
      {!loaded ? <VaultSkeleton mode={mode} /> : <List ctx={ctx} mode={mode} filter={filter} own={own} inbound={inbound} me={me} blocked={blocked} followers={followers} seenAt={seenAt.current} likes={likes} zaps={zaps} notes={notes} trusted={trusted} refreshes={refreshes} fetched={ready} />}
      </>}
      {!desk && <a class={`vault-status ${reach || "idle"}`} href="#/relay" aria-label={`Vault Dashboard: ${REACH[reach || "idle"]}`} title={REACH[reach || "idle"]}><Icon d={ICONS.safe} size={17} width={2.2} /><b>Vault</b></a>}
    </main>
  )
}

const REACH = { idle: "Reading your vault", checking: "Checking your relays", up: "Relays answered", down: "Couldn't reach your relays" }

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

const Chevron = () => <svg viewBox="0 0 24 24" width="10" height="10" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 9l6 6 6-6" /></svg>

/** A pill that opens a list under it, closed by a pick, a tap outside or Escape. */
function Menu({ label, title, align = "left", children }) {
  const [open, setOpen] = useState(false)
  const ref = useRef()
  useEffect(() => {
    if (!open) return
    const away = e => { if (!ref.current?.contains(e.target)) setOpen(false) }
    const key = e => { if (e.key === "Escape") setOpen(false) }
    addEventListener("pointerdown", away); addEventListener("keydown", key)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", key) }
  }, [open])
  return (
    <div class={`vault-menu ${align}`} ref={ref} onClick={e => { if (e.target.closest("[role=menuitem]")) setOpen(false) }}>
      <button class={`vault-pill ${open ? "open" : ""}`} aria-haspopup="menu" aria-expanded={open} aria-label={title} onClick={() => setOpen(!open)}>{label}</button>
      {open && <div class="vault-menu-list" role="menu">{children}</div>}
    </div>
  )
}
const MenuItem = ({ on, onClick, children }) => <button role="menuitem" class={on ? "on" : ""} aria-checked={on} onClick={onClick}>{children}</button>

function List({ ctx, mode, filter, own, inbound, me, blocked, followers, seenAt, likes, zaps, notes, trusted, refreshes = 0, fetched = true }) {
  // Nothing in this browser's relay yet, but the relays are still being asked: placeholders, not "nothing here".
  const Empty = ({ text }) => fetched ? <p class="empty">{text}</p> : <VaultSkeleton mode={mode} />
  switch (mode) {
    case "activity": {
      const follows = followers
      const rows = activityRows(inbound, me, { mine: own, follows, blocked }).filter(r => activityFilter(r, filter))
      return rows.length ? rows.map(r => <ActivityRow key={r.id} row={r} trusted={trusted} />) : <Empty text={filter === "mentions" ? "No replies, mentions or quotes yet." : "Nothing has come in yet. Replies, likes, zaps, reposts and new followers land here."} />
    }
    case "notes": {
      const list = notesFor(own, inbound, me, filter, blocked)
      return list.length ? list.map(n => <NoteCard key={n.id} event={n} />) : <Empty text={filter === "tagged" ? "No notes tag you yet." : "No notes yet."} />
    }
    case "articles": {
      const list = articlesFor(own, inbound, me, filter, blocked)
      return list.length ? list.map(a => <ArticleCard key={a.id} event={a} />) : <Empty text={filter === "recipes" ? "No recipes found. Recipes are articles tagged zapcooking or nostrcooking." : "Long-form posts you write or are tagged in land here."} />
    }
    case "highlights": {
      const list = highlightsFor(own, inbound, me, filter, blocked)
      return list.length ? list.map(h => <HighlightCard key={h.id} event={h} trusted={trusted} />) : <Empty text="No highlights yet." />
    }
    case "media": {
      if (filter !== "notes") return <BlossomGallery ctx={ctx} filter={filter} refreshes={refreshes} />
      const list = mediaFor(own)
      return list.length
        ? <div class="vault-grid">{list.map(p => <a key={p.url} href={`#/thread/${p.noteId}`} class="vault-thumb"><MediaImage item={p.item} author={me} loading="lazy" /></a>)}</div>
        : <Empty text="Pictures from your notes show here." />
    }
    case "likes": return likes.length ? likes.map(r => <EngagementRow key={r.id} row={r} note={notes.get(r.noteId)} me={me} trusted={trusted} />) : <Empty text={filter === "given" ? "You haven't liked anything from here yet." : "No likes on your notes yet."} />
    case "zaps": return zaps.length ? zaps.map(r => <EngagementRow key={r.id} row={r} note={notes.get(r.noteId)} me={me} trusted={trusted} />) : <Empty text={filter === "given" ? "No zaps you paid were found on your relays." : "No zaps on your notes yet."} />
    case "followers": {
      const list = followersFilter(followers, filter, seenAt)
      return list.length
        ? list.map(f => <a key={f.pubkey} class="person-row" href={`#/profile/${f.pubkey}`}><Avatar pubkey={f.pubkey} size={40} load={trusted(f.pubkey)} /><span class="person-names"><AuthorName pubkey={f.pubkey} /><span class="person-sub">followed you {ago(f.at)} ago</span></span></a>)
        : <Empty text={filter === "new" ? "No new followers since you last looked." : "No followers found on your relays yet."} />
    }
    default: return null
  }
}


/** One "Vault" line: who did what, the text or the note it was about, the pictures as thumbnails (your own notes').
 *  `trusted(pubkey)`: whose avatar and inline images may load; a stranger's would tell their server your IP. */
export function ActivityRow({ row, trusted = () => false }) {
  const ok = trusted(row.actors[0])
  const open = row.openId ? () => { location.hash = `#/thread/${row.openId}` } : undefined
  return (
    <article class={`note notification ${open ? "tappable" : ""}`} onClick={open && (e => { if (!e.target.closest("a, button")) open() })}>
      <div class="note-head">
        <Avatar pubkey={row.actors[0]} size={32} load={ok} />
        <span class="notif-who"><Who who={row.actors} /> {verb(row)}</span>
        <time class="note-time" datetime={new Date(row.created_at * 1000).toISOString()}>{ago(row.created_at)}</time>
      </div>
      {["reply", "mention", "quote", "article", "highlight"].includes(row.kind)
        ? <NoteText content={row.preview} images={ok} />
        : row.preview ? <div class="repost-line vault-about"><span>{cut(row.preview)}</span></div> : null}
      {row.images.length > 0 && <div class="vault-thumbs">{row.images.slice(0, 4).map(u => <MediaImage key={u} item={imageItem(u)} author={row.imagesBy} loading="lazy" />)}</div>}
    </article>
  )
}

function verb(row) {
  switch (row.kind) {
    case "reply": return "replied"
    case "mention": return "mentioned you"
    case "quote": return "quoted you"
    case "repost": return "reposted"
    case "like": return `liked ${row.emojis.filter(e => e !== "❤️").join(" ")}`.trim()
    case "zap": return row.sats ? `⚡ zapped ${formatSats(row.sats)} sats` : "⚡ zapped"
    case "follow": return "followed you"
    case "article": return "wrote an article tagging you"
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
