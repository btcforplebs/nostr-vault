// A note's thread: the root, then its replies indented under what they answer. Rendered only from Haven /feed;
// the network fills /feed in the background. Read-only: nothing here signs.
import { useEffect, useRef, useState } from "preact/hooks"
import { NoteCard } from "../components/NoteCard.jsx"
import { buildThread, flattenThread, readThread, repostedNote, rootIdOf, syncThread } from "../net/thread.js"
import { DEFAULT_RELAYS, pool, uniq } from "../net/pool.js"
import { fetchProfiles } from "../net/profiles.js"
import { isBlockedNote, visibleReplies } from "../net/blocks.js"
import { useBlocks } from "../components/useBlocks.js"
import { ArticleReader } from "../readers/ArticlesScreen.jsx"
import { SkeletonRows } from "../components/FeedExtras.jsx"
import { compose } from "../net/actions.js"
import { quotedById } from "../net/quotes.js"
import { SNO_KIND } from "../readers/sno.js"

if (import.meta.env) import("../styles/thread.css")

const MAX_INDENT = 4 // deeper replies line up with depth 4, so a long chain still fits a phone
const LOADING = "Loading replies…"

/** Where the thread for `id` opens, from Haven /feed alone (so offline too). A stored note opens under its root.
 *  A reposted note is not stored, only the kind 6 carrying it: it opens under its real root when /feed has that
 *  root, otherwise under itself. `extra` is that carried note, which /feed's reply query can't return.
 *  -> { rootId, extra: [event] } */
export async function threadStart(vault, id) {
  const [stored] = await vault.feed.query({ ids: [id] })
  if (stored) return { rootId: selfRooted(stored) ? stored.id : rootIdOf(stored), extra: [] }
  // A 3D object opened from its quote card: Haven /feed doesn't keep kind 33331, the quote cache has it.
  const quoted = quotedById(id)
  if (quoted?.kind === SNO_KIND) return { rootId: id, extra: [quoted] }
  const carried = await repostedNote(vault, id)
  if (!carried) return { rootId: id, extra: [] }
  const rid = rootIdOf(carried)
  const rootStored = rid !== id && (await vault.feed.query({ ids: [rid] })).length > 0
  return { rootId: rootStored ? rid : id, extra: [carried] }
}

/** Posts other than notes and reposts (an article, a poll, a highlight) start their own thread. */
const selfRooted = ev => !!ev && ev.kind !== 1 && ev.kind !== 6

/** `onAuthors(pubkeys)`: who wrote the thread (the root first), each time it changes. The guest view uses it for
 *  whose mesh vaults its photos may load from. */
export function ThreadScreen({ ctx, id, onAuthors }) {
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
    setStatus(LOADING)
    try {
      const synced = await syncThread(vault, id, relays)
      if (!isLive()) return
      // An article, poll or highlight is its own thread's root, whatever notes it tags.
      const [self] = await vault.feed.query({ ids: [id] })
      // A 3D object isn't kept in /feed: the one the relays returned is carried in memory, as a repost's note is.
      if (!self && synced.note?.id === id && synced.note.kind === SNO_KIND && !extra.current.some(e => e.id === id)) extra.current = [...extra.current, synced.note]
      const rid = selfRooted(self ?? (synced.note?.id === id ? synced.note : null)) ? id : synced.rootId
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
    onAuthors?.(authors.filter(Boolean))
  }, [thread])

  // Blocked people's replies are left out when drawn, not when stored, so unblocking brings them back.
  const rows = thread ? flattenThread(visibleReplies(thread.replies, blocked)) : []
  const rootBlocked = thread?.root && isBlockedNote(thread.root, blocked)
  // While the relays are asked, a missing root or an empty reply list may still arrive: placeholders, not "none".
  const syncing = status === LOADING
  // An article opens as the article, with its likes, comments, zaps and highlights, as the iPhone's does.
  if (thread?.root?.kind === 30023 && !rootBlocked) return <main class="screen"><ArticleReader event={thread.root} ctx={ctx} onBack={() => history.back()} /></main>
  // The note that was opened: the root, or the reply tapped further down (the iPhone's focused note).
  const focused = thread && (rows.find(r => r.event.id === id)?.event ?? (thread.root && !rootBlocked ? thread.root : null))
  const readOnly = !!ctx.signer?.readOnly
  return (
    <main class="screen thread-screen">
      {/* The iPhone's thread sheet: Done on the left, an action capsule on the right (NoteDetailView toolbar). */}
      <header class="thread-bar">
        <button type="button" class="thread-done" onClick={() => history.back()}>Done</button>
        <div class="thread-capsule">
          <button type="button" class="thread-capsule-btn" aria-label="Reply" title={readOnly ? "Read-only: sign in with a key to reply" : "Reply"}
            disabled={!focused || readOnly} onClick={() => focused && compose("reply", focused)}>
            <svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor" aria-hidden="true"><path d="M10 9V5l-7 7 7 7v-4.1c5 0 8.5 1.6 11 5.1-1-5-4-10-11-11z" /></svg>
          </button>
        </div>
      </header>
      {status && <div class="status-line">{status}</div>}
      {thread === null ? <SkeletonRows count={3} label="Opening the thread…" />
        : <>
            {rootBlocked ? <p class="empty">This note is from someone you blocked.</p>
              : thread.root ? <Focus on={thread.root.id === focused?.id} scroll={false} summary={<ReactionSummary ctx={ctx} note={thread.root} relays={relays} />}><NoteCard event={thread.root} /></Focus>
              : syncing ? <SkeletonRows count={1} label="Finding the note this thread starts from…" />
              : rootId && <p class="empty">The note this thread starts from wasn't found.</p>}
            {(rows.length > 0 || thread.root) && <h3 class="thread-replies-label">Replies</h3>}
            {rows.map(({ event, depth }) => (
              <div key={event.id} style={{ paddingLeft: `${Math.min(depth - 1, MAX_INDENT) * 16}px` }}>
                <Focus on={event.id === focused?.id} summary={<ReactionSummary ctx={ctx} note={event} relays={relays} />}><NoteCard event={event} /></Focus>
              </div>
            ))}
            {!rows.length && thread.root && (syncing ? <SkeletonRows count={2} label={LOADING} /> : <p class="empty">No replies yet.</p>)}
          </>}
    </main>
  )
}

