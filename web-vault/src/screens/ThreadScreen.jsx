// A note's thread: the root, then its replies indented under what they answer. Rendered only from Haven /feed;
// the network fills /feed in the background. Read-only: nothing here signs.
import { useEffect, useRef, useState } from "preact/hooks"
import { NoteCard } from "../components/NoteCard.jsx"
import { buildThread, flattenThread, readThread, repostedNote, rootIdOf, syncThread } from "../net/thread.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { fetchProfiles } from "../net/profiles.js"
import { isBlockedNote, visibleReplies } from "../net/blocks.js"
import { useBlocks } from "../components/useBlocks.js"
import { ArticleReader } from "../readers/ArticlesScreen.jsx"

const MAX_INDENT = 4 // deeper replies line up with depth 4, so a long chain still fits a phone

/** Where the thread for `id` opens, from Haven /feed alone (so offline too). A stored note opens under its root.
 *  A reposted note is not stored, only the kind 6 carrying it: it opens under its real root when /feed has that
 *  root, otherwise under itself. `extra` is that carried note, which /feed's reply query can't return.
 *  -> { rootId, extra: [event] } */
export async function threadStart(vault, id) {
  const [stored] = await vault.feed.query({ ids: [id] })
  if (stored) return { rootId: selfRooted(stored) ? stored.id : rootIdOf(stored), extra: [] }
  const carried = await repostedNote(vault, id)
  if (!carried) return { rootId: id, extra: [] }
  const rid = rootIdOf(carried)
  const rootStored = rid !== id && (await vault.feed.query({ ids: [rid] })).length > 0
  return { rootId: rootStored ? rid : id, extra: [carried] }
}

/** Posts other than notes and reposts (an article, a poll, a highlight) start their own thread. */
const selfRooted = ev => !!ev && ev.kind !== 1 && ev.kind !== 6

export function ThreadScreen({ ctx, id }) {
  const { vault, account } = ctx
  const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const [rootId, setRootId] = useState(null)
  const [thread, setThread] = useState(null)
  const [status, setStatus] = useState("")
  const extra = useRef([])
  const { blocked } = useBlocks(ctx)

  // Each run is for one id: once the screen has moved on, `isLive()` is false and the run touches nothing, so a late
  // read or sync for the previous thread can't take over this one's root, extra or status.
  const reload = async (rid, isLive) => {
    const evs = await readThread(vault, rid)
    const all = [...evs, ...extra.current]
    const t = buildThread(rid, all)
    // buildThread roots only notes; an article, poll or highlight is the root of its own thread.
    if (!t.root) t.root = all.find(e => e.id === rid && selfRooted(e)) ?? null
    if (isLive()) setThread(t)
  }
  const sync = async isLive => {
    if (!navigator.onLine) return setStatus("Offline: showing the saved thread")
    setStatus("Loading replies…")
    try {
      const synced = await syncThread(vault, id, relays)
      if (!isLive()) return
      // An article, poll or highlight is its own thread's root, whatever notes it tags.
      const [self] = await vault.feed.query({ ids: [id] })
      const rid = selfRooted(self) ? id : synced.rootId
      setRootId(rid)
      await reload(rid, isLive)
      if (isLive()) setStatus("")
    } catch (e) { if (isLive()) setStatus(`Couldn't load replies (${e?.message ?? e}): showing the saved thread`) }
  }

  useEffect(() => {
    let live = true
    const isLive = () => live
    ;(async () => {
      const start = await threadStart(vault, id)
      if (!live) return // a late run for the previous id: its carried note isn't this thread's
      const rid = start.rootId
      extra.current = start.extra
      setRootId(rid)
      await reload(rid, isLive)
      if (live) await sync(isLive)
    })().catch(e => { if (live) setStatus(String(e?.message ?? e)) })
    return () => { live = false }
  }, [id])

  useEffect(() => {
    if (!thread) return
    const authors = [thread.root?.pubkey, ...flattenThread(thread.replies).map(r => r.event.pubkey)]
    fetchProfiles(ctx.vault, authors.filter(Boolean), relays).catch(() => {})
  }, [thread])

  // Blocked people's replies are left out when drawn, not when stored, so unblocking brings them back.
  const rows = thread ? flattenThread(visibleReplies(thread.replies, blocked)) : []
  const rootBlocked = thread?.root && isBlockedNote(thread.root, blocked)
  // An article opens as the article, with its likes, comments, zaps and highlights, as the iPhone's does.
  if (thread?.root?.kind === 30023 && !rootBlocked) return <main class="screen"><ArticleReader event={thread.root} ctx={ctx} onBack={() => history.back()} /></main>
  return (
    <main class="screen">
      <header class="screen-head">
        <button class="small" onClick={() => history.back()}>Back</button>
        <h2>Thread</h2>
        {/* Mirrors Back so the title sits centred */}
        <button class="small" style={{ visibility: "hidden" }} aria-hidden="true" tabIndex={-1}>Back</button>
      </header>
      <div class="status-line">{status || (thread ? `${rows.length} ${rows.length === 1 ? "reply" : "replies"}` : "")}</div>
      {thread === null ? <p class="empty">Opening your relay…</p>
        : <>
            {rootBlocked ? <p class="empty">This note is from someone you blocked.</p>
              : thread.root ? <NoteCard event={thread.root} />
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
