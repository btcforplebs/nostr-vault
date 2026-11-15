// Notifications: who replied, mentioned, quoted, reposted, reacted, zapped, followed, or tagged the user in an
// article or highlight, newest first, one row each, as the iPhone's Vault list shows them (VaultActivityList).
// Read from the user's read relays; nothing here signs. The note each row is about comes from Haven's outbox
// (the user's own notes) or the network. Reuses .note / .note-head / .repost-line from app.css.
import { useEffect, useRef, useState } from "preact/hooks"
import { Faces, Who } from "../components/ActivityFaces.jsx"
import { Mention, NoteText } from "../components/NoteText.jsx"
import { ago } from "../components/time.js"
import { aboutPreview, reactionEmojiSummary } from "../net/notifications.js"
import { SkeletonList, Spinner } from "../components/Loading.jsx"
import { VaultPagesMenu } from "./VaultPagesMenu.jsx"
import { OutsideFold } from "../components/OutsideFold.jsx"
import { outsideCount } from "../net/outside-fold.js"
import { useNotifications, aboutYourPost } from "./useNotifications.js"
import "../styles/notifications.css"

export { Faces, Who, MAX_FACES } from "../components/ActivityFaces.jsx"

/** `vaultMenu`: on a phone it is one of the Vault's pages and wears the Vault menu top left (VaultPagesMenu.jsx), as Messages does. */
export function NotificationsScreen({ ctx, vaultMenu = false }) {
  const { session } = ctx
  const [filter, setFilter] = useState("all") // "all" | "mentions" (VaultToolbar: All / Mentions)
  const { shown, outside, notes, status, loading, more, loadMore, unreadSince, known } = useNotifications(ctx, filter)
  const end = useRef(null)
  useEffect(() => {
    const el = end.current
    if (!el || typeof IntersectionObserver === "undefined") return
    // Made again after each page: it reports straight away, so a page that leaves the end on screen asks for the next.
    const io = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) loadMore() }, { rootMargin: "400px" })
    io.observe(el)
    return () => io.disconnect()
  }, [shown, more.until, more.done, more.busy, filter])

  return (
    <main class="screen">
      <header class="screen-head">{vaultMenu ? <><VaultPagesMenu ctx={ctx} current="notifications" /><h2 class="sr-only">Notifications</h2></> : <h2>Notifications</h2>}</header>
      <div class="segmented" role="tablist" aria-label="Show">
        <button role="tab" aria-selected={filter === "all"} class={filter === "all" ? "on" : ""} onClick={() => setFilter("all")}>All</button>
        <button role="tab" aria-selected={filter === "mentions"} class={filter === "mentions" ? "on" : ""} onClick={() => setFilter("mentions")}>Mentions</button>
      </div>
      {status && <div class="status-line">{status}</div>}
      {shown !== null && <OutsideFold count={outsideCount(outside)} resetKey={session.pubkey}>
        {outside.map(r => <Row key={r.id} row={r} note={r.noteId ? notes.get(r.noteId) : undefined} trusted={known} unread={false} me={session.pubkey} />)}
      </OutsideFold>}
      {shown === null || (loading && !shown.length) ? <SkeletonList count={7} rowClass="note notification" avatar={32} label="Loading notifications…" />
        : !shown.length && !outside.length && (more.done || more.until === null) ? <Empty mentions={filter === "mentions"} />
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
