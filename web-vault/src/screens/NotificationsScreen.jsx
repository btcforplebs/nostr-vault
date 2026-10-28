// Notifications: who replied, mentioned, quoted, reposted, reacted, zapped, followed, or tagged the user in an
// article or highlight, newest first, one row each, as the iPhone's Vault list shows them (VaultActivityList).
// Read from the user's read relays; nothing here signs. The note each row is about comes from Haven's outbox
// (the user's own notes) or the network. Reuses .note / .note-head / .repost-line from app.css.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { Faces, Who } from "../components/ActivityFaces.jsx"
import { Mention, NoteText } from "../components/NoteText.jsx"
import { ago } from "../components/time.js"
import {
  aboutPreview, fetchNotificationEvents, fetchNotes, filterRows, groupNotifications, insideRows, reactionEmojiSummary,
  trustedWeb, visitNotifications,
} from "../net/notifications.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { receiptTrust } from "../net/zaps.js"
import { visibleRows } from "../net/blocks.js"
import { followLists } from "../net/wot.js"
import { useBlocks } from "../components/useBlocks.js"
import { SkeletonList, Spinner } from "../components/Loading.jsx"
import "../styles/notifications.css"

export { Faces, Who, MAX_FACES } from "../components/ActivityFaces.jsx"

const PAGE = 100

// What this session last had for each account: a second visit draws it at once and refreshes underneath, as the
// iPhone's list is already there when the Vault tab opens. Memory only; a reload asks the relays again.
const kept = new Map()
const mergeEvents = (have, page) => {
  if (!have?.length) return page
  const ids = new Set(have.map(ev => ev.id))
  const fresh = page.filter(ev => ev?.id && !ids.has(ev.id))
  return fresh.length ? [...have, ...fresh] : have
}

