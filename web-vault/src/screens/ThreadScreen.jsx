// A note's thread: the root, then its replies indented under what they answer. Rendered only from Haven /feed;
// the network fills /feed in the background. Read-only: nothing here signs.
import { useEffect, useRef, useState } from "preact/hooks"
import { NoteCard } from "../components/NoteCard.jsx"
import { buildThread, flattenThread, readThread, repostedNote, rootIdOf, syncThread } from "../net/thread.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { fetchProfiles } from "../net/profiles.js"

const MAX_INDENT = 4 // deeper replies line up with depth 4, so a long chain still fits a phone

/** Where the thread for `id` opens, from Haven /feed alone (so offline too). A stored note opens under its root.
 *  A reposted note is not stored, only the kind 6 carrying it: it opens under its real root when /feed has that
 *  root, otherwise under itself. `extra` is that carried note, which /feed's reply query can't return.
 *  -> { rootId, extra: [event] } */
export async function threadStart(vault, id) {
  const [stored] = await vault.feed.query({ ids: [id] })
  if (stored) return { rootId: rootIdOf(stored), extra: [] }
  const carried = await repostedNote(vault, id)
  if (!carried) return { rootId: id, extra: [] }
  const rid = rootIdOf(carried)
  const rootStored = rid !== id && (await vault.feed.query({ ids: [rid] })).length > 0
  return { rootId: rootStored ? rid : id, extra: [carried] }
}

export function ThreadScreen({ ctx, id }) {
  const { vault, account } = ctx
  const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const [rootId, setRootId] = useState(null)
  const [thread, setThread] = useState(null)
  const [status, setStatus] = useState("")
  const extra = useRef([])

  const reload = async rid => setThread(buildThread(rid, [...await readThread(vault, rid), ...extra.current]))
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
      const start = await threadStart(vault, id)
      const rid = start.rootId
      extra.current = start.extra
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
