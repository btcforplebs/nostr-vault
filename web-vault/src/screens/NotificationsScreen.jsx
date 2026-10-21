// Notifications: who replied, mentioned, quoted, reposted, reacted, zapped, followed, or tagged the user in an
// article or highlight, newest first, one row each, as the iPhone's Vault list shows them (VaultActivityList).
// Read from the user's read relays; nothing here signs. The note each row is about comes from Haven's outbox
// (the user's own notes) or the network. Reuses .note / .note-head / .repost-line from app.css.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { NoteText } from "../components/NoteText.jsx"
import { ago } from "../components/time.js"
import {
  fetchNotificationEvents, fetchNotes, filterRows, groupNotifications, insideRows, nextPage, reactionEmojiSummary,
  trustedWeb, visitNotifications,
} from "../net/notifications.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { receiptTrust } from "../net/zaps.js"
import { visibleRows } from "../net/blocks.js"
import { followLists } from "../net/wot.js"
import { useBlocks } from "../components/useBlocks.js"

const PAGE = 100

export function NotificationsScreen({ ctx }) {
  const { vault, account, session } = ctx
  const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const [events, setEvents] = useState(null) // every page's events, grouped together so folds span pages
  const [notes, setNotes] = useState(new Map())
  const [status, setStatus] = useState("")
  const [more, setMore] = useState({ until: null, done: false, busy: false })
  // Who counts as inside your network (TrustMap.web); empty until the follows' lists are in, and then nobody is outside.
  const [trusted, setTrusted] = useState(new Set())
  const { blocked } = useBlocks(ctx)
  const [filter, setFilter] = useState("all") // "all" | "mentions" (VaultToolbar: All / Mentions)
  // Rows newer than the last visit show a dot. Infinity until this visit is read, so nothing flashes as unread.
  const [unreadSince, setUnreadSince] = useState(Infinity)
  const gen = useRef(0) // a Refresh drops the pages an older load is still fetching
  useEffect(() => {
    setUnreadSince(visitNotifications(session.pubkey, { arriving: true }))
    return () => visitNotifications(session.pubkey, { arriving: false })
  }, [session.pubkey])

  const loadWeb = () => followLists(session.pubkey, account.follows).then(l => setTrusted(trustedWeb(account.follows, l))).catch(() => {})
  useEffect(() => { loadWeb() }, [session.pubkey, account.follows.length])

  // The notes rows are about, and the faces, for the events not seen before.
  const fillIn = async (page, have) => {
    const rows = groupNotifications(page, session.pubkey)
    fetchProfiles(vault, rows.flatMap(x => x.who), relays).catch(() => {})
    const about = await fetchNotes(vault, rows.map(x => x.noteId).filter(id => id && !have.has(id)), relays)
    setNotes(n => new Map([...n, ...about]))
    fetchProfiles(vault, [...about.values()].map(n => n.pubkey), relays).catch(() => {})
  }

  const load = async () => {
    const g = ++gen.current
    if (!navigator.onLine) { setStatus("Offline: notifications need the network"); setEvents(events ?? []); return }
    // The first load says so in the list itself; a Refresh over rows says so above them. Never both.
    setStatus(events ? "Loading…" : "")
    try {
      const [page] = await Promise.all([fetchNotificationEvents(session.pubkey, relays, { limit: PAGE, trust: receiptTrust(ctx) }), loadWeb()])
      if (g !== gen.current) return
      setEvents(page)
      setMore({ ...nextPage(page, new Set()), busy: false })
      setStatus("")
      await fillIn(page, new Map())
    } catch (e) { setStatus(`Couldn't load (${e?.message ?? e})`); setEvents(events ?? []) }
  }
  useEffect(() => { load() }, [session.pubkey])

  // Older pages, when the end of the list comes on screen (VaultActivityList.loadMoreActivity).
  const loadMore = async () => {
    if (!events || more.done || more.busy || !navigator.onLine) return
    const g = gen.current
    setMore(m => ({ ...m, busy: true }))
    try {
      const page = await fetchNotificationEvents(session.pubkey, relays, { limit: PAGE, until: more.until, trust: receiptTrust(ctx) })
      if (g !== gen.current) return
      const known = new Set(events.map(ev => ev.id))
      const fresh = page.filter(ev => ev?.id && !known.has(ev.id))
      setEvents([...events, ...fresh])
      setMore({ ...nextPage(page, known), busy: false })
      await fillIn(fresh, notes)
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

  const rows = useMemo(() => events && insideRows(groupNotifications(events, session.pubkey), session.pubkey, { trusted }), [events, trusted, session.pubkey])
  // A like, repost or zap on someone else's note that only tags the user isn't about the user's note: the iPhone keeps
  // no row for it, so it goes once that note has loaded and shows another author.
  const notMine = r => aboutYourPost(r) && notes.get(r.noteId) && notes.get(r.noteId).pubkey !== session.pubkey
  const shown = rows && filterRows(visibleRows(rows, blocked, session.pubkey), filter).filter(r => !notMine(r))
  // Anyone can reply, react or zap: only a follow's (or your own) picture host and inline images are fetched.
  const known = pk => pk === session.pubkey || account.follows.includes(pk)

  return (
    <main class="screen">
      <header class="screen-head"><h2>Notifications</h2><button class="small" onClick={load}>Refresh</button></header>
      <div class="segmented" role="tablist" aria-label="Show">
        <button role="tab" aria-selected={filter === "all"} class={filter === "all" ? "on" : ""} onClick={() => setFilter("all")}>All</button>
        <button role="tab" aria-selected={filter === "mentions"} class={filter === "mentions" ? "on" : ""} onClick={() => setFilter("mentions")}>Mentions</button>
      </div>
      {status && <div class="status-line">{status}</div>}
      {shown === null ? <p class="empty">Loading…</p>
        : !shown.length && (more.done || more.until === null) ? <Empty mentions={filter === "mentions"} />
        : shown.map(r => <Row key={r.id} row={r} note={r.noteId ? notes.get(r.noteId) : undefined} trusted={known} unread={r.created_at > unreadSince} me={session.pubkey} />)}
      {shown !== null && !more.done && more.until !== null && <p ref={end} class="empty">{more.busy ? "Loading…" : ""}</p>}
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

/** One row: who did what (and their words, or the note of the user's they reacted to). Several people on one note
 *  share a row. `trusted(pubkey)`: whose avatar and inline images may load; a stranger's would tell their server your IP. */
export function Row({ row, note, trusted = () => false, unread = false, me = "" }) {
  const lead = row.who[0]
  const ev = row.events[0]
  const ok = trusted(lead)
  const href = rowHref(row)
  return (
    <article class={`note notification ${href ? "tappable" : ""}`} role={href ? "link" : undefined} tabIndex={href ? 0 : undefined}
      onClick={href && follow(href)} onAuxClick={href && follow(href)} onKeyDown={href && (e => { if (e.key === "Enter" && e.target === e.currentTarget) location.hash = href })}>
      <div class="note-head">
        <Avatar pubkey={lead} size={32} load={ok} />
        <span class="notif-who"><Who who={row.who} /> {verb(row)}</span>
        <time class="note-time" datetime={new Date(row.created_at * 1000).toISOString()}>{ago(row.created_at)}</time>
        {unread && <span role="img" aria-label="New" title="New" style="flex: none; width: 8px; height: 8px; border-radius: 50%; background: var(--accent); align-self: center" />}
      </div>
      {row.type === "reply" || row.type === "mention" || row.type === "quote" || row.type === "highlight"
        ? <NoteText content={ev.content} images={ok} />
        : (row.type === "zap" || row.type === "article") && row.comment
          ? <NoteText content={row.comment} images={false} />
          : aboutYourPost(row) ? <About note={note} me={me} /> : null}
    </article>
  )
}

/** "Ann", "Ann and Bob", "Ann and 3 others" (VaultActivityRow.who). */
export function Who({ who }) {
  const [a, b] = who
  if (!a) return "Someone"
  if (!b) return <AuthorName pubkey={a} />
  if (who.length === 2) return <><AuthorName pubkey={a} /> and <AuthorName pubkey={b} /></>
  return <><AuthorName pubkey={a} /> and {who.length - 1} others</>
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

/** The user's note they reacted to, quieter than their own words, and nothing until it has loaded. Only the user's own
 *  notes are quoted, as on the iPhone. */
function About({ note, me }) {
  if (!note || (me && note.pubkey !== me)) return null
  const text = note.content.replace(/\s+/g, " ").trim()
  if (!text) return null
  return <div class="repost-line vault-about"><span>{text.length > 140 ? text.slice(0, 140) + "…" : text}</span></div>
}
