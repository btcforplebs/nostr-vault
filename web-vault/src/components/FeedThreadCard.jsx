// A whole conversation in the feed, as on the iPhone (FeedThreadCard): the root, then its replies as indented lines.
// Past COLLAPSED_REPLIES the fold shows only the newest ones, since a new reply is what lifted the thread; it opens in
// place. A thread whose root hasn't been fetched yet says so above the replies.
import { useState } from "preact/hooks"
import { CondensedNote } from "./CondensedNote.jsx"
import { COLLAPSED_REPLIES, latestReplies, repliesOf } from "../net/feed-layout.js"

export function FeedThreadCard({ thread, lines = 3 }) {
  const [open, setOpen] = useState(false)
  const all = repliesOf(thread)
  const shown = open ? all : latestReplies(thread, COLLAPSED_REPLIES)
  const hidden = all.length - shown.length
  return (
    <article class="note thread-card" data-thread-root={thread.rootId}>
      {thread.root
        ? <CondensedNote event={thread.root} depth={0} lines={lines} />
        : <div class="thread-missing muted">Loading the start of this thread…</div>}
      {hidden > 0 && <button type="button" class="thread-fold" onClick={() => setOpen(true)}>
        Show {hidden} earlier {hidden === 1 ? "reply" : "replies"}</button>}
      {shown.map(e => <CondensedNote key={e.note.id} event={e.note} depth={e.depth} lines={Math.max(1, lines - 1)} />)}
      {open && all.length > COLLAPSED_REPLIES && <button type="button" class="thread-fold" onClick={() => setOpen(false)}>Show fewer replies</button>}
    </article>
  )
}