// The focused note (the iPhone's orange border and glow, styled as `.note-card.focused` with the note rows), with its
// reaction summary under it. When it is a reply further down it is scrolled into view; marked for screen readers.
function Focus({ on, children, summary, scroll = true }) {
  const el = useRef(null)
  useEffect(() => { if (on && scroll) el.current?.scrollIntoView?.({ block: "center" }) }, [on])
  if (!on) return children
  return <div class="note-card focused" aria-current="true" ref={el}>{children}{summary}</div>
}

/** The focused note's reactions as chips, as under the iPhone's focused note: each emoji with how many people sent it,
 *  then reposts. One per person per emoji; "-" is a dislike (NIP-25) and not shown. Pure, for the tests.
 *  -> { reactions: [{ emoji, count }] most first, reposts } */
export function reactionSummary(events, noteId) {
  const byEmoji = new Map(), reposters = new Set(), seen = new Set()
  for (const ev of events) {
    if (!ev?.id || seen.has(ev.id) || !Array.isArray(ev.tags)) continue
    seen.add(ev.id)
    if (!ev.tags.some(t => t[0] === "e" && t[1] === noteId)) continue // a relay may answer a tag filter loosely
    if (ev.kind === 6) { reposters.add(ev.pubkey); continue }
    if (ev.kind !== 7) continue
    const c = typeof ev.content === "string" ? ev.content.trim() : ""
    if (c === "-") continue
    const emoji = c === "" || c === "+" ? "❤️" : c // "+" and empty are a like, as the iPhone shows them
    if (!byEmoji.has(emoji)) byEmoji.set(emoji, new Set())
    byEmoji.get(emoji).add(ev.pubkey)
  }
  const reactions = [...byEmoji].map(([emoji, who]) => ({ emoji, count: who.size }))
    .sort((a, b) => b.count - a.count || a.emoji.localeCompare(b.emoji))
  return { reactions, reposts: reposters.size }
}

/** Read-only: asks the read relays for the note's reactions and reposts once, and draws nothing until some arrive. */
function ReactionSummary({ ctx, note, relays }) {
  const [sum, setSum] = useState(null)
  const { blocked } = useBlocks(ctx)
  useEffect(() => {
    let live = true
    setSum(null)
    pool.querySync(relays, { kinds: [7, 6], "#e": [note.id], limit: 500 }, { maxWait: 6000 })
      .then(evs => { if (live) setSum(reactionSummary(evs.filter(ev => !blocked?.has?.(ev.pubkey)), note.id)) })
      .catch(() => {})
    return () => { live = false }
  }, [note.id])
  if (!sum || (!sum.reactions.length && !sum.reposts)) return null
  return (
    <div class="reaction-summary" aria-label="Reactions">
      {sum.reactions.length > 0 && <span class="reaction-chip">
        {sum.reactions.slice(0, 6).map(r => <span key={r.emoji} class="reaction-item"><span class="reaction-emoji">{r.emoji}</span> {r.count}</span>)}
      </span>}
      {sum.reposts > 0 && <span class="reaction-chip reaction-reposts">
        <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17 2l4 4-4 4" /><path d="M3 11V9a3 3 0 0 1 3-3h15" /><path d="M7 22l-4-4 4-4" /><path d="M21 13v2a3 3 0 0 1-3 3H3" /></svg>
        {sum.reposts}
      </span>}
    </div>
  )
}
