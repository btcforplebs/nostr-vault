// The Feed, Thread and someone's Profile as napplets (plan P4), when the napplet switch is on (flag.js): the Reader
// napplet fills the screen, and the Compose napplet opens in a sheet when the Reader asks (reader-intents.js). Both
// are ours (first-party grant, policy.js), answered by the same runtime as the Apps pane. Switch off: the old screens.
// `open`: { archetype, action, payload } to show first (a #/thread/<id> or #/profile/<pubkey> address), else the feed.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { openNapplet } from "./runtime.js"
import { grantStore } from "./policy.js"
import { createBus } from "./bus.js"
import { shellDeps } from "./shell-deps.js"
import { firstParty, READER_DTAG, COMPOSE_DTAG } from "./first-party.js"
import { COMPOSE_SENT, readerIntents } from "./reader-intents.js"
import { useLiveCtx } from "./usePaneNapplet.js"
import { verifyEvent } from "nostr-tools/pure"
import { repostWithUndo } from "../components/repost-undo.js"
import { ZapSheet, MenuSheet } from "./NoteSheets.jsx"
import { loadPreview } from "../components/link-preview.js"
import { outsideReplies } from "./outside-count.js"
import { globalTrust, TRUSTED_AUTHORS_CAP } from "../readers/trust.js"
import { CTX_EVENT, NAPPLET_KEY_EVENT, OPEN_TOPIC, PEEK_EVENT, READER_CMD_EVENT, ROW_CMDS, ROW_TOPIC, nappletKey, pageHover, pageMenu } from "./napplet-keys.js"
import { likedNote } from "./reader-intents.js"
import { MediaLightbox } from "../components/MediaLightbox.jsx"
import { ArticleReader } from "../readers/ArticlesScreen.jsx"
import { articleCard, highlightCard, pollCard } from "./kind-cards.js"
import { heldVotes, loadVotes, sendVote, votesFresh } from "../components/poll-votes.js"
import { isClosed, parsePoll } from "../components/polls.js"
import { getBlocks } from "../net/blocks.js"
import { READ_ONLY_SHORT } from "../signer/readonly.js"
import { NOTE_SENT_EVENT, actionState, compose as composeFull, loadSent, onActionState, reactionOf } from "../net/actions.js"
import { onZapTotals, wantTotals, zapTotal } from "../net/zaps.js"
import { displayEmoji, likeWithFeedback, pickFor } from "../components/ReactionButton.jsx"
import { STATS_TOPIC, statsOf } from "./note-stats.js"
import { mineIntents } from "./reader-mine.js"
import { bookmarkIntents } from "./reader-bookmarks.js"
import { notifIntents, notifAnswer, NOTIF_TOPIC } from "./reader-notifications.js"
import { ReaderNotifSource } from "./ReaderNotifSource.jsx"
import { rowHref, verb as notifVerb } from "../screens/NotificationsScreen.jsx"
import { aboutYourPost } from "../screens/useNotifications.js"
import { aboutPreview } from "../net/notifications.js"
import { whoText } from "../net/notify-watch.js"
import { loadBookmarks, onBookmarks, entries as bookmarkEntries } from "../net/bookmarks.js"
import { fetchEntries } from "../net/bookmark-notes.js"
import { npubEncode } from "nostr-tools/nip19"
import { getProfile, fetchProfiles } from "../net/profiles.js"
import { fetchFollowers, keptFollowers } from "../net/followers.js"
import { fetchShop } from "../net/profile-tabs.js"
import { priceLabel } from "../readers/market.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"
import { EditProfile } from "../screens/EditProfile.jsx"
import { ShareProfileSheet } from "../components/ShareProfile.jsx"
import { ListingView } from "../readers/MarketplaceScreen.jsx"
import "./napplet.css"

/** Tells the Reader your profile may have changed (saved, or the follower count came in): it asks profile/mine again. */
export const MINE_TOPIC = "nv.profile.changed"

const READY_WAIT_MS = 5000
const whenReady = async m => { await Promise.race([m.napplet.ready, new Promise(r => setTimeout(r, READY_WAIT_MS))]); return m.napplet }

