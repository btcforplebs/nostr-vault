// Following feed. Rendered only from Haven /feed; the network fills /feed in the background.
import { useEffect, useState } from "preact/hooks"
import { NoteCard } from "../components/NoteCard.jsx"
import { readFeed, syncFeed, FEED_KINDS } from "../net/sync.js"
import { pool, DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { fetchProfiles } from "../net/profiles.js"

const PAGE = 100

export function FeedScreen({ ctx }) {
  const { vault, account } = ctx
  const follows = account.follows
  const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const [notes, setNotes] = useState(null)
  const [status, setStatus] = useState("")

  const reload = async () => setNotes(await readFeed(vault, follows, { limit: Math.max(PAGE, notes?.length ?? 0) }))
  const sync = async () => {
    if (!navigator.onLine) return setStatus("Offline: showing your saved feed")
    setStatus("Syncing…")
    try {
      const n = await syncFeed(vault, follows, relays, { onProgress: p => setStatus(`Syncing ${p.done}/${p.of} follows · ${p.stored} saved`) })
      await reload()
      setStatus(n ? `${n} notes saved to your relay` : "Up to date")
    } catch (e) { setStatus(`Sync failed (${e?.message ?? e}): showing your saved feed`) }
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

  return (
    <main class="screen">
      <header class="screen-head"><h2>Following</h2><button class="small" onClick={sync}>Refresh</button></header>
      {status && <div class="status-line">{status}</div>}
      {!follows.length ? <p class="empty">{account.loaded ? "You don't follow anyone yet." : "Loading your follows…"}</p>
        : notes === null ? <p class="empty">Opening your relay…</p>
        : !notes.length ? <p class="empty">No notes saved yet.</p>
        : <>
            {notes.map(n => <NoteCard key={n.id} event={n} />)}
            <button class="more" onClick={older}>Older notes</button>
          </>}
    </main>
  )
}
