// Notifications: who replied, mentioned, reposted, reacted or zapped the user, newest first, one row each.
// Read from the user's read relays; nothing here signs. The note each row is about comes from Haven's outbox
// (the user's own notes) or the network. Reuses .note / .note-head / .repost-line from app.css.
import { useEffect, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { NoteText } from "../components/NoteText.jsx"
import { ago } from "../components/time.js"
import { fetchNotifications, fetchNotes, formatSats } from "../net/notifications.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"

const PAGE = 100

export function NotificationsScreen({ ctx }) {
  const { vault, account, session } = ctx
  const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const [rows, setRows] = useState(null)
  const [notes, setNotes] = useState(new Map())
  const [status, setStatus] = useState("")

  const load = async () => {
    if (!navigator.onLine) { setStatus("Offline: notifications need the network"); setRows(rows ?? []); return }
    setStatus("Loading…")
    try {
      const r = await fetchNotifications(session.pubkey, relays, { limit: PAGE })
      setRows(r)
      setStatus(r.length ? "" : "Nothing yet")
      fetchProfiles(r.flatMap(x => x.who), relays).catch(() => {})
      const about = await fetchNotes(vault, r.map(x => x.noteId), relays)
      setNotes(about)
      fetchProfiles([...about.values()].map(n => n.pubkey), relays).catch(() => {})
    } catch (e) { setStatus(`Couldn't load (${e?.message ?? e})`); setRows(rows ?? []) }
  }
  useEffect(() => { load() }, [session.pubkey])

  return (
    <main class="screen">
      <header class="screen-head"><h2>Notifications</h2><button class="small" onClick={load}>Refresh</button></header>
      {status && <div class="status-line">{status}</div>}
      {rows === null ? <p class="empty">Loading…</p>
        : !rows.length ? <p class="empty">No notifications yet.</p>
        : rows.map(r => <Row key={r.id} row={r} note={r.noteId ? notes.get(r.noteId) : undefined} />)}
    </main>
  )
}

/** One row: who did what (and the reply's text or the note it was about). Several people on one note share a row. */
function Row({ row, note }) {
  const lead = row.who[0]
  const ev = row.events[0]
  return (
    <article class="note notification">
      <div class="note-head">
        <Avatar pubkey={lead} size={32} />
        {/* Not .author-name on the outer span: that class is nowrap + ellipsis, and "A and B reacted" must wrap. */}
        <span style="flex: 1; min-width: 0; font: var(--t-headline)"><Who who={row.who} /> {what(row)}</span>
        <time class="note-time" datetime={new Date(row.created_at * 1000).toISOString()}>{ago(row.created_at)}</time>
      </div>
      {row.type === "reply" || row.type === "mention"
        ? <NoteText content={ev.content} />
        : row.type === "zap" && ev.content
          ? <NoteText content={ev.content} />
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