export function NotificationsScreen({ ctx }) {
  const { vault, account, session } = ctx
  const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const last = kept.get(session.pubkey)
  const [events, setEvents] = useState(last?.events ?? null) // every page's events, grouped together so folds span pages
  const [notes, setNotes] = useState(last?.notes ?? new Map())
  const [status, setStatus] = useState("")
  const [loading, setLoading] = useState(!last) // the first load is still out: an empty list isn't "nothing" yet
  const [more, setMore] = useState(last ? { ...last.more, busy: false } : { until: null, done: false, busy: false })
  // Who counts as inside your network (TrustMap.web): null until the follows' lists are in, and then empty when
  // there is no graph (nobody is outside).
  const [trusted, setTrusted] = useState(last?.trusted ?? null)
  const { blocked } = useBlocks(ctx)
  const [filter, setFilter] = useState("all") // "all" | "mentions" (VaultToolbar: All / Mentions)
  // Rows newer than the last visit show a dot. Infinity until this visit is read, so nothing flashes as unread.
  const [unreadSince, setUnreadSince] = useState(Infinity)
  const gen = useRef(0) // a Refresh drops the pages an older load is still fetching
  const filled = useRef(new Set(last?.notes?.keys() ?? [])) // notes asked for already, so each is fetched once
  useEffect(() => {
    setUnreadSince(visitNotifications(session.pubkey, { arriving: true }))
    return () => visitNotifications(session.pubkey, { arriving: false })
  }, [session.pubkey])
  useEffect(() => { if (events) kept.set(session.pubkey, { events, notes, more, trusted }) }, [events, notes, more, trusted, session.pubkey])

  // Not awaited by the list: likes, zaps and follows show at once, and notes from outside the follows wait for it.
  const loadWeb = () => followLists(session.pubkey, account.follows).then(l => setTrusted(trustedWeb(account.follows, l))).catch(() => setTrusted(new Set()))
  useEffect(() => { loadWeb() }, [session.pubkey, account.follows.length])

  // The notes rows are about, and the faces, for the events not seen before.
  const fillIn = async page => {
    const rows = groupNotifications(page, session.pubkey)
    fetchProfiles(vault, rows.flatMap(x => x.who), relays).catch(() => {})
    const ids = rows.map(x => x.noteId).filter(id => id && !filled.current.has(id))
    for (const id of ids) filled.current.add(id)
    const about = await fetchNotes(vault, ids, relays)
    if (!about.size) return
    setNotes(n => new Map([...n, ...about]))
    // Authors, and the people the user's notes name (drawn as @names in the quoted line).
    const named = [...about.values()].flatMap(n => [n.pubkey, ...aboutPreview(n).parts.filter(p => p.pubkey).map(p => p.pubkey)])
    fetchProfiles(vault, named, relays).catch(() => {})
  }

  // `quiet`: a return visit refreshing rows already on screen says nothing; a Refresh says so above them.
  const load = async ({ quiet = false } = {}) => {
    const g = ++gen.current
    if (!navigator.onLine) { setStatus("Offline: notifications need the network"); setEvents(e => e ?? []); return }
    // The first load says so in the list itself; a Refresh over rows says so above them. Never both.
    setStatus(events && !quiet ? "Loading…" : "")
    const first = !events
    if (!quiet) filled.current = new Set(notes.keys()) // a Refresh asks again for notes that didn't come
    try {
      const seen = new Set()
      const show = page => {
        if (g !== gen.current) return
        setEvents(e => mergeEvents(e, page))
        const fresh = page.filter(ev => !seen.has(ev.id))
        for (const ev of fresh) seen.add(ev.id)
        if (fresh.length) fillIn(fresh).catch(() => {})
      }
      const page = await fetchNotificationEvents(session.pubkey, relays, { limit: PAGE, trust: receiptTrust(ctx), onEvents: show })
      if (g !== gen.current) return
      show(page.events)
      // A refresh keeps the older pages already loaded, so where they end still holds.
      if (first) setMore({ until: page.until, done: page.done, busy: false })
      setStatus("")
    } catch (e) { setStatus(`Couldn't load (${e?.message ?? e})`); setEvents(e => e ?? []) }
    finally { if (g === gen.current) setLoading(false) }
  }
  useEffect(() => { load({ quiet: true }) }, [session.pubkey])

  // Older pages, when the end of the list comes on screen (VaultActivityList.loadMoreActivity).
  const loadMore = async () => {
    if (!events || more.done || more.busy || !navigator.onLine) return
    const g = gen.current
    setMore(m => ({ ...m, busy: true }))
    try {
      const page = await fetchNotificationEvents(session.pubkey, relays, { limit: PAGE, until: more.until, trust: receiptTrust(ctx) })
      if (g !== gen.current) return
      const known = new Set(events.map(ev => ev.id))
      const fresh = page.events.filter(ev => ev?.id && !known.has(ev.id))
      setEvents(e => mergeEvents(e, fresh))
      setMore({ until: page.until, done: page.done, busy: false })
      fillIn(fresh).catch(() => {})
    } catch { if (g === gen.current) setMore(m => ({ ...m, busy: false, done: true })) }
  }
  const end = useRef(null)
  useEffect(() => {
    const el = end.current
    if (!el || typeof IntersectionObserver === "undefined") return
    // Made again after each page: it reports straight away, so a page that leaves the end on screen asks for the next.
    const io = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) loadMore() }, { rootMargin: "400px" })
    io.observe(el)
    return () => io.disconnect()
  }, [events, more.until, more.done, more.busy, filter])

  const rows = useMemo(() => events && insideRows(groupNotifications(events, session.pubkey), session.pubkey, { trusted, follows: account.follows }),
    [events, trusted, session.pubkey, account.follows])
  // A like, repost or zap on someone else's note that only tags the user isn't about the user's note: the iPhone keeps
  // no row for it, so it goes once that note has loaded and shows another author.
  const notMine = r => aboutYourPost(r) && notes.get(r.noteId) && notes.get(r.noteId).pubkey !== session.pubkey
  const shown = rows && filterRows(visibleRows(rows, blocked, session.pubkey), filter).filter(r => !notMine(r))
  // Anyone can reply, react or zap: only a follow's (or your own) picture host and inline images are fetched.
  const known = pk => pk === session.pubkey || account.follows.includes(pk)

  return (
    <main class="screen">
      <header class="screen-head"><h2>Notifications</h2><button class="small" onClick={() => load()}>Refresh</button></header>
      <div class="segmented" role="tablist" aria-label="Show">
        <button role="tab" aria-selected={filter === "all"} class={filter === "all" ? "on" : ""} onClick={() => setFilter("all")}>All</button>
        <button role="tab" aria-selected={filter === "mentions"} class={filter === "mentions" ? "on" : ""} onClick={() => setFilter("mentions")}>Mentions</button>
      </div>
      {status && <div class="status-line">{status}</div>}
      {shown === null || (loading && !shown.length) ? <SkeletonList count={7} rowClass="note notification" avatar={32} label="Loading notifications…" />
        : !shown.length && (more.done || more.until === null) ? <Empty mentions={filter === "mentions"} />
        : shown.map(r => <Row key={r.id} row={r} note={r.noteId ? notes.get(r.noteId) : undefined} trusted={known} unread={r.created_at > unreadSince} me={session.pubkey} />)}
      {shown !== null && !more.done && more.until !== null && <p ref={end} class="waiting" role="status">{more.busy && <><Spinner />Loading older notifications…</>}</p>}
    </main>
  )
}

