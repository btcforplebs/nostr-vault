// Vault › Bookmarks (iPhone BookmarksView; parity N1): your kind 10003 bookmarks, newest first: notes by id (this
// browser's vault first, then your relays) and articles by their address. Private bookmarks are listed apart, as
// they are; change those in the app that made them. A note's ••• menu has Remove Bookmark.
import { useEffect, useState } from "preact/hooks"
import { NoteCard } from "../components/NoteCard.jsx"
import { SkeletonList } from "../components/Loading.jsx"
import { loadBookmarks, bookmarksState, onBookmarks, entries } from "../net/bookmarks.js"
import { fetchNotes } from "../net/notifications.js"
import { pool, DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { VaultPagesMenu } from "./VaultPagesMenu.jsx"

/** The events for `list` (entries), in its order: ids through the vault and relays, addresses asked of the relays. */
async function fetchEntries(ctx, list, relays) {
  const ids = list.filter(e => e.startsWith("e:")).map(e => e.slice(2))
  const byId = ids.length ? await fetchNotes(ctx.vault, ids, relays).catch(() => new Map()) : new Map()
  const byAddr = new Map()
  await Promise.all(list.filter(e => e.startsWith("a:")).map(async e => {
    const [kind, pubkey, ...d] = e.slice(2).split(":")
    const evs = await pool.querySync(relays, { kinds: [Number(kind)], authors: [pubkey], "#d": [d.join(":")] }, { maxWait: 6000 }).catch(() => [])
    const ev = evs.sort((a, b) => b.created_at - a.created_at)[0]
    if (ev) byAddr.set(e, ev)
  }))
  return list.map(e => (e.startsWith("e:") ? byId.get(e.slice(2)) : byAddr.get(e)) ?? null)
}

export function BookmarksScreen({ ctx }) {
  const [, bump] = useState(0)
  const [notes, setNotes] = useState(null) // { public: [ev|null], private: [ev|null] }
  useEffect(() => { loadBookmarks(ctx).catch(() => {}); return onBookmarks(() => bump(n => n + 1)) }, [])
  const s = bookmarksState()
  const loaded = s.pubkey === ctx.session.pubkey && s.event !== undefined
  const pub = loaded ? entries(s.event?.tags ?? []) : []
  const priv = loaded ? [...s.privateSet] : []
  const key = `${pub.join()}|${priv.join()}`
  useEffect(() => {
    if (!loaded) return
    let live = true
    const relays = uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS])
    Promise.all([fetchEntries(ctx, pub, relays), fetchEntries(ctx, priv, relays)]).then(([a, b]) => { if (live) setNotes({ public: a, private: b }) })
    return () => { live = false }
  }, [loaded, key])
  return (
    <main class="screen bookmarks">
      <header class="screen-head"><VaultPagesMenu ctx={ctx} current="bookmarks" /><h2 class="sr-only">Bookmarks</h2></header>
      {!loaded ? <p class="status-line" role="status">Reading your bookmarks…</p>
        : !pub.length && !priv.length ? <p class="empty">No bookmarks yet. Use Bookmark in a note's ••• menu to keep it here.</p>
        : !notes ? <SkeletonList rowClass="note" avatar={36} label="Reading your bookmarks…" />
        : <>
          {notes.public.map((ev, i) => (ev ? <NoteCard key={ev.id} event={ev} memoryOnly /> : <p key={pub[i]} class="status-line muted small">A bookmarked note no relay had.</p>))}
          {priv.length > 0 && <section class="bookmarks-private">
            <div class="section-label">Private bookmarks</div>
            <p class="status-line muted small">Only you can see these. They are shown here as they are; change them in the app that made them.</p>
            {notes.private.map((ev, i) => (ev ? <NoteCard key={ev.id} event={ev} memoryOnly /> : <p key={priv[i]} class="status-line muted small">A bookmarked note no relay had.</p>))}
          </section>}
        </>}
      {loaded && s.privateNote && <p class="status-line muted small">Your private bookmarks weren't read ({s.privateNote}).</p>}
    </main>
  )
}