// `beside(id)`: the desktop list's Reader opens a tapped note's thread beside the list (plan step 2); true when it did.
// `openId`: the note open beside it, marked in the list. `keys`: takes j/k/Enter/r/l/z (the list's Reader, not the one
// beside it). `fullCompose`: Post, Reply and Quote open the site's full composer (#/compose, the desktop's dialog) in
// place of the Compose napplet (plan step 2b); what it sends comes back to the Reader as inc nv.compose.sent.
export function ReaderPane({ ctx, open = null, hidden = false, beside = null, openId = "", keys = true, fullCompose = false, notifications = false }) {
  const host = useRef(null), composeHost = useRef(null)
  const [composing, setComposing] = useState(false)
  const [composeAside, setComposeAside] = useState(false) // a post counting down: the sheet steps aside, still mounted
  const [note, setNote] = useState("")
  const [sheet, setSheet] = useState(null) // { kind: "zap" | "menu", note }
  const grants = useMemo(() => grantStore(localStorage, ctx.session.pubkey), [ctx.session.pubkey])
  const liveCtx = useLiveCtx(ctx)
  // Notifications (plan step 6b): the latest list from ReaderNotifSource, while the desktop shows Notifications.
  const notifPipe = useMemo(() => ({ list: null, tell: () => {}, put(l) { this.list = l; this.tell() } }), [])
  const live = useRef(null) // { bus, me, reader }
  const openRef = useRef(open)
  openRef.current = open
  const besideRef = useRef(beside)
  besideRef.current = beside

  useEffect(() => {
    const bus = createBus()
    let reader = null, compose = null, composeWaiters = [], gone = false
    const mount = async (dTag, container, onGone) => {
      const n = firstParty(dTag)
      const r = await openNapplet({
        html: n.html, name: n.dTag, title: n.title, firstParty: true, domains: n.domains, container, grants,
        consent: async () => null, // first-party: never asked
        makeDeps: saveGrant => shellDeps(liveCtx, { ask: async () => false, saveGrant, bus }),
        onRevoke: why => { onGone(); if (!gone && why !== "closed by shell") setNote(`${n.title} closed: ${why}.`) },
      })
      return r.mounted
    }
    // Compose: mounted in the sheet on the first ask, kept while the sheet is open.
    const openCompose = () => new Promise((resolve, reject) => {
      if (compose) return resolve(whenReady(compose))
      composeWaiters.push({ resolve, reject })
      setComposing(true)
    })
    live.current = {
      bus,
      mountCompose: async container => {
        try {
          compose = await mount(COMPOSE_DTAG, container, () => { compose = null })
          const napplet = await whenReady(compose)
          composeWaiters.splice(0).forEach(w => w.resolve(napplet))
        } catch (e) { composeWaiters.splice(0).forEach(w => w.reject(e)) }
      },
      closeCompose: () => { compose?.close(); compose = null; setComposing(false); setComposeAside(false) },
    }
    const watched = new Set() // the notes whose Like and zaps the Reader asked about (napplet:note/stats)
    const wire = readerIntents({
      bus, openCompose,
      fullCompose: fullCompose ? (mode, ev) => { if (ev) composeFull(mode, ev); else location.hash = "#/compose" } : null,
      onComposeDone: () => live.current?.closeCompose(),
      onComposeWaiting: () => setComposeAside(true),
      onComposeUndone: () => setComposeAside(false),
      openUrl: url => window.open(url, "_blank", "noopener,noreferrer"),
      verify: verifyEvent,
      onRepost: n => repostWithUndo(liveCtx, n),
      onZap: n => setSheet({ kind: "zap", note: n }),
      onMenu: n => setSheet({ kind: "menu", note: n }),
      onMedia: v => setSheet({ kind: "media", ...v }),
      card: ev => kindCard(liveCtx, ev),
      vote: (ev, picks) => pollVote(liveCtx, ev, picks),
      onArticle: ev => setSheet({ kind: "article", event: ev }),
      onProfile: pk => { location.hash = `#/profile/${pk}` },
      stats: note => { watched.add(note.id); loadSent(liveCtx, note.id); wantTotals(liveCtx, note.id); return statsNow(note.id) },
      like: (note, emoji) => {
        if (liveCtx.signer?.readOnly) return READ_ONLY_SHORT
        likeWithFeedback(liveCtx, note, emoji === undefined ? undefined : pickFor(actionState(note.id).like === "sent" ? displayEmoji(reactionOf(note.id)) : null, emoji))
        return ""
      },
      // The desktop's keys and hover card over the frame (napplet-keys.js): handed to the page as events.
      onKey: p => { const k = nappletKey(p); if (k) dispatchEvent(new CustomEvent(NAPPLET_KEY_EVENT, { detail: k })) },
      onHover: p => { const h = pageHover(p, host.current?.querySelector("iframe")?.getBoundingClientRect()); if (h) dispatchEvent(new CustomEvent(PEEK_EVENT, { detail: h })) },
      onCtx: p => { const m = pageMenu(p, host.current?.querySelector("iframe")?.getBoundingClientRect(), ev => likedNote(ev, verifyEvent)); if (m) dispatchEvent(new CustomEvent(CTX_EVENT, { detail: m })) },
      beside: besideRef.current ? id => !!besideRef.current?.(id) : null,
      outside: id => outsideReplies(id, shellDeps(liveCtx, { ask: async () => false, saveGrant: () => {}, bus, storage: null })),
      webPeople: () => webPeopleOf(liveCtx),
      preview: loadPreview,
    })
    live.current.me = wire.me
    // Your own profile in the Reader (plan step 5, reader-mine.js): what only the shell holds, and its own screens.
    const mineChanged = () => bus.emit(wire.me, MINE_TOPIC, {})
    live.current.mineChanged = mineChanged
    let askedFollowers = false
    // Your bookmarks in the Reader (plan step 6a, reader-bookmarks.js): the list opened here, signed notes handed over.
    const offBookmarks = bookmarkIntents({
      bus, me: wire.me, verify: verifyEvent, onChange: onBookmarks,
      read: async () => {
        const s = await loadBookmarks(liveCtx)
        const relays = uniq([...liveCtx.account.relays.read, ...DEFAULT_RELAYS])
        const [pub, priv] = await Promise.all([fetchEntries(liveCtx, bookmarkEntries(s.event?.tags ?? []), relays), fetchEntries(liveCtx, [...s.privateSet], relays)])
        return { public: pub, private: priv, privateNote: s.privateNote }
      },
    })
    notifPipe.tell = () => bus.emit(wire.me, NOTIF_TOPIC, {})
    const offNotif = notifIntents({
      bus,
      answer: filter => {
        const l = notifPipe.list
        if (!l) return null
        const h = { me: liveCtx.session.pubkey, notes: l.notes, unreadSince: l.unreadSince, known: l.known, profileOf: getProfile, verbOf: notifVerb, whoOf: whoText, aboutOf: aboutPreview, aboutYourPost }
        return notifAnswer(l, filter, h, rowHref)
      },
      more: () => notifPipe.list?.loadMore(),
      open: to => { location.hash = to },
    })
    const offMine = mineIntents({
      bus,
      profile: async () => {
        const me = liveCtx.session.pubkey
        if (!getProfile(me)) await fetchProfiles(liveCtx.vault, [me], uniq([...liveCtx.account.relays.read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS])).catch(() => {})
        if (!askedFollowers && keptFollowers(me) == null) { askedFollowers = true; fetchFollowers(me, mineChanged).catch(() => {}) }
        return { me, npub: npubEncode(me), profile: getProfile(me), follows: liveCtx.account.follows.length, followers: keptFollowers(me) ?? null, readOnly: !!liveCtx.signer?.readOnly }
      },
      shop: () => fetchShop(liveCtx.session.pubkey, uniq([...liveCtx.account.relays.write, ...DEFAULT_RELAYS])),
      priceOf: priceLabel,
      onEdit: () => setSheet({ kind: "edit" }),
      onShare: () => setSheet({ kind: "share" }),
      onListing: listing => setSheet({ kind: "listing", listing }),
      onPage: to => { location.hash = to },
      copy: text => navigator.clipboard.writeText(text),
    })
    // Your Like and the zap totals, pushed to the Reader as they change (note-stats.js), for the notes it asked about.
    const push = id => { if (watched.has(id)) bus.emit(wire.me, STATS_TOPIC, statsNow(id)) }
    const offStats = [onActionState(push), onZapTotals(push)]
    // j/k/Enter/r/l/z for the Reader's rows (the shell has none to move along): passed in while this pane is shown.
    const rowCmd = e => { if (!host.current?.closest("[hidden]") && ROW_CMDS.has(e.detail?.cmd)) bus.emit(wire.me, ROW_TOPIC, { cmd: e.detail.cmd }) }
    if (keys) addEventListener(READER_CMD_EVENT, rowCmd)
    // A note the full composer sent (fullCompose): the Reader shows it at once, as it does one from the Compose napplet.
    const sentNote = e => { if (e.detail?.id) bus.emit(wire.me, COMPOSE_SENT, { event: e.detail }) }
    if (fullCompose) addEventListener(NOTE_SENT_EVENT, sentNote)
    ;(async () => {
      try {
        reader = await mount(READER_DTAG, host.current, () => { reader = null })
        if (gone) return reader.close()
        const readerNapplet = await whenReady(reader)
        const offs = ["note", "profile", "feed"].map(archetype => bus.register({ id: "nv-reader", title: "Reader", archetype, actions: archetype === "note" ? ["open", "removed"] : ["open"], conventions: [], open: async () => readerNapplet }))
        live.current.reader = { offs }
        if (openRef.current) bus.invoke(wire.me, openRef.current)
        if (openIdRef.current) bus.emit(wire.me, OPEN_TOPIC, { id: openIdRef.current })
      } catch (e) { if (!gone) setNote(`The Reader couldn't open: ${e?.message ?? e}`) }
    })()
    return () => { removeEventListener(READER_CMD_EVENT, rowCmd); removeEventListener(NOTE_SENT_EVENT, sentNote); gone = true; offStats.forEach(f => f()); offMine(); offBookmarks(); offNotif(); notifPipe.tell = () => {}; wire.close(); live.current?.reader?.offs.forEach(f => f()); reader?.close(); compose?.close(); live.current = null }
  }, [ctx.session.pubkey, ctx.vault, ctx.signer, grants])

  // The note open beside the list, marked in it (nv.note.open); "" when the side pane closes.
  const openIdRef = useRef(openId)
  openIdRef.current = openId
  useEffect(() => { const l = live.current; if (l?.reader) l.bus.emit(l.me, OPEN_TOPIC, { id: openId || "" }) }, [openId])

  // A new address (another thread or profile) while the Reader is up: hand it over instead of mounting again.
  const opened = useRef(JSON.stringify(open))
  useEffect(() => {
    const key = JSON.stringify(open)
    if (key === opened.current) return
    opened.current = key
    const l = live.current
    if (l?.reader) l.bus.invoke(l.me, open ?? { archetype: "feed", action: "open", payload: {} })
  }, [open])

  return (
    <main class="screen reader-pane" hidden={hidden}>
      {note && <p class="muted small napplet-note" role="status">{note}</p>}
      <div class="napplet-host reader-host" ref={host} />
      {sheet?.kind === "zap" && <ZapSheet ctx={ctx} note={sheet.note} onClose={() => setSheet(null)} />}
      {sheet?.kind === "menu" && <MenuSheet ctx={ctx} note={sheet.note} onClose={() => setSheet(null)}
        onDeleted={id => { const l = live.current; if (l?.reader) l.bus.invoke(l.me, { archetype: "note", action: "removed", payload: { id } }) }} />}
      {sheet?.kind === "article" && <div class="reader-article screen"><ArticleReader event={sheet.event} ctx={ctx} onBack={() => setSheet(null)} /></div>}
      {/* Your profile's own screens (reader-mine.js), over the Reader as an article is: Edit Profile signs in the shell. */}
      {sheet?.kind === "edit" && <div class="reader-article screen"><EditProfile ctx={ctx} onClose={() => { setSheet(null); live.current?.mineChanged?.() }} /></div>}
      {sheet?.kind === "listing" && <div class="reader-article screen"><ListingView ctx={ctx} listing={sheet.listing} onBack={() => setSheet(null)} /></div>}
      {sheet?.kind === "share" && <ShareProfileSheet pubkey={ctx.session.pubkey} own onClose={() => setSheet(null)} />}
      {sheet?.kind === "media" && <MediaLightbox items={sheet.items} author={sheet.author} start={sheet.start} onClose={() => setSheet(null)} />}
      {notifications && <ReaderNotifSource ctx={ctx} pipe={notifPipe} />}
      {composing && <ComposeSheet aside={composeAside} onClose={() => live.current?.closeCompose()} onMount={el => live.current?.mountCompose(el)} />}
    </main>
  )
}

