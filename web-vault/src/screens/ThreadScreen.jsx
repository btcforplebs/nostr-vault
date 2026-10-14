// A note's thread: the root, then its replies indented under what they answer. Rendered only from Haven /feed;
// the network fills /feed in the background. Read-only: nothing here signs.
import { useEffect, useRef, useState } from "preact/hooks"
import { NoteCard } from "../components/NoteCard.jsx"
import { buildThread, flattenThread, readThread, rootIdOf, syncThread } from "../net/thread.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { fetchProfiles } from "../net/profiles.js"

const MAX_INDENT = 4 // deeper replies line up with depth 4, so a long chain still fits a phone

export function ThreadScreen({ ctx, id }) {
  const { vault, account } = ctx
  const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const [rootId, setRootId] = useState(null)
  const [thread, setThread] = useState(null)
  const [status, setStatus] = useState("")

  const reload = async rid => setThread(buildThread(rid, await readThread(vault, rid)))
  const sync = async () => {
    if (!navigator.onLine) return setStatus("Offline: showing the saved thread")
    setStatus("Loading replies…")
    try {
      const { rootId: rid } = await syncThread(vault, id, relays)
      setRootId(rid)
      await reload(rid)
      setStatus("")
    } catch (e) { setStatus(`Couldn't load replies (${e?.message ?? e}): showing the saved thread`) }
  }

  useEffect(() => {
    let live = true
    ;(async () => {
      const [note] = await vault.feed.query({ ids: [id] })
      const rid = note ? rootIdOf(note) : id
      if (!live) return
      setRootId(rid)
      await reload(rid)
      if (live) await sync()
    })().catch(e => setStatus(String(e?.message ?? e)))
    return () => { live = false }
  }, [id])

  useEffect(() => {
    if (!thread) return
    const authors = [thread.root?.pubkey, ...flattenThread(thread.replies).map(r => r.event.pubkey)]
    fetchProfiles(ctx.vault, authors.filter(Boolean), relays).catch(() => {})
  }, [thread])

  const rows = thread ? flattenThread(thread.replies) : []
  return (
    <main class="screen">
      <header class="screen-head">
        <button class="small" onClick={() => history.back()}>Back</button>
        <h2>Thread</h2>
        {/* Mirrors Back so the title sits centred */}
        <button class="small" style={{ visibility: "hidden" }} aria-hidden="true" tabIndex={-1}>Back</button>
      </header>
      <div class="status-line">{status || (thread ? `${thread.count} ${thread.count === 1 ? "reply" : "replies"}` : "")}</div>
      {thread === null ? <p class="empty">Opening your relay…</p>
        : <>
            {thread.root ? <NoteCard event={thread.root} />
              : rootId && <p class="empty">The note this thread starts from wasn't found.</p>}
            {rows.map(({ event, depth }) => (
              <div key={event.id} style={{ paddingLeft: `${Math.min(depth - 1, MAX_INDENT) * 16}px` }}>
                <Focus on={event.id === id}><NoteCard event={event} /></Focus>
              </div>
            ))}
            {!rows.length && thread.root && <p class="empty">No replies yet.</p>}
          </>}
    </main>
  )
}

// The note that was tapped, when it is a reply further down: scrolled into view and marked for screen readers.
function Focus({ on, children }) {
  const el = useRef(null)
  useEffect(() => { if (on) el.current?.scrollIntoView?.({ block: "center" }) }, [on])
  return on ? <div aria-current="true" ref={el}>{children}</div> : children
}
