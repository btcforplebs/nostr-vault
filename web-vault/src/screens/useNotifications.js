// The Notifications list's data (NotificationsScreen.jsx, and the desktop Reader's Notifications through
// napplet/reader-notifications.js): read from the user's read relays; nothing here signs.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { useAutoLook } from "../components/auto-look.js"
import {
  aboutPreview, fetchNotificationEvents, fetchNotes, filterRows, groupNotifications, insideRows,
  trustedWeb, visitNotifications,
} from "../net/notifications.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, uniq } from "../net/pool.js"
import { receiptTrust } from "../net/zaps.js"
import { visibleRows } from "../net/blocks.js"
import { followLists } from "../net/wot.js"
import { useBlocks } from "../components/useBlocks.js"
import { splitOutsideLikes } from "../net/outside-fold.js"

const NOTIFY_RECHECK_MS = 60_000 // looked at again this often while the list is in front
const PAGE = 100

// What this session last had for each account: a second visit draws it at once and refreshes underneath, as the
// iPhone's list is already there when the Vault tab opens. Memory only; a reload asks the relays again.
const kept = new Map()
const mergeEvents = (have, page) => {
  if (!have?.length) return page
  const ids = new Set(have.map(ev => ev.id))
  const fresh = page.filter(ev => ev?.id && !ids.has(ev.id))
  return fresh.length ? [...have, ...fresh] : have
}

/** Likes, reposts and plain zaps quote the user's note; everything else quotes them (VaultActivityRow.aboutYourPost). */
export const aboutYourPost = row => row.type === "reaction" || row.type === "repost" || (row.type === "zap" && !row.comment && !!row.noteId)

/**
 * The Notifications list's data, as the screen draws it (and the desktop Reader's Notifications, napplet/reader-notifications.js):
 * every page's events grouped, the notes rows are about, who counts as inside your web, older pages as asked, and the
 * visit's unread mark (visitNotifications: mounted = visiting). `filter`: "all" | "mentions".
 * -> { shown, outside, notes, status, loading, more, loadMore, unreadSince, known } (shown null until the first load)
 */