/** Compose's sheet: a modal <dialog> that closes (not unmounts) while a post counts down, so the page behind it, with
 *  the Send Delay pill and its Undo, can be used; a closed <dialog> keeps its frame, so Undo brings the text back. */
function ComposeSheet({ aside, onClose, onMount }) {
  const ref = useRef(null)
  useEffect(() => { const d = ref.current; if (!d) return; if (aside) { if (d.open) d.close() } else if (!d.open) d.showModal() }, [aside])
  return (
    <dialog ref={ref} class="mod-dialog" aria-label="Compose" onCancel={e => { e.preventDefault(); onClose() }}>
      <ComposeMount onMount={onMount} />
    </dialog>
  )
}

function ComposeMount({ onMount }) {
  const ref = useRef(null)
  useEffect(() => { onMount(ref.current) }, [])
  return <div class="napplet-host compose-napplet-host" ref={ref} />
}

/** napplet:note/card: an article, highlight or poll card's strings, from the signed event (kind-cards.js). A poll's
 *  votes are read as the classic card reads them (poll-votes.js), blocked people left out. */
async function kindCard(ctx, ev) {
  if (ev.kind === 30023) return articleCard(ev)
  if (ev.kind === 9802) return highlightCard(ev)
  const poll = parsePoll(ev)
  if (!poll) return null
  const votes = votesFresh(poll.id) ? heldVotes(poll.id) : await loadVotes(poll, [...(ctx.account?.relays?.read ?? [])])
  return pollCard(ev, votes, { me: ctx.session?.pubkey ?? "", blocked: getBlocks().blocked })
}

