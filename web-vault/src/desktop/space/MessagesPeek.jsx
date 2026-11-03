// Messages peek: a "Your space" panel (Logen, 2026-11-02). The user's chats beside whatever is open, unread first, each
// with its last line. Nothing is typed here: a click opens the chat in the left column (#/dm/<pubkey>, which the
// desktop turns into Messages with the chat open, routes.js deskRedirect). It reads the messages itself, as the Messages
// screen does and with its rules (MessagesScreen.jsx useMessages: Haven's copies, then the inbox relays, opened by the
// signer), so it fills without a visit to Messages first (Logen, 2026-11-02 polish). It publishes nothing.
import { useEffect, useState } from "preact/hooks"
import { Avatar } from "../../components/Avatar.jsx"
import { AuthorName } from "../../components/NoteCard.jsx"
import { ago } from "../../components/time.js"
import { useBlocks } from "../../components/useBlocks.js"
import { useDmTrust } from "../../components/useDmTrust.js"
import { badgeCount } from "../../components/useUnreadTotal.js"
import { lastPreview } from "../../net/dms.js"
import { onRead, unreadCounts } from "../../net/dm-read.js"
import { useMessages } from "../../screens/MessagesScreen.jsx"
import { fetchProfiles } from "../../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../../net/pool.js"
import { peekRows, peekOpen } from "./messages-peek.js"
import { Icon, ICON } from "../Sidebar.jsx"
import "../../styles/messages-peek.css"

export function MessagesPeek({ ctx, open: shown = true, tools = null }) {
  const me = ctx.session.pubkey
  const [, setTick] = useState(0)
  useEffect(() => onRead(() => setTick(t => t + 1)), [])
  const { blocked } = useBlocks(ctx)
  const trusted = useDmTrust(ctx)
  const state = useMessages(ctx)
  const open = peekOpen(state, me)
  const rows = open ? peekRows(state.messages, me, blocked, trusted, unreadCounts(state.messages, me, blocked)) : []
  const waiting = rows.filter(r => r.unread > 0).length
  const peers = rows.map(r => r.peer).join()
  useEffect(() => {
    if (!peers) return
    const relays = uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS])
    fetchProfiles(ctx.vault, peers.split(","), relays).catch(() => {})
  }, [peers])
  return (
    <section class={shown ? "sp-panel msg-peek" : "sp-panel msg-peek closed"} aria-label="Messages">
      <header class="sp-head">
        <span class="sp-icon"><Icon d={ICON.messages} size={15} /></span>
        <h3>Messages</h3>
        {waiting > 0 && <span class="mp-count" role="img" aria-label={`${waiting} unread ${waiting === 1 ? "chat" : "chats"}`}>{badgeCount(waiting)}</span>}
        {tools}
      </header>
      <ul class="sp-rows">
        {!open ? <li class="sp-empty">{state.note ? `Your messages can't be read here (${state.note}).` : "Reading your messages…"}</li>
          : !rows.length ? <li class="sp-empty">No messages yet.</li>
          : rows.map(r => <Row key={r.peer} row={r} me={me} load={ctx.account.follows.includes(r.peer)} />)}
      </ul>
      <a class="sp-foot" href="#/messages">Open Messages ›</a>
    </section>
  )
}

/** One chat, one fixed height: the face, the name, the last line, when, and the unread count. A click opens it on the
 *  left. A stranger's picture waits, as in the Messages list. */
function Row({ row, me, load }) {
  const { peer, last, unread } = row
  return (
    <li>
      <a class={unread ? "sp-row unread" : "sp-row"} href={`#/dm/${peer}`}>
        <Avatar pubkey={peer} size={32} load={load} />
        <span class="sp-row-main">
          <span class="sp-row-who"><AuthorName pubkey={peer} /></span>
          <span class="sp-row-text">{last.from === me ? "You: " : ""}{lastPreview(last.content)}</span>
        </span>
        <span class="sp-row-side">
          <time datetime={new Date(last.at * 1000).toISOString()}>{ago(last.at)}</time>
          {unread > 1 ? <span class="mp-unread" role="img" aria-label={`${unread} unread`}>{badgeCount(unread)}</span> : unread ? <span class="sp-dot" role="img" aria-label="New" /> : null}
        </span>
      </a>
    </li>
  )
}