/** The empty list: a title and what lands here (VaultActivityList's empty state). */
function Empty({ mentions }) {
  return (
    <div class="empty">
      <div style="font: var(--t-headline); color: var(--text)">{mentions ? "No mentions yet" : "Nothing new yet"}</div>
      <div class="small">{mentions ? "Replies, mentions and quotes land here" : "Replies, likes, zaps and new followers land here"}</div>
    </div>
  )
}

/** Where a tap on a row goes (VaultActivityList.openActivity): the note it opens, else the Followers list for a day of
 *  several follows, else the first person's profile. */
export function rowHref(row) {
  const id = openId(row)
  if (id) return `#/thread/${id}`
  if (row.type === "follow" && row.who.length > 1) return "#/vault/followers"
  return row.who[0] ? `#/profile/${row.who[0]}` : null
}

/** The note a row opens (VaultActivity.openId): their reply, mention, quote, article or highlight itself; the user's
 *  note for a like, repost or zap; nothing for a follow or a zap on the profile. */
export function openId(row) {
  if (row.type === "follow") return null
  if (["reply", "mention", "quote", "article", "highlight"].includes(row.type)) return row.events[0]?.id ?? null
  return row.noteId ?? null
}

/** Likes, reposts and plain zaps quote the user's note; everything else quotes them (VaultActivityRow.aboutYourPost). */
const aboutYourPost = row => row.type === "reaction" || row.type === "repost" || (row.type === "zap" && !row.comment && !!row.noteId)

// Tapping a row opens what it's about; a tap on a link, a button or a playing video stays with it. A ⌘/Ctrl-click or
// a middle-click opens it in a new browser tab, as a link would (NoteCard's openThread).
const follow = href => e => {
  if (e.target.closest("a, button, video, audio, .media-box")) return
  if (e.type === "auxclick" && e.button !== 1) return
  if (e.metaKey || e.ctrlKey || e.button === 1) { open(href, "_blank", "noopener"); return }
  location.hash = href
}

/** One row, as VaultActivityRow: the kind's badge, the faces (up to six), when, and an unread dot; then who did what,
 *  and their words or the user's note they reacted to. Several people on one note share a row.
 *  `trusted(pubkey)`: whose avatar and inline images may load; a stranger's would tell their server your IP. */
export function Row({ row, note, trusted = () => false, unread = false, me = "" }) {
  const ev = row.events[0]
  const href = rowHref(row)
  return (
    <article class={`note notification notif-${row.type}${unread ? " unread" : ""}${href ? " tappable" : ""}`} role={href ? "link" : undefined} tabIndex={href ? 0 : undefined}
      onClick={href && follow(href)} onAuxClick={href && follow(href)} onKeyDown={href && (e => { if (e.key === "Enter" && e.target === e.currentTarget) location.hash = href })}>
      <span class="notif-badge" aria-hidden="true">{BADGES[row.type]}</span>
      <div class="notif-body">
        <div class="notif-top">
          <Faces who={row.who} trusted={trusted} />
          <time class="note-time" datetime={new Date(row.created_at * 1000).toISOString()}>{ago(row.created_at)}</time>
          {unread && <span class="notif-dot" role="img" aria-label="New" title="New" />}
        </div>
        <div class="notif-who"><Who who={row.who} /> {verb(row)}</div>
        {row.type === "reply" || row.type === "mention" || row.type === "quote" || row.type === "highlight"
          ? <NoteText content={ev.content} images={trusted(row.who[0])} />
          : (row.type === "zap" || row.type === "article") && row.comment
            ? <NoteText content={row.comment} images={false} />
            : aboutYourPost(row) ? <About note={note} me={me} /> : null}
      </div>
    </article>
  )
}

