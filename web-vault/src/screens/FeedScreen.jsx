// Following feed. Rendered only from Haven /feed; the network fills /feed in the background.
import { useEffect, useState } from "preact/hooks"
import { NoteCard } from "../components/NoteCard.jsx"
import { readFeed, syncFeed, FEED_KINDS } from "../net/sync.js"
import { pool, DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { fetchProfiles } from "../net/profiles.js"
import { visibleNotes } from "../net/blocks.js"
import { useBlocks } from "../components/useBlocks.js"

const PAGE = 100

export function FeedScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
  const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const [notes, setNotes] = useState(null)
  const [status, setStatus] = useState("")
  const [syncing, setSyncing] = useState(false)
  const { blocked, privateNote } = useBlocks(ctx)

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

  useEffect(() => { reload().then(sync) }, [follows.length])
  useEffect(() => {
    if (!notes?.length) return
    const authors = notes.flatMap(n => { if (n.kind !== 6) return [n.pubkey]; try { return [n.pubkey, JSON.parse(n.content).pubkey] } catch { return [n.pubkey] } })
    fetchProfiles(vault, authors.filter(Boolean), relays).catch(() => {})
  }, [notes])

  // Blocked people's notes stay in Haven and are only left out here, so unblocking brings them back.
  const shown = notes && visibleNotes(notes, blocked)
  return (
    <main class="screen">
      <header class="screen-head"><h2>Following</h2><button class="small" onClick={sync}>Refresh</button></header>
      {status && <div class="status-line">{status}</div>}
      {privateNote && <div class="status-line">Your private blocks weren't read ({privateNote}), so those people may still show.</div>}
      {!follows.length ? <p class="empty">{account.loaded ? "You don't follow anyone yet." : "Loading your follows…"}</p>
        : notes === null ? <p class="empty">Opening your relay…</p>
        : !notes.length ? <p class="empty">{syncing ? "Fetching notes from the people you follow…" : "No notes saved yet."}</p>
        : <>
            {shown.map(n => <NoteCard key={n.id} event={n} />)}
            <button class="more" onClick={older}>Older notes</button>
          </>}
    </main>
  )
}
