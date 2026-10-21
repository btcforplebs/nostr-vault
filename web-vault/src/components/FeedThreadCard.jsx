// A whole conversation in the feed, as on the iPhone (FeedThreadCard): the root, then its replies as indented lines
// under a rail. A click on a line opens it in place into the full note with its action bar; a click on the open note
// goes to the thread, as the iPhone's first and second taps do. One note is open across the whole feed (`openId`).
// Past COLLAPSED_REPLIES the fold shows only the newest replies, since a new reply is what lifted the thread; it opens
// in place. "Open thread" under a conversation goes straight to it. A root still being fetched says so above the
// replies; a root no relay has gets no line at all, so the replies read as posts.
import { useState } from "preact/hooks"
import { CondensedNote } from "./CondensedNote.jsx"
import { NoteCard } from "./NoteCard.jsx"
import { COLLAPSED_REPLIES, latestReplies, repliesOf } from "../net/feed-layout.js"
import { repostInner } from "../net/thread.js"

export function FeedThreadCard({ thread, lines = 3, openId, setOpenId, rootUnavailable = false, memoryOnly = false }) {
  const [unfolded, setUnfolded] = useState(false)
  const all = repliesOf(thread)
  const shown = unfolded ? all : latestReplies(thread, COLLAPSED_REPLIES)
  const hidden = all.length - shown.length
  const anchor = thread.root ?? all[0]?.note
  const line = (note, depth) => openId && openId === shownId(note)
    ? <OpenNote key={note.id} note={note} depth={depth} memoryOnly={memoryOnly} />
    : <CondensedNote key={note.id} event={note} depth={depth} lines={depth ? Math.max(1, lines - 1) : lines}
        onOpen={setOpenId && (n => setOpenId(n.id))} />
  return (
    <article class="note thread-card" data-thread-root={thread.rootId}>
      {thread.root ? line(thread.root, 0)
        : !rootUnavailable && <div class="thread-missing muted"><BubblesIcon />Loading the start of this thread…</div>}
      {hidden > 0 && <FoldButton icon="M7 4v8a4 4 0 0 0 4 4h8M15 12l4 4-4 4" onClick={() => setUnfolded(true)}>
        Show {hidden} earlier {hidden === 1 ? "reply" : "replies"}</FoldButton>}
      {shown.map(e => line(e.note, e.depth))}
      {unfolded && all.length > COLLAPSED_REPLIES && <FoldButton icon="M6 15l6-6 6 6" onClick={() => setUnfolded(false)}>Show fewer replies</FoldButton>}
      {all.length > 0 && anchor && <a class="thread-open-link" href={`#/thread/${anchor.id}`}>Open thread<Chevron /></a>}
    </article>
  )
}

/** The id a line opens under: a repost opens the note it carries if that note's signature checks, as its line shows;
 *  otherwise the repost itself, so a forged inner id can't aim Open thread at another note. */
export function shownId(note) {
  return (note.kind === 6 && repostInner(note)?.id) || note.id
}

/** A line opened in place: the full note and its actions, on the line's rail and indent so nothing shifts sideways.
 *  The card's own click goes to the thread: the second tap. */
function OpenNote({ note, depth, memoryOnly }) {
  return (
    <div class={`thread-open${depth ? " reply" : ""}`} style={depth ? `--indent: ${Math.min(depth, 4) * 14}px` : undefined}>
      {depth > 0 && <span class="condensed-rail" aria-hidden="true" />}
      <NoteCard event={note} memoryOnly={memoryOnly} />
    </div>
  )
}

function FoldButton({ icon, onClick, children }) {
  return (
    <button type="button" class="thread-fold" onClick={onClick}>
      <svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={icon} /></svg>
      {children}
    </button>
  )
}

const Chevron = () => (
  <svg viewBox="0 0 24 24" width="11" height="11" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 5l7 7-7 7" /></svg>
)
const BubblesIcon = () => (
  <svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linejoin="round" aria-hidden="true"><path d="M3 5h12v8H8l-4 3v-3H3zM18 9h3v8h-1v3l-4-3h-5v-2" /></svg>
)

