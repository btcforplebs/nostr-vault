// The Feed's notes in the layout picked for it (net/feed-layout.js): full cards, condensed lines, or thread cards.
// In both condensed layouts a click opens a line in place into the full note, one at a time across the feed, and a
// click on the open note goes to its thread (the iPhone's expandedNoteId). For threads, a root the feed doesn't carry
// is fetched (Haven, then the read relays) into memory only; the card says "Loading the start of this thread…" until
// it lands, and drops the line if no relay has it.
import { useEffect, useMemo, useState } from "preact/hooks"
import { NoteCard } from "./NoteCard.jsx"
import { CondensedNote } from "./CondensedNote.jsx"
import { FeedThreadCard } from "./FeedThreadCard.jsx"
import { hasKindBody } from "./FeedKinds.jsx"
import { buildThreads } from "../net/feed-layout.js"
import { tileNote } from "../net/media.js"
import { fetchNotes } from "../net/notifications.js"
import { replyRefs } from "../net/thread.js"

export function FeedRows({ notes, layout, keepFeedOrder = false, memoryOnly = false, fetchRoots }) {
  const [openId, setOpenId] = useState(null)
  if (layout === "condensed") return <div class="condensed-list">{notes.map(n => {
    const shown = tileNote(n) ?? n
    return openId && shown.id === openId
      ? <NoteCard key={n.id} event={n} memoryOnly={memoryOnly} />
      : <CondensedNote key={n.id} event={n} card onOpen={x => setOpenId(x.id)} />
  })}</div>
  if (layout === "threaded") return <Threads notes={notes} keepFeedOrder={keepFeedOrder} fetchRoots={fetchRoots} memoryOnly={memoryOnly} openId={openId} setOpenId={setOpenId} />
  // A reply shows the note it answers above it, unless that note is the very next row (the iPhone's parentIsNext).
  return notes.map((n, i) => <NoteCard key={n.id} event={n} memoryOnly={memoryOnly} showParent={n.kind === 1 && !!replyRefs(n).parent && notes[i + 1]?.id !== replyRefs(n).parent} />)
}

function Threads({ notes, keepFeedOrder, fetchRoots, memoryOnly, openId, setOpenId }) {
  // id -> the root event, or null once a fetch came back without it.
  const [fetched, setFetched] = useState(() => new Map())
  const threads = useMemo(() => buildThreads(notes.filter(n => n.kind === 1 || n.kind === 6 || hasKindBody(n)), { keepFeedOrder, resolve: id => fetched.get(id) ?? null }), [notes, fetched, keepFeedOrder])
  const missing = threads.filter(t => !t.root && !fetched.has(t.rootId)).map(t => t.rootId)
  const key = missing.join()
  useEffect(() => {
    if (!missing.length || !fetchRoots) return
    let live = true
    fetchRoots(missing).then(found => {
      if (!live) return
      setFetched(prev => {
        const next = new Map(prev)
        for (const id of missing) { const ev = found?.get(id); next.set(id, ev?.kind === 1 ? ev : null) }
        return next
      })
    }).catch(() => {})
    return () => { live = false }
  }, [key])
  return threads.map(t => <FeedThreadCard key={t.rootId} thread={t} openId={openId} setOpenId={setOpenId} memoryOnly={memoryOnly}
    rootUnavailable={!t.root && fetched.has(t.rootId)} />)
}

/** Fetch thread roots for the Feed: Haven's outbox, then the read relays; nothing is written anywhere. */
export const rootFetcher = (vault, relays) => ids => fetchNotes(vault, ids, relays)
