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
import { fetchProfiles } from "../net/profiles.js"
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

// Roots asked for this page load, id -> { ev (null when nobody had it), at }: coming back to the Feed draws them from
// here rather than asking the relays for the same roots again. One nobody had is asked again after ROOT_RETRY_MS.
const roots = new Map()
export const ROOT_RETRY_MS = 5 * 60_000
export const forgetRoots = () => roots.clear() // tests

/**
 * Fetch thread roots for the Feed: this page load's, then Haven /feed (often a follow's note) and outbox, then the
 * read relays; the roots are written nowhere. Their authors are often not followed, so their names are fetched too:
 * `save: false` keeps those in memory (Global, Popular).
 */
export const rootFetcher = (vault, relays, { save = true, names = fetchProfiles, now = Date.now } = {}) => async ids => {
  const t = now()
  const found = new Map(), ask = []
  for (const id of new Set(ids)) {
    const r = roots.get(id)
    if (r?.ev) found.set(id, r.ev)
    else if (!r || t - r.at >= ROOT_RETRY_MS) ask.push(id)
  }
  if (!ask.length) return found
  const local = new Map()
  try { for (const ev of await vault.feed.query({ ids: ask })) local.set(ev.id, ev) } catch {}
  const rest = ask.filter(id => !local.has(id))
  const got = new Map([...local, ...(rest.length ? await fetchNotes(vault, rest, relays) : [])])
  for (const id of ask) {
    const ev = got.get(id) ?? null
    roots.set(id, { ev, at: t })
    if (ev) found.set(id, ev)
  }
  const authors = [...got.values()].map(ev => ev.pubkey)
  if (authors.length) names(vault, authors, relays, { save }).catch(() => {})
  return found
}