export function useNotifications(ctx, filter = "all") {
  const { vault, account, session } = ctx
  const relays = uniq([...account.relays.read, ...DEFAULT_RELAYS])
  const last = kept.get(session.pubkey)
  const [events, setEvents] = useState(last?.events ?? null) // every page's events, grouped together so folds span pages
  const [notes, setNotes] = useState(last?.notes ?? new Map())
  const [status, setStatus] = useState("")
  const [loading, setLoading] = useState(!last) // the first load is still out: an empty list isn't "nothing" yet
  const [more, setMore] = useState(last ? { ...last.more, busy: false } : { until: null, done: false, busy: false })
  // Who counts as inside your network (TrustMap.web): null until the follows' lists are in, and then empty when
  // there is no graph (nobody is outside).
  const [trusted, setTrusted] = useState(last?.trusted ?? null)
  const { blocked } = useBlocks(ctx)
  // Rows newer than the last visit show a dot. Infinity until this visit is read, so nothing flashes as unread.
  const [unreadSince, setUnreadSince] = useState(Infinity)
  const gen = useRef(0) // a Refresh drops the pages an older load is still fetching
  const filled = useRef(new Set(last?.notes?.keys() ?? [])) // notes asked for already, so each is fetched once
  useEffect(() => {
    setUnreadSince(visitNotifications(session.pubkey, { arriving: true }))
    return () => visitNotifications(session.pubkey, { arriving: false })
  }, [session.pubkey])
  useEffect(() => { if (events) kept.set(session.pubkey, { events, notes, more, trusted }) }, [events, notes, more, trusted, session.pubkey])

  // Not awaited by the list: likes, zaps and follows show at once, and notes from outside the follows wait for it.
  const loadWeb = () => followLists(session.pubkey, account.follows).then(l => setTrusted(trustedWeb(account.follows, l))).catch(() => setTrusted(trustedWeb(account.follows, new Map())))
  useEffect(() => { loadWeb() }, [session.pubkey, account.follows.length])

  // The notes rows are about, and the faces, for the events not seen before.
  const fillIn = async page => {
    const rows = groupNotifications(page, session.pubkey)
    fetchProfiles(vault, rows.flatMap(x => x.who), relays).catch(() => {})
    const ids = rows.map(x => x.noteId).filter(id => id && !filled.current.has(id))
    for (const id of ids) filled.current.add(id)
    const about = await fetchNotes(vault, ids, relays)
    if (!about.size) return
    setNotes(n => new Map([...n, ...about]))
    // Authors, and the people the user's notes name (drawn as @names in the quoted line).
    const named = [...about.values()].flatMap(n => [n.pubkey, ...aboutPreview(n).parts.filter(p => p.pubkey).map(p => p.pubkey)])
    fetchProfiles(vault, named, relays).catch(() => {})
  }

  // No Refresh button (Logen 2026-11-04): the screen looks again on its own, quietly (components/auto-look.js).
  useAutoLook(() => load({ quiet: true }), { every: NOTIFY_RECHECK_MS }, [session.pubkey])
  // `quiet`: a return visit or a look of its own over rows already on screen says nothing.
  const load = async ({ quiet = false } = {}) => {
    const g = ++gen.current
    if (!navigator.onLine) { setStatus("Offline: notifications need the network"); setEvents(e => e ?? []); return }
    // The first load says so in the list itself; a Refresh over rows says so above them. Never both.
    setStatus(events && !quiet ? "Loading…" : "")
    const first = !events
    if (!quiet) filled.current = new Set(notes.keys()) // a Refresh asks again for notes that didn't come
    try {
      const seen = new Set()
      const show = page => {
        if (g !== gen.current) return
        setEvents(e => mergeEvents(e, page))
        const fresh = page.filter(ev => !seen.has(ev.id))
        for (const ev of fresh) seen.add(ev.id)
        if (fresh.length) fillIn(fresh).catch(() => {})
      }
      const page = await fetchNotificationEvents(session.pubkey, relays, { limit: PAGE, trust: receiptTrust(ctx), onEvents: show })
      if (g !== gen.current) return
      show(page.events)
      // A refresh keeps the older pages already loaded, so where they end still holds.
      if (first) setMore({ until: page.until, done: page.done, busy: false })
      setStatus("")
    } catch (e) { setStatus(`Couldn't load (${e?.message ?? e})`); setEvents(e => e ?? []) }
    finally { if (g === gen.current) setLoading(false) }
  }
  useEffect(() => { load({ quiet: true }) }, [session.pubkey])

  // Older pages, when the end of the list comes on screen (VaultActivityList.loadMoreActivity).
  const loadMore = async () => {
    if (!events || more.done || more.busy || !navigator.onLine) return
    const g = gen.current
    setMore(m => ({ ...m, busy: true }))
    try {
      const page = await fetchNotificationEvents(session.pubkey, relays, { limit: PAGE, until: more.until, trust: receiptTrust(ctx) })
      if (g !== gen.current) return
      const known = new Set(events.map(ev => ev.id))
      const fresh = page.events.filter(ev => ev?.id && !known.has(ev.id))
      setEvents(e => mergeEvents(e, fresh))
      setMore({ until: page.until, done: page.done, busy: false })
      fillIn(fresh).catch(() => {})
    } catch { if (g === gen.current) setMore(m => ({ ...m, busy: false, done: true })) }
  }
  // Likes and reposts from outside the web fold into one line (net/outside-fold.js); the rest are grouped as before.
  const split = useMemo(() => events && splitOutsideLikes(events, session.pubkey, { trusted, follows: account.follows }),
    [events, trusted, session.pubkey, account.follows])
  const rows = useMemo(() => split && insideRows(groupNotifications(split.inside, session.pubkey), session.pubkey, { trusted, follows: account.follows }),
    [split, trusted, session.pubkey, account.follows])
  // A like, repost or zap on someone else's note that only tags the user isn't about the user's note: the iPhone keeps
  // no row for it, so it goes once that note has loaded and shows another author.
  const notMine = r => aboutYourPost(r) && notes.get(r.noteId) && notes.get(r.noteId).pubkey !== session.pubkey
  const shown = rows && filterRows(visibleRows(rows, blocked, session.pubkey), filter).filter(r => !notMine(r))
  // Mentions never lists likes or reposts, so the fold only shows under All.
  const outside = split && filter === "all" ? visibleRows(groupNotifications(split.outside, session.pubkey), blocked, session.pubkey).filter(r => !notMine(r)) : []
  // Anyone can reply, react or zap: only a follow's (or your own) picture host and inline images are fetched.
  const known = pk => pk === session.pubkey || account.follows.includes(pk)
  return { shown, outside, notes, status, loading, more, loadMore, unreadSince, known }
}