// The kind's badge (VaultActivityRow.style): SF Symbols there, the same shapes here.
const svg = (...d) => <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">{d.map(x => typeof x === "string" ? <path d={x} /> : x)}</svg>
const solid = d => <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d={d} /></svg>
const BADGES = {
  reply: svg("M9 14 4 9l5-5", "M4 9h10.5a5.5 5.5 0 0 1 0 11H11"),
  mention: svg(<circle cx="12" cy="12" r="4" />, "M16 8v5a3 3 0 0 0 6 0v-1a10 10 0 1 0-4 8"),
  quote: solid("M5 3h14a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3H9l-5 4v-4H5a3 3 0 0 1-3-3V6a3 3 0 0 1 3-3Zm3 5v4h2.2c0 1-.6 1.6-1.6 1.8v1.4c2.1-.2 3.4-1.6 3.4-3.6V8Zm6 0v4h2.2c0 1-.6 1.6-1.6 1.8v1.4c2.1-.2 3.4-1.6 3.4-3.6V8Z"),
  reaction: solid("M12 21s-7.5-4.6-9.6-9.3C.9 8.4 2.9 4.5 6.6 4.5c2.1 0 3.9 1.2 5.4 3.1 1.5-1.9 3.3-3.1 5.4-3.1 3.7 0 5.7 3.9 4.2 7.2C19.5 16.4 12 21 12 21Z"),
  repost: svg("m17 2 4 4-4 4", "M3 11v-1a4 4 0 0 1 4-4h14", "m7 22-4-4 4-4", "M21 13v1a4 4 0 0 1-4 4H3"),
  zap: solid("M13.5 2 4 13.5h6.5L9.5 22 20 9.5h-6.5L13.5 2Z"),
  article: svg("M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8Z", "M14 2v6h6", "M16 13H8", "M16 17H8", "M10 9H8"),
  highlight: svg("m9 11-6 6v3h9l3-3", "m22 12-4.6 4.6a2 2 0 0 1-2.8 0l-5.2-5.2a2 2 0 0 1 0-2.8L14 4"),
  follow: svg("M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2", <circle cx="9" cy="7" r="4" />, "M19 8v6", "M22 11h-6"),
}

/** What they did, in the iPhone's words (VaultActivityRow.verb). */
export function verb(row) {
  switch (row.type) {
    case "reply": return "replied to you"
    case "mention": return "mentioned you"
    case "quote": return "quoted your note"
    case "reaction": {
      const emojis = reactionEmojiSummary(row.emojis ?? [row.emoji], 3)
      return emojis === "❤️" ? "liked your note" : `reacted ${emojis} to your note`
    }
    case "repost": return "reposted your note"
    case "zap": {
      const sats = row.sats.toLocaleString()
      return openId(row) ? `zapped your note ${sats} sats` : `zapped you ${sats} sats`
    }
    case "article": return "tagged you in an article"
    case "highlight": return "highlighted you"
    case "follow": return "followed you"
    default: return ""
  }
}

/** The user's note they reacted to, quieter than their own words and behind a rule, two lines at most, with its
 *  pictures as thumbnails (VaultActivityThumbnails: three, the last counting the rest); nothing until it has loaded.
 *  Only the user's own notes are quoted, as on the iPhone, so their pictures load. */
export const MAX_THUMBS = 3
function About({ note, me }) {
  if (!note || (me && note.pubkey !== me)) return null
  const { parts, images } = aboutPreview(note)
  if (!parts.length && !images.length) return null
  const thumbs = images.slice(0, MAX_THUMBS), rest = images.length - thumbs.length
  return (
    <>
      {parts.length > 0 && <div class="notif-about">{parts.map((p, i) => typeof p === "string" ? p : <Mention key={i} pubkey={p.pubkey} />)}</div>}
      {thumbs.length > 0 && (
        <div class="notif-thumbs" role="img" aria-label={images.length === 1 ? "1 picture" : `${images.length} pictures`}>
          {thumbs.map((src, i) => (
            <span key={src} class="notif-thumb">
              <img src={src} alt="" loading="lazy" referrerpolicy="no-referrer" />
              {rest > 0 && i === thumbs.length - 1 && <span class="notif-thumb-more">+{rest}</span>}
            </span>
          ))}
        </div>
      )}
    </>
  )
}
