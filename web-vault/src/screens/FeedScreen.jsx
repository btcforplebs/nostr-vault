// The Feed, with the picker (net/feeds.js). Following is rendered only from Haven /feed; the network fills /feed in
// the background. Global and Hashtag come from the network into memory only: strangers' notes never go into /feed.
import { useEffect, useRef, useState } from "preact/hooks"
import { NoteCard } from "../components/NoteCard.jsx"
import { readFeed, syncFeed, FEED_KINDS } from "../net/sync.js"
import { pool, DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { fetchProfiles } from "../net/profiles.js"
import { visibleNotes } from "../net/blocks.js"
import { useBlocks } from "../components/useBlocks.js"
import { FEEDS, loadChoice, saveChoice, normalizeTag, fetchStrangerFeed, fetchStrangerProfiles, mergePage, heldNotes, holdNotes, noteAuthors, feedKey } from "../net/feeds.js"

if (import.meta.env) import("../styles/feeds.css")

const PAGE = 100

export function FeedScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
  const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const [notes, setNotes] = useState(null)
  const [status, setStatus] = useState("")
  const [syncing, setSyncing] = useState(false)
  const { blocked, privateNote } = useBlocks(ctx)
  const [choice, setChoice] = useState(loadChoice)
  const [strange, setStrange] = useState(() => heldNotes(loadChoice()))
  const following = choice.mode === "following"
  const pick = c => { saveChoice(c); setChoice(c); setStrange(heldNotes(c)); setStatus("") }

  const reload = async () => setNotes(await readFeed(vault, follows, { limit: Math.max(PAGE, notes?.length ?? 0) }))
  const sync = async () => {
    // No follow list yet (still loading, or nobody followed): there is nothing to sync, so nothing is "up to date".
    if (!follows.length) return setStatus("")
    if (!navigator.onLine) return setStatus("Offline: showing your saved feed")
    setStatus("Syncing…")
    setSyncing(true)
    // Show notes as each chunk of follows lands, not after the last one. Reloads queue so an older read can't
    // land after a newer one.
    let shown = Promise.resolve(), seen = 0
    try {
      const n = await syncFeed(vault, follows, relays, { onProgress: p => {
        setStatus(`Syncing ${p.done}/${p.of} follows · ${p.stored} saved`)
        if (p.stored > seen) { seen = p.stored; shown = shown.then(reload) }
      } })
      await shown
      await reload()
      setStatus(n ? `${n} notes saved to your relay` : "Up to date")
    } catch (e) { setStatus(`Sync failed (${e?.message ?? e}): showing your saved feed`) }
    finally { setSyncing(false) }
  }
  const older = async () => {
    const until = notes.at(-1)?.created_at - 1
    let more = await readFeed(vault, follows, { limit: PAGE, until })
    if (more.length < PAGE / 2 && navigator.onLine) {
      setStatus("Fetching older notes…")
      for (let i = 0; i < follows.length; i += 250) {
        const evs = await pool.querySync(relays, { kinds: FEED_KINDS, authors: follows.slice(i, i + 250), until, limit: 200 }, { maxWait: 8000 })
        for (const ev of evs) await vault.feed.event(ev)
      }
      more = await readFeed(vault, follows, { limit: PAGE, until })
      setStatus("")
    }
    setNotes([...notes, ...more])
  }

  // Global and Hashtag. Each load is for one feed: once the picker has moved on, a late answer is dropped.
  const seq = useRef(0)
  const loadStrange = async (c, until) => {
    const n = ++seq.current
    if (c.mode === "hashtag" && !c.tag) return setStatus("")
    if (!navigator.onLine) return setStatus(`Offline: ${c.mode === "global" ? "Global" : "Hashtag"} needs the network`)
    setStatus(until ? "Fetching older notes…" : "Loading…")
    try {
      const page = await fetchStrangerFeed(c, account.relays.read, { until })
      if (n !== seq.current) return
      const all = until ? mergePage(heldNotes(c) ?? [], page) : page
      holdNotes(c, all)
      setStrange(all)
      setStatus(page.length ? "" : until ? "No older notes found" : "")
    } catch (e) { if (n === seq.current) setStatus(`Couldn't load (${e?.message ?? e})`) }
  }

  useEffect(() => { if (following) reload().then(sync) }, [follows.length, following])
  useEffect(() => { if (!following && !heldNotes(choice)) loadStrange(choice) }, [feedKey(choice)])
  useEffect(() => {
    if (following && notes?.length) fetchProfiles(vault, noteAuthors(notes), relays).catch(() => {})
  }, [notes, following])
  useEffect(() => {
    if (!following && strange?.length) fetchStrangerProfiles(noteAuthors(strange), account.relays.read).catch(() => {})
  }, [strange, following])

  // Blocked people's notes stay where they are and are only left out here, so unblocking brings them back.
  const list = following ? notes : strange
  const shown = list && visibleNotes(list, blocked)
  const label = FEEDS.find(f => f.id === choice.mode).label
  return (
    <main class="screen">
      <header class="screen-head">
        <h2>{choice.mode === "hashtag" && choice.tag ? `#${choice.tag}` : label}</h2>
        <button class="small" onClick={() => (following ? sync() : loadStrange(choice))}>Refresh</button>
      </header>
      <FeedPicker choice={choice} onPick={pick} />
      {status && <div class="status-line">{status}</div>}
      {privateNote && <div class="status-line">Your private blocks weren't read ({privateNote}), so those people may still show.</div>}
      {following
        ? !follows.length ? <p class="empty">{account.loaded ? "You don't follow anyone yet." : "Loading your follows…"}</p>
          : notes === null ? <p class="empty">Opening your relay…</p>
          : !notes.length ? <p class="empty">{syncing ? "Fetching notes from the people you follow…" : "No notes saved yet."}</p>
          : <Notes shown={shown} onOlder={older} />
        : choice.mode === "hashtag" && !choice.tag ? <p class="empty">Type a hashtag to see notes tagged with it.</p>
          : strange === null ? <p class="empty">{navigator.onLine ? "Loading notes…" : "This feed needs the network."}</p>
          : !strange.length ? <p class="empty">No notes found.</p>
          : <Notes shown={shown} onOlder={() => loadStrange(choice, strange.at(-1)?.created_at - 1)} />}
    </main>
  )
}

/** The notes left after blocks, then Older. When every loaded note is from someone blocked, say so instead. */
function Notes({ shown, onOlder }) {
  if (!shown.length) return <p class="empty">Every note loaded here is from someone you blocked.</p>
  return <>
    {shown.map(n => <NoteCard key={n.id} event={n} />)}
    <button class="more" onClick={onOlder}>Older notes</button>
  </>
}

/** Following / Global / Hashtag, and the tag box when Hashtag is picked. */
function FeedPicker({ choice, onPick }) {
  const [draft, setDraft] = useState(choice.tag)
  const submit = e => { e.preventDefault(); const tag = normalizeTag(draft); setDraft(tag); onPick({ mode: "hashtag", tag }) }
  return (
    <div class="feed-picker">
      <div class="feed-modes" role="tablist" aria-label="Feed">
        {FEEDS.map(f => (
          <button key={f.id} type="button" role="tab" aria-selected={choice.mode === f.id} class={choice.mode === f.id ? "on" : ""}
            onClick={() => onPick({ mode: f.id, tag: choice.tag })}>{f.label}</button>
        ))}
      </div>
      {choice.mode === "hashtag" && (
        <form class="feed-tag" onSubmit={submit}>
          <input type="search" value={draft} onInput={e => setDraft(e.currentTarget.value)} placeholder="#bitcoin" aria-label="Hashtag"
            enterkeyhint="go" autocapitalize="off" autocorrect="off" spellcheck={false} />
          <button type="submit" class="small">Show</button>
        </form>
      )}
    </div>
  )
}
