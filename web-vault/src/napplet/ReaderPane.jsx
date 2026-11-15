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
import { readerIntents } from "./reader-intents.js"
import { useLiveCtx } from "./usePaneNapplet.js"
import { verifyEvent } from "nostr-tools/pure"
import { repostWithUndo } from "../components/repost-undo.js"
import { ZapSheet, MenuSheet } from "./NoteSheets.jsx"
import { loadPreview } from "../components/link-preview.js"
import { NAPPLET_KEY_EVENT, PEEK_EVENT, READER_CMD_EVENT, ROW_CMDS, ROW_TOPIC, nappletKey, pageHover } from "./napplet-keys.js"
import { MediaLightbox } from "../components/MediaLightbox.jsx"
import { ArticleReader } from "../readers/ArticlesScreen.jsx"
import { articleCard, highlightCard, pollCard } from "./kind-cards.js"
import { heldVotes, loadVotes, sendVote, votesFresh } from "../components/poll-votes.js"
import { isClosed, parsePoll } from "../components/polls.js"
import { getBlocks } from "../net/blocks.js"
import { READ_ONLY_SHORT } from "../signer/readonly.js"
import { actionState, loadSent, onActionState, reactionOf } from "../net/actions.js"
import { onZapTotals, wantTotals, zapTotal } from "../net/zaps.js"
import { displayEmoji, likeWithFeedback, pickFor } from "../components/ReactionButton.jsx"
import { STATS_TOPIC, statsOf } from "./note-stats.js"
import "./napplet.css"

const READY_WAIT_MS = 5000
const whenReady = async m => { await Promise.race([m.napplet.ready, new Promise(r => setTimeout(r, READY_WAIT_MS))]); return m.napplet }

export function ReaderPane({ ctx, open = null, hidden = false }) {
  const host = useRef(null), composeHost = useRef(null)
  const [composing, setComposing] = useState(false)
  const [composeAside, setComposeAside] = useState(false) // a post counting down: the sheet steps aside, still mounted
  const [note, setNote] = useState("")
  const [sheet, setSheet] = useState(null) // { kind: "zap" | "menu", note }
  const grants = useMemo(() => grantStore(localStorage, ctx.session.pubkey), [ctx.session.pubkey])
  const liveCtx = useLiveCtx(ctx)
  const live = useRef(null) // { bus, me, reader }
  const openRef = useRef(open)
  openRef.current = open

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
      preview: loadPreview,
    })
    live.current.me = wire.me
    // Your Like and the zap totals, pushed to the Reader as they change (note-stats.js), for the notes it asked about.
    const push = id => { if (watched.has(id)) bus.emit(wire.me, STATS_TOPIC, statsNow(id)) }
    const offStats = [onActionState(push), onZapTotals(push)]
    // j/k/Enter/r/l/z for the Reader's rows (the shell has none to move along): passed in while this pane is shown.
    const rowCmd = e => { if (!host.current?.closest("[hidden]") && ROW_CMDS.has(e.detail?.cmd)) bus.emit(wire.me, ROW_TOPIC, { cmd: e.detail.cmd }) }
    addEventListener(READER_CMD_EVENT, rowCmd)
    ;(async () => {
      try {
        reader = await mount(READER_DTAG, host.current, () => { reader = null })
        if (gone) return reader.close()
        const readerNapplet = await whenReady(reader)
        const offs = ["note", "profile", "feed"].map(archetype => bus.register({ id: "nv-reader", title: "Reader", archetype, actions: archetype === "note" ? ["open", "removed"] : ["open"], conventions: [], open: async () => readerNapplet }))
        live.current.reader = { offs }
        if (openRef.current) bus.invoke(wire.me, openRef.current)
      } catch (e) { if (!gone) setNote(`The Reader couldn't open: ${e?.message ?? e}`) }
    })()
    return () => { removeEventListener(READER_CMD_EVENT, rowCmd); gone = true; offStats.forEach(f => f()); wire.close(); live.current?.reader?.offs.forEach(f => f()); reader?.close(); compose?.close(); live.current = null }
  }, [ctx.session.pubkey, ctx.vault, ctx.signer, grants])

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
      {sheet?.kind === "media" && <MediaLightbox items={sheet.items} author={sheet.author} start={sheet.start} onClose={() => setSheet(null)} />}
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