/** napplet:poll/vote: the classic vote, then the card again with it counted. */
async function pollVote(ctx, ev, picks) {
  if (ctx.signer?.readOnly) throw new Error(READ_ONLY_SHORT)
  const poll = parsePoll(ev)
  if (!poll || isClosed(poll)) throw new Error("This poll is closed.")
  await sendVote(ctx, poll, picks)
  return pollCard(ev, heldVotes(poll.id), { me: ctx.session?.pubkey ?? "", blocked: getBlocks().blocked })
}

/** A note's Like and zap total as the classic card has them now (note-stats.js). */
const statsNow = id => statsOf(id, { state: actionState(id), reaction: reactionOf(id), total: zapTotal(id) }, displayEmoji)

// napplet:web/people: your web as the classic Global names it in its first filter (readers/trust.js), worked out once
// per account and follow count and kept for ten minutes (it asks every follow's follow list).
let webCache = null // { key, at, people: Promise<string[]> }
function webPeopleOf(ctx) {
  const me = ctx.session.pubkey, follows = [...(ctx.account.follows ?? [])]
  const key = `${me}:${follows.length}`
  if (webCache?.key !== key || Date.now() - webCache.at > 10 * 60_000) {
    webCache = { key, at: Date.now(), people: globalTrust(me, follows).then(t => (t ? [...t].sort().slice(0, TRUSTED_AUTHORS_CAP) : [])).catch(() => []) }
  }
  return webCache.people
}
