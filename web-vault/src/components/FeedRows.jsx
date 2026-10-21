// The Feed's notes in the layout picked for it (net/feed-layout.js): full cards, condensed lines, or thread cards.
// For threads, a root the feed doesn't carry is fetched (Haven, then the read relays) into memory only, and the
// card says "Loading the start of this thread…" until it lands.
import { useEffect, useMemo, useState } from "preact/hooks"
import { NoteCard } from "./NoteCard.jsx"
import { CondensedNote } from "./CondensedNote.jsx"
import { FeedThreadCard } from "./FeedThreadCard.jsx"
import { buildThreads } from "../net/feed-layout.js"
import { fetchNotes } from "../net/notifications.js"

export function FeedRows({ notes, layout, keepFeedOrder = false, memoryOnly = false, fetchRoots }) {
  if (layout === "condensed") return <div class="condensed-list">{notes.map(n => <CondensedNote key={n.id} event={n} card />)}</div>
  if (layout === "threaded") return <Threads notes={notes} keepFeedOrder={keepFeedOrder} fetchRoots={fetchRoots} />
  return notes.map(n => <NoteCard key={n.id} event={n} memoryOnly={memoryOnly} />)
}

function Threads({ notes, keepFeedOrder, fetchRoots }) {
  const [fetched, setFetched] = useState(() => new Map())
  const threads = useMemo(() => buildThreads(notes.filter(n => n.kind === 1 || n.kind === 6), { keepFeedOrder, resolve: id => fetched.get(id) ?? null }), [notes, fetched, keepFeedOrder])
  const missing = threads.filter(t => !t.root && !fetched.has(t.rootId)).map(t => t.rootId)
  const key = missing.join()
  useEffect(() => {
    if (!missing.length || !fetchRoots) return
    let live = true
    fetchRoots(missing).then(found => {
      if (!live || !found?.size) return
      setFetched(prev => { const next = new Map(prev); for (const [id, ev] of found) if (ev?.kind === 1) next.set(id, ev); return next })
    }).catch(() => {})
    return () => { live = false }
  }, [key])
  return threads.map(t => <FeedThreadCard key={t.rootId} thread={t} />)
}

/** Fetch thread roots for the Feed: Haven's outbox, then the read relays; nothing is written anywhere. */
export const rootFetcher = (vault, relays) => ids => fetchNotes(vault, ids, relays)
