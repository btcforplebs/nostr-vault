// Notifications: who replied, mentioned, quoted, reposted, reacted, zapped, followed, or tagged the user in an
// article or highlight, newest first, one row each.
// Read from the user's read relays; nothing here signs. The note each row is about comes from Haven's outbox
// (the user's own notes) or the network. Reuses .note / .note-head / .repost-line from app.css.
import { useEffect, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { NoteText } from "../components/NoteText.jsx"
import { ago } from "../components/time.js"
import { fetchNotifications, fetchNotes, filterRows, formatSats, visitNotifications } from "../net/notifications.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { receiptTrust } from "../net/zaps.js"
import { visibleRows } from "../net/blocks.js"
import { useBlocks } from "../components/useBlocks.js"

const PAGE = 100

export function NotificationsScreen({ ctx }) {
  const { vault, account, session } = ctx
  const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const [rows, setRows] = useState(null)
  const [notes, setNotes] = useState(new Map())
  const [status, setStatus] = useState("")
  const { blocked } = useBlocks(ctx)
  const [filter, setFilter] = useState("all") // "all" | "mentions" (VaultToolbar: All / Mentions)
  // Rows newer than the last visit show a dot. Infinity until this visit is read, so nothing flashes as unread.
  const [unreadSince, setUnreadSince] = useState(Infinity)
  useEffect(() => {
    setUnreadSince(visitNotifications(session.pubkey, { arriving: true }))
    return () => visitNotifications(session.pubkey, { arriving: false })
  }, [session.pubkey])

  const load = async () => {
    if (!navigator.onLine) { setStatus("Offline: notifications need the network"); setRows(rows ?? []); return }
    setStatus("Loading…")
    try {
      const r = await fetchNotifications(session.pubkey, relays, { limit: PAGE, trust: receiptTrust(ctx) })
      setRows(r)
      setStatus(r.length ? "" : "Nothing yet")
      fetchProfiles(ctx.vault, r.flatMap(x => x.who), relays).catch(() => {})
      const about = await fetchNotes(vault, r.map(x => x.noteId), relays)
      setNotes(about)
      fetchProfiles(ctx.vault, [...about.values()].map(n => n.pubkey), relays).catch(() => {})
    } catch (e) { setStatus(`Couldn't load (${e?.message ?? e})`); setRows(rows ?? []) }
  }
  useEffect(() => { load() }, [session.pubkey])
  const shown = rows && filterRows(visibleRows(rows, blocked, session.pubkey), filter)
  // Anyone can reply, react or zap: only a follow's (or your own) picture host and inline images are fetched.
  const trusted = pk => pk === session.pubkey || account.follows.includes(pk)

  return (
    <main class="screen">
      <header class="screen-head"><h2>Notifications</h2><button class="small" onClick={load}>Refresh</button></header>
      <div class="segmented" role="tablist" aria-label="Show">
        <button role="tab" aria-selected={filter === "all"} class={filter === "all" ? "on" : ""} onClick={() => setFilter("all")}>All</button>
        <button role="tab" aria-selected={filter === "mentions"} class={filter === "mentions" ? "on" : ""} onClick={() => setFilter("mentions")}>Mentions</button>
      </div>
      {status && <div class="status-line">{status}</div>}
      {rows === null ? <p class="empty">Loading…</p>
        : !shown.length ? <p class="empty">{filter === "mentions" ? "No mentions yet. Replies, mentions and quotes land here." : "No notifications yet."}</p>
        : shown.map(r => <Row key={r.id} row={r} note={r.noteId ? notes.get(r.noteId) : undefined} trusted={trusted} unread={r.created_at > unreadSince} />)}
    </main>
  )
}

/** One row: who did what (and the reply's text or the note it was about). Several people on one note share a row.
 *  `trusted(pubkey)`: whose avatar and inline images may load; a stranger's would tell their server your IP. */
export function Row({ row, note, trusted = () => false, unread = false }) {
  const lead = row.who[0]
  const ev = row.events[0]
  const ok = trusted(lead)
  return (
    <article class="note notification">
      <div class="note-head">
        <Avatar pubkey={lead} size={32} load={ok} />
        {/* Not .author-name on the outer span: that class is nowrap + ellipsis, and "A and B reacted" must wrap. */}
        <span style="flex: 1; min-width: 0; font: var(--t-headline)"><Who who={row.who} /> {what(row)}</span>
        <time class="note-time" datetime={new Date(row.created_at * 1000).toISOString()}>{ago(row.created_at)}</time>
        {unread && <span role="img" aria-label="New" title="New" style="flex: none; width: 8px; height: 8px; border-radius: 50%; background: var(--accent); align-self: center" />}
      </div>
      {row.type === "reply" || row.type === "mention" || row.type === "quote" || row.type === "highlight"
        ? <NoteText content={ev.content} images={ok} />
        : (row.type === "zap" || row.type === "article") && row.comment
          ? <NoteText content={row.comment} images={false} />
          : null}
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

function what(row) {
  switch (row.type) {
    case "reply": return "replied"
    case "mention": return "mentioned you"
    case "quote": return "quoted your note"
    case "follow": return "followed you"
    case "article": return "tagged you in an article"
    case "highlight": return "highlighted your note"
    case "repost": return "reposted"
    case "reaction": return `reacted ${row.emoji}`
    case "zap": return row.sats ? `⚡ zapped ${formatSats(row.sats)} sats` : "⚡ zapped"
    default: return ""
  }
}

/** The note the row is about: a one-line excerpt, or a placeholder while it loads / when it can't be found. */
function About({ note }) {
  if (!note) return <div class="repost-line muted" style="margin: 8px 0 0">your note</div>
  const text = note.content.replace(/\s+/g, " ").trim()
  return (
    <div class="repost-line" style="margin: 8px 0 0; align-items: baseline">
      <span style="flex: none"><AuthorName pubkey={note.pubkey} />:</span>
      <span>{text.length > 140 ? text.slice(0, 140) + "…" : text || "(media)"}</span>
    </div>
  )
}
